#!/usr/bin/env bash
# Static and synthetic regression for OCI cloud-image FORWARD REJECT
# normalization. Never runs iptables, nft, ufw, or SSH. Never contacts OCI.
set -euo pipefail

export PYTHONDONTWRITEBYTECODE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

cleanup() {
  rm -rf "$ROOT/ansible/roles/microk8s/files/__pycache__"
}
trap cleanup EXIT

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True

ROOT = Path(sys.argv[1]).resolve()
HELPER = (
    ROOT
    / "ansible/roles/microk8s/files/normalize_oci_forward_reject.py"
)
TASKS = ROOT / "ansible/roles/microk8s/tasks/main.yml"
README = ROOT / "ansible/README.md"
V2_DOC = ROOT / "docs/V2_CLEAN_ROOM_DEPLOYMENT.md"
CHANGELOG = ROOT / "CHANGELOG.md"
WORKFLOW = ROOT / ".github/workflows/repository-validation.yml"

FORWARD_REJECT = "-A FORWARD -j REJECT --reject-with icmp-host-prohibited"
INPUT_REJECT = "-A INPUT -j REJECT --reject-with icmp-host-prohibited"
OUTPUT_JUMP = "-A OUTPUT -d 169.254.0.0/16 -j InstanceServices"
SIMILAR_FORWARD = (
    "-A FORWARD -s 192.0.2.0/24 -j REJECT --reject-with icmp-host-prohibited"
)
INSTANCE_SERVICES_RULE = (
    "-A InstanceServices -d 169.254.169.254/32 -p tcp -m tcp --dport 80 "
    "-j ACCEPT"
)


def load_helper():
    spec = importlib.util.spec_from_file_location(
        "normalize_oci_forward_reject", HELPER
    )
    if spec is None or spec.loader is None:
        raise SystemExit("unable to load FORWARD REJECT helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_helper()


def oci_rules(
    *,
    include_forward_reject: bool = True,
    extra_forward: str | None = None,
) -> str:
    forward_block = ""
    if include_forward_reject:
        forward_block += FORWARD_REJECT + "\n"
    if extra_forward is not None:
        forward_block += extra_forward + "\n"
    return (
        "# CLOUD_IMG: This file was created/modified by the Cloud Image "
        "build process\n"
        "# iptables configuration for Oracle Cloud Infrastructure\n"
        "*filter\n"
        ":INPUT ACCEPT [0:0]\n"
        ":FORWARD ACCEPT [0:0]\n"
        ":OUTPUT ACCEPT [0:0]\n"
        ":InstanceServices - [0:0]\n"
        "-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
        "-A INPUT -p icmp -j ACCEPT\n"
        "-A INPUT -i lo -j ACCEPT\n"
        "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT\n"
        f"{INPUT_REJECT}\n"
        f"{forward_block}"
        f"{OUTPUT_JUMP}\n"
        f"{INSTANCE_SERVICES_RULE}\n"
        "-A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 53 "
        "-j ACCEPT\n"
        "COMMIT\n"
    )


def unexpected_rules() -> str:
    return (
        "*filter\n"
        ":INPUT ACCEPT [0:0]\n"
        ":FORWARD ACCEPT [0:0]\n"
        ":OUTPUT ACCEPT [0:0]\n"
        f"{FORWARD_REJECT}\n"
        "COMMIT\n"
    )


def run_cli(path: Path, *, dry_run: bool = False) -> subprocess.CompletedProcess[str]:
    argv = [sys.executable, str(HELPER), "--rules-file", str(path)]
    if dry_run:
        argv.append("--dry-run")
    return subprocess.run(argv, check=False, capture_output=True, text=True)


def expect_error(text: str, code: int) -> str:
    try:
        helper.normalize_rules_text(text)
    except helper.NormalizeError as exc:
        if exc.code != code:
            raise SystemExit(
                f"expected exit {code}, got {exc.code}: {exc}"
            ) from exc
        return str(exc)
    raise SystemExit("expected NormalizeError")


# --- CASE 1: OCI baseline with the exact bad FORWARD REJECT ---

case1 = oci_rules()
normalized, removed = helper.normalize_rules_text(case1)
if removed != 1:
    raise SystemExit(f"CASE 1: expected 1 removal, got {removed}")
if FORWARD_REJECT in {
    line.strip() for line in normalized.splitlines()
}:
    raise SystemExit("CASE 1: exact FORWARD REJECT still present")
if INPUT_REJECT not in normalized:
    raise SystemExit("CASE 1: INPUT REJECT was not preserved")
if ":InstanceServices" not in normalized:
    raise SystemExit("CASE 1: InstanceServices chain was not preserved")
if OUTPUT_JUMP not in normalized:
    raise SystemExit("CASE 1: OUTPUT jump to InstanceServices was not preserved")
if INSTANCE_SERVICES_RULE not in normalized:
    raise SystemExit("CASE 1: InstanceServices rule was not preserved")
if "# CLOUD_IMG:" not in normalized:
    raise SystemExit("CASE 1: CLOUD_IMG marker was not preserved")
if "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT" not in normalized:
    raise SystemExit("CASE 1: SSH INPUT accept was not preserved")
if FORWARD_REJECT not in case1:
    raise SystemExit("CASE 1 fixture must contain the bad rule")
print("PASS: CASE 1 OCI baseline exact FORWARD REJECT is removed")


# --- CASE 2: already normalized OCI baseline ---

case2 = oci_rules(include_forward_reject=False)
normalized2, removed2 = helper.normalize_rules_text(case2)
if removed2 != 0:
    raise SystemExit(f"CASE 2: expected no removal, got {removed2}")
if normalized2 != case2:
    raise SystemExit("CASE 2: already-normalized file must be byte-identical")
print("PASS: CASE 2 already-normalized OCI baseline is a no-op")


# --- CASE 3: rules.v4 absent ---

with tempfile.TemporaryDirectory() as tmp:
    missing = Path(tmp) / "rules.v4"
    action = helper.normalize_rules_file(missing, write=True)
    if action != "absent":
        raise SystemExit(f"CASE 3: expected absent, got {action}")
    if missing.exists():
        raise SystemExit("CASE 3: absent path must not create a rules file")
    backup = missing.with_name(missing.name + helper.BACKUP_SUFFIX)
    if backup.exists():
        raise SystemExit("CASE 3: absent path must not create a backup")
    cli = run_cli(missing)
    if cli.returncode != 0 or cli.stdout.strip() != "absent":
        raise SystemExit(
            f"CASE 3 CLI failed: rc={cli.returncode} out={cli.stdout!r} "
            f"err={cli.stderr!r}"
        )
print("PASS: CASE 3 absent rules.v4 is a safe no-op")


# --- CASE 4: unexpected / non-OCI rules.v4 ---

message4 = expect_error(unexpected_rules(), helper.EXIT_UNEXPECTED)
if "refusing to modify unexpected firewall file" not in message4:
    raise SystemExit(f"CASE 4: missing fail-closed diagnostic: {message4}")
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "rules.v4"
    original = unexpected_rules()
    path.write_text(original, encoding="utf-8")
    cli = run_cli(path)
    if cli.returncode != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"CASE 4 CLI expected rc 2, got {cli.returncode}")
    if path.read_text(encoding="utf-8") != original:
        raise SystemExit("CASE 4: unexpected file must not be rewritten")
    backup = path.with_name(path.name + helper.BACKUP_SUFFIX)
    if backup.exists():
        raise SystemExit("CASE 4: unexpected file must not create a backup")
print("PASS: CASE 4 unexpected rules.v4 fails closed")


# --- CASE 5: similarly named but non-exact FORWARD rule ---

case5 = oci_rules(include_forward_reject=False, extra_forward=SIMILAR_FORWARD)
normalized5, removed5 = helper.normalize_rules_text(case5)
if removed5 != 0:
    raise SystemExit("CASE 5: non-exact FORWARD REJECT must not be deleted")
if SIMILAR_FORWARD not in normalized5:
    raise SystemExit("CASE 5: similar FORWARD rule was lost")
if normalized5 != case5:
    raise SystemExit("CASE 5: non-exact file must remain byte-identical")

case5b = oci_rules(include_forward_reject=True, extra_forward=SIMILAR_FORWARD)
normalized5b, removed5b = helper.normalize_rules_text(case5b)
if removed5b != 1:
    raise SystemExit("CASE 5b: only the exact FORWARD REJECT must be removed")
if SIMILAR_FORWARD not in normalized5b:
    raise SystemExit("CASE 5b: similar FORWARD rule must be retained")
if FORWARD_REJECT in {line.strip() for line in normalized5b.splitlines()}:
    raise SystemExit("CASE 5b: exact FORWARD REJECT still present")
print("PASS: CASE 5 non-exact FORWARD rules are not deleted")


# --- CASE 6: preservation of INPUT / InstanceServices / OUTPUT jump ---

preserved_needles = (
    INPUT_REJECT,
    OUTPUT_JUMP,
    INSTANCE_SERVICES_RULE,
    ":InstanceServices - [0:0]",
    "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT",
)
for needle in preserved_needles:
    if needle not in normalized:
        raise SystemExit(f"CASE 6: missing preserved line: {needle}")
print("PASS: CASE 6 INPUT REJECT, InstanceServices, and OUTPUT jump retained")


# --- CLI write + idempotent second run + stable backup ---

with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "rules.v4"
    original = oci_rules()
    path.write_text(original, encoding="utf-8")
    first = run_cli(path)
    if first.returncode != 0 or first.stdout.strip() != "removed":
        raise SystemExit(
            f"CLI write failed: rc={first.returncode} out={first.stdout!r} "
            f"err={first.stderr!r}"
        )
    written = path.read_text(encoding="utf-8")
    if FORWARD_REJECT in {line.strip() for line in written.splitlines()}:
        raise SystemExit("CLI write left the exact FORWARD REJECT in place")
    backup = path.with_name(path.name + helper.BACKUP_SUFFIX)
    if not backup.exists():
        raise SystemExit("CLI write must create a one-time backup")
    if backup.read_text(encoding="utf-8") != original:
        raise SystemExit("backup must contain the original rules file")
    backup_mtime = backup.stat().st_mtime_ns
    second = run_cli(path)
    if second.returncode != 0 or second.stdout.strip() != "unchanged":
        raise SystemExit(
            f"CLI second run expected unchanged: rc={second.returncode} "
            f"out={second.stdout!r}"
        )
    if path.read_text(encoding="utf-8") != written:
        raise SystemExit("CLI second run mutated an already-normalized file")
    if backup.stat().st_mtime_ns != backup_mtime:
        raise SystemExit("CLI second run must not rewrite the stable backup")
    dry = run_cli(Path(tmp) / "rules.v4", dry_run=True)
    if dry.returncode != 0 or dry.stdout.strip() != "unchanged":
        raise SystemExit("dry-run of normalized file must report unchanged")
print("PASS: CLI write, backup, and second-run idempotency")


# --- fail-closed variants ---

almost_oci = oci_rules().replace("Oracle Cloud Infrastructure", "Example Cloud")
expect_error(almost_oci, helper.EXIT_UNEXPECTED)
expect_error(oci_rules().replace(INPUT_REJECT, ""), helper.EXIT_UNEXPECTED)
expect_error(oci_rules().replace(OUTPUT_JUMP, "-A OUTPUT -j ACCEPT"), helper.EXIT_UNEXPECTED)
print("PASS: incomplete OCI lookalikes fail closed")


# --- repository contract ---

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


tasks = read(TASKS)
helper_src = read(HELPER)

if "normalize_oci_forward_reject.py" not in tasks:
    raise SystemExit("microk8s role must invoke the FORWARD REJECT helper")
for register_name in (
    "microk8s_oci_forward_reject_file",
    "microk8s_iptables_nft_stat",
    "microk8s_oci_forward_reject_check",
    "microk8s_oci_forward_reject_delete",
):
    if f"register: {register_name}" not in tasks:
        raise SystemExit(f"missing role-prefixed register {register_name}")
for match in re.finditer(r"(?m)^\s+register:\s+(\S+)\s*$", tasks):
    var = match.group(1)
    if not var.startswith("microk8s_"):
        raise SystemExit(f"register {var} must use the microk8s_ role prefix")
if "/etc/iptables/rules.v4" not in tasks:
    raise SystemExit("persistent normalization must target /etc/iptables/rules.v4")
if "/usr/sbin/iptables-nft" not in tasks:
    raise SystemExit("runtime normalization must use /usr/sbin/iptables-nft")
if "iptables-legacy" in tasks and "are not modified" not in tasks:
    raise SystemExit("role must not mutate iptables-legacy")

install_idx = tasks.find("Install MicroK8s from the pinned snap channel")
ready_idx = tasks.find("Wait for MicroK8s to become ready")
helper_idx = tasks.find("Normalize persistent OCI cloud-image IPv4 FORWARD REJECT")
runtime_idx = tasks.find("Delete nft-compatible unconditional IPv4 FORWARD REJECT")
if min(install_idx, ready_idx, helper_idx, runtime_idx) < 0:
    raise SystemExit("microk8s role is missing required FORWARD/MicroK8s tasks")
if not (helper_idx < runtime_idx < install_idx < ready_idx):
    raise SystemExit(
        "OCI FORWARD normalization must run before MicroK8s install/readiness"
    )

if re.search(r'(?m)^\s+-\s+(-n|--line-numbers)\s*$', tasks):
    raise SystemExit("runtime deletion must not use numeric line numbers")
if re.search(r'(?m)^\s+-\s+(-F|-X|--flush)\s*$', tasks):
    raise SystemExit("role must not flush iptables chains")
if "iptables-restore" in tasks:
    raise SystemExit("role must not restore a full iptables table")
if "ufw disable" in tasks or "state: disabled" in tasks:
    raise SystemExit("role must not disable UFW")
if "10.152.183.1" in tasks or "10.1.118" in tasks:
    raise SystemExit("role must not hard-code Kubernetes Service or pod IPs")

check_spec = (
    "-C",
    "FORWARD",
    "-j",
    "REJECT",
    "--reject-with",
    "icmp-host-prohibited",
)
delete_spec = (
    "-D",
    "FORWARD",
    "-j",
    "REJECT",
    "--reject-with",
    "icmp-host-prohibited",
)
for token in check_spec + delete_spec:
    if token not in tasks:
        raise SystemExit(f"runtime tasks missing semantic token {token}")
print("PASS: Ansible task ordering and semantic nft -C/-D contract")

if re.search(r"\b(subprocess|os\.system|os\.popen|Popen)\b", helper_src):
    raise SystemExit("helper must not spawn processes")
if re.search(
    r"""['\"](/sbin/|/usr/sbin/|/usr/bin/)?(iptables|ip6tables|nft|ufw)""",
    helper_src,
):
    raise SystemExit("helper must not invoke firewall binaries")
if "10.152.183.1" in helper_src or "10.1.118" in helper_src:
    raise SystemExit("helper must not hard-code Kubernetes Service or pod IPs")
if re.search(r'(?m)^\s+.*\b(-F|--flush)\b', helper_src):
    raise SystemExit("helper must not flush firewall chains")
print("PASS: helper is file-only and does not call firewall binaries")

readme = read(README)
for needle in (
    "unconditional IPv4 FORWARD REJECT",
    "DEFAULT_FORWARD_POLICY",
    "InstanceServices",
    "/etc/iptables/rules.v4",
):
    if needle not in readme:
        raise SystemExit(f"ansible/README.md missing {needle}")
if "iptables -F" in readme and "Do not" not in readme:
    raise SystemExit("ansible/README.md must not recommend iptables flushing")
print("PASS: ansible README documents the OCI FORWARD contract")

v2 = read(V2_DOC)
v2_lower = v2.lower()
for needle in (
    "FORWARD REJECT",
    "no route to host",
    "CoreDNS",
    "metrics-server",
    "InstanceServices",
    "do not flush",
):
    if needle.lower() not in v2_lower:
        raise SystemExit(f"V2 clean-room doc missing {needle}")
print("PASS: V2 clean-room doc covers expected MicroK8s firewall state")

changelog = read(CHANGELOG)
unreleased = changelog.split("## [0.1.0]", 1)[0]
if "FORWARD REJECT" not in unreleased and "forwarding firewall" not in unreleased.lower():
    raise SystemExit("CHANGELOG [Unreleased] must mention the firewall fix")
print("PASS: CHANGELOG [Unreleased] records the firewall fix")

workflow = read(WORKFLOW)
if "test_ansible_oci_forward_reject_contract.sh" not in workflow:
    raise SystemExit("CI must run the OCI FORWARD REJECT contract test")
print("PASS: CI enforces the OCI FORWARD REJECT contract")

implementation_files = (TASKS, HELPER, README, V2_DOC)
forbidden_live = (
    "10.0.1.31",
    "10.152.183.1",
    "10.1.118",
    "frt2nffgchiv",
    "BEGIN PRIVATE KEY",
    "130.61.",
    "132.145.",
)
for path in implementation_files:
    text = read(path)
    for needle in forbidden_live:
        if needle in text:
            raise SystemExit(f"{path.relative_to(ROOT)} must not contain {needle}")
print("PASS: implementation files contain no live IP/OCID hard-codes")

compile(HELPER.read_text(encoding="utf-8"), str(HELPER), "exec")
print("PASS: FORWARD REJECT helper py_compile")
print("PASS: Ansible OCI FORWARD REJECT contract")
PY

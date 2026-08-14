#!/usr/bin/env bash
# Static and synthetic regression for OCI cloud-image MicroK8s firewall
# normalization (FORWARD reject removal + INPUT pod-API allow).
# Never runs iptables, nft, ufw, or SSH. Never contacts OCI.
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
    / "ansible/roles/microk8s/files/normalize_oci_microk8s_firewall.py"
)
TASKS = ROOT / "ansible/roles/microk8s/tasks/main.yml"
DEFAULTS = ROOT / "ansible/roles/microk8s/defaults/main.yml"
README = ROOT / "ansible/README.md"
V2_DOC = ROOT / "docs/V2_CLEAN_ROOM_DEPLOYMENT.md"
CHANGELOG = ROOT / "CHANGELOG.md"
WORKFLOW = ROOT / ".github/workflows/repository-validation.yml"

POD_CIDR = "10.1.0.0/16"
API_PORT = "16443"
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
ALLOW = (
    f"-A INPUT -s {POD_CIDR} -p tcp -m tcp --dport {API_PORT} -j ACCEPT"
)
SIMILAR_ALLOW = (
    "-A INPUT -s 192.0.2.0/24 -p tcp -m tcp --dport 16443 -j ACCEPT"
)


def load_helper():
    spec = importlib.util.spec_from_file_location(
        "normalize_oci_microk8s_firewall", HELPER
    )
    if spec is None or spec.loader is None:
        raise SystemExit("unable to load MicroK8s firewall helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_helper()


def oci_rules(
    *,
    include_forward_reject: bool = True,
    include_allow: bool = False,
    allow_after_reject: bool = False,
    extra_forward: str | None = None,
    extra_input_before_reject: str | None = None,
    duplicate_input_reject: bool = False,
) -> str:
    forward_block = ""
    if include_forward_reject:
        forward_block += FORWARD_REJECT + "\n"
    if extra_forward is not None:
        forward_block += extra_forward + "\n"
    before_reject = ""
    if include_allow and not allow_after_reject:
        before_reject += ALLOW + "\n"
    if extra_input_before_reject is not None:
        before_reject += extra_input_before_reject + "\n"
    after_reject = ""
    if include_allow and allow_after_reject:
        after_reject += ALLOW + "\n"
    second_reject = ""
    if duplicate_input_reject:
        second_reject = INPUT_REJECT + "\n"
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
        f"{before_reject}"
        f"{INPUT_REJECT}\n"
        f"{second_reject}"
        f"{after_reject}"
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
        f"{INPUT_REJECT}\n"
        "COMMIT\n"
    )


def run_cli(
    path: Path | None,
    *,
    dry_run: bool = False,
    plan_text: str | None = None,
    pod_cidr: str = POD_CIDR,
    apiserver_port: str = API_PORT,
) -> subprocess.CompletedProcess[str]:
    argv = [
        sys.executable,
        str(HELPER),
        "--pod-cidr",
        pod_cidr,
        "--apiserver-port",
        apiserver_port,
    ]
    if plan_text is not None:
        argv.append("--plan-input-runtime")
        return subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            input=plan_text,
        )
    if path is None:
        raise SystemExit("run_cli requires a path unless planning runtime")
    argv.extend(["--rules-file", str(path)])
    if dry_run:
        argv.append("--dry-run")
    return subprocess.run(argv, check=False, capture_output=True, text=True)


def expect_error(text: str, code: int, **kwargs) -> str:
    try:
        helper.normalize_rules_text(text, POD_CIDR, API_PORT, **kwargs)
    except helper.NormalizeError as exc:
        if exc.code != code:
            raise SystemExit(
                f"expected exit {code}, got {exc.code}: {exc}"
            ) from exc
        return str(exc)
    raise SystemExit("expected NormalizeError")


def allow_immediately_before_reject(text: str) -> bool:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    try:
        idx = lines.index(INPUT_REJECT)
    except ValueError:
        return False
    return idx > 0 and lines[idx - 1] == ALLOW


def preserved(text: str) -> None:
    for needle in (
        INPUT_REJECT,
        OUTPUT_JUMP,
        INSTANCE_SERVICES_RULE,
        ":InstanceServices - [0:0]",
        "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT",
    ):
        if needle not in text:
            raise SystemExit(f"missing preserved line: {needle}")


# --- CASE A: OCI baseline, allow absent, FORWARD reject present ---

case_a = oci_rules()
normalized_a, action_a = helper.normalize_rules_text(case_a, POD_CIDR, API_PORT)
if action_a != "changed":
    raise SystemExit(f"CASE A: expected changed, got {action_a}")
if FORWARD_REJECT in {line.strip() for line in normalized_a.splitlines()}:
    raise SystemExit("CASE A: exact FORWARD REJECT still present")
if not allow_immediately_before_reject(normalized_a):
    raise SystemExit("CASE A: allow is not immediately before INPUT REJECT")
preserved(normalized_a)
if "# CLOUD_IMG:" not in normalized_a:
    raise SystemExit("CASE A: CLOUD_IMG marker was not preserved")
print("PASS: CASE A OCI baseline inserts allow before INPUT REJECT and drops FORWARD REJECT")


# --- CASE B: already fully normalized ---

case_b = oci_rules(include_forward_reject=False, include_allow=True)
normalized_b, action_b = helper.normalize_rules_text(case_b, POD_CIDR, API_PORT)
if action_b != "unchanged":
    raise SystemExit(f"CASE B: expected unchanged, got {action_b}")
if normalized_b != case_b:
    raise SystemExit("CASE B: already-normalized file must be byte-identical")
print("PASS: CASE B already-normalized OCI baseline is a no-op")


# --- CASE C: allow exists after reject ---

case_c = oci_rules(
    include_forward_reject=False,
    include_allow=True,
    allow_after_reject=True,
)
normalized_c, action_c = helper.normalize_rules_text(case_c, POD_CIDR, API_PORT)
if action_c != "changed":
    raise SystemExit("CASE C: allow-after-reject must be corrected")
if not allow_immediately_before_reject(normalized_c):
    raise SystemExit("CASE C: allow was not moved before INPUT REJECT")
if sum(1 for line in normalized_c.splitlines() if line.strip() == ALLOW) != 1:
    raise SystemExit("CASE C: duplicate allow after reorder")
preserved(normalized_c)
print("PASS: CASE C allow-after-reject is reordered before INPUT REJECT")


# --- CASE D: non-OCI file ---

message_d = expect_error(unexpected_rules(), helper.EXIT_UNEXPECTED)
if "refusing to modify unexpected firewall file" not in message_d:
    raise SystemExit(f"CASE D: missing fail-closed diagnostic: {message_d}")
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "rules.v4"
    original = unexpected_rules()
    path.write_text(original, encoding="utf-8")
    cli = run_cli(path)
    if cli.returncode != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"CASE D CLI expected rc 2, got {cli.returncode}")
    if path.read_text(encoding="utf-8") != original:
        raise SystemExit("CASE D: unexpected file must not be rewritten")
print("PASS: CASE D unexpected rules.v4 fails closed")


# --- CASE E: rules.v4 absent ---

with tempfile.TemporaryDirectory() as tmp:
    missing = Path(tmp) / "rules.v4"
    action = helper.normalize_rules_file(
        missing, POD_CIDR, API_PORT, write=True
    )
    if action != "absent":
        raise SystemExit(f"CASE E: expected absent, got {action}")
    if missing.exists():
        raise SystemExit("CASE E: absent path must not create a rules file")
    cli = run_cli(missing)
    if cli.returncode != 0 or cli.stdout.strip() != "absent":
        raise SystemExit(
            f"CASE E CLI failed: rc={cli.returncode} out={cli.stdout!r}"
        )
print("PASS: CASE E absent rules.v4 is a safe no-op")


# --- CASE F: duplicate INPUT REJECT ---

case_f = oci_rules(duplicate_input_reject=True)
expect_error(case_f, helper.EXIT_UNEXPECTED)
print("PASS: CASE F duplicate INPUT REJECT fails closed")


# --- CASE G: preservation + similar non-exact rules retained ---

case_g = oci_rules(
    include_forward_reject=True,
    extra_forward=SIMILAR_FORWARD,
    extra_input_before_reject=SIMILAR_ALLOW,
)
normalized_g, action_g = helper.normalize_rules_text(case_g, POD_CIDR, API_PORT)
if action_g != "changed":
    raise SystemExit("CASE G: expected changed")
if SIMILAR_FORWARD not in normalized_g:
    raise SystemExit("CASE G: similar FORWARD rule was lost")
if SIMILAR_ALLOW not in normalized_g:
    raise SystemExit("CASE G: similar INPUT allow was lost")
if not allow_immediately_before_reject(normalized_g):
    raise SystemExit("CASE G: exact allow missing before INPUT REJECT")
preserved(normalized_g)
print("PASS: CASE G preservation and non-exact rules retained")


# --- PR #54 FORWARD-only already gone, allow missing ---

case_forward_gone = oci_rules(include_forward_reject=False, include_allow=False)
normalized_fg, action_fg = helper.normalize_rules_text(
    case_forward_gone, POD_CIDR, API_PORT
)
if action_fg != "changed":
    raise SystemExit("FORWARD-gone/allow-missing must insert the allow")
if FORWARD_REJECT in {line.strip() for line in normalized_fg.splitlines()}:
    raise SystemExit("FORWARD REJECT must remain absent")
if not allow_immediately_before_reject(normalized_fg):
    raise SystemExit("allow missing after FORWARD-only host state")
print("PASS: post-PR54 file without allow receives INPUT allow only")


# --- CLI write + idempotent second run ---

with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "rules.v4"
    original = oci_rules()
    path.write_text(original, encoding="utf-8")
    first = run_cli(path)
    if first.returncode != 0 or first.stdout.strip() != "changed":
        raise SystemExit(
            f"CLI write failed: rc={first.returncode} out={first.stdout!r} "
            f"err={first.stderr!r}"
        )
    written = path.read_text(encoding="utf-8")
    if not allow_immediately_before_reject(written):
        raise SystemExit("CLI write did not place allow before INPUT REJECT")
    backup = path.with_name(path.name + helper.BACKUP_SUFFIX)
    if not backup.exists() or backup.read_text(encoding="utf-8") != original:
        raise SystemExit("CLI write must create a one-time original backup")
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
print("PASS: CLI write, backup, and second-run idempotency")


# --- runtime planner ---

runtime_baseline = (
    "-P INPUT ACCEPT\n"
    "-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
    "-A INPUT -p icmp -j ACCEPT\n"
    "-A INPUT -i lo -j ACCEPT\n"
    "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT\n"
    f"{INPUT_REJECT}\n"
    "-A INPUT -j ufw-before-logging-input\n"
)
if helper.plan_input_runtime(runtime_baseline, POD_CIDR, API_PORT) != "ensure":
    raise SystemExit("runtime plan must ensure when allow is absent")

runtime_ok = runtime_baseline.replace(
    INPUT_REJECT, ALLOW + "\n" + INPUT_REJECT
)
if helper.plan_input_runtime(runtime_ok, POD_CIDR, API_PORT) != "unchanged":
    raise SystemExit("runtime plan must be unchanged when allow precedes REJECT")

runtime_after = runtime_baseline + ALLOW + "\n"
if helper.plan_input_runtime(runtime_after, POD_CIDR, API_PORT) != "ensure":
    raise SystemExit("runtime plan must ensure when allow follows REJECT")

runtime_dup_reject = runtime_baseline + INPUT_REJECT + "\n"
try:
    helper.plan_input_runtime(runtime_dup_reject, POD_CIDR, API_PORT)
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"runtime duplicate REJECT expected rc 2: {exc}")
else:
    raise SystemExit("runtime duplicate REJECT must fail closed")

plan_cli = run_cli(None, plan_text=runtime_ok)
if plan_cli.returncode != 0 or plan_cli.stdout.strip() != "unchanged":
    raise SystemExit(f"runtime plan CLI failed: {plan_cli.stdout!r} {plan_cli.stderr!r}")
print("PASS: runtime INPUT planner ordering contract")


# --- invalid CIDR / port ---

try:
    helper.build_allow_line("10.1.0.0/32", API_PORT)
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_USAGE:
        raise SystemExit(f"narrow CIDR expected usage error: {exc}")
else:
    raise SystemExit("host-sized CIDR must be rejected")
try:
    helper.build_allow_line(POD_CIDR, "not-a-port")
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_USAGE:
        raise SystemExit(f"bad port expected usage error: {exc}")
else:
    raise SystemExit("non-numeric API port must be rejected")
print("PASS: helper rejects host-sized CIDR and invalid API port")


# --- fail-closed lookalikes ---

almost_oci = oci_rules().replace("Oracle Cloud Infrastructure", "Example Cloud")
expect_error(almost_oci, helper.EXIT_UNEXPECTED)
expect_error(oci_rules().replace(INPUT_REJECT, ""), helper.EXIT_UNEXPECTED)
expect_error(oci_rules().replace(OUTPUT_JUMP, "-A OUTPUT -j ACCEPT"), helper.EXIT_UNEXPECTED)
print("PASS: incomplete OCI lookalikes fail closed")


# --- repository contract ---

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


tasks = read(TASKS)
defaults = read(DEFAULTS)
helper_src = read(HELPER)

if "normalize_oci_microk8s_firewall.py" not in tasks:
    raise SystemExit("microk8s role must invoke the firewall helper")
if 'microk8s_pod_cidr: "10.1.0.0/16"' not in defaults:
    raise SystemExit("defaults must set canonical MicroK8s 1.29 pod CIDR")
if 'microk8s_apiserver_port: "16443"' not in defaults:
    raise SystemExit("defaults must set MicroK8s API port 16443")
if "microk8s_pod_cidr | trim" not in tasks or "microk8s_apiserver_port | trim" not in tasks:
    raise SystemExit("tasks must pass pod CIDR and API port from role defaults")
if tasks.count("10.1.0.0/16") != 0:
    raise SystemExit("tasks must not hard-code the pod CIDR")
if re.search(r'(?m)^\s+-\s+"16443"\s*$', tasks):
    raise SystemExit("tasks must not bury 16443 as a literal argv value")

for register_name in (
    "microk8s_oci_firewall_file",
    "microk8s_iptables_nft_stat",
    "microk8s_oci_forward_reject_check",
    "microk8s_oci_forward_reject_delete",
    "microk8s_oci_input_save",
    "microk8s_oci_input_plan",
    "microk8s_oci_input_allow_delete",
    "microk8s_oci_input_allow_insert",
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
if " -S " not in tasks and "\n      - -S\n" not in tasks:
    if "-S" not in tasks:
        raise SystemExit("runtime INPUT plan must use iptables-nft -S")

install_idx = tasks.find("Install MicroK8s from the pinned snap channel")
ready_idx = tasks.find("Wait for MicroK8s to become ready")
ufw_idx = tasks.find("Enable UFW with the explicit MicroK8s-compatible host policy")
helper_idx = tasks.find("Normalize persistent OCI cloud-image IPv4 firewall for MicroK8s")
forward_idx = tasks.find("Delete nft-compatible unconditional IPv4 FORWARD REJECT")
input_idx = tasks.find("Insert nft-compatible INPUT pod-API allow")
if min(install_idx, ready_idx, ufw_idx, helper_idx, forward_idx, input_idx) < 0:
    raise SystemExit("microk8s role is missing required firewall/MicroK8s tasks")
if not (helper_idx < forward_idx < input_idx < ufw_idx < install_idx < ready_idx):
    raise SystemExit(
        "OCI firewall normalization must run before UFW enable and MicroK8s readiness"
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
if "--handle" in tasks or "nft delete" in tasks:
    raise SystemExit("runtime deletion must not use nft handles")

for token in (
    "-C",
    "FORWARD",
    "-D",
    "-I",
    "INPUT",
    "-j",
    "REJECT",
    "--reject-with",
    "icmp-host-prohibited",
    "ACCEPT",
    "--dport",
    "--plan-input-runtime",
):
    if token not in tasks:
        raise SystemExit(f"runtime tasks missing semantic token {token}")
print("PASS: Ansible task ordering and semantic nft contract")

if re.search(r"\b(subprocess|os\.system|os\.popen|Popen)\b", helper_src):
    raise SystemExit("helper must not spawn processes")
if re.search(
    r"""['\"](/sbin/|/usr/sbin/|/usr/bin/)?(iptables|ip6tables|nft|ufw)""",
    helper_src,
):
    raise SystemExit("helper must not invoke firewall binaries")
if "10.152.183.1" in helper_src or "10.1.118" in helper_src:
    raise SystemExit("helper must not hard-code Kubernetes Service or pod IPs")
if "10.1.0.0/16" in helper_src:
    raise SystemExit("helper must take pod CIDR as input, not hard-code it")
if re.search(r'(?m)^\s+.*\b(-F|--flush)\b', helper_src):
    raise SystemExit("helper must not flush firewall chains")
if "INPUT_REJECT" not in helper_src or "FORWARD_REJECT" not in helper_src:
    raise SystemExit("helper must retain both INPUT and FORWARD contracts")
print("PASS: helper is file/plan-only and does not call firewall binaries")

readme = read(README)
for needle in (
    "unconditional IPv4 FORWARD REJECT",
    "DEFAULT_FORWARD_POLICY",
    "InstanceServices",
    "/etc/iptables/rules.v4",
    "INPUT REJECT",
    "kube-proxy",
    "16443",
    "10.1.0.0/16",
):
    if needle not in readme:
        raise SystemExit(f"ansible/README.md missing {needle}")
if "iptables -F" in readme and "Do not" not in readme:
    raise SystemExit("ansible/README.md must not recommend iptables flushing")
print("PASS: ansible README documents FORWARD and INPUT contracts")

v2 = read(V2_DOC)
v2_lower = v2.lower()
for needle in (
    "FORWARD REJECT",
    "INPUT REJECT",
    "no route to host",
    "CoreDNS",
    "metrics-server",
    "InstanceServices",
    "do not flush",
    "kube-proxy",
    "16443",
):
    if needle.lower() not in v2_lower:
        raise SystemExit(f"V2 clean-room doc missing {needle}")
print("PASS: V2 clean-room doc covers both OCI firewall problems")

changelog = read(CHANGELOG)
unreleased = changelog.split("## [0.1.0]", 1)[0]
if "node-local" not in unreleased.lower() and "INPUT" not in unreleased:
    raise SystemExit("CHANGELOG [Unreleased] must mention the INPUT/API allow")
print("PASS: CHANGELOG [Unreleased] records the INPUT allow")

workflow = read(WORKFLOW)
if "test_ansible_oci_forward_reject_contract.sh" not in workflow:
    raise SystemExit("CI must run the OCI firewall contract test")
print("PASS: CI enforces the OCI firewall contract")

implementation_files = (TASKS, HELPER, README, V2_DOC, DEFAULTS)
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
print("PASS: firewall helper py_compile")
print("PASS: Ansible OCI MicroK8s firewall contract")
PY

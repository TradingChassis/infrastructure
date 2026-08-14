#!/usr/bin/env bash
# Static and synthetic regression for MicroK8s Calico UFW ownership.
# Never runs ufw, iptables, nft, or SSH. Never contacts OCI.
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
HELPER = ROOT / "ansible/roles/microk8s/files/verify_microk8s_calico_ufw.py"
TASKS = ROOT / "ansible/roles/microk8s/tasks/main.yml"
DEFAULTS = ROOT / "ansible/roles/microk8s/defaults/main.yml"
FIREWALL_HELPER = ROOT / "ansible/roles/microk8s/files/normalize_oci_microk8s_firewall.py"
UNIT = ROOT / "ansible/roles/microk8s/templates/tradingchassis-oci-microk8s-firewall.service.j2"
README = ROOT / "ansible/README.md"
V2_DOC = ROOT / "docs/V2_CLEAN_ROOM_DEPLOYMENT.md"
CHANGELOG = ROOT / "CHANGELOG.md"
WORKFLOW = ROOT / ".github/workflows/repository-validation.yml"

COMMENT = "MicroK8s Calico VXLAN inbound"


def load_helper():
    spec = importlib.util.spec_from_file_location("verify_microk8s_calico_ufw", HELPER)
    if spec is None or spec.loader is None:
        raise SystemExit("unable to load Calico UFW verification helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_helper()


def ufw_file(*, family: str, commented: bool, omit: str | None = None) -> str:
    if family == "ipv4":
        addr = "0.0.0.0/0"
        input_chain = "ufw-user-input"
        output_chain = "ufw-user-output"
    elif family == "ipv6":
        addr = "::/0"
        input_chain = "ufw6-user-input"
        output_chain = "ufw6-user-output"
    else:
        raise SystemExit(f"unknown UFW family {family}")
    rules = {
        "vxlan-in": (
            f"### tuple ### allow any any {addr} any {addr} in on vxlan.calico",
            f"-A {input_chain} -i vxlan.calico -j ACCEPT",
        ),
        "vxlan-out": (
            f"### tuple ### allow any any {addr} any {addr} out on vxlan.calico",
            f"-A {output_chain} -o vxlan.calico -j ACCEPT",
        ),
        "cali-in": (
            f"### tuple ### allow any any {addr} any {addr} in on cali+",
            f"-A {input_chain} -i cali+ -j ACCEPT",
        ),
        "cali-out": (
            f"### tuple ### allow any any {addr} any {addr} out on cali+",
            f"-A {output_chain} -o cali+ -j ACCEPT",
        ),
    }
    if commented:
        rules = {
            key: (
                header + f" comment={COMMENT}",
                body.replace(
                    " -j ACCEPT",
                    f' -m comment --comment "{COMMENT}" -j ACCEPT',
                ),
            )
            for key, (header, body) in rules.items()
        }
    body = ""
    for key, (header, line) in rules.items():
        if key == omit:
            continue
        body += header + "\n" + line + "\n"
    return (
        "*filter\n"
        f":{input_chain} - [0:0]\n"
        f":{output_chain} - [0:0]\n"
        "### RULES ###\n"
        f"{body}"
        "### END RULES ###\n"
        "COMMIT\n"
    )


def run_helper(user: str, user6: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        user_path = Path(tmp) / "user.rules"
        user6_path = Path(tmp) / "user6.rules"
        user_path.write_text(user, encoding="utf-8")
        user6_path.write_text(user6, encoding="utf-8")
        before = (user_path.stat().st_mtime_ns, user6_path.stat().st_mtime_ns)
        proc = subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--user-rules",
                str(user_path),
                "--user6-rules",
                str(user6_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        after = (user_path.stat().st_mtime_ns, user6_path.stat().st_mtime_ns)
        if before != after or user_path.read_text(encoding="utf-8") != user:
            raise SystemExit("verifier mutated persisted UFW rule files")
        if user6_path.read_text(encoding="utf-8") != user6:
            raise SystemExit("verifier mutated persisted IPv6 UFW rule files")
        return proc


def expect_ok(label: str, user: str, user6: str) -> None:
    proc = run_helper(user, user6)
    if proc.returncode != 0 or proc.stdout.strip() != "ok":
        raise SystemExit(
            f"{label}: expected ok, rc={proc.returncode} "
            f"stdout={proc.stdout!r} stderr={proc.stderr!r}"
        )


def expect_fail(label: str, user: str, user6: str, *needles: str) -> None:
    proc = run_helper(user, user6)
    if proc.returncode != helper.EXIT_UNEXPECTED:
        raise SystemExit(
            f"{label}: expected rc 2, got {proc.returncode} stderr={proc.stderr!r}"
        )
    if "missing MicroK8s Calico UFW allowances" not in proc.stderr:
        raise SystemExit(f"{label}: missing diagnostic: {proc.stderr!r}")
    for needle in needles:
        if needle not in proc.stderr:
            raise SystemExit(f"{label}: expected {needle!r} in {proc.stderr!r}")


plain4 = ufw_file(family="ipv4", commented=False)
plain6 = ufw_file(family="ipv6", commented=False)
commented4 = ufw_file(family="ipv4", commented=True)
commented6 = ufw_file(family="ipv6", commented=True)
extra4 = plain4.replace(
    "-A ufw-user-input -i vxlan.calico -j ACCEPT",
    "-A ufw-user-input -p all -i vxlan.calico -j ACCEPT",
)
LIVE4 = (
    "-A ufw-user-input -i vxlan.calico -j ACCEPT\n"
    "-A ufw-user-output -o vxlan.calico -j ACCEPT\n"
    "-A ufw-user-input -i cali+ -j ACCEPT\n"
    "-A ufw-user-output -o cali+ -j ACCEPT\n"
)
LIVE6 = (
    "-A ufw6-user-input -i vxlan.calico -j ACCEPT\n"
    "-A ufw6-user-output -o vxlan.calico -j ACCEPT\n"
    "-A ufw6-user-input -i cali+ -j ACCEPT\n"
    "-A ufw6-user-output -o cali+ -j ACCEPT\n"
)
expect_ok("MicroK8s uncommented rules", plain4, plain6)
expect_ok("TradingChassis commented rules", commented4, commented6)
expect_ok("mixed comment presentation", commented4, plain6)
expect_ok("harmless extra protocol token", extra4, plain6)
expect_ok("exact live IPv4 and IPv6 chain names", LIVE4, LIVE6)
expect_fail(
    "missing IPv4 vxlan in",
    ufw_file(family="ipv4", commented=False, omit="vxlan-in"),
    plain6,
    "ufw-user-input",
    "-i vxlan.calico",
)
expect_fail(
    "missing IPv6 cali out",
    plain4,
    ufw_file(family="ipv6", commented=False, omit="cali-out"),
    "ufw6-user-output",
    "-o cali+",
)
expect_fail(
    "missing IPv6 vxlan in",
    plain4,
    ufw_file(family="ipv6", commented=False, omit="vxlan-in"),
    "ufw6-user-input",
    "-i vxlan.calico",
)
expect_fail(
    "IPv6 file using IPv4 chain names",
    LIVE4,
    LIVE4,
    "ufw6-user-input",
    "ufw6-user-output",
)
expect_fail(
    "IPv4 file using IPv6 chain names",
    LIVE6,
    LIVE6,
    "ufw-user-input",
    "ufw-user-output",
)
expect_fail(
    "IPv6 DROP instead of ACCEPT",
    LIVE4,
    LIVE6.replace("-j ACCEPT", "-j DROP"),
    "ufw6-user-input",
    "ufw6-user-output",
)
expect_fail(
    "IPv6 forward chain instead of input/output",
    LIVE4,
    LIVE6.replace("ufw6-user-input", "ufw6-user-forward").replace(
        "ufw6-user-output", "ufw6-user-forward"
    ),
    "ufw6-user-input",
    "ufw6-user-output",
)

missing_file = subprocess.run(
    [
        sys.executable,
        str(HELPER),
        "--user-rules",
        "/tmp/tradingchassis-absent-user.rules",
        "--user6-rules",
        "/tmp/tradingchassis-absent-user6.rules",
    ],
    check=False,
    capture_output=True,
    text=True,
)
if missing_file.returncode != helper.EXIT_UNEXPECTED:
    raise SystemExit(f"absent UFW files expected rc 2: {missing_file}")
print("PASS: Calico UFW verifier accepts functional rules with or without comments")

src = HELPER.read_text(encoding="utf-8")
if "shell=True" in src or "eval(" in src or "subprocess" in src:
    raise SystemExit("verifier must not execute shell or subprocess commands")
if "import ufw" in src or "os.system" in src or "Popen" in src:
    raise SystemExit("verifier must not mutate or invoke ufw/iptables/nft")
if "REQUIRED_IPV4" not in src or "REQUIRED_IPV6" not in src:
    raise SystemExit("verifier must keep separate IPv4 and IPv6 chain contracts")
if "ufw6-user-input" not in src or "ufw6-user-output" not in src:
    raise SystemExit("verifier must require ufw6-user-* chains for IPv6")
if src.count("ufw-user-input") < 1 or src.count("ufw6-user-input") < 1:
    raise SystemExit("verifier must distinguish ufw-user-* from ufw6-user-*")
compile(src, str(HELPER), "exec")
print("PASS: Calico UFW verifier is read-only")

tasks = TASKS.read_text(encoding="utf-8")
defaults = DEFAULTS.read_text(encoding="utf-8")
if "interface: vxlan.calico" in tasks or "interface: cali+" in tasks:
    raise SystemExit("role must not mutate Calico UFW interface rules")
if "MicroK8s Calico VXLAN inbound" in tasks:
    raise SystemExit("role must not write TradingChassis Calico UFW comments")
if "skip.ufw" in tasks or "skip.ufw" in defaults:
    raise SystemExit("role must not manage MicroK8s skip.ufw")
for needle in (
    "Set UFW default incoming policy to deny",
    "Set UFW default outgoing policy to allow",
    "Set UFW default routed policy to allow for MicroK8s CNI",
    "Allow SSH on the host firewall",
    "Enable UFW with the explicit MicroK8s-compatible host policy",
):
    if needle not in tasks:
        raise SystemExit(f"missing base UFW ownership task: {needle}")
if "state: enabled" not in tasks:
    raise SystemExit("role must still enable UFW")
if "Verify MicroK8s-owned Calico UFW interface allowances" not in tasks:
    raise SystemExit("role must verify MicroK8s Calico UFW allowances")
if "verify_microk8s_calico_ufw.py" not in tasks:
    raise SystemExit("role must run the Calico UFW verifier")
if "Install MicroK8s Calico UFW verification helper" in tasks:
    raise SystemExit("verifier must not be copied onto the host")
if "microk8s_calico_ufw_verify_helper_path" in tasks or "microk8s_calico_ufw_verify_helper_path" in defaults:
    raise SystemExit("role must not persist a Calico UFW verifier path")
verify_block = tasks.split("Verify MicroK8s-owned Calico UFW interface allowances", 1)[1][:900]
if "changed_when: false" not in verify_block:
    raise SystemExit("Calico UFW verification must be changed=false")
if "ansible.builtin.script:" not in verify_block:
    raise SystemExit("Calico UFW verification must run the Git-owned helper via script")
if "community.general.ufw" in verify_block:
    raise SystemExit("Calico UFW verification must not use the ufw module")
if "state: enabled" in verify_block or "rule: allow" in verify_block:
    raise SystemExit("Calico UFW verification must not mutate UFW")
if "ufw allow" in tasks:
    raise SystemExit("role must not invoke ufw allow for Calico interfaces")
ufw_enable = tasks.find("Enable UFW with the explicit MicroK8s-compatible host policy")
install = tasks.find("Install MicroK8s from the pinned snap channel")
ready = tasks.find("Wait for MicroK8s to become ready")
addon_ready = tasks.find("Wait for MicroK8s readiness after addon convergence")
verify = tasks.find("Verify MicroK8s-owned Calico UFW interface allowances")
if min(ufw_enable, install, ready, addon_ready, verify) < 0:
    raise SystemExit("missing UFW/MicroK8s/verify ordering tasks")
if not (ufw_enable < install < ready < addon_ready < verify):
    raise SystemExit("Calico UFW verification must run after MicroK8s is ready")
mutating_ufw = []
for block in re.split(r"(?m)^- name: ", tasks)[1:]:
    name, _, rest = block.partition("\n")
    if "community.general.ufw:" in rest:
        mutating_ufw.append(name)
expected_ufw = [
    "Set UFW default incoming policy to deny",
    "Set UFW default outgoing policy to allow",
    "Set UFW default routed policy to allow for MicroK8s CNI",
    "Allow SSH on the host firewall",
    "Enable UFW with the explicit MicroK8s-compatible host policy",
]
if mutating_ufw != expected_ufw:
    raise SystemExit(f"unexpected UFW mutation tasks: {mutating_ufw}")
for name in mutating_ufw:
    block = tasks.split(f"- name: {name}", 1)[1]
    block = block.split("\n- name:", 1)[0]
    if "changed_when: false" in block:
        raise SystemExit(f"mutating UFW task {name!r} must not hide changed")
    if re.search(r"(?m)^\s+interface:\s+(vxlan\.calico|cali\+)\s*$", rest):
        raise SystemExit(f"mutating UFW task {name!r} must not own Calico interfaces")
print("PASS: Ansible verifies Calico UFW after MicroK8s and does not mutate it")

if "microk8s_ufw_user_rules_file:" not in defaults:
    raise SystemExit("defaults must set user.rules path")
if "microk8s_ufw_user6_rules_file:" not in defaults:
    raise SystemExit("defaults must set user6.rules path")
if "/etc/ufw/user.rules" not in defaults or "/etc/ufw/user6.rules" not in defaults:
    raise SystemExit("defaults must pin Ubuntu UFW user rule paths")
if "10.1.0.0/16" in HELPER.read_text(encoding="utf-8"):
    raise SystemExit("verifier must not hard-code pod CIDR")
if "skip.ufw" in FIREWALL_HELPER.read_text(encoding="utf-8"):
    raise SystemExit("OCI firewall helper must not grow skip.ufw coupling")
unit = UNIT.read_text(encoding="utf-8")
if "verify_microk8s_calico_ufw" in unit:
    raise SystemExit("boot unit must not take Calico UFW ownership")
print("PASS: Calico UFW ownership stays with MicroK8s")

readme = README.read_text(encoding="utf-8")
v2 = V2_DOC.read_text(encoding="utf-8")
changelog = CHANGELOG.read_text(encoding="utf-8")
unreleased = changelog.split("## [0.1.0]", 1)[0]
for needle in (
    "MicroK8s owns",
    "vxlan.calico",
    "cali+",
    "verif",
):
    if needle.lower() not in readme.lower():
        raise SystemExit(f"ansible/README.md missing {needle}")
if "skip.ufw" in readme:
    skip_idx = readme.find("skip.ufw")
    window = readme[max(0, skip_idx - 80) : skip_idx]
    if "Do not" not in window and "do not" not in window:
        raise SystemExit("README must not recommend skip.ufw")
if "vxlan.calico" not in v2 or "cali+" not in v2:
    raise SystemExit("V2 doc must record Calico UFW interface ownership")
if "Calico" not in unreleased or "UFW" not in unreleased:
    raise SystemExit("CHANGELOG [Unreleased] must record the Calico UFW ownership fix")
if "ufw6-user-input" not in unreleased or "ufw6-user-output" not in unreleased:
    raise SystemExit("CHANGELOG [Unreleased] must record the IPv6 UFW chain fix")
print("PASS: docs record MicroK8s Calico UFW ownership")

workflow = WORKFLOW.read_text(encoding="utf-8")
if "test_ansible_microk8s_calico_ufw_ownership.sh" not in workflow:
    raise SystemExit("CI must run the Calico UFW ownership contract test")
print("PASS: CI enforces Calico UFW ownership")
print("PASS: Ansible MicroK8s Calico UFW ownership contract")
PY

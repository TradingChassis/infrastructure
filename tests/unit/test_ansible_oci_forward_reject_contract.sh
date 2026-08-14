#!/usr/bin/env bash
# Static and synthetic regression for OCI cloud-image MicroK8s firewall
# normalization (FORWARD reject removal + INPUT pod-host allows).
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
import shutil
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
KUBELET_PORT = "10250"
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
ORACLE_IS_COMMENT = (
    "See the Oracle-Provided Images section in the Oracle Cloud "
    "Infrastructure documentation for security impact of modifying or "
    "removing this rule"
)


def oracle_is_rule(body: str, jump: str) -> str:
    return (
        f"-A InstanceServices {body} -m comment --comment "
        f'"{ORACLE_IS_COMMENT}" {jump}'
    )


IS_TCP_OWNER_3260 = oracle_is_rule(
    "-d 169.254.0.2/32 -p tcp -m owner --uid-owner 0 -m tcp --dport 3260",
    "-j ACCEPT",
)
IS_TCP_80_COMMENT = oracle_is_rule(
    "-d 169.254.169.254/32 -p tcp -m tcp --dport 80",
    "-j ACCEPT",
)
IS_UDP_53_COMMENT = oracle_is_rule(
    "-d 169.254.169.254/32 -p udp -m udp --dport 53",
    "-j ACCEPT",
)
IS_UDP_123_COMMENT = oracle_is_rule(
    "-d 169.254.169.254/32 -p udp -m udp --dport 123",
    "-j ACCEPT",
)
IS_TCP_REJECT_COMMENT = oracle_is_rule(
    "-d 169.254.0.0/16 -p tcp -m tcp --dport 3260",
    "-j REJECT --reject-with icmp-host-prohibited",
)
IS_UDP_REJECT_COMMENT = oracle_is_rule(
    "-d 169.254.0.0/16 -p udp -m udp --dport 123",
    "-j REJECT --reject-with icmp-port-unreachable",
)
QUOTED_IS_RULES = (
    IS_TCP_OWNER_3260,
    IS_TCP_80_COMMENT,
    IS_UDP_53_COMMENT,
    IS_UDP_123_COMMENT,
    IS_TCP_REJECT_COMMENT,
    IS_UDP_REJECT_COMMENT,
)
CLOUD_IMG_IS_RULES = (
    oracle_is_rule(
        "-d 169.254.0.2/32 -p tcp -m owner --uid-owner 0 -m tcp --dport 3260",
        "-j ACCEPT",
    ),
    oracle_is_rule(
        "-d 169.254.2.0/24 -p tcp -m owner --uid-owner 0 -m tcp --dport 3260",
        "-j ACCEPT",
    ),
    oracle_is_rule(
        "-d 169.254.4.0/24 -p tcp -m owner --uid-owner 0 -m tcp --dport 3260",
        "-j ACCEPT",
    ),
    oracle_is_rule(
        "-d 169.254.5.0/24 -p tcp -m owner --uid-owner 0 -m tcp --dport 3260",
        "-j ACCEPT",
    ),
    oracle_is_rule("-d 169.254.0.2/32 -p tcp -m tcp --dport 80", "-j ACCEPT"),
    oracle_is_rule(
        "-d 169.254.169.254/32 -p udp -m udp --dport 53",
        "-j ACCEPT",
    ),
    oracle_is_rule(
        "-d 169.254.169.254/32 -p tcp -m tcp --dport 53",
        "-j ACCEPT",
    ),
    oracle_is_rule(
        "-d 169.254.0.3/32 -p tcp -m owner --uid-owner 0 -m tcp --dport 80",
        "-j ACCEPT",
    ),
    oracle_is_rule("-d 169.254.0.4/32 -p tcp -m tcp --dport 80", "-j ACCEPT"),
    oracle_is_rule(
        "-d 169.254.169.254/32 -p tcp -m tcp --dport 80",
        "-j ACCEPT",
    ),
    oracle_is_rule(
        "-d 169.254.169.254/32 -p udp -m udp --dport 67",
        "-j ACCEPT",
    ),
    oracle_is_rule(
        "-d 169.254.169.254/32 -p udp -m udp --dport 69",
        "-j ACCEPT",
    ),
    oracle_is_rule("-d 169.254.169.254/32 -p udp --dport 123", "-j ACCEPT"),
    oracle_is_rule(
        "-d 169.254.0.0/16 -p tcp -m tcp",
        "-j REJECT --reject-with tcp-reset",
    ),
    oracle_is_rule(
        "-d 169.254.0.0/16 -p udp -m udp",
        "-j REJECT --reject-with icmp-port-unreachable",
    ),
)
IS_NTP_IMPLICIT = CLOUD_IMG_IS_RULES[12]
IS_NTP_EXPLICIT = oracle_is_rule(
    "-d 169.254.169.254/32 -p udp -m udp --dport 123",
    "-j ACCEPT",
)
IS_TCP_80_IMPLICIT = oracle_is_rule(
    "-d 169.254.169.254/32 -p tcp --dport 80",
    "-j ACCEPT",
)
API_ALLOW = (
    f"-A INPUT -s {POD_CIDR} -p tcp -m tcp --dport {API_PORT} -j ACCEPT"
)
KUBELET_ALLOW = (
    f"-A INPUT -s {POD_CIDR} -p tcp -m tcp --dport {KUBELET_PORT} -j ACCEPT"
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
    api_allows: tuple[str, ...] = (),
    kubelet_allows: tuple[str, ...] = (),
    extra_forward: str | None = None,
    extra_input_before_reject: str | None = None,
    duplicate_input_reject: bool = False,
) -> str:
    forward_block = ""
    if include_forward_reject:
        forward_block += FORWARD_REJECT + "\n"
    if extra_forward is not None:
        forward_block += extra_forward + "\n"

    def copies(kind: tuple[str, ...], line: str) -> tuple[str, str]:
        before = "".join(line + "\n" for item in kind if item == "before")
        after = "".join(line + "\n" for item in kind if item == "after")
        return before, after

    api_before, api_after = copies(api_allows, API_ALLOW)
    kubelet_before, kubelet_after = copies(kubelet_allows, KUBELET_ALLOW)
    extra_before = ""
    if extra_input_before_reject is not None:
        extra_before = extra_input_before_reject + "\n"
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
        f"{api_before}"
        f"{kubelet_before}"
        f"{extra_before}"
        f"{INPUT_REJECT}\n"
        f"{second_reject}"
        f"{api_after}"
        f"{kubelet_after}"
        f"{forward_block}"
        f"{OUTPUT_JUMP}\n"
        f"{INSTANCE_SERVICES_RULE}\n"
        "-A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 53 "
        "-j ACCEPT\n"
        "COMMIT\n"
    )


def oci_baseline_is_block() -> str:
    return (
        f"{INSTANCE_SERVICES_RULE}\n"
        "-A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 53 "
        "-j ACCEPT\n"
    )


def oci_quoted_rules() -> str:
    quoted_is = "".join(rule + "\n" for rule in QUOTED_IS_RULES)
    return oci_rules(
        include_forward_reject=False,
        api_allows=("before",),
        kubelet_allows=("before",),
    ).replace(oci_baseline_is_block(), quoted_is)


def oci_cloud_img_rules() -> str:
    quoted_is = "".join(rule + "\n" for rule in CLOUD_IMG_IS_RULES)
    return oci_rules(
        include_forward_reject=False,
        api_allows=("before",),
        kubelet_allows=("before",),
    ).replace(oci_baseline_is_block(), quoted_is)


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
    kubelet_port: str = KUBELET_PORT,
) -> subprocess.CompletedProcess[str]:
    argv = [
        sys.executable,
        str(HELPER),
        "--pod-cidr",
        pod_cidr,
        "--apiserver-port",
        apiserver_port,
        "--kubelet-port",
        kubelet_port,
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


def expect_error(text: str, code: int) -> str:
    try:
        helper.normalize_rules_text(
            text, POD_CIDR, API_PORT, KUBELET_PORT
        )
    except helper.NormalizeError as exc:
        if exc.code != code:
            raise SystemExit(
                f"expected exit {code}, got {exc.code}: {exc}"
            ) from exc
        return str(exc)
    raise SystemExit("expected NormalizeError")


def host_allows_immediately_before_reject(text: str) -> bool:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    try:
        idx = lines.index(INPUT_REJECT)
    except ValueError:
        return False
    return (
        idx >= 2
        and lines[idx - 2] == API_ALLOW
        and lines[idx - 1] == KUBELET_ALLOW
    )


def count_line(text: str, needle: str) -> int:
    return sum(1 for line in text.splitlines() if line.strip() == needle)


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
    if count_line(text, INPUT_REJECT) != 1:
        raise SystemExit("INPUT REJECT must remain exactly once")
    if FORWARD_REJECT in {line.strip() for line in text.splitlines()}:
        raise SystemExit("exact FORWARD REJECT must remain absent")


def normalize(text: str) -> tuple[str, str]:
    return helper.normalize_rules_text(
        text, POD_CIDR, API_PORT, KUBELET_PORT
    )


def plan(text: str) -> tuple[str, tuple[str, ...]]:
    return helper.plan_input_runtime(
        text, POD_CIDR, API_PORT, KUBELET_PORT
    )


def apply_runtime_inserts(save_text: str, ports: tuple[str, ...]) -> str:
    """Simulate iptables-nft -D <spec> then -I INPUT <spec> for each port."""
    lines = save_text.splitlines()
    ended = save_text.endswith("\n")
    for port in ports:
        allow = (
            f"-A INPUT -s {POD_CIDR} -p tcp -m tcp --dport {port} -j ACCEPT"
        )
        lines = [line for line in lines if line.strip() != allow]
        insert_at = 0
        for idx, line in enumerate(lines):
            if line.startswith("-P "):
                insert_at = idx + 1
        lines.insert(insert_at, allow)
    joined = "\n".join(lines)
    if ended:
        return joined + "\n"
    return joined


# --- CASE A: original OCI baseline ---

case_a = oci_rules()
normalized_a, action_a = normalize(case_a)
if action_a != "changed":
    raise SystemExit(f"CASE A: expected changed, got {action_a}")
if count_line(normalized_a, API_ALLOW) != 1:
    raise SystemExit("CASE A: API allow missing or duplicated")
if count_line(normalized_a, KUBELET_ALLOW) != 1:
    raise SystemExit("CASE A: kubelet allow missing or duplicated")
if not host_allows_immediately_before_reject(normalized_a):
    raise SystemExit("CASE A: host allows are not immediately before INPUT REJECT")
preserved(normalized_a)
if "# CLOUD_IMG:" not in normalized_a:
    raise SystemExit("CASE A: CLOUD_IMG marker was not preserved")
print("PASS: CASE A OCI baseline inserts both host allows and drops FORWARD REJECT")


# --- CASE B: post-PR54, both service allows absent ---

case_b = oci_rules(include_forward_reject=False)
normalized_b, action_b = normalize(case_b)
if action_b != "changed":
    raise SystemExit("CASE B: expected changed when both allows are missing")
if not host_allows_immediately_before_reject(normalized_b):
    raise SystemExit("CASE B: both allows must be inserted before INPUT REJECT")
preserved(normalized_b)
print("PASS: CASE B post-PR54 file receives both INPUT host allows")


# --- CASE C: post-PR55, API allow present, kubelet missing ---

case_c = oci_rules(
    include_forward_reject=False,
    api_allows=("before",),
)
normalized_c, action_c = normalize(case_c)
if action_c != "changed":
    raise SystemExit("CASE C: missing kubelet allow must change the file")
if count_line(normalized_c, API_ALLOW) != 1:
    raise SystemExit("CASE C: API allow must remain exactly once")
if count_line(normalized_c, KUBELET_ALLOW) != 1:
    raise SystemExit("CASE C: kubelet allow must be inserted once")
if not host_allows_immediately_before_reject(normalized_c):
    raise SystemExit("CASE C: both allows must sit immediately before INPUT REJECT")
preserved(normalized_c)
print("PASS: CASE C post-PR55 file adds only the missing kubelet allow")


# --- CASE D: fully normalized ---

case_d = oci_rules(
    include_forward_reject=False,
    api_allows=("before",),
    kubelet_allows=("before",),
)
normalized_d, action_d = normalize(case_d)
if action_d != "unchanged":
    raise SystemExit(f"CASE D: expected unchanged, got {action_d}")
if normalized_d != case_d:
    raise SystemExit("CASE D: already-normalized file must be byte-identical")
print("PASS: CASE D fully normalized OCI baseline is a no-op")


# --- CASE E: 10250 allow after INPUT reject ---

case_e = oci_rules(
    include_forward_reject=False,
    api_allows=("before",),
    kubelet_allows=("after",),
)
normalized_e, action_e = normalize(case_e)
if action_e != "changed":
    raise SystemExit("CASE E: kubelet allow after REJECT must be corrected")
if not host_allows_immediately_before_reject(normalized_e):
    raise SystemExit("CASE E: kubelet allow was not moved before INPUT REJECT")
if count_line(normalized_e, KUBELET_ALLOW) != 1:
    raise SystemExit("CASE E: duplicate kubelet allow after reorder")
if count_line(normalized_e, API_ALLOW) != 1:
    raise SystemExit("CASE E: API allow must remain exactly once")
preserved(normalized_e)
print("PASS: CASE E kubelet allow-after-reject is reordered before INPUT REJECT")


# --- CASE F: duplicate 10250 allow ---

case_f = oci_rules(
    include_forward_reject=False,
    api_allows=("before",),
    kubelet_allows=("before", "before"),
)
normalized_f, action_f = normalize(case_f)
if action_f != "changed":
    raise SystemExit("CASE F: duplicate kubelet allow must be deduplicated")
if count_line(normalized_f, KUBELET_ALLOW) != 1:
    raise SystemExit("CASE F: kubelet allow was not reduced to one copy")
if not host_allows_immediately_before_reject(normalized_f):
    raise SystemExit("CASE F: deduped kubelet allow is not before INPUT REJECT")
preserved(normalized_f)
print("PASS: CASE F duplicate kubelet allow is deduplicated")


# --- CASE G: duplicate 16443 allow ---

case_g = oci_rules(
    include_forward_reject=False,
    api_allows=("before", "before"),
    kubelet_allows=("before",),
)
normalized_g, action_g = normalize(case_g)
if action_g != "changed":
    raise SystemExit("CASE G: duplicate API allow must be deduplicated")
if count_line(normalized_g, API_ALLOW) != 1:
    raise SystemExit("CASE G: API allow was not reduced to one copy")
if count_line(normalized_g, KUBELET_ALLOW) != 1:
    raise SystemExit("CASE G: kubelet allow must remain exactly once")
if not host_allows_immediately_before_reject(normalized_g):
    raise SystemExit("CASE G: deduped API allow is not before INPUT REJECT")
preserved(normalized_g)
print("PASS: CASE G duplicate API allow is deduplicated")


# --- CASE H: non-OCI file ---

message_h = expect_error(unexpected_rules(), helper.EXIT_UNEXPECTED)
if "refusing to modify unexpected firewall file" not in message_h:
    raise SystemExit(f"CASE H: missing fail-closed diagnostic: {message_h}")
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "rules.v4"
    original = unexpected_rules()
    path.write_text(original, encoding="utf-8")
    cli = run_cli(path)
    if cli.returncode != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"CASE H CLI expected rc 2, got {cli.returncode}")
    if path.read_text(encoding="utf-8") != original:
        raise SystemExit("CASE H: unexpected file must not be rewritten")
print("PASS: CASE H unexpected rules.v4 fails closed")


# --- CASE I: duplicate INPUT REJECT ---

case_i = oci_rules(duplicate_input_reject=True)
expect_error(case_i, helper.EXIT_UNEXPECTED)
print("PASS: CASE I duplicate INPUT REJECT fails closed")


# --- CASE J: preservation + similar non-exact rules retained ---

case_j = oci_rules(
    include_forward_reject=True,
    extra_forward=SIMILAR_FORWARD,
    extra_input_before_reject=SIMILAR_ALLOW,
)
normalized_j, action_j = normalize(case_j)
if action_j != "changed":
    raise SystemExit("CASE J: expected changed")
if SIMILAR_FORWARD not in normalized_j:
    raise SystemExit("CASE J: similar FORWARD rule was lost")
if SIMILAR_ALLOW not in normalized_j:
    raise SystemExit("CASE J: similar INPUT allow was lost")
if not host_allows_immediately_before_reject(normalized_j):
    raise SystemExit("CASE J: exact host allows missing before INPUT REJECT")
preserved(normalized_j)
print("PASS: CASE J preservation and non-exact rules retained")


# --- swapped persistent order is rewritten once, then stable ---

swapped = oci_rules(
    include_forward_reject=False,
    kubelet_allows=("before",),
    api_allows=("before",),
)
# Fixture emits API copies before kubelet copies, so force kubelet-then-API.
swapped_text = swapped.replace(API_ALLOW + "\n" + KUBELET_ALLOW, KUBELET_ALLOW + "\n" + API_ALLOW)
if KUBELET_ALLOW + "\n" + API_ALLOW not in swapped_text:
    raise SystemExit("failed to construct swapped persistent allows")
normalized_swap, action_swap = normalize(swapped_text)
if action_swap != "changed":
    raise SystemExit("swapped persistent host allows must be canonicalized")
if not host_allows_immediately_before_reject(normalized_swap):
    raise SystemExit("swapped persistent allows were not canonicalized")
normalized_swap2, action_swap2 = normalize(normalized_swap)
if action_swap2 != "unchanged" or normalized_swap2 != normalized_swap:
    raise SystemExit("canonical persistent allows must then be a no-op")
print("PASS: persistent host-allow order is canonical and then unchanged")


# --- absent rules.v4 ---

with tempfile.TemporaryDirectory() as tmp:
    missing = Path(tmp) / "rules.v4"
    action = helper.normalize_rules_file(
        missing, POD_CIDR, API_PORT, KUBELET_PORT, write=True
    )
    if action != "absent":
        raise SystemExit(f"absent file: expected absent, got {action}")
    if missing.exists():
        raise SystemExit("absent path must not create a rules file")
    cli = run_cli(missing)
    if cli.returncode != 0 or cli.stdout.strip() != "absent":
        raise SystemExit(
            f"absent CLI failed: rc={cli.returncode} out={cli.stdout!r}"
        )
print("PASS: absent rules.v4 is a safe no-op")


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
    if not host_allows_immediately_before_reject(written):
        raise SystemExit("CLI write did not place host allows before INPUT REJECT")
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


def with_allows(text: str, *allows: str, after_reject: bool = False) -> str:
    if after_reject:
        return text.replace(
            "-A INPUT -j ufw-before-logging-input\n",
            "".join(allow + "\n" for allow in allows)
            + "-A INPUT -j ufw-before-logging-input\n",
        )
    return text.replace(
        INPUT_REJECT, "\n".join(allows) + "\n" + INPUT_REJECT
    )


def expect_plan(text: str, action: str, ports: tuple[str, ...], label: str) -> None:
    got_action, got_ports = plan(text)
    if got_action != action or got_ports != ports:
        raise SystemExit(
            f"{label}: expected {(action, ports)}, got {(got_action, got_ports)}"
        )


expect_plan(
    runtime_baseline,
    "ensure",
    (KUBELET_PORT, API_PORT),
    "runtime neither allow",
)
expect_plan(
    with_allows(runtime_baseline, API_ALLOW),
    "ensure",
    (KUBELET_PORT,),
    "runtime only 16443",
)
expect_plan(
    with_allows(runtime_baseline, KUBELET_ALLOW),
    "ensure",
    (API_PORT,),
    "runtime only 10250",
)
expect_plan(
    with_allows(runtime_baseline, API_ALLOW, KUBELET_ALLOW),
    "unchanged",
    (),
    "runtime both before reject",
)
expect_plan(
    with_allows(runtime_baseline, KUBELET_ALLOW, API_ALLOW),
    "unchanged",
    (),
    "runtime swapped order before reject",
)
expect_plan(
    with_allows(runtime_baseline, API_ALLOW, after_reject=True),
    "ensure",
    (KUBELET_PORT, API_PORT),
    "runtime 16443 after reject",
)
expect_plan(
    with_allows(runtime_baseline, KUBELET_ALLOW, after_reject=True),
    "ensure",
    (KUBELET_PORT, API_PORT),
    "runtime 10250 after reject",
)
expect_plan(
    with_allows(
        runtime_baseline, API_ALLOW, KUBELET_ALLOW, after_reject=True
    ),
    "ensure",
    (KUBELET_PORT, API_PORT),
    "runtime both after reject",
)

dup_kubelet = with_allows(runtime_baseline, KUBELET_ALLOW, KUBELET_ALLOW)
expect_plan(
    dup_kubelet,
    "ensure",
    (KUBELET_PORT, API_PORT),
    "runtime duplicate 10250",
)
dup_api = with_allows(runtime_baseline, API_ALLOW, API_ALLOW)
expect_plan(dup_api, "ensure", (KUBELET_PORT, API_PORT), "runtime duplicate 16443")
expect_plan(
    with_allows(runtime_baseline, API_ALLOW, KUBELET_ALLOW, KUBELET_ALLOW),
    "ensure",
    (KUBELET_PORT,),
    "runtime duplicate 10250 with correct API",
)
expect_plan(
    with_allows(runtime_baseline, API_ALLOW, API_ALLOW, KUBELET_ALLOW),
    "ensure",
    (API_PORT,),
    "runtime duplicate 16443 with correct kubelet",
)
kubelet_ok = with_allows(runtime_baseline, KUBELET_ALLOW)
expect_plan(
    with_allows(kubelet_ok, API_ALLOW, after_reject=True),
    "ensure",
    (API_PORT,),
    "runtime 16443 after reject with kubelet ok",
)

runtime_dup_reject = runtime_baseline + INPUT_REJECT + "\n"
try:
    plan(runtime_dup_reject)
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"runtime duplicate REJECT expected rc 2: {exc}")
else:
    raise SystemExit("runtime duplicate REJECT must fail closed")

action_none, ports_none = plan(runtime_baseline)
updated_none = apply_runtime_inserts(runtime_baseline, ports_none)
expect_plan(
    updated_none,
    "unchanged",
    (),
    "runtime second pass after inserting both",
)
if not updated_none.splitlines()[1].endswith(f"--dport {API_PORT} -j ACCEPT"):
    raise SystemExit("greenfield -I order must leave API allow at INPUT position 1")
if not updated_none.splitlines()[2].endswith(
    f"--dport {KUBELET_PORT} -j ACCEPT"
):
    raise SystemExit("greenfield -I order must leave kubelet allow at INPUT position 2")

post55 = with_allows(runtime_baseline, API_ALLOW)
action_c, ports_c = plan(post55)
if ports_c != (KUBELET_PORT,):
    raise SystemExit(f"post-PR55 runtime plan must insert only kubelet, got {ports_c}")
updated_c = apply_runtime_inserts(post55, ports_c)
expect_plan(updated_c, "unchanged", (), "runtime second pass after kubelet-only insert")

plan_cli = run_cli(None, plan_text=with_allows(runtime_baseline, API_ALLOW, KUBELET_ALLOW))
if plan_cli.returncode != 0 or plan_cli.stdout.strip() != "unchanged":
    raise SystemExit(
        f"runtime plan CLI failed: {plan_cli.stdout!r} {plan_cli.stderr!r}"
    )
plan_cli_missing = run_cli(None, plan_text=runtime_baseline)
if plan_cli_missing.returncode != 0 or plan_cli_missing.stdout.strip() != (
    f"ensure\n{KUBELET_PORT}\n{API_PORT}"
):
    raise SystemExit(
        f"runtime plan CLI insert order failed: {plan_cli_missing.stdout!r}"
    )
print("PASS: runtime INPUT planner ordering and second-pass contract")


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
    raise SystemExit("non-numeric host TCP port must be rejected")
try:
    helper.host_tcp_ports(API_PORT, API_PORT)
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_USAGE:
        raise SystemExit(f"duplicate ports expected usage error: {exc}")
else:
    raise SystemExit("identical API and kubelet ports must be rejected")
try:
    helper.build_allow_lines(POD_CIDR, API_PORT, "0")
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_USAGE:
        raise SystemExit(f"port 0 expected usage error: {exc}")
else:
    raise SystemExit("kubelet port 0 must be rejected")
print("PASS: helper rejects host-sized CIDR, invalid ports, and duplicate ports")


# --- fail-closed lookalikes ---

almost_oci = oci_rules().replace("Oracle Cloud Infrastructure", "Example Cloud")
expect_error(almost_oci, helper.EXIT_UNEXPECTED)
expect_error(oci_rules().replace(INPUT_REJECT, ""), helper.EXIT_UNEXPECTED)
expect_error(oci_rules().replace(OUTPUT_JUMP, "-A OUTPUT -j ACCEPT"), helper.EXIT_UNEXPECTED)
dup_output_jump = oci_rules().replace(
    OUTPUT_JUMP, OUTPUT_JUMP + "\n" + OUTPUT_JUMP
)
expect_error(dup_output_jump, helper.EXIT_UNEXPECTED)
no_is_rules = oci_rules().replace(INSTANCE_SERVICES_RULE + "\n", "").replace(
    "-A InstanceServices -d 169.254.169.254/32 -p udp -m udp --dport 53 "
    "-j ACCEPT\n",
    "",
)
expect_error(no_is_rules, helper.EXIT_UNEXPECTED)
dup_is_rules = oci_rules().replace(
    INSTANCE_SERVICES_RULE, INSTANCE_SERVICES_RULE + "\n" + INSTANCE_SERVICES_RULE
)
expect_error(dup_is_rules, helper.EXIT_UNEXPECTED)
print("PASS: incomplete OCI lookalikes fail closed")


# --- nft filter runtime planner (boot/Ansible --apply-runtime) ---

PERSIST = case_d
required_input, required_output_jump, required_is = helper.desired_runtime_contract(
    PERSIST, POD_CIDR, API_PORT, KUBELET_PORT
)
UFW_INPUT = (
    "-A INPUT -j ufw-before-logging-input\n"
    "-A INPUT -j ufw-before-input\n"
    "-A INPUT -j ufw-after-input\n"
    "-A INPUT -j ufw-after-logging-input\n"
    "-A INPUT -j ufw-reject-input\n"
    "-A INPUT -j ufw-track-input\n"
)
UFW_FORWARD = (
    "-A FORWARD -j ufw-before-logging-forward\n"
    "-A FORWARD -j ufw-before-forward\n"
    "-A FORWARD -j ufw-after-forward\n"
    "-A FORWARD -j ufw-after-logging-forward\n"
    "-A FORWARD -j ufw-reject-forward\n"
    "-A FORWARD -j ufw-track-forward\n"
)
UFW_OUTPUT = (
    "-A OUTPUT -j ufw-before-logging-output\n"
    "-A OUTPUT -j ufw-before-output\n"
    "-A OUTPUT -j ufw-after-output\n"
    "-A OUTPUT -j ufw-after-logging-output\n"
    "-A OUTPUT -j ufw-reject-output\n"
    "-A OUTPUT -j ufw-track-output\n"
)
MICROK8S_FORWARD = f"-A FORWARD -s {POD_CIDR} -j ACCEPT"
UNRELATED_INPUT = (
    "-A INPUT -s 192.0.2.0/24 -p tcp -m tcp --dport 16443 -j ACCEPT"
)
UNRELATED_FORWARD = "-A FORWARD -s 192.0.2.0/24 -j ACCEPT"
OCI_INPUT_BASELINE = (
    "-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT\n"
    "-A INPUT -p icmp -j ACCEPT\n"
    "-A INPUT -i lo -j ACCEPT\n"
    "-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT\n"
)


def ufw_only_input() -> str:
    return "-P INPUT DROP\n" + UFW_INPUT


def ufw_only_forward(*, with_microk8s: bool = False, with_oci_reject: bool = False) -> str:
    extra = ""
    if with_oci_reject:
        extra += FORWARD_REJECT + "\n"
    if with_microk8s:
        extra += MICROK8S_FORWARD + "\n"
    return "-P FORWARD DROP\n" + extra + UFW_FORWARD


def ufw_only_output(*, with_jump: bool = False) -> str:
    prefix = ""
    if with_jump:
        prefix = required_output_jump + "\n"
    return "-P OUTPUT ACCEPT\n" + prefix + UFW_OUTPUT


def is_dump(rules: list[str] | None) -> str | None:
    if rules is None:
        return None
    return "-N InstanceServices\n" + "".join(rule + "\n" for rule in rules)


def canonical_input(*, extra_after: str = "") -> str:
    body = "".join(line + "\n" for line in required_input)
    return "-P INPUT DROP\n" + body + extra_after + UFW_INPUT


def plan_filter(
    persist: str,
    input_save: str,
    forward_save: str,
    output_save: str,
    is_save: str | None,
) -> tuple[str, list[tuple[str, ...]]]:
    return helper.plan_filter_runtime(
        persist,
        POD_CIDR,
        API_PORT,
        KUBELET_PORT,
        input_save=input_save,
        forward_save=forward_save,
        output_save=output_save,
        instanceservices_save=is_save,
    )


def assert_safe_ops(ops: list[tuple[str, ...]], label: str) -> None:
    for op in ops:
        if not op:
            raise SystemExit(f"{label}: empty nft op")
        if op[0] not in {"-N", "-A", "-D", "-I"}:
            raise SystemExit(f"{label}: unexpected nft op {op}")
        if any(part in {"-F", "-X", "--flush"} for part in op):
            raise SystemExit(f"{label}: flush/delete-chain op {op}")
        joined = " ".join(op)
        if "legacy" in joined or "restore" in joined or "iptables-restore" in joined:
            raise SystemExit(f"{label}: forbidden nft op {op}")
        if op[0] in {"-I", "-D"} and len(op) > 2 and op[2].isdigit():
            if int(op[2]) < 1:
                raise SystemExit(f"{label}: invalid INPUT rule index {op}")
            if op[0] == "-D" and len(op) != 3:
                raise SystemExit(f"{label}: numbered delete must be -D CHAIN N {op}")
        if op[0] == "-N" and op[1:] != ("InstanceServices",):
            raise SystemExit(f"{label}: refusing to create unexpected chain {op}")


def parse_chain(save: str | None, chain: str) -> dict[str, object]:
    if save is None:
        return {"exists": False, "headers": [], "rules": []}
    headers: list[str] = []
    rules: list[str] = []
    for raw in save.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("-A "):
            rules.append(line)
        else:
            headers.append(line)
    return {"exists": True, "headers": headers, "rules": rules}


def render_chain(state: dict[str, object], chain: str) -> str | None:
    if not state["exists"]:
        return None
    headers = list(state["headers"])  # type: ignore[arg-type]
    rules = list(state["rules"])  # type: ignore[arg-type]
    return "\n".join(headers + rules) + "\n"


def simulate_iptables_nft_s_tokens(tokens: tuple[str, ...]) -> tuple[str, ...]:
    """Insert redundant -m tcp/-m udp the way iptables-nft -S renders ports."""
    rendered = list(tokens)
    protocol: str | None = None
    protocol_at: int | None = None
    has_match = False
    has_port = False
    index = 0
    while index < len(rendered):
        token = rendered[index]
        if (
            token == "-p"
            and index + 1 < len(rendered)
            and rendered[index + 1] in {"tcp", "udp"}
        ):
            protocol = rendered[index + 1]
            protocol_at = index
            index += 2
            continue
        if (
            protocol is not None
            and token == "-m"
            and index + 1 < len(rendered)
            and rendered[index + 1] == protocol
        ):
            has_match = True
            index += 2
            continue
        if token in {"--dport", "--sport"}:
            has_port = True
        index += 1
    if protocol is not None and protocol_at is not None and has_port and not has_match:
        insert_at = protocol_at + 2
        rendered[insert_at:insert_at] = ["-m", protocol]
    return tuple(rendered)


def apply_ops(
    input_save: str,
    forward_save: str,
    output_save: str,
    is_save: str | None,
    ops: list[tuple[str, ...]],
) -> tuple[str, str, str, str | None]:
    states = {
        "INPUT": parse_chain(input_save, "INPUT"),
        "FORWARD": parse_chain(forward_save, "FORWARD"),
        "OUTPUT": parse_chain(output_save, "OUTPUT"),
        "InstanceServices": parse_chain(is_save, "InstanceServices"),
    }
    for op in ops:
        action = op[0]
        if action == "-N":
            chain = op[1]
            if states[chain]["exists"]:
                raise SystemExit(f"simulate: chain {chain} already exists")
            states[chain] = {
                "exists": True,
                "headers": [f"-N {chain}"],
                "rules": [],
            }
            continue
        chain = op[1]
        rules = list(states[chain]["rules"])  # type: ignore[arg-type]
        if action == "-D" and len(op) == 3 and op[2].isdigit():
            delete_at = int(op[2]) - 1
            if delete_at < 0 or delete_at >= len(rules):
                raise SystemExit(f"simulate: invalid delete index {op}")
            del rules[delete_at]
            states[chain]["rules"] = rules
            continue
        if action == "-I" and len(op) > 2 and op[2].isdigit():
            insert_at = int(op[2]) - 1
            spec_line = helper.format_spec_line(
                simulate_iptables_nft_s_tokens(("-A", chain, *op[3:]))
            )
            if insert_at < 0 or insert_at > len(rules):
                raise SystemExit(f"simulate: invalid insert index {op}")
            rules.insert(insert_at, spec_line)
            states[chain]["rules"] = rules
            continue
        argv_spec = ("-A", *op[1:])
        spec_key = helper._spec_semantic_tokens(argv_spec)
        spec_line = helper.format_spec_line(simulate_iptables_nft_s_tokens(argv_spec))
        if action == "-D":
            found = next(
                (
                    index
                    for index, line in enumerate(rules)
                    if helper._spec_key(line) == spec_key
                ),
                None,
            )
            if found is None:
                raise SystemExit(f"simulate: cannot delete {spec_line}")
            del rules[found]
        elif action == "-I":
            rules.insert(0, spec_line)
        elif action == "-A":
            rules.append(spec_line)
        else:
            raise SystemExit(f"simulate: unknown action {op}")
        states[chain]["rules"] = rules
    return (
        render_chain(states["INPUT"], "INPUT") or "",
        render_chain(states["FORWARD"], "FORWARD") or "",
        render_chain(states["OUTPUT"], "OUTPUT") or "",
        render_chain(states["InstanceServices"], "InstanceServices"),
    )


def is_reject_insert(op: tuple[str, ...]) -> bool:
    return (
        op[0] == "-I"
        and len(op) > 1
        and op[1] == "INPUT"
        and "-j" in op
        and "REJECT" in op
    )


def assert_partial_safety(
    label: str,
    input_save: str,
    forward_save: str,
    output_save: str,
    is_save: str | None,
    ops: list[tuple[str, ...]],
) -> None:
    current = (input_save, forward_save, output_save, is_save)
    live_input = helper._chain_append_lines(current[0], "INPUT")
    if not helper.input_ssh_path_intact(live_input, required_input):
        # Starting lockout is allowed only when REJECT already precedes SSH/UFW.
        # The first INPUT mutation must restore a path, not insert another REJECT.
        pass
    seen_required_accept_insert = False
    saw_is_append = False
    for index, op in enumerate(ops):
        if is_reject_insert(op):
            if not op[2].isdigit():
                raise SystemExit(
                    f"{label}: INPUT REJECT insert must be indexed, got {op}"
                )
            if int(op[2]) != len(
                [line for line in required_input if line != INPUT_REJECT]
            ) + 1:
                raise SystemExit(
                    f"{label}: INPUT REJECT inserted at {op[2]}, not after accepts: {op}"
                )
            if not seen_required_accept_insert:
                live_before = helper._chain_append_lines(current[0], "INPUT")
                accepts = [line for line in required_input if line != INPUT_REJECT]
                if live_before[: len(accepts)] != accepts:
                    raise SystemExit(
                        f"{label}: INPUT REJECT inserted before ACCEPT prefix "
                        f"at op {index}: {op}"
                    )
        if (
            op[0] == "-I"
            and len(op) > 1
            and op[1] == "INPUT"
            and not is_reject_insert(op)
        ):
            seen_required_accept_insert = True
        if len(op) > 1 and op[1] == "InstanceServices" and op[0] == "-A":
            saw_is_append = True
        if len(op) > 1 and op[1] == "InstanceServices" and op[0] == "-D":
            if not saw_is_append and current[3] is not None:
                live_is = helper._chain_append_lines(current[3], "InstanceServices")
                if live_is and any(live_is.count(line) == 0 for line in required_is):
                    raise SystemExit(
                        f"{label}: InstanceServices deleted before adding missing rules"
                    )
        current = apply_ops(*current, [op])
        live_input = helper._chain_append_lines(current[0], "INPUT")
        if not helper.input_ssh_path_intact(live_input, required_input):
            raise SystemExit(
                f"{label}: SSH lockout after op {index} {op}: {live_input}"
            )
        if op[0] in {"-F", "-X", "--flush"}:
            raise SystemExit(f"{label}: flush after op {index} {op}")
        if len(op) > 1 and op[1] == "InstanceServices" and op[0] == "-D":
            if current[3] is None:
                raise SystemExit(f"{label}: InstanceServices disappeared after {op}")
            if not helper._chain_append_lines(current[3], "InstanceServices"):
                raise SystemExit(
                    f"{label}: InstanceServices emptied after op {index} {op}"
                )


def expect_filter(
    label: str,
    persist: str,
    input_save: str,
    forward_save: str,
    output_save: str,
    is_save: str | None,
    *,
    want_action: str,
) -> tuple[str, str, str, str | None]:
    action, ops = plan_filter(
        persist, input_save, forward_save, output_save, is_save
    )
    if action != want_action:
        raise SystemExit(f"{label}: expected action {want_action}, got {action} ops={ops}")
    assert_safe_ops(ops, label)
    if want_action == "unchanged":
        if ops:
            raise SystemExit(f"{label}: unchanged plan emitted ops {ops}")
        return input_save, forward_save, output_save, is_save
    assert_partial_safety(label, input_save, forward_save, output_save, is_save, ops)
    updated = apply_ops(input_save, forward_save, output_save, is_save, ops)
    second_action, second_ops = plan_filter(persist, *updated)
    if second_action != "unchanged" or second_ops:
        raise SystemExit(
            f"{label}: second pass expected unchanged, got {second_action} {second_ops}"
        )
    return updated


def assert_contract(
    label: str,
    input_save: str,
    forward_save: str,
    output_save: str,
    is_save: str | None,
    *,
    persist: str | None = None,
) -> None:
    req_in, req_out, req_is = (
        helper.desired_runtime_contract(persist, POD_CIDR, API_PORT, KUBELET_PORT)
        if persist is not None
        else (required_input, required_output_jump, required_is)
    )
    live_input = helper._chain_append_lines(input_save, "INPUT")
    prefix_len = len(req_in)
    if [helper._spec_key(line) for line in live_input[:prefix_len]] != [
        helper._spec_key(line) for line in req_in
    ]:
        raise SystemExit(f"{label}: owned INPUT prefix mismatch: {live_input[:prefix_len]}")
    req_in_keys = {helper._spec_key(line) for line in req_in}
    if any(helper._spec_key(line) in req_in_keys for line in live_input[prefix_len:]):
        raise SystemExit(f"{label}: owned INPUT rule duplicated after prefix")
    for jump in helper._chain_append_lines(UFW_INPUT, "INPUT"):
        if jump not in live_input:
            raise SystemExit(f"{label}: missing UFW INPUT jump {jump}")
    if FORWARD_REJECT in helper._chain_append_lines(forward_save, "FORWARD"):
        raise SystemExit(f"{label}: OCI FORWARD REJECT present at runtime")
    live_output = helper._chain_append_lines(output_save, "OUTPUT")
    out_key = helper._spec_key(req_out)
    if sum(1 for line in live_output if helper._spec_key(line) == out_key) != 1:
        raise SystemExit(f"{label}: OUTPUT InstanceServices jump must exist once")
    if is_save is None:
        raise SystemExit(f"{label}: InstanceServices chain missing")
    if [helper._spec_key(line) for line in helper._chain_append_lines(is_save, "InstanceServices")] != [
        helper._spec_key(line) for line in req_is
    ]:
        raise SystemExit(f"{label}: InstanceServices rules mismatch")
        raise SystemExit(f"{label}: InstanceServices rules mismatch")


# 5. UFW-only post-reboot runtime
updated = expect_filter(
    "ufw-only post-reboot",
    PERSIST,
    ufw_only_input(),
    ufw_only_forward(),
    ufw_only_output(),
    None,
    want_action="changed",
)
assert_contract("ufw-only post-reboot", *updated)
print("PASS: UFW-only post-reboot runtime is reconciled then unchanged")

# 6. missing all OCI runtime baseline rules (UFW + MicroK8s FORWARD only)
updated = expect_filter(
    "missing OCI baseline",
    PERSIST,
    ufw_only_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(),
    None,
    want_action="changed",
)
assert_contract("missing OCI baseline", *updated)
if MICROK8S_FORWARD not in updated[1]:
    raise SystemExit("missing OCI baseline: MicroK8s FORWARD rule was lost")
print("PASS: missing OCI runtime baseline is restored without touching MicroK8s FORWARD")

# 7-8. missing InstanceServices chain / OUTPUT jump with otherwise canonical INPUT
updated = expect_filter(
    "missing InstanceServices",
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(),
    None,
    want_action="changed",
)
assert_contract("missing InstanceServices", *updated)
print("PASS: missing InstanceServices chain and OUTPUT jump are restored")

updated = expect_filter(
    "missing OUTPUT jump",
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("missing OUTPUT jump", *updated)
print("PASS: missing OUTPUT InstanceServices jump is restored")

# 9-11. missing only 16443 / only 10250 / both
input_no_api = canonical_input().replace(API_ALLOW + "\n", "")
updated = expect_filter(
    "missing only 16443",
    PERSIST,
    input_no_api,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("missing only 16443", *updated)
if count_line(updated[0], API_ALLOW) != 1:
    raise SystemExit("missing only 16443: API allow not restored once")
print("PASS: missing only 16443 is restored before INPUT REJECT")

input_no_kubelet = canonical_input().replace(KUBELET_ALLOW + "\n", "")
updated = expect_filter(
    "missing only 10250",
    PERSIST,
    input_no_kubelet,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("missing only 10250", *updated)
print("PASS: missing only 10250 is restored before INPUT REJECT")

input_no_pods = canonical_input().replace(API_ALLOW + "\n", "").replace(
    KUBELET_ALLOW + "\n", ""
)
updated = expect_filter(
    "missing both pod allows",
    PERSIST,
    input_no_pods,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("missing both pod allows", *updated)
print("PASS: missing both pod allows are restored before INPUT REJECT")

# 12. duplicate owned rules
dup_input = canonical_input().replace(
    API_ALLOW + "\n", API_ALLOW + "\n" + API_ALLOW + "\n"
)
updated = expect_filter(
    "duplicate owned INPUT",
    PERSIST,
    dup_input,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("duplicate owned INPUT", *updated)
print("PASS: duplicate owned INPUT rules are collapsed")

# 13. misplaced owned rules (pod allows after REJECT / UFW)
misplaced = (
    "-P INPUT DROP\n"
    + OCI_INPUT_BASELINE
    + INPUT_REJECT
    + "\n"
    + UFW_INPUT
    + API_ALLOW
    + "\n"
    + KUBELET_ALLOW
    + "\n"
)
updated = expect_filter(
    "misplaced owned INPUT",
    PERSIST,
    misplaced,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("misplaced owned INPUT", *updated)
print("PASS: misplaced owned INPUT rules are moved before INPUT REJECT")

# 14-16. fully normalized pre-reboot / post-service / second pass
canonical = (
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
)
expect_filter("fully normalized", PERSIST, *canonical, want_action="unchanged")
assert_contract("fully normalized", *canonical)
print("PASS: fully normalized runtime is unchanged")

# PR #56 live pre-reboot order (10250 then 16443 then OCI baseline) canonicalizes once
pr56_live_input = (
    "-P INPUT DROP\n"
    f"{KUBELET_ALLOW}\n"
    f"{API_ALLOW}\n"
    + OCI_INPUT_BASELINE
    + INPUT_REJECT
    + "\n"
    + UFW_INPUT
)
updated = expect_filter(
    "PR56 live INPUT order",
    PERSIST,
    pr56_live_input,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("PR56 live INPUT order", *updated)
print("PASS: pre-reboot PR56 INPUT order canonicalizes once then is unchanged")

# 17-18. UFW chains and unrelated rules preserved
with_unrelated = canonical_input(extra_after=UNRELATED_INPUT + "\n")
forward_with_unrelated = (
    ufw_only_forward(with_microk8s=True).rstrip("\n") + "\n" + UNRELATED_FORWARD + "\n"
)
updated = expect_filter(
    "unrelated INPUT preserved",
    PERSIST,
    with_unrelated,
    forward_with_unrelated,
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="unchanged",
)
if UNRELATED_INPUT not in updated[0]:
    raise SystemExit("unrelated INPUT rule was lost")
if UNRELATED_FORWARD not in updated[1]:
    raise SystemExit("unrelated FORWARD rule was lost")
if MICROK8S_FORWARD not in updated[1]:
    raise SystemExit("MicroK8s FORWARD rule was lost")
print("PASS: UFW jumps and unrelated INPUT rules are preserved")

# 19-20. FORWARD MicroK8s preserved; forbidden OCI FORWARD reject removed
updated = expect_filter(
    "FORWARD REJECT removal",
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True, with_oci_reject=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
    want_action="changed",
)
assert_contract("FORWARD REJECT removal", *updated)
if MICROK8S_FORWARD not in updated[1]:
    raise SystemExit("FORWARD REJECT removal deleted MicroK8s FORWARD")
if FORWARD_REJECT in updated[1]:
    raise SystemExit("FORWARD REJECT removal left the OCI FORWARD REJECT")
print("PASS: OCI FORWARD REJECT is deleted; MicroK8s FORWARD is preserved")

# 21. unexpected persistent baseline
try:
    plan_filter(
        unexpected_rules(),
        ufw_only_input(),
        ufw_only_forward(),
        ufw_only_output(),
        None,
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"unexpected persist expected rc 2: {exc}")
else:
    raise SystemExit("unexpected persist must fail closed")
print("PASS: unexpected persistent baseline fails closed")

# 22-23. malformed / duplicate / unexpected live InstanceServices
try:
    plan_filter(
        PERSIST,
        canonical_input(),
        ufw_only_forward(),
        ufw_only_output(with_jump=True),
        is_dump(required_is + ["-A InstanceServices -j ACCEPT"]),
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"unexpected IS rule expected rc 2: {exc}")
else:
    raise SystemExit("unexpected live InstanceServices rule must fail closed")

try:
    plan_filter(
        PERSIST,
        canonical_input(),
        ufw_only_forward(),
        "-P OUTPUT ACCEPT\n-A OUTPUT -d 192.0.2.1 -j InstanceServices\n" + UFW_OUTPUT,
        is_dump(required_is),
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"unexpected OUTPUT jump expected rc 2: {exc}")
else:
    raise SystemExit("unexpected OUTPUT InstanceServices jump must fail closed")
print("PASS: malformed or unexpected InstanceServices runtime fails closed")

# apply-runtime absent persist fails closed without needing live nft
with tempfile.TemporaryDirectory() as tmp:
    missing = Path(tmp) / "rules.v4"
    try:
        helper.apply_filter_runtime(
            missing, POD_CIDR, API_PORT, KUBELET_PORT, execute=True
        )
    except helper.NormalizeError as exc:
        if exc.code != helper.EXIT_UNEXPECTED:
            raise SystemExit(f"absent apply-runtime expected rc 2: {exc}")
        if "required for runtime" not in str(exc):
            raise SystemExit(f"absent apply-runtime diagnostic: {exc}")
    else:
        raise SystemExit("absent persist apply-runtime must fail closed")
print("PASS: apply-runtime fails closed when rules.v4 is absent")


def interrupt_each_op(
    label: str,
    persist: str,
    input_save: str,
    forward_save: str,
    output_save: str,
    is_save: str | None,
) -> None:
    action, ops = plan_filter(
        persist, input_save, forward_save, output_save, is_save
    )
    if action != "changed":
        raise SystemExit(f"{label}: expected changed plan, got {action} {ops}")
    assert_safe_ops(ops, label)
    assert_partial_safety(
        label, input_save, forward_save, output_save, is_save, ops
    )
    input_ops = [op for op in ops if len(op) > 1 and op[1] == "INPUT"]
    if input_ops and is_reject_insert(input_ops[0]):
        raise SystemExit(
            f"{label}: first INPUT mutation inserted REJECT: {input_ops[0]}"
        )
    current = (input_save, forward_save, output_save, is_save)
    for index, op in enumerate(ops):
        current = apply_ops(*current, [op])
        live_input = helper._chain_append_lines(current[0], "INPUT")
        if not helper.input_ssh_path_intact(live_input, required_input):
            raise SystemExit(
                f"{label}: interrupt after op {index} {op} blocked SSH: {live_input}"
            )
    assert_contract(label + " final", *current, persist=persist)
    second_action, second_ops = plan_filter(persist, *current)
    if second_action != "unchanged" or second_ops:
        raise SystemExit(
            f"{label}: second pass expected unchanged, got {second_action} {second_ops}"
        )


interrupt_each_op(
    "UFW-only partial INPUT",
    PERSIST,
    ufw_only_input(),
    ufw_only_forward(),
    ufw_only_output(),
    None,
)
print("PASS: UFW-only INPUT stays SSH-safe after every planned mutation")

pr56_recovery_input = (
    "-P INPUT DROP\n"
    f"{API_ALLOW}\n"
    f"{KUBELET_ALLOW}\n"
    + UFW_INPUT
)
updated = expect_filter(
    "PR56 live recovery INPUT",
    PERSIST,
    pr56_recovery_input,
    ufw_only_forward(),
    ufw_only_output(),
    None,
    want_action="changed",
)
assert_contract("PR56 live recovery INPUT", *updated)
if OCI_INPUT_BASELINE.splitlines()[0] not in updated[0]:
    raise SystemExit("PR56 recovery: OCI RELATED/ESTABLISHED missing")
if INPUT_REJECT not in updated[0]:
    raise SystemExit("PR56 recovery: INPUT REJECT missing")
interrupt_each_op(
    "PR56 live recovery partial INPUT",
    PERSIST,
    pr56_recovery_input,
    ufw_only_forward(),
    ufw_only_output(),
    None,
)
print("PASS: exact PR #56 16443+10250+UFW recovery fixture reconciles SSH-safely")

reject_early = "-P INPUT DROP\n" + INPUT_REJECT + "\n" + UFW_INPUT
interrupt_each_op(
    "REJECT misplaced early",
    PERSIST,
    reject_early,
    ufw_only_forward(),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
)
print("PASS: REJECT-before-UFW is restored without an SSH lockout window")

reject_late = "-P INPUT DROP\n" + UFW_INPUT + INPUT_REJECT + "\n"
interrupt_each_op(
    "REJECT misplaced late",
    PERSIST,
    reject_late,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
)
print("PASS: REJECT-after-UFW is moved without an SSH lockout window")

interrupt_each_op(
    "duplicate owned INPUT partial",
    PERSIST,
    dup_input,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
)
interrupt_each_op(
    "missing only 16443 partial",
    PERSIST,
    input_no_api,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
)
print("PASS: duplicate and single-missing INPUT rebuilds stay SSH-safe")

prefix_plus_extra = canonical_input(extra_after=API_ALLOW + "\n")
interrupt_each_op(
    "owned INPUT extra after prefix",
    PERSIST,
    prefix_plus_extra,
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(required_is),
)
print("PASS: extra owned INPUT after a correct prefix is trimmed without lockout")

# InstanceServices: add missing first, never flush, unknown rules mutate nothing
missing_one_is = required_is[:1]
updated = expect_filter(
    "InstanceServices missing one rule",
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(missing_one_is),
    want_action="changed",
)
assert_contract("InstanceServices missing one rule", *updated)
action, is_ops = plan_filter(
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(missing_one_is),
)
if any(op[0] == "-D" for op in is_ops):
    raise SystemExit("InstanceServices missing one rule must append, not delete")
if is_ops[0][0] != "-A" or is_ops[0][1] != "InstanceServices":
    raise SystemExit(f"InstanceServices missing rule must start with -A: {is_ops}")
interrupt_each_op(
    "InstanceServices missing one rule partial",
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(missing_one_is),
)

reordered_is = list(reversed(required_is))
action, reorder_ops = plan_filter(
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(reordered_is),
)
is_chain_ops = [op for op in reorder_ops if len(op) > 1 and op[1] == "InstanceServices"]
first_delete = next(
    (i for i, op in enumerate(is_chain_ops) if op[0] == "-D"),
    None,
)
first_append = next(
    (i for i, op in enumerate(is_chain_ops) if op[0] == "-A"),
    None,
)
if first_append is None or (first_delete is not None and first_delete < first_append):
    raise SystemExit(
        f"InstanceServices reorder must append before deleting: {is_chain_ops}"
    )
if any(op[0] in {"-F", "-X"} for op in reorder_ops):
    raise SystemExit("InstanceServices reorder flushed the chain")
interrupt_each_op(
    "InstanceServices reorder partial",
    PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(reordered_is),
)
print("PASS: InstanceServices adds missing rules before destructive cleanup")

try:
    plan_filter(
        PERSIST,
        ufw_only_input(),
        ufw_only_forward(),
        ufw_only_output(),
        is_dump(required_is + ["-A InstanceServices -p tcp -j ACCEPT"]),
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"unknown IS plus UFW-only expected rc 2: {exc}")
else:
    raise SystemExit("unknown InstanceServices rule must emit zero mutations")
print("PASS: unknown InstanceServices rules cause zero nft mutations")

# --- quoted Oracle InstanceServices comments (live PR #57 apply failure) ---

def expect_argv(label: str, line: str, action: str, want: tuple[str, ...]) -> None:
    got = helper._spec_argv(line, action)
    if got != want:
        raise SystemExit(f"{label}: argv mismatch\n got: {got}\nwant: {want}")
    if any('"' in token or "'" in token for token in got):
        raise SystemExit(f"{label}: quote characters leaked into argv: {got}")


owner_3260_argv = (
    "-A",
    "InstanceServices",
    "-d",
    "169.254.0.2/32",
    "-p",
    "tcp",
    "-m",
    "owner",
    "--uid-owner",
    "0",
    "-m",
    "tcp",
    "--dport",
    "3260",
    "-m",
    "comment",
    "--comment",
    ORACLE_IS_COMMENT,
    "-j",
    "ACCEPT",
)
expect_argv("TCP owner 3260 comment", IS_TCP_OWNER_3260, "-A", owner_3260_argv)
if owner_3260_argv.count(ORACLE_IS_COMMENT) != 1:
    raise SystemExit("Oracle comment must be exactly one argv element")
split_tokens = IS_TCP_OWNER_3260.split()
if "the" not in split_tokens:
    raise SystemExit("whitespace split of quoted comment must be the live failure mode")
if "the" in owner_3260_argv:
    raise SystemExit("quoted parser must not emit standalone token 'the'")

expect_argv(
    "TCP 80 comment",
    IS_TCP_80_COMMENT,
    "-A",
    (
        "-A",
        "InstanceServices",
        "-d",
        "169.254.169.254/32",
        "-p",
        "tcp",
        "-m",
        "tcp",
        "--dport",
        "80",
        "-m",
        "comment",
        "--comment",
        ORACLE_IS_COMMENT,
        "-j",
        "ACCEPT",
    ),
)
expect_argv(
    "UDP 53 comment",
    IS_UDP_53_COMMENT,
    "-A",
    (
        "-A",
        "InstanceServices",
        "-d",
        "169.254.169.254/32",
        "-p",
        "udp",
        "-m",
        "udp",
        "--dport",
        "53",
        "-m",
        "comment",
        "--comment",
        ORACLE_IS_COMMENT,
        "-j",
        "ACCEPT",
    ),
)
expect_argv(
    "UDP 123 comment",
    IS_UDP_123_COMMENT,
    "-A",
    (
        "-A",
        "InstanceServices",
        "-d",
        "169.254.169.254/32",
        "-p",
        "udp",
        "-m",
        "udp",
        "--dport",
        "123",
        "-m",
        "comment",
        "--comment",
        ORACLE_IS_COMMENT,
        "-j",
        "ACCEPT",
    ),
)
expect_argv(
    "TCP REJECT comment",
    IS_TCP_REJECT_COMMENT,
    "-A",
    (
        "-A",
        "InstanceServices",
        "-d",
        "169.254.0.0/16",
        "-p",
        "tcp",
        "-m",
        "tcp",
        "--dport",
        "3260",
        "-m",
        "comment",
        "--comment",
        ORACLE_IS_COMMENT,
        "-j",
        "REJECT",
        "--reject-with",
        "icmp-host-prohibited",
    ),
)
expect_argv(
    "UDP REJECT comment",
    IS_UDP_REJECT_COMMENT,
    "-A",
    (
        "-A",
        "InstanceServices",
        "-d",
        "169.254.0.0/16",
        "-p",
        "udp",
        "-m",
        "udp",
        "--dport",
        "123",
        "-m",
        "comment",
        "--comment",
        ORACLE_IS_COMMENT,
        "-j",
        "REJECT",
        "--reject-with",
        "icmp-port-unreachable",
    ),
)
unquoted_input_argv = helper._spec_argv(API_ALLOW, "-I")
if unquoted_input_argv != (
    "-I",
    "INPUT",
    "-s",
    POD_CIDR,
    "-p",
    "tcp",
    "-m",
    "tcp",
    "--dport",
    API_PORT,
    "-j",
    "ACCEPT",
):
    raise SystemExit(f"unquoted INPUT argv changed: {unquoted_input_argv}")
print("PASS: quoted Oracle comment rules parse to one argv comment element")

try:
    helper._spec_argv(
        '-A InstanceServices -m comment --comment "unterminated',
        "-A",
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"unterminated quote expected rc 2: {exc}")
else:
    raise SystemExit("unterminated quoted comment must fail closed")

malformed_persist = oci_quoted_rules().replace(
    f'"{ORACLE_IS_COMMENT}"',
    f'"{ORACLE_IS_COMMENT}',
    1,
)
try:
    plan_filter(
        malformed_persist,
        pr56_recovery_input,
        ufw_only_forward(),
        ufw_only_output(),
        is_dump([]),
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"malformed persist quote expected rc 2: {exc}")
else:
    raise SystemExit("malformed persist quoting must fail closed before mutation")
print("PASS: malformed quoted comments fail closed before nft mutation")

QUOTED_PERSIST = oci_quoted_rules()
quoted_input, quoted_output, quoted_is = helper.desired_runtime_contract(
    QUOTED_PERSIST, POD_CIDR, API_PORT, KUBELET_PORT
)
if quoted_is != list(QUOTED_IS_RULES):
    raise SystemExit("quoted persist InstanceServices contract mismatch")

single_quoted_live = [rule.replace('"', "'") for rule in quoted_is]
if [helper._spec_key(line) for line in single_quoted_live] != [
    helper._spec_key(line) for line in quoted_is
]:
    raise SystemExit("single-quoted live -S form must match persist keys")

pr57_failed_input = pr56_recovery_input
empty_existing_is = is_dump([])
if "-N InstanceServices" not in (empty_existing_is or ""):
    raise SystemExit("empty existing chain fixture must include -N InstanceServices")
action, live_fail_ops = plan_filter(
    QUOTED_PERSIST,
    pr57_failed_input,
    ufw_only_forward(),
    ufw_only_output(),
    empty_existing_is,
)
if action != "changed":
    raise SystemExit(f"PR57 failed live state expected changed: {live_fail_ops}")
if any(op[0] == "-N" for op in live_fail_ops):
    raise SystemExit("existing empty InstanceServices must not be created again")
first_is_append = next(op for op in live_fail_ops if op[0] == "-A" and op[1] == "InstanceServices")
if first_is_append != owner_3260_argv:
    raise SystemExit(
        "first InstanceServices append must be the live-failed 3260 rule argv: "
        f"{first_is_append}"
    )
if "the" in first_is_append:
    raise SystemExit("planned 3260 append still contains split token 'the'")
updated = expect_filter(
    "PR57 failed live partial state",
    QUOTED_PERSIST,
    pr57_failed_input,
    ufw_only_forward(),
    ufw_only_output(),
    empty_existing_is,
    want_action="changed",
)
assert_contract(
    "PR57 failed live partial state",
    *updated,
    persist=QUOTED_PERSIST,
)
interrupt_each_op(
    "PR57 failed live partial INPUT/IS",
    QUOTED_PERSIST,
    pr57_failed_input,
    ufw_only_forward(),
    ufw_only_output(),
    empty_existing_is,
)
print("PASS: exact PR #57 failed live state resumes from empty InstanceServices")

interrupt_each_op(
    "quoted IS first-N prefix",
    QUOTED_PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(list(quoted_is[:2])),
)
interrupt_each_op(
    "quoted IS arbitrary subset",
    QUOTED_PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump([quoted_is[0], quoted_is[2], quoted_is[5]]),
)
interrupt_each_op(
    "quoted IS duplicate exact rule",
    QUOTED_PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump([quoted_is[0], quoted_is[0], *quoted_is[1:]]),
)
interrupt_each_op(
    "quoted IS wrong order",
    QUOTED_PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(list(reversed(quoted_is))),
)
expect_filter(
    "quoted IS already complete",
    QUOTED_PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(list(quoted_is)),
    want_action="unchanged",
)
expect_filter(
    "quoted IS complete with single-quoted live form",
    QUOTED_PERSIST,
    canonical_input(),
    ufw_only_forward(with_microk8s=True),
    ufw_only_output(with_jump=True),
    is_dump(single_quoted_live),
    want_action="unchanged",
)
print("PASS: exact expected InstanceServices subsets and quoting variants resume")

try:
    plan_filter(
        QUOTED_PERSIST,
        pr57_failed_input,
        ufw_only_forward(),
        ufw_only_output(),
        is_dump([quoted_is[0], "-A InstanceServices -p tcp -j ACCEPT"]),
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"foreign quoted IS mix expected rc 2: {exc}")
else:
    raise SystemExit("foreign InstanceServices rule must emit zero mutations")
print("PASS: foreign InstanceServices rules still cause zero nft mutations")

# --- semantic protocol-match canonicalization (live PR #58 second converge) ---

if len(CLOUD_IMG_IS_RULES) != 15:
    raise SystemExit(f"CLOUD_IMG fixture must have 15 IS rules, got {len(CLOUD_IMG_IS_RULES)}")
if "-m udp" in IS_NTP_IMPLICIT.split(" --dport ", 1)[0]:
    raise SystemExit("persist NTP rule must omit redundant -m udp before --dport")
if "-m udp" not in IS_NTP_EXPLICIT:
    raise SystemExit("live NTP rule must include explicit -m udp")

ntp_persist_tokens = helper._spec_tokens(IS_NTP_IMPLICIT)
ntp_live_tokens = helper._spec_tokens(IS_NTP_EXPLICIT)
if ntp_persist_tokens == ntp_live_tokens:
    raise SystemExit("persist vs live NTP tokens must differ syntactically")
if "udp" not in ntp_persist_tokens or "--dport" not in ntp_persist_tokens:
    raise SystemExit("persist NTP tokens missing protocol/port")
if ntp_persist_tokens.count("-m") != 1 or ntp_live_tokens.count("-m") != 2:
    raise SystemExit("live NTP must add exactly one redundant -m udp module")
if helper._spec_semantic_key(IS_NTP_IMPLICIT) != helper._spec_semantic_key(IS_NTP_EXPLICIT):
    raise SystemExit("implicit and explicit UDP NTP rules must share a semantic key")
if helper._spec_semantic_key(IS_TCP_80_IMPLICIT) != helper._spec_semantic_key(IS_TCP_80_COMMENT):
    raise SystemExit("implicit and explicit TCP dport rules must share a semantic key")
if helper._spec_semantic_key(IS_NTP_EXPLICIT) != helper._spec_semantic_key(IS_NTP_EXPLICIT):
    raise SystemExit("explicit UDP both sides must remain equal")

ntp_argv = helper._spec_argv(IS_NTP_IMPLICIT, "-A")
if ntp_argv != (
    "-A",
    "InstanceServices",
    "-d",
    "169.254.169.254/32",
    "-p",
    "udp",
    "--dport",
    "123",
    "-m",
    "comment",
    "--comment",
    ORACLE_IS_COMMENT,
    "-j",
    "ACCEPT",
):
    raise SystemExit(f"persist NTP execution argv was rewritten: {ntp_argv}")
if ntp_argv[5:7] == ("udp", "-m"):
    raise SystemExit("execution argv must not insert -m udp")

if helper._spec_semantic_key(IS_NTP_IMPLICIT) == helper._spec_semantic_key(IS_TCP_80_COMMENT):
    raise SystemExit("UDP and TCP dport rules must not be semantically equal")
udp_sport = oracle_is_rule(
    "-d 169.254.169.254/32 -p udp --sport 123",
    "-j ACCEPT",
)
if helper._spec_semantic_key(IS_NTP_IMPLICIT) == helper._spec_semantic_key(udp_sport):
    raise SystemExit("sport and dport rules must not be semantically equal")
udp_other_port = oracle_is_rule(
    "-d 169.254.169.254/32 -p udp --dport 53",
    "-j ACCEPT",
)
if helper._spec_semantic_key(IS_NTP_IMPLICIT) == helper._spec_semantic_key(udp_other_port):
    raise SystemExit("different UDP ports must not be semantically equal")
udp_other_dest = oracle_is_rule(
    "-d 169.254.0.2/32 -p udp --dport 123",
    "-j ACCEPT",
)
if helper._spec_semantic_key(IS_NTP_IMPLICIT) == helper._spec_semantic_key(udp_other_dest):
    raise SystemExit("different destinations must not be semantically equal")
udp_other_comment = IS_NTP_IMPLICIT.replace(ORACLE_IS_COMMENT, "other comment")
if helper._spec_semantic_key(IS_NTP_IMPLICIT) == helper._spec_semantic_key(udp_other_comment):
    raise SystemExit("different comments must not be semantically equal")
if helper._spec_semantic_key(IS_TCP_OWNER_3260) == helper._spec_semantic_key(
    oracle_is_rule("-d 169.254.0.2/32 -p tcp -m tcp --dport 3260", "-j ACCEPT")
):
    raise SystemExit("owner match must not be normalized away")
print("PASS: quoted Oracle protocol-match syntax is semantically equivalent")

CLOUD_IMG_PERSIST = oci_cloud_img_rules()
cloud_input, cloud_output, cloud_is = helper.desired_runtime_contract(
    CLOUD_IMG_PERSIST, POD_CIDR, API_PORT, KUBELET_PORT
)
if cloud_is != list(CLOUD_IMG_IS_RULES):
    raise SystemExit("CLOUD_IMG persist InstanceServices contract mismatch")
if cloud_is.count(IS_NTP_IMPLICIT) != 1:
    raise SystemExit("CLOUD_IMG persist must keep implicit NTP rule")

cloud_live_is = []
for rule in cloud_is:
    cloud_live_is.append(
        helper.format_spec_line(simulate_iptables_nft_s_tokens(helper._spec_tokens(rule)))
    )
if len(cloud_live_is) != 15:
    raise SystemExit("live CLOUD_IMG InstanceServices dump must have 15 rules")
if cloud_live_is.count(IS_NTP_EXPLICIT) != 1:
    raise SystemExit("simulated live NTP rule must be explicit -m udp form")
if [helper._spec_tokens(line) for line in cloud_live_is] == [
    helper._spec_tokens(line) for line in cloud_is
]:
    raise SystemExit("simulated first apply must change NTP syntax before second compare")

cloud_canonical_input = (
    "-P INPUT DROP\n" + "".join(line + "\n" for line in cloud_input) + UFW_INPUT
)
cloud_output_save = "-P OUTPUT ACCEPT\n" + cloud_output + "\n" + UFW_OUTPUT
expect_filter(
    "PR58 live second converge 15-rule NTP canonicalization",
    CLOUD_IMG_PERSIST,
    cloud_canonical_input,
    ufw_only_forward(with_microk8s=True),
    cloud_output_save,
    is_dump(cloud_live_is),
    want_action="unchanged",
)
assert_contract(
    "PR58 live second converge 15-rule NTP canonicalization",
    cloud_canonical_input,
    ufw_only_forward(with_microk8s=True),
    cloud_output_save,
    is_dump(cloud_live_is),
    persist=CLOUD_IMG_PERSIST,
)

updated = expect_filter(
    "PR58 first apply then canonicalized second run",
    CLOUD_IMG_PERSIST,
    pr57_failed_input,
    ufw_only_forward(),
    ufw_only_output(),
    is_dump([]),
    want_action="changed",
)
live_after_first = helper._chain_append_lines(updated[3] or "", "InstanceServices")
if IS_NTP_EXPLICIT not in live_after_first:
    raise SystemExit(
        "simulated iptables-nft -S after first apply must emit explicit NTP -m udp"
    )
if IS_NTP_IMPLICIT in live_after_first:
    raise SystemExit("simulated live dump must not keep persist NTP syntax unchanged")
second_action, second_ops = plan_filter(CLOUD_IMG_PERSIST, *updated)
if second_action != "unchanged" or second_ops:
    raise SystemExit(
        f"canonicalized second run expected unchanged, got {second_action} {second_ops}"
    )
print("PASS: exact PR #58 15-rule live NTP normalization is unchanged")

try:
    plan_filter(
        CLOUD_IMG_PERSIST,
        cloud_canonical_input,
        ufw_only_forward(with_microk8s=True),
        cloud_output_save,
        is_dump(cloud_live_is[:-1] + ["-A InstanceServices -p tcp -m ttl --ttl-eq 1 -j ACCEPT"]),
    )
except helper.NormalizeError as exc:
    if exc.code != helper.EXIT_UNEXPECTED:
        raise SystemExit(f"unknown module expected rc 2: {exc}")
else:
    raise SystemExit("unknown InstanceServices module must remain foreign")
print("PASS: unknown protocol-match modules remain fail-closed")
print("PASS: nft filter runtime planner contract")


# --- repository contract ---

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


UNIT = (
    ROOT
    / "ansible/roles/microk8s/templates/tradingchassis-oci-microk8s-firewall.service.j2"
)
HANDLERS = ROOT / "ansible/roles/microk8s/handlers/main.yml"
tasks = read(TASKS)
defaults = read(DEFAULTS)
helper_src = read(HELPER)
unit_src = read(UNIT)
handlers = read(HANDLERS)

if "normalize_oci_microk8s_firewall.py" not in tasks:
    raise SystemExit("microk8s role must invoke the firewall helper")
if 'microk8s_pod_cidr: "10.1.0.0/16"' not in defaults:
    raise SystemExit("defaults must set canonical MicroK8s 1.29 pod CIDR")
if 'microk8s_apiserver_port: "16443"' not in defaults:
    raise SystemExit("defaults must set MicroK8s API port 16443")
if 'microk8s_kubelet_port: "10250"' not in defaults:
    raise SystemExit("defaults must set MicroK8s kubelet port 10250")
if "microk8s_firewall_helper_path:" not in defaults:
    raise SystemExit("defaults must set the installed firewall helper path")
if "tradingchassis-oci-microk8s-firewall.service" not in defaults:
    raise SystemExit("defaults must set the repository-owned firewall unit name")
if "microk8s_pod_cidr | trim" not in tasks:
    raise SystemExit("tasks must pass pod CIDR from role defaults")
if "microk8s_apiserver_port | trim" not in tasks:
    raise SystemExit("tasks must pass API port from role defaults")
if "microk8s_kubelet_port | trim" not in tasks:
    raise SystemExit("tasks must pass kubelet port from role defaults")
if "--kubelet-port" not in tasks:
    raise SystemExit("tasks must pass --kubelet-port to the helper")
if "--apply-runtime" not in tasks:
    raise SystemExit("role must reconcile nft runtime via --apply-runtime")
if tasks.count("10.1.0.0/16") != 0:
    raise SystemExit("tasks must not hard-code the pod CIDR")
if re.search(r'(?m)^\s+-\s+"16443"\s*$', tasks):
    raise SystemExit("tasks must not bury 16443 as a literal argv value")
if re.search(r'(?m)^\s+-\s+"10250"\s*$', tasks):
    raise SystemExit("tasks must not bury 10250 as a literal argv value")
if "/tmp/tradingchassis-normalize" in tasks:
    raise SystemExit("firewall helper must not live in /tmp")

for register_name in (
    "microk8s_oci_firewall_file",
    "microk8s_iptables_nft_stat",
    "microk8s_oci_firewall_runtime",
    "microk8s_oci_firewall_unit",
    "microk8s_oci_firewall_unit_enable",
):
    if f"register: {register_name}" not in tasks:
        raise SystemExit(f"missing role-prefixed register {register_name}")
for match in re.finditer(r"(?m)^\s+register:\s+(\S+)\s*$", tasks):
    var = match.group(1)
    if not var.startswith("microk8s_"):
        raise SystemExit(f"register {var} must use the microk8s_ role prefix")

if "microk8s_firewall_rules_file" not in tasks:
    raise SystemExit("persistent normalization must use the role rules-file default")
if "microk8s_iptables_nft" not in tasks:
    raise SystemExit("role must assert the iptables-nft path from defaults")
if "/usr/sbin/iptables-nft" not in defaults:
    raise SystemExit("defaults must pin /usr/sbin/iptables-nft")
if "iptables-legacy" in tasks and "are not modified" not in tasks:
    raise SystemExit("role must not mutate iptables-legacy")
if "iptables-persistent" in tasks or "netfilter-persistent" in tasks:
    raise SystemExit("role must not install a second full-table firewall manager")
if "force: \"{{ microk8s_oci_firewall_unit is changed }}\"" not in tasks:
    raise SystemExit(
        "unit enablement must refresh [Install] aliases when the unit file changes"
    )
if "state: started" in tasks.split("Enable OCI MicroK8s firewall boot reconciliation unit", 1)[-1][:500]:
    raise SystemExit("boot unit enablement must not start the oneshot during converge")

install_idx = tasks.find("Install MicroK8s from the pinned snap channel")
ready_idx = tasks.find("Wait for MicroK8s to become ready")
ufw_idx = tasks.find("Enable UFW with the explicit MicroK8s-compatible host policy")
helper_idx = tasks.find("Normalize persistent OCI cloud-image IPv4 firewall for MicroK8s")
apply_idx = tasks.find("Reconcile nft-compatible OCI MicroK8s firewall runtime")
unit_idx = tasks.find("Install OCI MicroK8s firewall boot reconciliation unit")
flush_idx = tasks.find("Flush systemd reload before enabling the firewall boot unit")
enable_idx = tasks.find("Enable OCI MicroK8s firewall boot reconciliation unit")
if min(
    install_idx,
    ready_idx,
    ufw_idx,
    helper_idx,
    apply_idx,
    unit_idx,
    flush_idx,
    enable_idx,
) < 0:
    raise SystemExit("microk8s role is missing required firewall/MicroK8s tasks")
if not (
    helper_idx
    < ufw_idx
    < apply_idx
    < unit_idx
    < flush_idx
    < enable_idx
    < install_idx
    < ready_idx
):
    raise SystemExit(
        "persist, UFW enable, runtime apply, and boot unit must precede MicroK8s"
    )

if re.search(r'(?m)^\s+-\s+(-n|--line-numbers)\s*$', tasks):
    raise SystemExit("runtime deletion must not use numeric line numbers")
if re.search(r'(?m)^\s+-\s+(-F|-X|--flush)\s*$', tasks):
    raise SystemExit("role must not flush iptables chains")
if "iptables-restore" in tasks or "iptables-nft-restore" in tasks:
    raise SystemExit("role must not restore a full iptables table")
if "ufw disable" in tasks or "state: disabled" in tasks:
    raise SystemExit("role must not disable UFW")
if "10.152.183.1" in tasks or "10.1.118" in tasks:
    raise SystemExit("role must not hard-code Kubernetes Service or pod IPs")
if "--handle" in tasks or "nft delete" in tasks:
    raise SystemExit("runtime deletion must not use nft handles")
if "notify: Reload systemd for OCI MicroK8s firewall boot unit" not in tasks:
    raise SystemExit("unit file changes must notify the systemd daemon-reload handler")
if "meta: flush_handlers" not in tasks:
    raise SystemExit("systemd daemon-reload handler must flush before unit enablement")
if "daemon_reload: true" not in handlers:
    raise SystemExit("firewall boot unit handler must daemon-reload systemd")
if "when: microk8s_oci_firewall_unit is changed" in tasks:
    raise SystemExit("daemon reload must be a handler, not an inline when: changed task")
if "changed_when: (microk8s_oci_firewall_runtime.stdout | trim) == \"changed\"" not in tasks:
    raise SystemExit("runtime apply must report changed only when the helper says changed")
print("PASS: Ansible task ordering and semantic nft contract")

if helper.IPTABLES_NFT != "/usr/sbin/iptables-nft":
    raise SystemExit("helper must pin IPTABLES_NFT to /usr/sbin/iptables-nft")
if "/sbin/iptables-legacy" in helper_src or "/usr/sbin/iptables-legacy" in helper_src:
    raise SystemExit("helper must not invoke iptables-legacy")
if "iptables-restore" in helper_src or "iptables-nft-restore" in helper_src:
    raise SystemExit("helper must not restore a whole iptables table")
if "shell=True" in helper_src:
    raise SystemExit("helper must not invoke iptables through a shell")
if "os.system" in helper_src or "os.popen" in helper_src or "Popen" in helper_src:
    raise SystemExit("helper must not use os.system/os.popen/Popen")
if "10.152.183.1" in helper_src or "10.1.118" in helper_src:
    raise SystemExit("helper must not hard-code Kubernetes Service or pod IPs")
if "10.1.0.0/16" in helper_src:
    raise SystemExit("helper must take pod CIDR as input, not hard-code it")
if '"-F", "-X", "--flush"' not in helper_src and "'-F', '-X', '--flush'" not in helper_src:
    raise SystemExit("helper must refuse flush operations")
if "INPUT_REJECT" not in helper_src or "FORWARD_REJECT" not in helper_src:
    raise SystemExit("helper must retain both INPUT and FORWARD contracts")
if "10250" in helper_src:
    raise SystemExit("helper must take kubelet port as input, not hard-code it")
if "16443" in helper_src:
    raise SystemExit("helper must take API port as input, not hard-code it")
if "subprocess.run" not in helper_src:
    raise SystemExit("apply-runtime must invoke iptables-nft via subprocess.run")
if "append_line.split(" in helper_src:
    raise SystemExit("iptables specs must not be tokenized with str.split")
if "shlex.split" not in helper_src:
    raise SystemExit("iptables specs must preserve quoted comment arguments")
if "def _spec_semantic_key" not in helper_src:
    raise SystemExit("comparison must use a semantic spec key")
if "parts = _spec_tokens(append_line)" not in helper_src:
    raise SystemExit("execution argv must keep parsed persist tokens")
if "eval(" in helper_src:
    raise SystemExit("helper must not eval")
if "reversed(required_input)" in helper_src:
    raise SystemExit("must not prepend REJECT by reversing the full INPUT contract")
if "input_ssh_path_intact" not in helper_src:
    raise SystemExit("helper must check SSH accessibility while planning INPUT")
print("PASS: helper apply-runtime uses argv-only iptables-nft without flush/restore")

for needle in (
    "DefaultDependencies=no",
    "After=local-fs.target ufw.service",
    "Wants=ufw.service network-pre.target",
    "PartOf=ufw.service",
    "Before=network-pre.target snap.microk8s.daemon-containerd.service snap.microk8s.daemon-kubelite.service",
    "Type=oneshot",
    "RemainAfterExit=yes",
    "WantedBy=multi-user.target ufw.service",
    "RequiredBy=snap.microk8s.daemon-containerd.service snap.microk8s.daemon-kubelite.service",
    "--apply-runtime",
    "{{ microk8s_python_interpreter }}",
    "{{ microk8s_firewall_helper_path }}",
    "{{ microk8s_firewall_rules_file }}",
    "{{ microk8s_pod_cidr | trim }}",
    "{{ microk8s_apiserver_port | trim }}",
    "{{ microk8s_kubelet_port | trim }}",
):
    if needle not in unit_src:
        raise SystemExit(f"firewall unit missing {needle}")
if "Sleep" in unit_src or "sleep" in unit_src:
    raise SystemExit("firewall unit must not sleep")
if "network-online" in unit_src:
    raise SystemExit("firewall unit must not wait for network-online")
if "iptables-legacy" in unit_src or "iptables-restore" in unit_src:
    raise SystemExit("firewall unit must not invoke legacy/restore")
if "10.1.0.0/16" in unit_src or "16443" in unit_src or "10250" in unit_src:
    raise SystemExit("firewall unit must template CIDR/ports from role defaults")
if re.search(r"(?m)^Requires=.*snap\.microk8s", unit_src):
    raise SystemExit("firewall unit must not Require snap units (cycle risk)")
if "PartOf=snap" in unit_src:
    raise SystemExit("firewall unit must not be PartOf snap units")
if re.search(r"(?m)^WantedBy=ufw\.service$", unit_src):
    raise SystemExit("WantedBy=ufw.service must be combined with multi-user.target")
if "BindsTo=ufw.service" in unit_src:
    raise SystemExit("firewall unit must not BindsTo ufw.service")
print("PASS: systemd boot unit ordering and ExecStart contract")

analyze = shutil.which("systemd-analyze")
if analyze is not None:
    rendered = (
        unit_src.replace("{{ microk8s_python_interpreter }}", "/usr/bin/python3")
        .replace(
            "{{ microk8s_firewall_helper_path }}",
            "/usr/local/lib/tradingchassis/normalize_oci_microk8s_firewall.py",
        )
        .replace("{{ microk8s_firewall_rules_file }}", "/etc/iptables/rules.v4")
        .replace("{{ microk8s_pod_cidr | trim }}", "192.0.2.0/24")
        .replace("{{ microk8s_apiserver_port | trim }}", "1")
        .replace("{{ microk8s_kubelet_port | trim }}", "2")
    )
    if "{{" in rendered:
        raise SystemExit("firewall unit still contains unrendered Jinja")
    with tempfile.TemporaryDirectory() as tmp:
        unit_path = Path(tmp) / "tradingchassis-oci-microk8s-firewall.service"
        unit_path.write_text(rendered, encoding="utf-8")
        proc = subprocess.run(
            [analyze, "verify", str(unit_path)],
            check=False,
            capture_output=True,
            text=True,
        )
        verify_text = (proc.stdout + proc.stderr).lower()
        if "cyclic" in verify_text or "ordering cycle" in verify_text:
            raise SystemExit(
                f"systemd-analyze verify reported a cycle:\n{proc.stdout}{proc.stderr}"
            )
    print("PASS: systemd-analyze verify reported no unit ordering cycle")
else:
    print("PASS: systemd-analyze not installed; unit cycle check is static")

readme = read(README)
for needle in (
    "unconditional IPv4 FORWARD REJECT",
    "DEFAULT_FORWARD_POLICY",
    "InstanceServices",
    "/etc/iptables/rules.v4",
    "INPUT REJECT",
    "kube-proxy",
    "16443",
    "10250",
    "10.1.0.0/16",
    "kubelet",
    "tradingchassis-oci-microk8s-firewall.service",
    "UFW boot",
    "PartOf=ufw.service",
    "RequiredBy",
    "WantedBy=ufw.service",
    "quoted",
):
    if needle not in readme:
        raise SystemExit(f"ansible/README.md missing {needle}")
if "iptables -F" in readme and "Do not" not in readme:
    raise SystemExit("ansible/README.md must not recommend iptables flushing")
if "iptables-persistent" in readme and "Do not" not in readme:
    raise SystemExit("ansible/README.md must not recommend iptables-persistent")
print("PASS: ansible README documents FORWARD, INPUT, and boot contracts")

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
    "10250",
    "kubelet",
    "tradingchassis-oci-microk8s-firewall.service",
    "NOT yet",
    "PartOf=ufw.service",
    "RequiredBy",
    "WantedBy=ufw.service",
    "quoted",
):
    if needle.lower() not in v2_lower:
        raise SystemExit(f"V2 clean-room doc missing {needle}")
print("PASS: V2 clean-room doc covers OCI firewall problems")

changelog = read(CHANGELOG)
unreleased = changelog.split("## [0.1.0]", 1)[0]
if "10250" not in unreleased and "kubelet" not in unreleased.lower():
    raise SystemExit("CHANGELOG [Unreleased] must mention the kubelet INPUT allow")
if "reboot" not in unreleased.lower() and "boot" not in unreleased.lower():
    raise SystemExit("CHANGELOG [Unreleased] must mention boot/reboot firewall reconciliation")
if "quoted" not in unreleased.lower():
    raise SystemExit("CHANGELOG [Unreleased] must mention quoted iptables comment parsing")
print("PASS: CHANGELOG [Unreleased] records the kubelet allow and boot reconcile")

workflow = read(WORKFLOW)
if "test_ansible_oci_forward_reject_contract.sh" not in workflow:
    raise SystemExit("CI must run the OCI firewall contract test")
print("PASS: CI enforces the OCI firewall contract")

implementation_files = (TASKS, HELPER, README, V2_DOC, DEFAULTS, UNIT, HANDLERS)
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

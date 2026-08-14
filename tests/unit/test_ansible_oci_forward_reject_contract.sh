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
if 'microk8s_kubelet_port: "10250"' not in defaults:
    raise SystemExit("defaults must set MicroK8s kubelet port 10250")
if "microk8s_pod_cidr | trim" not in tasks:
    raise SystemExit("tasks must pass pod CIDR from role defaults")
if "microk8s_apiserver_port | trim" not in tasks:
    raise SystemExit("tasks must pass API port from role defaults")
if "microk8s_kubelet_port | trim" not in tasks:
    raise SystemExit("tasks must pass kubelet port from role defaults")
if "--kubelet-port" not in tasks:
    raise SystemExit("tasks must pass --kubelet-port to the helper")
if tasks.count("10.1.0.0/16") != 0:
    raise SystemExit("tasks must not hard-code the pod CIDR")
if re.search(r'(?m)^\s+-\s+"16443"\s*$', tasks):
    raise SystemExit("tasks must not bury 16443 as a literal argv value")
if re.search(r'(?m)^\s+-\s+"10250"\s*$', tasks):
    raise SystemExit("tasks must not bury 10250 as a literal argv value")

for register_name in (
    "microk8s_oci_firewall_file",
    "microk8s_iptables_nft_stat",
    "microk8s_oci_forward_reject_check",
    "microk8s_oci_forward_reject_delete",
    "microk8s_oci_input_save",
    "microk8s_oci_input_plan",
    "microk8s_oci_input_kubelet_allow_delete",
    "microk8s_oci_input_api_allow_delete",
    "microk8s_oci_input_kubelet_allow_insert",
    "microk8s_oci_input_api_allow_insert",
):
    if f"register: {register_name}" not in tasks:
        raise SystemExit(f"missing role-prefixed register {register_name}")
for match in re.finditer(r"(?m)^\s+register:\s+(\S+)\s*$", tasks):
    var = match.group(1)
    if not var.startswith("microk8s_"):
        raise SystemExit(f"register {var} must use the microk8s_ role prefix")
if "microk8s_oci_input_plan_action" not in tasks:
    raise SystemExit("role must record the INPUT plan action")
if "microk8s_oci_input_plan_ports" not in tasks:
    raise SystemExit("role must record the INPUT plan ports")
plan_fact_block = tasks.split(
    "Record nft-compatible INPUT pod-host allow plan", 1
)
if len(plan_fact_block) != 2 or "changed_when: false" not in plan_fact_block[1][:400]:
    raise SystemExit("INPUT plan set_fact must not report changed")

if "/etc/iptables/rules.v4" not in tasks:
    raise SystemExit("persistent normalization must target /etc/iptables/rules.v4")
if "/usr/sbin/iptables-nft" not in tasks:
    raise SystemExit("runtime normalization must use /usr/sbin/iptables-nft")
if "iptables-legacy" in tasks and "are not modified" not in tasks:
    raise SystemExit("role must not mutate iptables-legacy")
if "-S" not in tasks:
    raise SystemExit("runtime INPUT plan must use iptables-nft -S")

install_idx = tasks.find("Install MicroK8s from the pinned snap channel")
ready_idx = tasks.find("Wait for MicroK8s to become ready")
ufw_idx = tasks.find("Enable UFW with the explicit MicroK8s-compatible host policy")
helper_idx = tasks.find("Normalize persistent OCI cloud-image IPv4 firewall for MicroK8s")
forward_idx = tasks.find("Delete nft-compatible unconditional IPv4 FORWARD REJECT")
kubelet_insert_idx = tasks.find("Insert nft-compatible INPUT pod-kubelet allow")
api_insert_idx = tasks.find("Insert nft-compatible INPUT pod-API allow")
if min(
    install_idx,
    ready_idx,
    ufw_idx,
    helper_idx,
    forward_idx,
    kubelet_insert_idx,
    api_insert_idx,
) < 0:
    raise SystemExit("microk8s role is missing required firewall/MicroK8s tasks")
if not (
    helper_idx
    < forward_idx
    < kubelet_insert_idx
    < api_insert_idx
    < ufw_idx
    < install_idx
    < ready_idx
):
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
    "--kubelet-port",
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
if "10250" in helper_src:
    raise SystemExit("helper must take kubelet port as input, not hard-code it")
if "16443" in helper_src:
    raise SystemExit("helper must take API port as input, not hard-code it")
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
    "10250",
    "10.1.0.0/16",
    "kubelet",
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
    "10250",
    "kubelet",
):
    if needle.lower() not in v2_lower:
        raise SystemExit(f"V2 clean-room doc missing {needle}")
print("PASS: V2 clean-room doc covers OCI firewall problems")

changelog = read(CHANGELOG)
unreleased = changelog.split("## [0.1.0]", 1)[0]
if "10250" not in unreleased and "kubelet" not in unreleased.lower():
    raise SystemExit("CHANGELOG [Unreleased] must mention the kubelet INPUT allow")
print("PASS: CHANGELOG [Unreleased] records the kubelet allow")

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

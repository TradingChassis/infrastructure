#!/usr/bin/env bash
# Shared helpers for TradingChassis clean-room operator tools.
# Source only. Does not mutate infrastructure by itself.
# shellcheck shell=bash
# Shared CLEAN_ROOM_* constants are consumed by scripts that source this helper.
# They appear unused when this file is linted standalone.
# shellcheck disable=SC2034

CLEAN_ROOM_TF_CANONICAL_VERSION="1.15.8"
CLEAN_ROOM_ANSIBLE_CORE_PIN="2.21.2"
CLEAN_ROOM_VENV_DIR="${HOME}/.venvs/tradingchassis-ansible"
CLEAN_ROOM_TF_BIN_DIR="${HOME}/bin"
CLEAN_ROOM_SSH_USER="ubuntu"
CLEAN_ROOM_SSH_KEY="${HOME}/.ssh/tradingchassis"
CLEAN_ROOM_OCI_PROFILE="tradingchassis"
CLEAN_ROOM_SCRATCH_MOUNT="/mnt/scratch"
CLEAN_ROOM_BLANK_SCRATCH_MSG="The scratch volume has no filesystem. Set scratch_storage_allow_format=true"

clean_room_info() { printf 'INFO: %s\n' "$1"; }
clean_room_pass() { printf 'PASS: %s\n' "$1"; }
clean_room_warn() { printf 'WARN: %s\n' "$1"; }
clean_room_fail() { printf 'FAIL: %s\n' "$1"; }

clean_room_die() {
  clean_room_fail "$1"
  exit "${2:-1}"
}

clean_room_python() {
  if command -v python3.12 >/dev/null 2>&1; then
    command -v python3.12
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  return 1
}

clean_room_warn_tmux() {
  if [[ -z "${TMUX:-}" ]]; then
    cat <<'EOF'
WARNING: tmux not detected.
Running the clean-room workflow inside tmux is recommended for Cloud Shell
browser/network disconnect resilience.
EOF
  else
    clean_room_info "tmux session detected"
  fi
}

clean_room_terraform_zip_arch() {
  local machine="${1:-$(uname -m)}"
  case "$machine" in
    aarch64|arm64)
      printf '%s\n' arm64
      ;;
    x86_64|amd64)
      printf '%s\n' amd64
      ;;
    *)
      return 1
      ;;
  esac
}

clean_room_terraform_version_ok() {
  local ver="${1:-}"
  local py
  py="$(clean_room_python)" || return 1
  "$py" - "$ver" <<'PY'
import sys

ver = sys.argv[1].strip().lstrip("v")
parts = []
for token in ver.split("."):
    digits = "".join(ch for ch in token if ch.isdigit())
    if digits == "":
        break
    parts.append(int(digits))
    if len(parts) == 3:
        break
while len(parts) < 3:
    parts.append(0)
major, minor, patch = parts
ok = (major, minor, patch) >= (1, 15, 0) and (major, minor) < (1, 16)
sys.exit(0 if ok else 1)
PY
}

# True when an active (non-comment, non-blank) line contains < or >.
# Full-line comments such as sed 's/<.*$//' are documentation, not placeholders.
clean_room_has_angle_placeholders() {
  local path="$1"
  grep -Eq '^[[:space:]]*[^#[:space:]].*[<>]' "$path"
}

clean_room_require_exact_input() {
  local expected="$1"
  local reply=""
  if ! IFS= read -r reply; then
    reply=""
  fi
  if [[ "$reply" != "$expected" ]]; then
    return 1
  fi
  return 0
}

clean_room_is_blank_scratch_gate() {
  local log="$1"
  grep -Fq "$CLEAN_ROOM_BLANK_SCRATCH_MSG" "$log"
}

clean_room_plan_is_destructive() {
  local json_file="$1"
  local py
  py="$(clean_room_python)" || return 2
  "$py" - "$json_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    plan = json.load(handle)

destructive = []
for change in plan.get("resource_changes") or []:
    actions = list((change.get("change") or {}).get("actions") or [])
    if "delete" in actions:
        address = change.get("address") or "unknown"
        destructive.append(f"{address} actions={actions}")

if destructive:
    for line in destructive:
        print(line)
    sys.exit(2)
sys.exit(0)
PY
}

clean_room_parse_play_recap() {
  local log="$1"
  local require_zero_changed="${2:-1}"
  local py
  py="$(clean_room_python)" || return 2
  "$py" - "$log" "$require_zero_changed" <<'PY'
import re
import sys

path = sys.argv[1]
require_zero_changed = sys.argv[2] != "0"
text = open(path, encoding="utf-8", errors="replace").read()
recap = False
hosts = []
pattern = re.compile(
    r"^(\S+)\s+:\s+ok=(\d+)\s+changed=(\d+)\s+unreachable=(\d+)\s+failed=(\d+)"
)
for line in text.splitlines():
    if line.startswith("PLAY RECAP"):
        recap = True
        continue
    if not recap:
        continue
    match = pattern.match(line.strip())
    if match:
        hosts.append(
            {
                "host": match.group(1),
                "ok": int(match.group(2)),
                "changed": int(match.group(3)),
                "unreachable": int(match.group(4)),
                "failed": int(match.group(5)),
            }
        )

if not hosts:
    print("FAIL: PLAY RECAP not found or not parseable")
    sys.exit(2)

errors = []
for host in hosts:
    if host["unreachable"] != 0:
        errors.append(f"{host['host']} unreachable={host['unreachable']}")
    if host["failed"] != 0:
        errors.append(f"{host['host']} failed={host['failed']}")
    if require_zero_changed and host["changed"] != 0:
        errors.append(f"{host['host']} changed={host['changed']}")

if errors:
    print("FAIL: " + "; ".join(errors))
    sys.exit(1)
print("PASS: PLAY RECAP ok changed=0 unreachable=0 failed=0")
sys.exit(0)
PY
}

# Stream ansible-playbook stdout/stderr live while retaining a complete log.
# Returns the ansible-playbook exit code (PIPESTATUS[0]), never tee's.
# Callers must wrap the invocation with set +e if they need to inspect a
# non-zero status under set -e. pipefail is restored before return.
clean_room_run_playbook() {
  local log="$1"
  local rc=0
  shift
  set +e
  set +o pipefail
  ANSIBLE_CONFIG="${ANSIBLE_CONFIG_FILE:-}" "${ANSIBLE_PLAYBOOK:?ansible-playbook is not set}" "$@" 2>&1 | tee "$log"
  rc="${PIPESTATUS[0]}"
  set -o pipefail
  return "$rc"
}

clean_room_eval_argo_json() {
  local json_file="$1"
  local py
  py="$(clean_room_python)" || return 2
  "$py" - "$json_file" <<'PY'
import json
import sys

# PASS: every Application is Synced + Healthy.
# WAIT: incomplete first-reconcile states, including the live-proven
# OutOfSync/Missing pair. Unknown means status is not yet assessed, not
# that the Application is Healthy or terminally Degraded; the bounded
# waiter still times out if it never converges.
# FAIL-FAST (3): Health Degraded — resources were assessed as unhealthy.
# FAIL (2): empty set or JSON that cannot be evaluated.

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except (OSError, UnicodeError, json.JSONDecodeError) as exc:
    print(f"FAIL: Argo Application JSON is not evaluable ({type(exc).__name__})")
    sys.exit(2)

try:
    items = data.get("items")
    if not isinstance(items, list) or not items:
        print("FAIL: no Argo Applications found")
        sys.exit(2)

    immediate = []
    pending = []
    for item in items:
        if not isinstance(item, dict):
            print("FAIL: Argo Application item is not an object")
            sys.exit(2)
        name = ((item.get("metadata") or {}).get("name")) or "unnamed"
        status = item.get("status") or {}
        if not isinstance(status, dict):
            status = {}
        sync = ((status.get("sync") or {}).get("status")) or ""
        health = ((status.get("health") or {}).get("status")) or ""
        if health == "Degraded":
            immediate.append(f"{name} sync={sync or 'unset'} health={health}")
            continue
        if sync != "Synced" or health != "Healthy":
            pending.append(f"{name} sync={sync or 'unset'} health={health or 'unset'}")

    if immediate:
        print("FAIL: " + "; ".join(immediate))
        sys.exit(3)
    if pending:
        print("WAIT: " + "; ".join(pending))
        sys.exit(1)
    print("PASS: all Argo Applications are Synced and Healthy")
    sys.exit(0)
except SystemExit:
    raise
except Exception as exc:
    print(f"FAIL: Argo Application evaluation failed ({type(exc).__name__})")
    sys.exit(2)
PY
}

clean_room_eval_pods_json() {
  local json_file="$1"
  local py
  py="$(clean_room_python)" || return 2
  "$py" - "$json_file" <<'PY'
import json
import sys

UNHEALTHY_WAITING = {
    "CrashLoopBackOff",
    "ImagePullBackOff",
    "ErrImagePull",
    "CreateContainerError",
    "InvalidImageName",
}

data = json.load(open(sys.argv[1], encoding="utf-8"))
items = data.get("items")
if not isinstance(items, list) or not items:
    print("WAIT: no Pods found")
    sys.exit(1)

unhealthy = []
pending = []
for item in items:
    metadata = item.get("metadata") or {}
    namespace = metadata.get("namespace") or "unknown"
    status = item.get("status") or {}
    phase = status.get("phase") or ""
    if phase == "Succeeded":
        continue
    reasons = []
    for cs in status.get("containerStatuses") or []:
        waiting = ((cs.get("state") or {}).get("waiting") or {})
        reason = waiting.get("reason") or ""
        if reason:
            reasons.append(reason)
        last_waiting = ((cs.get("lastState") or {}).get("waiting") or {})
        last_reason = last_waiting.get("reason") or ""
        if last_reason in UNHEALTHY_WAITING:
            reasons.append(last_reason)
    if phase == "Failed" or any(reason in UNHEALTHY_WAITING for reason in reasons):
        shown = ",".join(reasons) if reasons else phase
        unhealthy.append(f"namespace={namespace} phase={phase} reason={shown}")
        continue
    if phase == "Running":
        statuses = status.get("containerStatuses") or []
        if statuses and all(cs.get("ready") for cs in statuses):
            continue
        pending.append(f"namespace={namespace} phase={phase} reason=not-ready")
        continue
    pending.append(f"namespace={namespace} phase={phase or 'unset'}")

if unhealthy:
    print("FAIL: " + "; ".join(unhealthy))
    sys.exit(2)
if pending:
    print("WAIT: " + "; ".join(pending))
    sys.exit(1)
print("PASS: Kubernetes workloads are healthy")
sys.exit(0)
PY
}

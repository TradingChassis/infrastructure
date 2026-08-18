#!/usr/bin/env bash
# shellcheck shell=bash
# Static and stubbed contract tests for clean-room operator automation.
# Does not contact OCI, SSH, Kubernetes, or download Terraform.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PASS_COUNT=0
FAIL_COUNT=0
TMP_ROOT=""

# ShellCheck cannot see that cleanup is invoked indirectly by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  if [[ -n "${TMP_ROOT}" && -d "${TMP_ROOT}" ]]; then
    rm -rf "${TMP_ROOT}"
  fi
}
trap cleanup EXIT

pass() {
  printf 'PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_contains() {
  local name="$1"
  local needle="$2"
  local text="$3"
  if printf '%s' "$text" | grep -Fq "$needle"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_not_contains() {
  local name="$1"
  local needle="$2"
  local text="$3"
  if printf '%s' "$text" | grep -Fq "$needle"; then
    fail "$name"
  else
    pass "$name"
  fi
}

python3 <<'PY'
from __future__ import annotations

import json
import re
import tempfile
from pathlib import Path

ROOT = Path(".").resolve()
TOOLS = {
    "bootstrap": ROOT / "tools/bootstrap-cloud-shell",
    "deploy": ROOT / "tools/deploy-clean-room",
    "verify": ROOT / "tools/verify-clean-room",
    "lib": ROOT / "tools/lib/clean-room-common.sh",
    "readiness": ROOT / "tools/check-cloud-shell-readiness",
}


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def main() -> None:
    for name, path in TOOLS.items():
        if not path.is_file():
            raise SystemExit(f"missing {path}")
        text = read(path)
        if name != "lib" and not text.startswith("#!/usr/bin/env bash"):
            raise SystemExit(f"{path} must use #!/usr/bin/env bash")
        if "set -x" in text or "set -o xtrace" in text:
            raise SystemExit(f"{path} must not enable xtrace")
        for token in (".clean-room-step", ".deployment-state", "last_completed_step"):
            if token in text:
                raise SystemExit(f"{path} must not use hidden step-state {token}")
    print("PASS: tools exist without hidden step-state or xtrace")

    bootstrap = read(TOOLS["bootstrap"])
    deploy = read(TOOLS["deploy"])
    verify = read(TOOLS["verify"])
    lib = read(TOOLS["lib"])
    readiness = read(TOOLS["readiness"])
    combined = "\n".join([bootstrap, deploy, verify, lib, readiness])

    for needle in (
        "WARNING: tmux not detected.",
        "Running the clean-room workflow inside tmux is recommended",
    ):
        if needle not in lib:
            raise SystemExit(f"tmux warning missing from shared helper: {needle}")
    for name, text in (("bootstrap", bootstrap), ("deploy", deploy), ("verify", verify)):
        if "clean_room_warn_tmux" not in text:
            raise SystemExit(f"{name} must print the shared tmux warning")
    if "tmux new" in combined or "tmux attach" in combined or "apt-get install tmux" in combined:
        raise SystemExit("tools must not install or start tmux")
    print("PASS: tmux warning is present and tmux remains optional")

    if "python3.12 -m venv" not in bootstrap:
        raise SystemExit("bootstrap must create the venv with python3.12")
    if "ansible-core==2.21.2" not in bootstrap and 'CLEAN_ROOM_ANSIBLE_CORE_PIN="2.21.2"' not in lib:
        raise SystemExit("bootstrap/lib must pin ansible-core==2.21.2")
    if "rm -rf" in bootstrap and "tradingchassis-ansible" in bootstrap:
        if re.search(r"rm\s+-rf[^\n]*tradingchassis-ansible", bootstrap):
            raise SystemExit("bootstrap must not blindly rm -rf the Ansible venv")
    if "git clone" in bootstrap:
        raise SystemExit("bootstrap must not clone the repository")
    print("PASS: bootstrap uses python3.12 and does not clone or destroy the venv")

    if "require_cmd python3.12" not in readiness:
        raise SystemExit("readiness must require python3.12")
    if re.search(r"(?m)^require_cmd python3$", readiness):
        raise SystemExit("readiness must not treat generic python3 as the Ansible interpreter")
    print("PASS: readiness requires python3.12")

    if "clean_room_has_angle_placeholders" not in lib:
        raise SystemExit("shared placeholder detector is missing from the helper")
    if re.search(r"grep -Eq '<|>'", lib):
        raise SystemExit("placeholder detector must not scan comment-only angle brackets")
    if "clean_room_has_angle_placeholders" not in deploy:
        raise SystemExit("deploy must use the shared placeholder detector")
    if "clean_room_has_angle_placeholders" not in verify:
        raise SystemExit("verify must use the shared placeholder detector")
    if "clean_room_has_angle_placeholders" not in readiness:
        raise SystemExit("readiness must use the shared placeholder detector")
    if re.search(r"grep -Eq '<|>'", readiness):
        raise SystemExit("readiness must not duplicate whole-file angle-bracket grep")
    print("PASS: placeholder detection ignores comment-only angle brackets")

    if "-auto-approve" in deploy:
        raise SystemExit("deploy-clean-room must not use -auto-approve")
    if not re.search(r"-e\s+scratch_storage_allow_format=true", deploy):
        raise SystemExit("deploy must be able to pass the one-time FORMAT extra-var")
    if re.search(r"-e\s+scratch_storage_allow_format=true", verify):
        raise SystemExit("verify-clean-room must never pass scratch_storage_allow_format=true")
    if re.search(r"(?m)^\s*terraform\s+apply\b", verify):
        raise SystemExit("verify-clean-room must not run terraform apply")
    if "APPLY" not in deploy or "FORMAT" not in deploy:
        raise SystemExit("deploy must implement APPLY and FORMAT gates")
    if "REBOOT" not in verify:
        raise SystemExit("verify must implement the REBOOT gate")
    print("PASS: APPLY/FORMAT/REBOOT gates and no verify apply/format")

    for forbidden in (
        "rollout restart",
        "kubectl delete job",
        "microk8s kubectl delete",
        "init-mlflow-postgres",
        "Monitoring operator",
        "sleep 300",
        "sleep 5m",
    ):
        if forbidden in deploy or forbidden in verify:
            raise SystemExit(f"operator tools must not include recovery hack: {forbidden}")
    print("PASS: no Monitoring/Postgres recovery commands")

    if "detailed-exitcode" not in deploy or "detailed-exitcode" not in verify:
        raise SystemExit("tools must use terraform -detailed-exitcode")
    if "show -json" not in deploy:
        raise SystemExit("deploy must inspect terraform show -json")
    print("PASS: Terraform detailed-exitcode and JSON inspection are present")

    if '-e "@${PRIVATE_VARS}"' not in deploy or "private-runtime.yml" not in deploy:
        raise SystemExit("deploy must use file-based private-runtime extra-vars")
    print("PASS: private-runtime extra-vars are file-based")

    if "clean_room_run_playbook" not in lib:
        raise SystemExit("shared live playbook helper is missing")
    if "tee" not in lib or "PIPESTATUS[0]" not in lib:
        raise SystemExit("run_playbook must tee live output and preserve PIPESTATUS[0]")
    if re.search(r'>\s*"\$log"\s+2>&1', deploy) or re.search(r'>\s*"\$log"\s+2>&1', verify):
        raise SystemExit("operator tools must not buffer ansible-playbook output until exit")
    if "clean_room_run_playbook" not in deploy or "clean_room_run_playbook" not in verify:
        raise SystemExit("deploy and verify must use the shared live playbook helper")
    print("PASS: ansible-playbook output is live-teed with preserved exit code")

    if re.search(r'health in \{[^}]*Missing', lib):
        raise SystemExit("Missing Argo health must not fail immediately")
    if re.search(r'sync in \{[^}]*Unknown', lib):
        raise SystemExit("Unknown Argo sync must not fail immediately")
    if 'health == "Degraded"' not in lib:
        raise SystemExit("Degraded Argo health must remain an immediate failure")
    if "JSONDecodeError" not in lib:
        raise SystemExit("Argo evaluator must fail closed on malformed JSON")
    for name, text in (("deploy", deploy), ("verify", verify)):
        if "clean_room_eval_argo_json" not in text:
            raise SystemExit(f"{name} must evaluate Argo Applications via the shared helper")
        if "not yet Synced+Healthy" not in text:
            raise SystemExit(f"{name} must retry when the Argo evaluator returns WAIT")
        if "empty or unhealthy" not in text:
            raise SystemExit(f"{name} must fail immediately on empty/unhealthy Argo sets")
        if "before timeout" not in text:
            raise SystemExit(f"{name} must keep the bounded Argo wait timeout")
    print("PASS: Argo evaluator distinguishes PASS/WAIT/FAIL-FAST")

    synthetic_forbidden = (
        "BEGIN PRIVATE KEY",
        "BEGIN RSA PRIVATE KEY",
    )
    for path in TOOLS.values():
        text = read(path)
        for token in synthetic_forbidden:
            if token in text:
                raise SystemExit(f"{path} must not contain {token}")
        unix_home_root = "/" + "home"
        home_user_re = re.compile(
            re.escape(unix_home_root) + r"/[A-Za-z0-9._-]+(?:/|$)"
        )
        if home_user_re.search(text):
            raise SystemExit(f"{path} must not contain a concrete Unix home path")
        if re.search(r"ocid1\.[a-z]+\.oc1\.[a-z0-9]{8,}", text, flags=re.I):
            raise SystemExit(f"{path} must not embed live-looking OCIDs")
    print("PASS: tools contain no live identifiers or private key material")

    with tempfile.TemporaryDirectory(prefix="clean-room-json-") as tmp:
        tmp_path = Path(tmp)
        destructive = {
            "resource_changes": [
                {
                    "address": "oci_core_instance.node",
                    "change": {"actions": ["delete", "create"]},
                }
            ]
        }
        delete_only = {
            "resource_changes": [
                {
                    "address": "oci_core_subnet.public",
                    "change": {"actions": ["delete"]},
                }
            ]
        }
        create_only = {
            "resource_changes": [
                {
                    "address": "oci_core_vcn.this",
                    "change": {"actions": ["create"]},
                }
            ]
        }
        (tmp_path / "replace.json").write_text(json.dumps(destructive), encoding="utf-8")
        (tmp_path / "delete.json").write_text(json.dumps(delete_only), encoding="utf-8")
        (tmp_path / "create.json").write_text(json.dumps(create_only), encoding="utf-8")

    print("PASS: static clean-room automation contracts")


if __name__ == "__main__":
    main()
PY

# shellcheck source=../../tools/lib/clean-room-common.sh
# Dynamic ROOT path is not followed without shellcheck -x; the helper is linted separately.
# shellcheck disable=SC1091
source "${ROOT}/tools/lib/clean-room-common.sh"

if [[ "$(clean_room_terraform_zip_arch aarch64)" == "arm64" ]]; then
  pass "arch map aarch64 -> arm64"
else
  fail "arch map aarch64 -> arm64"
fi
if [[ "$(clean_room_terraform_zip_arch arm64)" == "arm64" ]]; then
  pass "arch map arm64 -> arm64"
else
  fail "arch map arm64 -> arm64"
fi
if [[ "$(clean_room_terraform_zip_arch x86_64)" == "amd64" ]]; then
  pass "arch map x86_64 -> amd64"
else
  fail "arch map x86_64 -> amd64"
fi
if [[ "$(clean_room_terraform_zip_arch amd64)" == "amd64" ]]; then
  pass "arch map amd64 -> amd64"
else
  fail "arch map amd64 -> amd64"
fi
if clean_room_terraform_zip_arch riscv64 >/dev/null 2>&1; then
  fail "unsupported arch must fail"
else
  pass "unsupported arch must fail"
fi

if clean_room_terraform_version_ok "1.15.8"; then
  pass "terraform 1.15.8 satisfies ~> 1.15.0"
else
  fail "terraform 1.15.8 satisfies ~> 1.15.0"
fi
if clean_room_terraform_version_ok "1.14.9"; then
  fail "terraform 1.14.9 must not satisfy ~> 1.15.0"
else
  pass "terraform 1.14.9 must not satisfy ~> 1.15.0"
fi
if clean_room_terraform_version_ok "1.16.0"; then
  fail "terraform 1.16.0 must not satisfy ~> 1.15.0"
else
  pass "terraform 1.16.0 must not satisfy ~> 1.15.0"
fi

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clean-room-automation.XXXXXX")"
PH_DIR="${TMP_ROOT}/placeholders"
mkdir -p "$PH_DIR"

cat >"${PH_DIR}/active.hcl" <<'EOF'
oci_region = "<oci-region>"
EOF
if clean_room_has_angle_placeholders "${PH_DIR}/active.hcl"; then
  pass "active HCL placeholder is rejected"
else
  fail "active HCL placeholder is rejected"
fi

cat >"${PH_DIR}/active.yml" <<'EOF'
private_runtime_config_vault_id: "<vault-ocid>"
EOF
if clean_room_has_angle_placeholders "${PH_DIR}/active.yml"; then
  pass "active YAML placeholder is rejected"
else
  fail "active YAML placeholder is rejected"
fi

cat >"${PH_DIR}/comment-only.tfvars" <<'EOF'
# curl -s checkip.dyndns.org | sed -e 's/.*Current IP Address: //' -e 's/<.*$//'
ssh_ingress_cidr = "203.0.113.10/32"
EOF
if clean_room_has_angle_placeholders "${PH_DIR}/comment-only.tfvars"; then
  fail "comment-only angle bracket is accepted"
else
  pass "comment-only angle bracket is accepted"
fi

cat >"${PH_DIR}/ws-comment.tfvars" <<'EOF'
  #   curl -s checkip.dyndns.org | sed -e 's/.*Current IP Address: //' -e 's/<.*$//'
ssh_ingress_cidr = "203.0.113.10/32"
EOF
if clean_room_has_angle_placeholders "${PH_DIR}/ws-comment.tfvars"; then
  fail "leading-whitespace comment-only angle bracket is accepted"
else
  pass "leading-whitespace comment-only angle bracket is accepted"
fi

python3 - "${ROOT}/terraform/terraform.tfvars.example" "${PH_DIR}/populated.tfvars" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text(encoding="utf-8")
replacements = {
    "<oci-region>": "eu-frankfurt-1",
    "<compartment-ocid>": "ocid1.compartment.oc1..example",
    "<tenancy-ocid>": "ocid1.tenancy.oc1..example",
    "<vault-ocid>": "ocid1.vault.oc1..example",
    "<vault-compartment-ocid>": "ocid1.compartment.oc1..vault-example",
    "<cloud-shell-or-operator-cidr>": "203.0.113.10/32",
    "<contents-of-~/.ssh/tradingchassis.pub>": (
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "
        "contract-test@example.invalid"
    ),
}
for old, new in replacements.items():
    src = src.replace(old, new)
Path(sys.argv[2]).write_text(src, encoding="utf-8")
PY
if grep -Fq "s/<.*\$//" "${PH_DIR}/populated.tfvars" \
  && ! clean_room_has_angle_placeholders "${PH_DIR}/populated.tfvars"; then
  pass "populated terraform.tfvars-style fixture with curl/sed comment is accepted"
else
  fail "populated terraform.tfvars-style fixture with curl/sed comment is accepted"
fi

if clean_room_has_angle_placeholders "${ROOT}/terraform/terraform.tfvars.example" \
  && clean_room_has_angle_placeholders "${ROOT}/terraform/backend.hcl.example" \
  && clean_room_has_angle_placeholders "${ROOT}/ansible/extra-vars/private-runtime.yml.example"; then
  pass "committed example files still fail placeholder checks"
else
  fail "committed example files still fail placeholder checks"
fi

HELPER_DIR="${TMP_ROOT}/helper"
mkdir -p "$HELPER_DIR"

python3 - "$HELPER_DIR" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
(root / "replace.json").write_text(
    json.dumps(
        {
            "resource_changes": [
                {
                    "address": "oci_core_instance.node",
                    "change": {"actions": ["delete", "create"]},
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "delete.json").write_text(
    json.dumps(
        {
            "resource_changes": [
                {
                    "address": "oci_core_subnet.public",
                    "change": {"actions": ["delete"]},
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "create.json").write_text(
    json.dumps(
        {
            "resource_changes": [
                {
                    "address": "oci_core_vcn.this",
                    "change": {"actions": ["create"]},
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "ok-recap.log").write_text(
    "PLAY RECAP *********************************************************************\n"
    "reference-node              : ok=12   changed=0    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0\n",
    encoding="utf-8",
)
(root / "changed-recap.log").write_text(
    "PLAY RECAP *********************************************************************\n"
    "reference-node              : ok=12   changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0\n",
    encoding="utf-8",
)
(root / "blank.log").write_text(
    "fatal: [reference-node]: FAILED! => {\n"
    "  'msg': 'The scratch volume has no filesystem. Set scratch_storage_allow_format=true "
    "only after verifying that this is the intended Terraform-managed scratch volume.'\n"
    "}\n",
    encoding="utf-8",
)
(root / "other.log").write_text("fatal: [reference-node]: FAILED! => ntp configuration failed\n", encoding="utf-8")
(root / "argo-ok.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "root"},
                    "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}},
                },
                {
                    "metadata": {"name": "monitoring"},
                    "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}},
                },
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-empty.json").write_text(json.dumps({"items": []}), encoding="utf-8")
(root / "argo-degraded.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "postgres"},
                    "status": {"sync": {"status": "Synced"}, "health": {"status": "Degraded"}},
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-pending.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "root"},
                    "status": {
                        "sync": {"status": "OutOfSync"},
                        "health": {"status": "Progressing"},
                    },
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-missing.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "monitoring"},
                    "status": {
                        "sync": {"status": "OutOfSync"},
                        "health": {"status": "Missing"},
                    },
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-synced-progressing.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "root"},
                    "status": {
                        "sync": {"status": "Synced"},
                        "health": {"status": "Progressing"},
                    },
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-unknown.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "mlflow"},
                    "status": {
                        "sync": {"status": "Synced"},
                        "health": {"status": "Unknown"},
                    },
                }
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-mixed-wait.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "root"},
                    "status": {"sync": {"status": "Synced"}, "health": {"status": "Healthy"}},
                },
                {
                    "metadata": {"name": "monitoring"},
                    "status": {
                        "sync": {"status": "OutOfSync"},
                        "health": {"status": "Missing"},
                    },
                },
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-mixed-fail.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": "monitoring"},
                    "status": {
                        "sync": {"status": "OutOfSync"},
                        "health": {"status": "Missing"},
                    },
                },
                {
                    "metadata": {"name": "postgres"},
                    "status": {"sync": {"status": "Synced"}, "health": {"status": "Degraded"}},
                },
            ]
        }
    ),
    encoding="utf-8",
)
(root / "argo-malformed.json").write_text("{not-json\n", encoding="utf-8")
(root / "missing-recap.log").write_text("ok: all tasks completed\n", encoding="utf-8")
(root / "malformed-recap.log").write_text(
    "PLAY RECAP *********************************************************************\n"
    "reference-node completed without counters\n",
    encoding="utf-8",
)
(root / "pods-ok.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"namespace": "postgres"},
                    "status": {
                        "phase": "Succeeded",
                        "containerStatuses": [
                            {"ready": False, "state": {"terminated": {"reason": "Completed"}}}
                        ],
                    },
                },
                {
                    "metadata": {"namespace": "mlflow"},
                    "status": {
                        "phase": "Running",
                        "containerStatuses": [{"ready": True, "state": {"running": {}}}],
                    },
                },
            ]
        }
    ),
    encoding="utf-8",
)
(root / "pods-crash.json").write_text(
    json.dumps(
        {
            "items": [
                {
                    "metadata": {"namespace": "monitoring"},
                    "status": {
                        "phase": "Running",
                        "containerStatuses": [
                            {
                                "ready": False,
                                "state": {"waiting": {"reason": "CrashLoopBackOff"}},
                            }
                        ],
                    },
                }
            ]
        }
    ),
    encoding="utf-8",
)
PY

if clean_room_plan_is_destructive "${HELPER_DIR}/replace.json" >/dev/null; then
  fail "replace plan must be destructive"
else
  pass "replace plan is rejected"
fi
if clean_room_plan_is_destructive "${HELPER_DIR}/delete.json" >/dev/null; then
  fail "delete plan must be destructive"
else
  pass "delete plan is rejected"
fi
if clean_room_plan_is_destructive "${HELPER_DIR}/create.json" >/dev/null; then
  pass "create-only plan is non-destructive"
else
  fail "create-only plan is non-destructive"
fi

if clean_room_parse_play_recap "${HELPER_DIR}/ok-recap.log" 1 >/dev/null; then
  pass "PLAY RECAP changed=0 is accepted"
else
  fail "PLAY RECAP changed=0 is accepted"
fi
if clean_room_parse_play_recap "${HELPER_DIR}/changed-recap.log" 1 >/dev/null; then
  fail "PLAY RECAP changed>0 must fail"
else
  pass "PLAY RECAP changed>0 must fail"
fi
set +e
clean_room_parse_play_recap "${HELPER_DIR}/missing-recap.log" 1 >/dev/null
missing_recap_rc=$?
clean_room_parse_play_recap "${HELPER_DIR}/malformed-recap.log" 1 >/dev/null
malformed_recap_rc=$?
set -e
if [[ "$missing_recap_rc" -ne 0 ]]; then
  pass "missing PLAY RECAP fails closed"
else
  fail "missing PLAY RECAP fails closed (rc=${missing_recap_rc})"
fi
if [[ "$malformed_recap_rc" -ne 0 ]]; then
  pass "malformed PLAY RECAP fails closed"
else
  fail "malformed PLAY RECAP fails closed (rc=${malformed_recap_rc})"
fi

if clean_room_is_blank_scratch_gate "${HELPER_DIR}/blank.log"; then
  pass "blank-scratch fail-closed message is detected"
else
  fail "blank-scratch fail-closed message is detected"
fi
if clean_room_is_blank_scratch_gate "${HELPER_DIR}/other.log"; then
  fail "unrelated Ansible failure must not look like FORMAT gate"
else
  pass "unrelated Ansible failure must not look like FORMAT gate"
fi

if clean_room_eval_argo_json "${HELPER_DIR}/argo-ok.json" >/dev/null; then
  pass "Synced+Healthy Applications pass"
else
  fail "Synced+Healthy Applications pass"
fi
set +e
clean_room_eval_argo_json "${HELPER_DIR}/argo-empty.json" >/dev/null
empty_rc=$?
clean_room_eval_argo_json "${HELPER_DIR}/argo-degraded.json" >/dev/null
degraded_rc=$?
set -e
if [[ "$empty_rc" -eq 2 ]]; then
  pass "empty Application set fails"
else
  fail "empty Application set fails (rc=${empty_rc})"
fi
if [[ "$degraded_rc" -eq 3 ]]; then
  pass "Degraded Application fails immediately"
else
  fail "Degraded Application fails immediately (rc=${degraded_rc})"
fi
set +e
clean_room_eval_argo_json "${HELPER_DIR}/argo-pending.json" >/dev/null
pending_rc=$?
set -e
if [[ "$pending_rc" -eq 1 ]]; then
  pass "non-converged Applications wait rather than pass"
else
  fail "non-converged Applications wait rather than pass (rc=${pending_rc})"
fi
set +e
clean_room_eval_argo_json "${HELPER_DIR}/argo-missing.json" >/dev/null
missing_rc=$?
clean_room_eval_argo_json "${HELPER_DIR}/argo-synced-progressing.json" >/dev/null
synced_progressing_rc=$?
clean_room_eval_argo_json "${HELPER_DIR}/argo-unknown.json" >/dev/null
unknown_rc=$?
clean_room_eval_argo_json "${HELPER_DIR}/argo-mixed-wait.json" >/dev/null
mixed_wait_rc=$?
clean_room_eval_argo_json "${HELPER_DIR}/argo-mixed-fail.json" >/dev/null
mixed_fail_rc=$?
clean_room_eval_argo_json "${HELPER_DIR}/argo-malformed.json" >/dev/null
malformed_argo_rc=$?
set -e
if [[ "$missing_rc" -eq 1 ]]; then
  pass "OutOfSync/Missing Applications wait"
else
  fail "OutOfSync/Missing Applications wait (rc=${missing_rc})"
fi
if [[ "$synced_progressing_rc" -eq 1 ]]; then
  pass "Synced/Progressing Applications wait"
else
  fail "Synced/Progressing Applications wait (rc=${synced_progressing_rc})"
fi
if [[ "$unknown_rc" -eq 1 ]]; then
  pass "Unknown Argo health waits within the bounded timeout"
else
  fail "Unknown Argo health waits within the bounded timeout (rc=${unknown_rc})"
fi
if [[ "$mixed_wait_rc" -eq 1 ]]; then
  pass "Healthy plus transient Applications wait"
else
  fail "Healthy plus transient Applications wait (rc=${mixed_wait_rc})"
fi
if [[ "$mixed_fail_rc" -eq 3 ]]; then
  pass "transient plus Degraded Applications fail immediately"
else
  fail "transient plus Degraded Applications fail immediately (rc=${mixed_fail_rc})"
fi
if [[ "$malformed_argo_rc" -eq 2 ]]; then
  pass "malformed Argo JSON fails closed"
else
  fail "malformed Argo JSON fails closed (rc=${malformed_argo_rc})"
fi

write_playbook_stub() {
  local dest="$1"
  local exit_code="$2"
  cat >"$dest" <<STUB
#!/usr/bin/env bash
printf '%s\n' "LIVE-STDOUT"
printf '%s\n' "LIVE-STDERR" >&2
printf '%s\n' "The scratch volume has no filesystem. Set scratch_storage_allow_format=true only after verifying that this is the intended Terraform-managed scratch volume."
cat <<'REC'
PLAY RECAP *********************************************************************
reference-node              : ok=1    changed=0    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
REC
exit ${exit_code}
STUB
  chmod +x "$dest"
}

PB_STUBS="${TMP_ROOT}/playbook-stubs"
mkdir -p "$PB_STUBS"
write_playbook_stub "${PB_STUBS}/ansible-ok" 0
write_playbook_stub "${PB_STUBS}/ansible-fail" 7
ANSIBLE_CONFIG_FILE="/dev/null"
PB_OK_LOG="${TMP_ROOT}/playbook-ok.log"
PB_FAIL_LOG="${TMP_ROOT}/playbook-fail.log"
ANSIBLE_PLAYBOOK="${PB_STUBS}/ansible-ok"
set +e
pb_ok_out="$(clean_room_run_playbook "$PB_OK_LOG" site.yml 2>&1)"
pb_ok_rc=$?
set -e
if [[ "$pb_ok_rc" -eq 0 ]]; then
  pass "successful run_playbook returns 0"
else
  fail "successful run_playbook returns 0 (rc=${pb_ok_rc})"
fi
assert_contains "successful run_playbook is operator-visible" "LIVE-STDOUT" "$pb_ok_out"
assert_contains "successful run_playbook stderr is operator-visible" "LIVE-STDERR" "$pb_ok_out"
if grep -Fq "LIVE-STDOUT" "$PB_OK_LOG" && grep -Fq "LIVE-STDERR" "$PB_OK_LOG"; then
  pass "successful run_playbook retains a complete log"
else
  fail "successful run_playbook retains a complete log"
fi
ANSIBLE_PLAYBOOK="${PB_STUBS}/ansible-fail"
set +e
pb_fail_out="$(clean_room_run_playbook "$PB_FAIL_LOG" site.yml 2>&1)"
pb_fail_rc=$?
set -e
if [[ "$pb_fail_rc" -eq 7 ]]; then
  pass "failed run_playbook returns the ansible-playbook exit code"
else
  fail "failed run_playbook returns the ansible-playbook exit code (rc=${pb_fail_rc})"
fi
assert_contains "failed run_playbook is operator-visible" "LIVE-STDOUT" "$pb_fail_out"
if grep -Fq "LIVE-STDOUT" "$PB_FAIL_LOG"; then
  pass "failed run_playbook retains a complete log"
else
  fail "failed run_playbook retains a complete log"
fi
if [[ "$pb_fail_rc" -eq 0 ]]; then
  fail "pipeline behavior cannot convert an Ansible failure into success"
else
  pass "pipeline behavior cannot convert an Ansible failure into success"
fi
if clean_room_is_blank_scratch_gate "$PB_FAIL_LOG"; then
  pass "blank-scratch gate remains detectable from the live-teed log"
else
  fail "blank-scratch gate remains detectable from the live-teed log"
fi
if clean_room_parse_play_recap "$PB_FAIL_LOG" 1 >/dev/null; then
  pass "PLAY RECAP parsing still works from the live-teed log"
else
  fail "PLAY RECAP parsing still works from the live-teed log"
fi
unset ANSIBLE_PLAYBOOK ANSIBLE_CONFIG_FILE

if clean_room_eval_pods_json "${HELPER_DIR}/pods-ok.json" >/dev/null; then
  pass "completed Jobs are treated as healthy"
else
  fail "completed Jobs are treated as healthy"
fi
set +e
clean_room_eval_pods_json "${HELPER_DIR}/pods-crash.json" >/dev/null
crash_rc=$?
set -e
if [[ "$crash_rc" -eq 2 ]]; then
  pass "CrashLoopBackOff pods fail"
else
  fail "CrashLoopBackOff pods fail (rc=${crash_rc})"
fi

printf 'APPLY\n' | clean_room_require_exact_input APPLY
pass "exact APPLY input is accepted"
if printf 'nope\n' | clean_room_require_exact_input APPLY; then
  fail "non-APPLY input must be rejected"
else
  pass "non-APPLY input must be rejected"
fi

unset TMUX || true
tmux_out="$(clean_room_warn_tmux)"
assert_contains "tmux warning when TMUX is unset" "WARNING: tmux not detected." "$tmux_out"

seed_fixture() {
  local fx="$1"
  mkdir -p \
    "${fx}/terraform" \
    "${fx}/ansible/extra-vars" \
    "${fx}/ansible/playbooks" \
    "${fx}/ansible/inventory" \
    "${fx}/docs" \
    "${fx}/tools"
  cp "${ROOT}/terraform/versions.tf" "${fx}/terraform/versions.tf"
  cp "${ROOT}/terraform/backend.hcl.example" "${fx}/terraform/backend.hcl.example"
  cp "${ROOT}/terraform/terraform.tfvars.example" "${fx}/terraform/terraform.tfvars.example"
  cp "${ROOT}/ansible/extra-vars/private-runtime.yml.example" \
    "${fx}/ansible/extra-vars/private-runtime.yml.example"
  cp "${ROOT}/ansible/requirements.yml" "${fx}/ansible/requirements.yml"
  cp "${ROOT}/ansible/playbooks/site.yml" "${fx}/ansible/playbooks/site.yml"
  cp "${ROOT}/ansible/playbooks/private-runtime-config.yml" \
    "${fx}/ansible/playbooks/private-runtime-config.yml"
  cp "${ROOT}/ansible/ansible.cfg" "${fx}/ansible/ansible.cfg"
  cp "${ROOT}/docs/V2_CLEAN_ROOM_DEPLOYMENT.md" "${fx}/docs/V2_CLEAN_ROOM_DEPLOYMENT.md"
}

write_completed_inputs() {
  local fx="$1"
  cat >"${fx}/terraform/backend.hcl" <<'EOF'
bucket    = "example-state-bucket"
namespace = "examplenamespace"
region    = "eu-frankfurt-1"
key       = "tradingchassis/production/terraform.tfstate"
auth                = "APIKey"
config_file_profile = "tradingchassis"
EOF
  cat >"${fx}/terraform/terraform.tfvars" <<'EOF'
oci_auth                = "APIKey"
oci_config_file_profile = "tradingchassis"
oci_region               = "eu-frankfurt-1"
oci_compartment_id       = "ocid1.compartment.oc1..example"
oci_tenancy_id           = "ocid1.tenancy.oc1..example"
oci_vault_id             = "ocid1.vault.oc1..example"
oci_vault_compartment_id = "ocid1.compartment.oc1..vault-example"
# Cloud Shell public egress IP is dynamic across sessions.
# Example discovery (Cloud Shell docs):
#   curl -s checkip.dyndns.org | sed -e 's/.*Current IP Address: //' -e 's/<.*$//'
ssh_ingress_cidr = "203.0.113.10/32"
ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA contract-test@example.invalid"
EOF
  cat >"${fx}/ansible/extra-vars/private-runtime.yml" <<'EOF'
private_runtime_config_vault_id: "ocid1.vault.oc1.eu-test-1..aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private_runtime_config_oci_region: "eu-test-1"
EOF
  chmod 600 \
    "${fx}/terraform/backend.hcl" \
    "${fx}/terraform/terraform.tfvars" \
    "${fx}/ansible/extra-vars/private-runtime.yml"
}

seed_operator_home() {
  local home="$1"
  mkdir -p "${home}/bin" "${home}/.oci" "${home}/.ssh" "${home}/.venvs/tradingchassis-ansible/bin"
  printf '%s\n' "[tradingchassis]" >"${home}/.oci/config"
  printf '%s\n' "not-a-secret" >"${home}/.oci/tradingchassis_api_key.pem"
  printf '%s\n' "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA contract-test@example.invalid" \
    >"${home}/.ssh/tradingchassis.pub"
  printf '%s\n' "not-a-secret-key" >"${home}/.ssh/tradingchassis"
  chmod 600 "${home}/.oci/config" "${home}/.oci/tradingchassis_api_key.pem" "${home}/.ssh/tradingchassis"
}

write_python312_stub() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-c" ]]; then
  if [[ "${2:-}" == *'%d.%d'* ]]; then
    printf '%s\n' "3.12"
    exit 0
  fi
  exec python3 -c "${2}"
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
  dest="${3:?}"
  mkdir -p "${dest}/bin"
  cat >"${dest}/bin/python" <<'PY'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-c" ]]; then
  if [[ "${2:-}" == *version_info[:2]* ]]; then
    exit 0
  fi
  exec python3 -c "${2}"
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then
  exit 0
fi
exit 0
PY
  cat >"${dest}/bin/pip" <<'PIP'
#!/usr/bin/env bash
exit 0
PIP
  cat >"${dest}/bin/ansible-playbook" <<'AP'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "ansible-playbook [core 2.21.2]"
  exit 0
fi
exit 0
AP
  cat >"${dest}/bin/ansible-galaxy" <<'AG'
#!/usr/bin/env bash
exit 0
AG
  chmod +x "${dest}/bin/python" "${dest}/bin/pip" "${dest}/bin/ansible-playbook" "${dest}/bin/ansible-galaxy"
  exit 0
fi
exec python3 "$@"
EOF
  chmod +x "$dest"
}

write_tf_stub() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log="${TF_STUB_LOG:-/dev/null}"
printf '%s\n' "$*" >>"$log"
args=()
for arg in "$@"; do
  case "$arg" in
    -chdir=*) ;;
    *) args+=("$arg") ;;
  esac
done
set -- "${args[@]}"
case "${1:-}" in
  version)
    if [[ "${2:-}" == "-json" ]]; then
      printf '%s\n' '{"terraform_version":"1.15.8"}'
    else
      printf '%s\n' "Terraform v1.15.8"
    fi
    exit 0
    ;;
  init|validate)
    exit 0
    ;;
  plan)
    count_file="${TF_STUB_PLAN_COUNT:-}"
    n=1
    if [[ -n "$count_file" ]]; then
      if [[ -f "$count_file" ]]; then
        n="$(cat "$count_file")"
        n=$((n + 1))
      fi
      printf '%s\n' "$n" >"$count_file"
    fi
    out=""
    for arg in "$@"; do
      case "$arg" in
        -out=*) out="${arg#-out=}" ;;
      esac
    done
    if [[ -n "$out" ]]; then
      printf 'stub-plan\n' >"$out"
    fi
    if [[ -n "$count_file" && "$n" -ge 2 ]]; then
      exit "${TF_STUB_POST_PLAN_EXIT:-0}"
    fi
    exit "${TF_STUB_PLAN_EXIT:-0}"
    ;;
  apply)
    printf 'apply\n' >>"${TF_STUB_APPLY_LOG:-/dev/null}"
    exit 0
    ;;
  show)
    if [[ "${2:-}" == "-json" ]]; then
      cat "${TF_STUB_PLAN_JSON:?}"
      exit 0
    fi
    printf '%s\n' "Plan: 1 to add, 0 to change, 0 to destroy."
    exit 0
    ;;
  output)
    printf '%s\n' "192.0.2.10"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$dest"
}

write_ansible_stub() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${ANSIBLE_STUB_LOG:?}"
if printf '%s' "$*" | grep -Fq 'scratch_storage_allow_format=true'; then
  printf 'FORMAT_FLAG\n' >>"${ANSIBLE_STUB_LOG}"
fi
if printf '%s' "$*" | grep -Fq 'private-runtime-config.yml'; then
  if [[ "${PRIV_RECAP:-ok}" == "missing" ]]; then
    printf '%s\n' "ok: private-runtime finished without recap"
    exit "${PRIV_EXIT:-0}"
  fi
  if [[ "${PRIV_RECAP:-ok}" == "malformed" ]]; then
    cat <<'REC'
PLAY RECAP *********************************************************************
reference-node completed without counters
REC
    exit "${PRIV_EXIT:-0}"
  fi
  cat <<REC
PLAY RECAP *********************************************************************
reference-node              : ok=8    changed=${PRIV_CHANGED:-0}    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
REC
  exit "${PRIV_EXIT:-0}"
fi
if printf '%s' "$*" | grep -Fq 'site.yml'; then
  if [[ "${SITE_MODE:-ok}" == "blank" ]] && ! printf '%s' "$*" | grep -Fq 'scratch_storage_allow_format=true'; then
    cat <<'BLANK'
fatal: [reference-node]: FAILED! => {
    "msg": "The scratch volume has no filesystem. Set scratch_storage_allow_format=true only after verifying that this is the intended Terraform-managed scratch volume."
}
BLANK
    exit 2
  fi
  if [[ "${SITE_MODE:-ok}" == "other-fail" ]]; then
    printf '%s\n' "fatal: [reference-node]: FAILED! => ntp configuration failed"
    exit 2
  fi
  if [[ "${SITE_RECAP:-ok}" == "missing" ]]; then
    printf '%s\n' "ok: site.yml finished without recap"
    exit "${SITE_EXIT:-0}"
  fi
  if [[ "${SITE_RECAP:-ok}" == "malformed" ]]; then
    cat <<'REC'
PLAY RECAP *********************************************************************
reference-node completed without counters
REC
    exit "${SITE_EXIT:-0}"
  fi
  cat <<REC
PLAY RECAP *********************************************************************
reference-node              : ok=20   changed=${SITE_CHANGED:-0}    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
REC
  exit "${SITE_EXIT:-0}"
fi
exit 0
EOF
  chmod +x "$dest"
}

write_ssh_stub() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${SSH_STUB_LOG:?}"
remote=""
for arg in "$@"; do
  remote="$arg"
done
case "$remote" in
  true)
    if [[ -f "${SSH_REBOOTED:-/tmp/does-not-exist}" && ! -f "${SSH_DROPPED:-/tmp/does-not-exist}" ]]; then
      : >"${SSH_DROPPED}"
      exit 1
    fi
    exit 0
    ;;
  *get\ applications*)
    cat "${ARGO_JSON:?}"
    exit 0
    ;;
  *get\ pods*)
    cat "${PODS_JSON:?}"
    exit 0
    ;;
  *boot_id*)
    rebooted=0
    if [[ -f "${SSH_REBOOTED:-/tmp/does-not-exist}" ]]; then
      rebooted=1
    fi
    case "${SSH_BOOT_MODE:-ok}" in
      empty-before)
        if [[ "$rebooted" -eq 0 ]]; then
          printf '\n'
          exit 0
        fi
        printf '%s\n' "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        exit 0
        ;;
      fail-before)
        if [[ "$rebooted" -eq 0 ]]; then
          exit 1
        fi
        printf '%s\n' "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        exit 0
        ;;
      unchanged)
        printf '%s\n' "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        exit 0
        ;;
      empty-after)
        if [[ "$rebooted" -eq 1 ]]; then
          printf '\n'
          exit 0
        fi
        printf '%s\n' "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        exit 0
        ;;
      *)
        if [[ "$rebooted" -eq 1 ]]; then
          printf '%s\n' "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        else
          printf '%s\n' "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        fi
        exit 0
        ;;
    esac
    ;;
  *mountpoint*)
    exit "${MOUNT_RC:-0}"
    ;;
  *microk8s\ status*)
    printf '%s\n' "microk8s is running"
    exit 0
    ;;
  *reboot*)
    : >"${SSH_REBOOTED:?}"
    exit 255
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "$dest"
}

write_oci_stub() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${OCI_STUB_LOG:-/dev/null}"
if printf '%s' "$*" | grep -Fq 'instance_obo_user'; then
  echo "refusing instance_obo_user" >&2
  exit 1
fi
if printf '%s' "$*" | grep -Fq -- '--auth api_key'; then
  exit 0
fi
exit 1
EOF
  chmod +x "$dest"
}

write_curl_stub() {
  local dest="$1"
  cat >"$dest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${CURL_STUB_LOG:?}"
out=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      out="$2"
      shift 2
      ;;
    --proto|--proto-redir)
      shift 2
      ;;
    --tlsv1.2|-fsSL|-s|-f|-L|-S)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
if [[ -z "$out" || -z "$url" ]]; then
  exit 1
fi
if [[ "$url" == *SHA256SUMS ]]; then
  cp "${CURL_SUMS:?}" "$out"
  exit 0
fi
if [[ "$url" == *.zip ]]; then
  cp "${CURL_ZIP:?}" "$out"
  exit 0
fi
exit 1
EOF
  chmod +x "$dest"
}

# --- bootstrap: tmux warning does not fail ---
fx="${TMP_ROOT}/boot-tmux"
home="${TMP_ROOT}/home-tmux"
mkdir -p "$fx" "$home" "${TMP_ROOT}/stubs-tmux"
seed_fixture "$fx"
seed_operator_home "$home"
write_python312_stub "${TMP_ROOT}/stubs-tmux/python3.12"
write_tf_stub "${home}/bin/terraform"
write_ansible_stub "${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook"
printf '%s\n' '#!/usr/bin/env bash' 'echo ansible-playbook [core 2.21.2]' >"${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook"
chmod +x "${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook"
# recreate a venv python that claims 3.12 so reuse path works
mkdir -p "${home}/.venvs/tradingchassis-ansible/bin"
cat >"${home}/.venvs/tradingchassis-ansible/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == *version_info[:2]* ]]; then
  exit 0
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then
  exit 0
fi
exit 0
EOF
cat >"${home}/.venvs/tradingchassis-ansible/bin/ansible-galaxy" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${home}/.venvs/tradingchassis-ansible/bin/python" \
  "${home}/.venvs/tradingchassis-ansible/bin/ansible-galaxy" \
  "${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook"
write_curl_stub "${TMP_ROOT}/stubs-tmux/curl"
export CURL_STUB_LOG="${TMP_ROOT}/curl-tmux.log"
: >"$CURL_STUB_LOG"
unset TMUX || true
set +e
out="$(
  HOME="$home" PATH="${TMP_ROOT}/stubs-tmux:${home}/bin:${PATH}" \
    "${ROOT}/tools/bootstrap-cloud-shell" --root "$fx" 2>&1
)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  pass "bootstrap succeeds when TMUX is unset"
else
  fail "bootstrap succeeds when TMUX is unset (rc=${rc})"
  printf '%s\n' "$out"
fi
assert_contains "bootstrap prints tmux warning" "WARNING: tmux not detected." "$out"
assert_contains "bootstrap does not start deployment" "Deployment has NOT begun." "$out"
assert_not_contains "bootstrap did not download Terraform when present" "releases.hashicorp.com" "$out"

# --- bootstrap: create vs preserve operator files ---
fx="${TMP_ROOT}/boot-files"
home="${TMP_ROOT}/home-files"
mkdir -p "${TMP_ROOT}/stubs-files"
seed_fixture "$fx"
seed_operator_home "$home"
write_python312_stub "${TMP_ROOT}/stubs-files/python3.12"
write_tf_stub "${home}/bin/terraform"
mkdir -p "${home}/.venvs/tradingchassis-ansible/bin"
cat >"${home}/.venvs/tradingchassis-ansible/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == *version_info[:2]* ]]; then exit 0; fi
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then exit 0; fi
exit 0
EOF
printf '%s\n' '#!/usr/bin/env bash' 'echo ansible-playbook [core 2.21.2]' \
  >"${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  >"${home}/.venvs/tradingchassis-ansible/bin/ansible-galaxy"
chmod +x \
  "${home}/.venvs/tradingchassis-ansible/bin/python" \
  "${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook" \
  "${home}/.venvs/tradingchassis-ansible/bin/ansible-galaxy"
printf '%s\n' "UNIQUE_OPERATOR_MARKER" >"${fx}/terraform/backend.hcl"
HOME="$home" PATH="${TMP_ROOT}/stubs-files:${home}/bin:${PATH}" \
  "${ROOT}/tools/bootstrap-cloud-shell" --root "$fx" >/dev/null
if grep -Fq "UNIQUE_OPERATOR_MARKER" "${fx}/terraform/backend.hcl"; then
  pass "bootstrap does not overwrite existing operator files"
else
  fail "bootstrap does not overwrite existing operator files"
fi
if [[ -f "${fx}/terraform/terraform.tfvars" && -f "${fx}/ansible/extra-vars/private-runtime.yml" ]]; then
  pass "bootstrap creates missing operator input files from examples"
else
  fail "bootstrap creates missing operator input files from examples"
fi

# --- bootstrap: checksum mismatch is fatal ---
fx="${TMP_ROOT}/boot-sum"
home="${TMP_ROOT}/home-sum"
mkdir -p "${TMP_ROOT}/stubs-sum" "$home"
seed_fixture "$fx"
seed_operator_home "$home"
rm -f "${home}/bin/terraform"
write_python312_stub "${TMP_ROOT}/stubs-sum/python3.12"
arch="$(clean_room_terraform_zip_arch)"
zip_name="terraform_1.15.8_linux_${arch}.zip"
python3 - "${TMP_ROOT}/${zip_name}" "${TMP_ROOT}/bad.SHA256SUMS" "${TMP_ROOT}/good.SHA256SUMS" <<'PY'
import hashlib
import sys
import zipfile
from pathlib import Path

zip_path = Path(sys.argv[1])
with zipfile.ZipFile(zip_path, "w") as zf:
    zf.writestr("terraform", "#!/bin/sh\necho Terraform v1.15.8\n")
digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
Path(sys.argv[2]).write_text(f"{'0'*64}  {zip_path.name}\n", encoding="utf-8")
Path(sys.argv[3]).write_text(f"{digest}  {zip_path.name}\n", encoding="utf-8")
PY
write_curl_stub "${TMP_ROOT}/stubs-sum/curl"
export CURL_STUB_LOG="${TMP_ROOT}/curl-sum.log"
export CURL_SUMS="${TMP_ROOT}/bad.SHA256SUMS"
export CURL_ZIP="${TMP_ROOT}/${zip_name}"
mkdir -p "${home}/.venvs/tradingchassis-ansible/bin"
cat >"${home}/.venvs/tradingchassis-ansible/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == *version_info[:2]* ]]; then exit 0; fi
if [[ "${1:-}" == "-m" && "${2:-}" == "pip" ]]; then exit 0; fi
exit 0
EOF
printf '%s\n' '#!/usr/bin/env bash' 'echo ansible-playbook [core 2.21.2]' \
  >"${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
  >"${home}/.venvs/tradingchassis-ansible/bin/ansible-galaxy"
chmod +x \
  "${home}/.venvs/tradingchassis-ansible/bin/python" \
  "${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook" \
  "${home}/.venvs/tradingchassis-ansible/bin/ansible-galaxy"
set +e
out="$(
  HOME="$home" PATH="${TMP_ROOT}/stubs-sum:${PATH}" \
    "${ROOT}/tools/bootstrap-cloud-shell" --root "$fx" 2>&1
)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "checksum mismatch"; then
  pass "Terraform checksum mismatch is fatal"
else
  fail "Terraform checksum mismatch is fatal (rc=${rc})"
  printf '%s\n' "$out"
fi
if [[ -e "${home}/bin/terraform" ]]; then
  fail "checksum failure must not install Terraform"
else
  pass "checksum failure must not install Terraform"
fi

# --- deploy/verify integration stubs ---
prepare_runtime() {
  local prefix="$1"
  local fx="${TMP_ROOT}/${prefix}-fx"
  local home="${TMP_ROOT}/${prefix}-home"
  local stubs="${TMP_ROOT}/${prefix}-stubs"
  rm -rf "$fx" "$home" "$stubs"
  mkdir -p "$fx" "$home" "$stubs"
  seed_fixture "$fx"
  write_completed_inputs "$fx"
  seed_operator_home "$home"
  write_python312_stub "${stubs}/python3.12"
  write_tf_stub "${home}/bin/terraform"
  write_ansible_stub "${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook"
  cat >"${home}/.venvs/tradingchassis-ansible/bin/python" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == *version_info[:2]* ]]; then exit 0; fi
exit 0
EOF
  printf '%s\n' '#!/usr/bin/env bash' 'echo ansible-playbook [core 2.21.2]' \
    >"${home}/.venvs/tradingchassis-ansible/bin/ansible-playbook.version"
  write_ssh_stub "${stubs}/ssh"
  write_oci_stub "${stubs}/oci"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"${stubs}/ssh-keygen"
  chmod +x "${home}/.venvs/tradingchassis-ansible/bin/python" "${stubs}/ssh-keygen"
  cp "${HELPER_DIR}/create.json" "${TMP_ROOT}/${prefix}-create.json"
  cp "${HELPER_DIR}/replace.json" "${TMP_ROOT}/${prefix}-replace.json"
  cp "${HELPER_DIR}/argo-ok.json" "${TMP_ROOT}/${prefix}-argo.json"
  cp "${HELPER_DIR}/pods-ok.json" "${TMP_ROOT}/${prefix}-pods.json"
  printf '%s' "$fx $home $stubs"
}

run_deploy_env() {
  local fx="$1" home="$2" stubs="$3"
  HOME="$home" \
    PATH="${home}/bin:${home}/.venvs/tradingchassis-ansible/bin:${stubs}:${PATH}" \
    TF_STUB_LOG="${home}/tf.log" \
    TF_STUB_APPLY_LOG="${home}/apply.log" \
    TF_STUB_PLAN_COUNT="${home}/plan.count" \
    TF_STUB_PLAN_EXIT="${TF_STUB_PLAN_EXIT:-0}" \
    TF_STUB_POST_PLAN_EXIT="${TF_STUB_POST_PLAN_EXIT:-0}" \
    TF_STUB_PLAN_JSON="${TF_STUB_PLAN_JSON:-}" \
    ANSIBLE_STUB_LOG="${home}/ansible.log" \
    SSH_STUB_LOG="${home}/ssh.log" \
    OCI_STUB_LOG="${home}/oci.log" \
    ARGO_JSON="${home}/argo.json" \
    PODS_JSON="${home}/pods.json" \
    SSH_REBOOTED="${home}/rebooted" \
    SSH_DROPPED="${home}/dropped" \
    SITE_MODE="${SITE_MODE:-ok}" \
    SITE_CHANGED="${SITE_CHANGED:-0}" \
    PRIV_CHANGED="${PRIV_CHANGED:-0}" \
    CLEAN_ROOM_SSH_ATTEMPTS=2 \
    CLEAN_ROOM_SSH_DELAY=0 \
    CLEAN_ROOM_ARGO_ATTEMPTS=2 \
    CLEAN_ROOM_ARGO_DELAY=0 \
    CLEAN_ROOM_WORKLOAD_ATTEMPTS=2 \
    CLEAN_ROOM_WORKLOAD_DELAY=0 \
    "${ROOT}/tools/deploy-clean-room" --root "$fx"
}

read -r fx home stubs <<<"$(prepare_runtime nochg2)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/apply.log"
set +e
out="$(TF_STUB_PLAN_EXIT=0 TF_STUB_PLAN_JSON="${HELPER_DIR}/create.json" SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -Fq "skipping APPLY"; then
  pass "no-change Terraform plan skips APPLY"
else
  fail "no-change Terraform plan skips APPLY (rc=${rc})"
  printf '%s\n' "$out"
fi
if [[ -s "${home}/apply.log" ]]; then
  fail "no-change plan must not apply"
else
  pass "no-change plan must not apply"
fi
if grep -Fq FORMAT_FLAG "${home}/ansible.log" 2>/dev/null; then
  fail "successful site.yml must not pass FORMAT"
else
  pass "successful site.yml must not pass FORMAT"
fi
if grep -Fq "private-runtime-config.yml" "${home}/ansible.log"; then
  pass "private-runtime runs after successful site.yml"
else
  fail "private-runtime runs after successful site.yml"
fi

# changed plan requires APPLY; other input prevents apply
read -r fx home stubs <<<"$(prepare_runtime applyno)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/apply.log"
set +e
out="$(printf 'nope\n' | TF_STUB_PLAN_EXIT=2 TF_STUB_PLAN_JSON="${HELPER_DIR}/create.json" SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "APPLY was not confirmed"; then
  pass "non-APPLY input prevents terraform apply"
else
  fail "non-APPLY input prevents terraform apply (rc=${rc})"
  printf '%s\n' "$out"
fi
if [[ -s "${home}/apply.log" ]]; then
  fail "refused APPLY must not create an apply record"
else
  pass "refused APPLY must not create an apply record"
fi

# APPLY confirmed + post-apply no-change
read -r fx home stubs <<<"$(prepare_runtime applyyes)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/apply.log"
: >"${home}/plan.count"
set +e
out="$(printf 'APPLY\n' | TF_STUB_PLAN_EXIT=2 TF_STUB_POST_PLAN_EXIT=0 TF_STUB_PLAN_JSON="${HELPER_DIR}/create.json" SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -Fq apply "${home}/apply.log"; then
  pass "exact APPLY applies the saved plan"
else
  fail "exact APPLY applies the saved plan (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "post-apply Terraform plan has no changes"; then
  pass "successful apply requires post-apply no-change"
else
  fail "successful apply requires post-apply no-change"
  printf '%s\n' "$out"
fi

# destructive plan rejected before apply
read -r fx home stubs <<<"$(prepare_runtime destroy)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/apply.log"
set +e
out="$(printf 'APPLY\n' | TF_STUB_PLAN_EXIT=2 TF_STUB_PLAN_JSON="${HELPER_DIR}/replace.json" SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "delete or replace"; then
  pass "destructive Terraform plan is rejected before apply"
else
  fail "destructive Terraform plan is rejected before apply (rc=${rc})"
  printf '%s\n' "$out"
fi
if [[ -s "${home}/apply.log" ]]; then
  fail "destructive plan must not apply"
else
  pass "destructive plan must not apply"
fi

# blank scratch offers FORMAT; unrelated failure does not
read -r fx home stubs <<<"$(prepare_runtime blank)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(printf 'FORMAT\n' | TF_STUB_PLAN_EXIT=0 SITE_MODE=blank run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -Fq FORMAT_FLAG "${home}/ansible.log"; then
  pass "blank-scratch fail-closed error offers FORMAT and reruns with the flag"
else
  fail "blank-scratch FORMAT path (rc=${rc})"
  printf '%s\n' "$out"
fi

read -r fx home stubs <<<"$(prepare_runtime otherans)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=other-fail run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "FORMAT was not offered"; then
  pass "unrelated Ansible error does not offer FORMAT"
else
  fail "unrelated Ansible error does not offer FORMAT (rc=${rc})"
  printf '%s\n' "$out"
fi
if grep -Fq FORMAT_FLAG "${home}/ansible.log" 2>/dev/null; then
  fail "unrelated Ansible error must not pass FORMAT flag"
else
  pass "unrelated Ansible error must not pass FORMAT flag"
fi

read -r fx home stubs <<<"$(prepare_runtime fmtno)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(printf 'nope\n' | TF_STUB_PLAN_EXIT=0 SITE_MODE=blank run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "FORMAT was not confirmed"; then
  pass "non-FORMAT input stops without formatting"
else
  fail "non-FORMAT input stops without formatting (rc=${rc})"
  printf '%s\n' "$out"
fi

# rerun with existing scratch never supplies format flag
read -r fx home stubs <<<"$(prepare_runtime rerun)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && ! grep -Fq FORMAT_FLAG "${home}/ansible.log"; then
  pass "rerun with existing scratch never supplies FORMAT flag"
else
  fail "rerun with existing scratch never supplies FORMAT flag (rc=${rc})"
  printf '%s\n' "$out"
fi

# empty Argo set fails
read -r fx home stubs <<<"$(prepare_runtime argoempty)"
cp "${HELPER_DIR}/argo-empty.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Eq 'empty or unhealthy|no Argo Applications'; then
  pass "empty Application set fails deploy wait"
else
  fail "empty Application set fails deploy wait (rc=${rc})"
  printf '%s\n' "$out"
fi

read -r fx home stubs <<<"$(prepare_runtime argodeg)"
cp "${HELPER_DIR}/argo-degraded.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "empty or unhealthy"; then
  pass "Degraded Applications fail deploy wait immediately"
else
  fail "Degraded Applications fail deploy wait immediately (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "not yet Synced+Healthy"; then
  fail "Degraded Applications must not enter the Argo wait loop"
else
  pass "Degraded Applications must not enter the Argo wait loop"
fi
if printf '%s' "$out" | grep -Fq "before timeout"; then
  fail "Degraded Applications must not wait until timeout"
else
  pass "Degraded Applications must not wait until timeout"
fi

read -r fx home stubs <<<"$(prepare_runtime argomiss)"
cp "${HELPER_DIR}/argo-missing.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "not yet Synced+Healthy" && printf '%s' "$out" | grep -Fq "before timeout"; then
  pass "OutOfSync/Missing waits then times out"
else
  fail "OutOfSync/Missing waits then times out (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "empty or unhealthy"; then
  fail "OutOfSync/Missing must not fail immediately as unhealthy"
else
  pass "OutOfSync/Missing must not fail immediately as unhealthy"
fi

read -r fx home stubs <<<"$(prepare_runtime argomixw)"
cp "${HELPER_DIR}/argo-mixed-wait.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "not yet Synced+Healthy"; then
  pass "mixed Healthy plus Missing waits"
else
  fail "mixed Healthy plus Missing waits (rc=${rc})"
  printf '%s\n' "$out"
fi

read -r fx home stubs <<<"$(prepare_runtime argomixf)"
cp "${HELPER_DIR}/argo-mixed-fail.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "empty or unhealthy"; then
  pass "mixed Missing plus Degraded fails immediately"
else
  fail "mixed Missing plus Degraded fails immediately (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "not yet Synced+Healthy"; then
  fail "mixed Missing plus Degraded must not wait"
else
  pass "mixed Missing plus Degraded must not wait"
fi

read -r fx home stubs <<<"$(prepare_runtime argotime)"
cp "${HELPER_DIR}/argo-pending.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "before timeout"; then
  pass "Argo timeout fails deploy wait"
else
  fail "Argo timeout fails deploy wait (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room deployment convergence completed"; then
  fail "Argo timeout must not report deploy PASS"
else
  pass "Argo timeout must not report deploy PASS"
fi

# post-apply remaining changes stop before Ansible
read -r fx home stubs <<<"$(prepare_runtime postdrift)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/apply.log"
: >"${home}/ansible.log"
: >"${home}/plan.count"
set +e
out="$(printf 'APPLY\n' | TF_STUB_PLAN_EXIT=2 TF_STUB_POST_PLAN_EXIT=2 TF_STUB_PLAN_JSON="${HELPER_DIR}/create.json" SITE_MODE=ok run_deploy_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "stopping before Ansible"; then
  pass "post-apply Terraform changes stop deploy before Ansible"
else
  fail "post-apply Terraform changes stop deploy before Ansible (rc=${rc})"
  printf '%s\n' "$out"
fi
if grep -Fq apply "${home}/apply.log"; then
  pass "post-apply drift still applied the saved plan"
else
  fail "post-apply drift still applied the saved plan"
fi
if grep -Eq 'site.yml|private-runtime-config.yml' "${home}/ansible.log"; then
  fail "post-apply drift must not continue into Ansible"
else
  pass "post-apply drift must not continue into Ansible"
fi

run_verify_env() {
  local fx="$1" home="$2" stubs="$3"
  HOME="$home" \
    PATH="${home}/bin:${home}/.venvs/tradingchassis-ansible/bin:${stubs}:${PATH}" \
    TF_STUB_LOG="${home}/tf.log" \
    TF_STUB_APPLY_LOG="${home}/apply.log" \
    TF_STUB_PLAN_COUNT="${home}/plan.count" \
    TF_STUB_PLAN_EXIT="${TF_STUB_PLAN_EXIT:-0}" \
    TF_STUB_PLAN_JSON="${TF_STUB_PLAN_JSON:-}" \
    ANSIBLE_STUB_LOG="${home}/ansible.log" \
    SSH_STUB_LOG="${home}/ssh.log" \
    OCI_STUB_LOG="${home}/oci.log" \
    ARGO_JSON="${home}/argo.json" \
    PODS_JSON="${home}/pods.json" \
    SSH_REBOOTED="${home}/rebooted" \
    SSH_DROPPED="${home}/dropped" \
    SSH_BOOT_MODE="${SSH_BOOT_MODE:-ok}" \
    SITE_MODE="${SITE_MODE:-ok}" \
    SITE_CHANGED="${SITE_CHANGED:-0}" \
    SITE_RECAP="${SITE_RECAP:-ok}" \
    PRIV_CHANGED="${PRIV_CHANGED:-0}" \
    PRIV_RECAP="${PRIV_RECAP:-ok}" \
    CLEAN_ROOM_SSH_ATTEMPTS=2 \
    CLEAN_ROOM_SSH_DELAY=0 \
    CLEAN_ROOM_ARGO_ATTEMPTS=2 \
    CLEAN_ROOM_ARGO_DELAY=0 \
    CLEAN_ROOM_WORKLOAD_ATTEMPTS=2 \
    CLEAN_ROOM_WORKLOAD_DELAY=0 \
    CLEAN_ROOM_REBOOT_DROP_ATTEMPTS=3 \
    CLEAN_ROOM_REBOOT_DROP_DELAY=0 \
    CLEAN_ROOM_REBOOT_RETURN_ATTEMPTS=3 \
    CLEAN_ROOM_REBOOT_RETURN_DELAY=0 \
    CLEAN_ROOM_MICROK8S_TIMEOUT=1 \
    "${ROOT}/tools/verify-clean-room" --root "$fx"
}

# terraform drift fails verify without apply
read -r fx home stubs <<<"$(prepare_runtime vdrift)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/apply.log"
set +e
out="$(TF_STUB_PLAN_EXIT=2 run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "Terraform drift detected"; then
  pass "Terraform drift fails verification instead of applying"
else
  fail "Terraform drift fails verification instead of applying (rc=${rc})"
  printf '%s\n' "$out"
fi
if [[ -s "${home}/apply.log" ]]; then
  fail "verify must not apply Terraform"
else
  pass "verify must not apply Terraform"
fi

read -r fx home stubs <<<"$(prepare_runtime vplanerr)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/apply.log"
set +e
out="$(TF_STUB_PLAN_EXIT=1 run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "terraform plan failed"; then
  pass "Terraform plan error fails verification without a drift message"
else
  fail "Terraform plan error fails verification without a drift message (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "Terraform drift detected"; then
  fail "plan error must not be reported as drift"
else
  pass "plan error must not be reported as drift"
fi
if [[ -s "${home}/apply.log" ]]; then
  fail "plan error must not apply Terraform"
else
  pass "plan error must not apply Terraform"
fi

# private-runtime changed>0 fails; site.yml changed=0 required
read -r fx home stubs <<<"$(prepare_runtime vpriv)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 PRIV_CHANGED=2 run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "not idempotent"; then
  pass "private-runtime changed>0 fails acceptance"
else
  fail "private-runtime changed>0 fails acceptance (rc=${rc})"
  printf '%s\n' "$out"
fi

read -r fx home stubs <<<"$(prepare_runtime vsitechg)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_CHANGED=4 run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "not idempotent"; then
  pass "site.yml changed>0 fails acceptance"
else
  fail "site.yml changed>0 fails acceptance (rc=${rc})"
  printf '%s\n' "$out"
fi

read -r fx home stubs <<<"$(prepare_runtime vprivrecap)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 PRIV_RECAP=missing run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "not idempotent"; then
  pass "missing private-runtime PLAY RECAP fails verification"
else
  fail "missing private-runtime PLAY RECAP fails verification (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  fail "missing private-runtime recap must not report acceptance PASS"
else
  pass "missing private-runtime recap must not report acceptance PASS"
fi

read -r fx home stubs <<<"$(prepare_runtime vsiterecap)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 SITE_RECAP=malformed run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "not idempotent"; then
  pass "malformed site.yml PLAY RECAP fails verification"
else
  fail "malformed site.yml PLAY RECAP fails verification (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  fail "malformed site.yml recap must not report acceptance PASS"
else
  pass "malformed site.yml recap must not report acceptance PASS"
fi

# decline reboot: no reboot, no final PASS
read -r fx home stubs <<<"$(prepare_runtime vnoreboot)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(printf 'nope\n' | TF_STUB_PLAN_EXIT=0 SITE_CHANGED=0 PRIV_CHANGED=0 run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "acceptance is incomplete"; then
  pass "declining REBOOT does not report final PASS"
else
  fail "declining REBOOT does not report final PASS (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  fail "declined reboot must not print acceptance PASS"
else
  pass "declined reboot must not print acceptance PASS"
fi
if grep -Fq "sudo reboot" "${home}/ssh.log"; then
  fail "declined REBOOT must not issue reboot"
else
  pass "declined REBOOT must not issue reboot"
fi
if grep -Fq 'scratch_storage_allow_format=true' "${home}/ansible.log"; then
  fail "verify site.yml must never receive FORMAT flag"
else
  pass "verify site.yml must never receive FORMAT flag"
fi

# full verify PASS with REBOOT
read -r fx home stubs <<<"$(prepare_runtime vpass)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(printf 'REBOOT\n' | TF_STUB_PLAN_EXIT=0 SITE_CHANGED=0 PRIV_CHANGED=0 run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  pass "REBOOT confirmation plus post-reboot checks can PASS"
else
  fail "REBOOT confirmation plus post-reboot checks can PASS (rc=${rc})"
  printf '%s\n' "$out"
fi
if grep -Fq "sudo reboot" "${home}/ssh.log"; then
  pass "confirmed REBOOT issues remote reboot"
else
  fail "confirmed REBOOT issues remote reboot"
fi

# unhealthy pods fail verify
read -r fx home stubs <<<"$(prepare_runtime vcrash)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-crash.json" "${home}/pods.json"
set +e
out="$(TF_STUB_PLAN_EXIT=0 run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "unhealthy"; then
  pass "unhealthy pods fail verification"
else
  fail "unhealthy pods fail verification (rc=${rc})"
  printf '%s\n' "$out"
fi

read -r fx home stubs <<<"$(prepare_runtime vbootempty)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/ssh.log"
set +e
out="$(printf 'REBOOT\n' | TF_STUB_PLAN_EXIT=0 SITE_CHANGED=0 PRIV_CHANGED=0 SSH_BOOT_MODE=empty-before run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "pre-reboot boot identity"; then
  pass "empty pre-reboot boot ID fails before REBOOT"
else
  fail "empty pre-reboot boot ID fails before REBOOT (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  fail "empty pre-reboot boot ID must not report acceptance PASS"
else
  pass "empty pre-reboot boot ID must not report acceptance PASS"
fi
if grep -Fq "sudo reboot" "${home}/ssh.log"; then
  fail "empty pre-reboot boot ID must not issue reboot"
else
  pass "empty pre-reboot boot ID must not issue reboot"
fi

read -r fx home stubs <<<"$(prepare_runtime vbootfail)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
: >"${home}/ssh.log"
set +e
out="$(printf 'REBOOT\n' | TF_STUB_PLAN_EXIT=0 SITE_CHANGED=0 PRIV_CHANGED=0 SSH_BOOT_MODE=fail-before run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "pre-reboot boot identity"; then
  pass "unavailable pre-reboot boot ID fails before REBOOT"
else
  fail "unavailable pre-reboot boot ID fails before REBOOT (rc=${rc})"
  printf '%s\n' "$out"
fi
if grep -Fq "sudo reboot" "${home}/ssh.log"; then
  fail "unavailable pre-reboot boot ID must not issue reboot"
else
  pass "unavailable pre-reboot boot ID must not issue reboot"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  fail "unavailable pre-reboot boot ID must not report acceptance PASS"
else
  pass "unavailable pre-reboot boot ID must not report acceptance PASS"
fi

read -r fx home stubs <<<"$(prepare_runtime vbootunch)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(printf 'REBOOT\n' | TF_STUB_PLAN_EXIT=0 SITE_CHANGED=0 PRIV_CHANGED=0 SSH_BOOT_MODE=unchanged run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "did not change after reboot"; then
  pass "unchanged boot ID fails verification"
else
  fail "unchanged boot ID fails verification (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  fail "unchanged boot ID must not report acceptance PASS"
else
  pass "unchanged boot ID must not report acceptance PASS"
fi
if grep -Fq "sudo reboot" "${home}/ssh.log"; then
  pass "unchanged boot ID still issued reboot"
else
  fail "unchanged boot ID still issued reboot"
fi

read -r fx home stubs <<<"$(prepare_runtime vbootafter)"
cp "${HELPER_DIR}/argo-ok.json" "${home}/argo.json"
cp "${HELPER_DIR}/pods-ok.json" "${home}/pods.json"
set +e
out="$(printf 'REBOOT\n' | TF_STUB_PLAN_EXIT=0 SITE_CHANGED=0 PRIV_CHANGED=0 SSH_BOOT_MODE=empty-after run_verify_env "$fx" "$home" "$stubs" 2>&1)"
rc=$?
set -e
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -Fq "post-reboot boot identity"; then
  pass "empty post-reboot boot ID fails verification"
else
  fail "empty post-reboot boot ID fails verification (rc=${rc})"
  printf '%s\n' "$out"
fi
if printf '%s' "$out" | grep -Fq "PASS: clean-room acceptance completed"; then
  fail "empty post-reboot boot ID must not report acceptance PASS"
else
  pass "empty post-reboot boot ID must not report acceptance PASS"
fi

echo
echo "Summary: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0

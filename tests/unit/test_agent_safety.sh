#!/usr/bin/env bash
# Unit tests for tools/check-agent-safety.
# No root, no network, no host or infrastructure changes.
# Uses temporary fixture trees and fake non-credential data only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHECKER="${REPO_ROOT}/tools/check-agent-safety"

PASS_COUNT=0
FAIL_COUNT=0
TMP_ROOT=""

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

assert_success() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name (expected success)"
  fi
}

assert_failure() {
  local name="$1"
  shift
  if "$@"; then
    fail "$name (expected failure)"
  else
    pass "$name"
  fi
}

write_file() {
  local path="$1"
  local dir
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  cat >"$path"
}

seed_valid_fixture() {
  local root="$1"

  write_file "${root}/.cursor/rules/safe-infrastructure-development.mdc" <<'EOF'
---
description: "Safety and workflow rules for TradingChassis infrastructure development"
alwaysApply: true
---

# Safe Infrastructure Development
Verify first. Fix only if confirmed.
EOF

  write_file "${root}/.cursor/permissions.json" <<'EOF'
{
  "mcpAllowlist": [],
  "terminalAllowlist": [
    "git status",
    "git diff",
    "./tools/check-agent-safety",
    "./tools/validate-safe"
  ],
  "autoRun": {
    "allow_instructions": [
      "Allow read-only repository inspection."
    ],
    "block_instructions": [
      "Block privilege escalation including sudo."
    ]
  }
}
EOF

  write_file "${root}/.cursor/cli.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Read(**/*.md)",
      "Shell(git:status)",
      "Shell(git:diff)",
      "Shell(git:log)",
      "Shell(git:show)",
      "Shell(git:rev-parse)",
      "Shell(./tools/check-agent-safety)",
      "Shell(./tools/validate-safe)"
    ],
    "deny": [
      "Shell(sudo)",
      "Shell(su)",
      "Shell(doas)",
      "Shell(bash)",
      "Shell(sh)",
      "Shell(zsh)",
      "Shell(fish)",
      "Shell(env)",
      "Shell(xargs)",
      "Shell(make)",
      "Shell(find)",
      "Shell(python)",
      "Shell(python3)",
      "Shell(perl)",
      "Shell(ruby)",
      "Shell(node)",
      "Shell(terraform)",
      "Shell(tofu)",
      "Shell(oci)",
      "Shell(ansible)",
      "Shell(ansible-playbook)",
      "Shell(ansible-pull)",
      "Shell(ansible-galaxy)",
      "Shell(kubectl)",
      "Shell(helm)",
      "Shell(kustomize)",
      "Shell(microk8s)",
      "Shell(argocd)",
      "Shell(mkfs)",
      "Shell(mount)",
      "Shell(umount)",
      "Shell(fdisk)",
      "Shell(parted)",
      "Shell(iptables)",
      "Shell(nft)",
      "Shell(ufw)",
      "Shell(ip)",
      "Shell(route)",
      "Shell(resolvectl)",
      "Shell(systemctl)",
      "Shell(service)",
      "Shell(snap)",
      "Shell(apt)",
      "Shell(apt-get)",
      "Shell(dnf)",
      "Shell(yum)",
      "Shell(rpm)",
      "Shell(curl)",
      "Shell(wget)",
      "Shell(ssh)",
      "Shell(scp)",
      "Shell(rsync)",
      "Shell(git:commit)",
      "Shell(git:push)",
      "Shell(git:tag)",
      "Shell(git:reset)",
      "Shell(git:rebase)",
      "Shell(git:clean)",
      "Shell(git:merge)",
      "Shell(git:checkout)",
      "Shell(git:switch)",
      "Shell(git:cherry-pick)",
      "Shell(git:revert)",
      "Shell(git:config)",
      "Shell(git:remote)",
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/*.tfstate)",
      "Read(**/*.tfstate.*)",
      "Read(**/terraform.tfvars)",
      "Read(**/*.auto.tfvars)",
      "Read(**/.oci/**)",
      "Read(**/kubeconfig)",
      "Read(**/*.kubeconfig)",
      "Read(**/*.pem)",
      "Read(**/*.key)",
      "Read(**/*.p12)",
      "Read(**/*.ppk)",
      "Read(**/id_rsa)",
      "Read(**/*vault*)",
      "Write(**/.env)",
      "Write(**/*.tfstate)",
      "Write(**/terraform.tfvars)",
      "Write(**/.oci/**)",
      "Write(**/kubeconfig)",
      "Write(**/*.pem)",
      "Write(**/*.key)",
      "Write(**/*.p12)",
      "Write(**/*.ppk)",
      "Write(.cursor/**)",
      "Write(.cursorignore)",
      "Write(AGENTS.md)",
      "Write(tools/check-agent-safety)",
      "Write(tools/validate-safe)",
      "Write(tests/unit/test_agent_safety.sh)"
    ]
  }
}
EOF

  write_file "${root}/.cursor/BUGBOT.md" <<'EOF'
# Bugbot review focus
- Secrets, credentials, private keys, Terraform state, and real OCIDs
- Terraform / Ansible / Argo CD ownership conflicts
- Destructive storage, firewall, network and host operations
- Terraform provider, module and Actions pinning
- Ansible idempotency and broad error suppression
- Kubernetes RBAC, security contexts, NodePorts, mutable images and Secret handling
- Unsafe GitHub Actions permissions and pull_request_target
- Execution of live infrastructure commands from CI
- Weakening or bypassing Safety files and tests
- Claims that exceed static or CI evidence
EOF

  write_file "${root}/.cursorignore" <<'EOF'
# Fixture ignore. Does not protect terminal or MCP access.
.env
.env.*
!.env.example
.terraform/
*.tfstate
*.tfstate.*
terraform.tfvars
*.auto.tfvars
*.tfvars
!*.tfvars.example
.oci/
kubeconfig
*.kubeconfig
*.pem
*.key
*.p12
*.ppk
id_rsa
id_ed25519
*.vault_pass
vault_password
rendered-secrets/
diagnostics/
EOF

  write_file "${root}/AGENTS.md" <<'EOF'
# Agent entry point
See .cursor/rules/safe-infrastructure-development.mdc
Verify first. Fix only if confirmed.
EOF

  mkdir -p "${root}/tools" "${root}/tests/unit"
  # Minimal non-executing placeholders that still satisfy existence checks.
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'echo fixture-check' >"${root}/tools/check-agent-safety"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'echo fixture-validate' >"${root}/tools/validate-safe"
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'echo fixture-test' >"${root}/tests/unit/test_agent_safety.sh"
  chmod +x "${root}/tools/check-agent-safety" "${root}/tools/validate-safe" "${root}/tests/unit/test_agent_safety.sh"
}

main() {
  if [[ "${AGENT_SAFETY_VALIDATE_SAFE_ACTIVE:-}" == "1" ]]; then
    echo "Note: invoked from validate-safe; this test does not call validate-safe (no recursion)."
  fi

  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-safety-test.XXXXXX")"
  echo "Using temporary fixture root under: ${TMP_ROOT}"

  echo "==> Current repository Safety configuration passes"
  assert_success "repo safety configuration passes" "$CHECKER" --root "$REPO_ROOT"

  local fixture

  fixture="${TMP_ROOT}/missing-rule"
  seed_valid_fixture "$fixture"
  rm -f "${fixture}/.cursor/rules/safe-infrastructure-development.mdc"
  echo "==> Missing canonical rule fails"
  assert_failure "missing canonical rule fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/always-apply-false"
  seed_valid_fixture "$fixture"
  write_file "${fixture}/.cursor/rules/safe-infrastructure-development.mdc" <<'EOF'
---
description: "Safety and workflow rules for TradingChassis infrastructure development"
alwaysApply: false
---
# Broken fixture
EOF
  echo "==> alwaysApply: false fails"
  assert_failure "alwaysApply false fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/broad-ide-git"
  seed_valid_fixture "$fixture"
  write_file "${fixture}/.cursor/permissions.json" <<'EOF'
{
  "mcpAllowlist": [],
  "terminalAllowlist": ["git", "git status"],
  "autoRun": {
    "allow_instructions": [],
    "block_instructions": []
  }
}
EOF
  echo "==> Broad IDE allow such as plain git fails"
  assert_failure "broad IDE git allow fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/broad-cli-shell"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["allow"].append("Shell(*)")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Broad CLI allow such as Shell(*) fails"
  assert_failure "broad CLI Shell(*) allow fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/missing-tfstate-ignore"
  seed_valid_fixture "$fixture"
  grep -v 'tfstate' "${fixture}/.cursorignore" >"${fixture}/.cursorignore.tmp"
  mv "${fixture}/.cursorignore.tmp" "${fixture}/.cursorignore"
  echo "==> Missing Terraform state ignore pattern fails"
  assert_failure "missing tfstate ignore fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/missing-kubeconfig"
  seed_valid_fixture "$fixture"
  grep -vi 'kubeconfig' "${fixture}/.cursorignore" >"${fixture}/.cursorignore.tmp"
  mv "${fixture}/.cursorignore.tmp" "${fixture}/.cursorignore"
  echo "==> Missing kubeconfig protection fails"
  assert_failure "missing kubeconfig protection fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/missing-deny"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
deny = data["permissions"]["deny"]
data["permissions"]["deny"] = [
    entry for entry in deny
    if entry not in {"Shell(terraform)", "Shell(kubectl)"}
]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Missing dangerous Terraform or Kubernetes deny category fails"
  assert_failure "missing terraform/kubectl deny fails" "$CHECKER" --root "$fixture"

  echo
  echo "Summary: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"

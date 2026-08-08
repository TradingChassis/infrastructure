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
    "git branch --show-current",
    "git rev-parse HEAD",
    "git rev-parse --show-toplevel",
    "git remote -v",
    "git ls-files",
    "./tools/check-agent-safety",
    "./tools/validate-safe"
  ],
  "autoRun": {
    "allow_instructions": [
      "Allow narrow read-only repository state queries."
    ],
    "block_instructions": [
      "Block privilege escalation including sudo.",
      "Require manual review for git diff, git grep, git show, and git log."
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
      "Shell(git:branch --show-current)",
      "Shell(git:rev-parse HEAD)",
      "Shell(git:rev-parse --show-toplevel)",
      "Shell(git:remote -v)",
      "Shell(git:ls-files)",
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
      "Read(**/*.env)",
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
      "Read(**/id_ed25519)",
      "Read(**/*.vault_pass)",
      "Write(**/.env)",
      "Write(**/*.env)",
      "Write(**/*.tfstate)",
      "Write(**/terraform.tfvars)",
      "Write(**/.oci/**)",
      "Write(**/kubeconfig)",
      "Write(**/*.pem)",
      "Write(**/*.key)",
      "Write(**/*.p12)",
      "Write(**/*.ppk)",
      "Write(**/id_rsa)",
      "Write(**/id_ed25519)",
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

  fixture="${TMP_ROOT}/ide-git-diff"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/permissions.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["terminalAllowlist"].append("git diff")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> IDE allowlist with git diff fails"
  assert_failure "IDE git diff allow fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/ide-git-grep"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/permissions.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["terminalAllowlist"].append("git grep")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> IDE allowlist with git grep fails"
  assert_failure "IDE git grep allow fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/cli-git-diff"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["allow"].append("Shell(git:diff*)")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> CLI allowlist with Shell(git:diff*) fails"
  assert_failure "CLI git diff allow fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/cli-git-grep"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["allow"].append("Shell(git:grep*)")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> CLI allowlist with Shell(git:grep*) fails"
  assert_failure "CLI git grep allow fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/no-index"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/permissions.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["terminalAllowlist"].append("git status --no-index")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Allow entry with --no-index fails"
  assert_failure "allow entry with --no-index fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/unknown-key"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/permissions.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["terminalAllowLists"] = ["git status"]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Unknown relevant JSON key fails"
  assert_failure "unknown permissions.json key fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/wrong-type"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["allow"] = "Shell(git:status)"
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Wrong allow-list data type fails"
  assert_failure "wrong allow list type fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/sh-not-covered-by-ssh"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [
    entry for entry in data["permissions"]["deny"]
    if entry not in {"Shell(sh)", "Shell(sh:*)"}
]
if "Shell(ssh)" not in data["permissions"]["deny"]:
    data["permissions"]["deny"].append("Shell(ssh)")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Shell(sh) is not covered by Shell(ssh)"
  assert_failure "Shell(sh) not covered by Shell(ssh)" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/su-not-covered-by-sudo"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [
    entry for entry in data["permissions"]["deny"]
    if entry not in {"Shell(su)", "Shell(su:*)"}
]
if "Shell(sudo)" not in data["permissions"]["deny"]:
    data["permissions"]["deny"].append("Shell(sudo)")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Shell(su) is not covered by Shell(sudo)"
  assert_failure "Shell(su) not covered by Shell(sudo)" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/exact-shell-sh-passes"
  seed_valid_fixture "$fixture"
  echo "==> Exact required Shell(sh) deny passes"
  assert_success "exact Shell(sh) deny passes" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/git-commit-wildcard-covers"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
deny = [
    entry for entry in data["permissions"]["deny"]
    if entry != "Shell(git:commit)"
]
if "Shell(git:commit*)" not in deny:
    deny.append("Shell(git:commit*)")
data["permissions"]["deny"] = deny
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Supported Shell(git:commit*) wildcard covers Shell(git:commit)"
  assert_success "Shell(git:commit*) covers Shell(git:commit)" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/missing-id-rsa-read"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [e for e in data["permissions"]["deny"] if e != "Read(**/id_rsa)"]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Missing id_rsa Read deny fails"
  assert_failure "missing id_rsa Read deny fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/missing-id-rsa-write"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [e for e in data["permissions"]["deny"] if e != "Write(**/id_rsa)"]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Missing id_rsa Write deny fails"
  assert_failure "missing id_rsa Write deny fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/missing-id-ed25519-read"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [e for e in data["permissions"]["deny"] if e != "Read(**/id_ed25519)"]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Missing id_ed25519 Read deny fails"
  assert_failure "missing id_ed25519 Read deny fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/missing-id-ed25519-write"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [e for e in data["permissions"]["deny"] if e != "Write(**/id_ed25519)"]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Missing id_ed25519 Write deny fails"
  assert_failure "missing id_ed25519 Write deny fails" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/id-rsa-not-ed25519"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [
    e for e in data["permissions"]["deny"]
    if "id_ed25519" not in e
]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> id_rsa entries do not satisfy id_ed25519 requirements"
  assert_failure "id_rsa does not satisfy id_ed25519" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/id-ed25519-not-rsa"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [
    e for e in data["permissions"]["deny"]
    if "id_rsa" not in e
]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> id_ed25519 entries do not satisfy id_rsa requirements"
  assert_failure "id_ed25519 does not satisfy id_rsa" "$CHECKER" --root "$fixture"

  fixture="${TMP_ROOT}/unrelated-key-substring"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/cli.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["permissions"]["deny"] = [
    e for e in data["permissions"]["deny"]
    if "id_rsa" not in e and "id_ed25519" not in e
]
# Visibly fake path fragment; not a real key path.
data["permissions"]["deny"].append("Read(**/example-not-a-secret-id_rsa-fragment)")
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Unrelated substring does not satisfy key categories"
  assert_failure "unrelated substring does not satisfy key denies" "$CHECKER" --root "$fixture"

  for cmd in zsh fish doas env xargs find; do
    fixture="${TMP_ROOT}/ide-forbidden-${cmd}"
    seed_valid_fixture "$fixture"
    python3 - "$fixture/.cursor/permissions.json" "$cmd" <<'PY'
import json, sys
path = sys.argv[1]
cmd = sys.argv[2]
data = json.load(open(path, encoding="utf-8"))
data["terminalAllowlist"].append(cmd)
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
    echo "==> IDE allowlist with ${cmd} fails"
    assert_failure "IDE forbidden token ${cmd} fails" "$CHECKER" --root "$fixture"
  done

  fixture="${TMP_ROOT}/ide-safe-entries-still-ok"
  seed_valid_fixture "$fixture"
  python3 - "$fixture/.cursor/permissions.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["terminalAllowlist"] = [
    "git status",
    "git branch --show-current",
    "git rev-parse HEAD",
    "./tools/check-agent-safety",
    "./tools/validate-safe",
]
json.dump(data, open(path, "w", encoding="utf-8"), indent=2)
PY
  echo "==> Safe IDE allowlist entries still pass"
  assert_success "safe IDE allowlist entries pass" "$CHECKER" --root "$fixture"

  echo
  echo "Summary: PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
  # Explicit cleanup call so ShellCheck sees a direct reference; trap covers early exits.
  cleanup
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"

#!/usr/bin/env bash
# Unit tests for tools/check-sensitive-metadata.
# Static/synthetic only. Does not contact OCI, GitHub, or any credential API.
# Forbidden examples are constructed at runtime so this file does not embed
# complete live-looking values that would then need a global allowlist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHECKER="${REPO_ROOT}/tools/check-sensitive-metadata"

python3 - "$REPO_ROOT" "$CHECKER" <<'PY'
from __future__ import annotations

import os
import re
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(sys.argv[1]).resolve()
CHECKER = Path(sys.argv[2]).resolve()
WORKFLOW = REPO_ROOT / ".github/workflows/repository-validation.yml"
PIN = REPO_ROOT / "tools/gitleaks.pin"
GITLEAKS_TOML = REPO_ROOT / ".gitleaks.toml"
SECURITY_DOC = REPO_ROOT / "docs/REPOSITORY_SECURITY.md"
CHANGELOG = REPO_ROOT / "CHANGELOG.md"
K8S_TEST = REPO_ROOT / "tests/unit/test_ansible_k8s_runtime_contract.sh"
CLOUD_TEST = REPO_ROOT / "tests/unit/test_cloud_shell_execution_contracts.sh"

PASS = 0
FAIL = 0


def pass_(name: str) -> None:
    global PASS
    PASS += 1
    print(f"PASS: {name}")


def fail_(name: str) -> None:
    global FAIL
    FAIL += 1
    print(f"FAIL: {name}")


def run_checker(root: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(CHECKER), "--root", str(root)],
        check=False,
        capture_output=True,
        text=True,
    )


def write(root: Path, rel: str, content: str) -> None:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def unix_home(user: str, tail: str = "repo") -> str:
    return "/" + "home/" + user + "/" + tail


def mac_home(user: str, tail: str = "repo") -> str:
    return "/" + "Us" + "ers/" + user + "/" + tail


def win_home(user: str, tail: str = "repo") -> str:
    return "C:" + chr(92) + "Us" + "ers" + chr(92) + user + chr(92) + tail


def assert_pass(name: str, proc: subprocess.CompletedProcess[str]) -> None:
    if proc.returncode == 0 and "PASS: no sensitive-metadata findings" in proc.stdout:
        pass_(name)
        return
    fail_(f"{name} (exit={proc.returncode}, stdout={proc.stdout!r}, stderr={proc.stderr!r})")


def assert_fail_rule(name: str, proc: subprocess.CompletedProcess[str], rule: str) -> None:
    if proc.returncode != 0 and f"rule={rule}" in proc.stdout:
        pass_(name)
        return
    fail_(
        f"{name} (exit={proc.returncode}, expected rule={rule}, "
        f"stdout={proc.stdout!r}, stderr={proc.stderr!r})"
    )


def checker_is_executable() -> None:
    mode = CHECKER.stat().st_mode
    if mode & stat.S_IXUSR:
        pass_("checker is executable")
    else:
        fail_("checker is executable")


checker_is_executable()

checker_text = CHECKER.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
pin = PIN.read_text(encoding="utf-8")
k8s_test = K8S_TEST.read_text(encoding="utf-8")
cloud_test = CLOUD_TEST.read_text(encoding="utf-8")
changelog = CHANGELOG.read_text(encoding="utf-8")
unreleased = changelog.split("## [0.1.0]", 1)[0]

# --- current tree ---
repo_scan = run_checker(REPO_ROOT)
assert_pass("current repository tree is clean", repo_scan)

# --- accept fixtures ---
with tempfile.TemporaryDirectory(prefix="meta-accept-") as tmp:
    root = Path(tmp)
    write(
        root,
        "docs/ok.md",
        "\n".join(
            [
                "Clone under $HOME/infrastructure",
                "Clone under ${HOME}/repo",
                "Clone under ~/repo",
                "Path " + unix_home("<user>"),
                "Path " + unix_home("example"),
                "Path " + unix_home("test-user"),
                "Path " + mac_home("example"),
                "Path " + win_home("example"),
                "Cloud Shell OCI CLI is typically " + unix_home("oci", "bin/oci"),
                "ansible_user: ubuntu",
                "username: example",
                "user: ubuntu",
                "Documentation IP 192.0.2.10 and CIDR 203.0.113.0/24",
                "RFC1918 10.0.1.10 and pod CIDR 10.1.0.0/16",
                "Synthetic vault ocid1.vault.oc1.eu-test-1.." + ("a" * 48),
                "Example tenancy ocid1.tenancy.oc1..example",
                "password variable postgres-password",
                "grafana-login-password secretKeyRef private_runtime_config_vault_id",
                "ubuntu@<instance_public_ip>:",
            ]
        )
        + "\n",
    )
    proc = run_checker(root)
    assert_pass("synthetic accept fixtures pass", proc)

# --- reject fixtures: multiple synthetic users, same rule ---
synthetic_users = (
    "alice-example",
    "operator-test",
    "person123",
    "operator123",
)
with tempfile.TemporaryDirectory(prefix="meta-reject-home-") as tmp:
    root = Path(tmp)
    observed_rules = set()
    for user in synthetic_users:
        write(root, f"docs/{user}.md", "checkout " + unix_home(user) + "\n")
        proc = run_checker(root)
        assert_fail_rule(f"unix home path rejected for {user}", proc, "home-path")
        for line in proc.stdout.splitlines():
            if line.startswith("FINDING "):
                match = re.search(r"rule=(\S+)", line)
                if match:
                    observed_rules.add(match.group(1))
        (root / f"docs/{user}.md").unlink()
    if observed_rules == {"home-path"}:
        pass_("multiple synthetic usernames trigger the same home-path rule")
    else:
        fail_(f"multiple synthetic usernames share one rule (got {observed_rules})")

def reject_one(name: str, rel: str, content: str, rule: str) -> None:
    with tempfile.TemporaryDirectory(prefix="meta-reject-one-") as tmp:
        root = Path(tmp)
        write(root, rel, content)
        assert_fail_rule(name, run_checker(root), rule)


reject_one("macOS home path rejected", "docs/mac.md", "path " + mac_home("person123") + "\n", "home-path")
reject_one("Windows home path rejected", "docs/win.md", "path " + win_home("person123") + "\n", "home-path")
reject_one(
    "concrete ansible_user rejected",
    "inventory.yml",
    "ansible_user" + ": " + "alice-example" + "\n",
    "identity-field",
)
reject_one(
    "operator_user field rejected",
    "ops.yml",
    "operator_user" + ": " + "person123" + "\n",
    "identity-field",
)
reject_one(
    "shell prompt with concrete user rejected",
    "docs/prompt.md",
    "alice-example" + "@" + "laptop-local" + ":~\n",
    "shell-prompt",
)
public_ip = ".".join(("9", "9", "9", "9"))
reject_one("public IPv4 rejected", "docs/ip.md", "ssh to " + public_ip + " and continue\n", "public-ipv4")
live_unique = "a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6"
reject_one(
    "live-looking OCID rejected",
    "docs/ocid.md",
    "vault_id: ocid1.vault.oc1.eu-frankfurt-1.." + live_unique + "\n",
    "ocid-live-shape",
)
pem_begin = "-----BEGIN " + "PRIVATE KEY-----"
pem_end = "-----END " + "PRIVATE KEY-----"
reject_one(
    "PEM private-key armor rejected",
    "docs/key.pem",
    pem_begin + "\nexample-not-a-secret\n" + pem_end + "\n",
    "private-key-armor",
)

# --- checker/tests do not encode the current operator username ---
operator = (os.environ.get("USER") or os.environ.get("USERNAME") or "").strip()
skip_names = {
    "root",
    "ubuntu",
    "oci",
    "runner",
    "example",
    "test-user",
    "nobody",
    "git",
}
if operator and operator.lower() not in skip_names:
    haystacks = {
        "checker": checker_text,
        "metadata unit test": (
            REPO_ROOT / "tests/unit/test_sensitive_metadata_contract.sh"
        ).read_text(encoding="utf-8"),
        "k8s runtime test": k8s_test,
        "cloud shell test": cloud_test,
        "changelog unreleased": unreleased,
    }
    leaked = [label for label, text in haystacks.items() if operator in text]
    if leaked:
        fail_("current operator username is absent from security rules and tests")
    else:
        pass_("current operator username is absent from security rules and tests")
else:
    pass_("current operator username is absent from security rules and tests")

# Complete forbidden home-path literals must not appear as a single-name denylist.
home_prefix = "/" + "home/"
denylist_hit = False
for source, text in (
    ("checker", checker_text),
    ("k8s runtime test", k8s_test),
    ("cloud shell test", cloud_test),
):
    for match in re.finditer(re.escape(home_prefix) + r"([A-Za-z0-9._-]+)/", text):
        user = match.group(1)
        if user not in {"example", "test-user", "ubuntu", "oci"} and not user.startswith("<"):
            denylist_hit = True
            fail_(f"{source} embeds concrete home path user class member {user!r}")
if not denylist_hit:
    pass_("no concrete home-path username denylist is embedded in rules or related tests")

# Do not re-encode historical tenancy namespace values as denylist tokens.
cloud_block = cloud_test.split("forbidden_live", 1)
if len(cloud_block) == 2:
    needle_block = cloud_block[1].split(")", 1)[0]
    if re.search(r'"[a-z0-9]{10,16}"', needle_block):
        fail_("cloud-shell contract test must not denylist a concrete tenancy namespace")
    else:
        pass_("cloud-shell contract test does not denylist a concrete tenancy namespace")
else:
    pass_("cloud-shell contract test does not denylist a concrete tenancy namespace")

# --- CI / pin / docs contracts ---
if "name: Security validation" in workflow:
    pass_("workflow defines Security validation job")
else:
    fail_("workflow defines Security validation job")

if "name: Static repository checks" in workflow and "name: Terraform validation" in workflow:
    pass_("existing Static/Terraform jobs remain named")
else:
    fail_("existing Static/Terraform jobs remain named")

security_job = workflow.split("name: Security validation", 1)
if len(security_job) == 2:
    body = security_job[1].split("\n  terraform:", 1)[0]
    if "fetch-depth: 0" in body:
        pass_("security job requests fetch-depth 0")
    else:
        fail_("security job requests fetch-depth 0")
    if "--redact" in body:
        pass_("gitleaks invocation redacts secrets in logs")
    else:
        fail_("gitleaks invocation redacts secrets in logs")
    if "gitleaks dir" in body and "gitleaks git" in body:
        pass_("security job runs directory and git gitleaks modes")
    else:
        fail_("security job runs directory and git gitleaks modes")
    if "check-sensitive-metadata" in body:
        pass_("security job runs the metadata checker")
    else:
        fail_("security job runs the metadata checker")
    if "test_sensitive_metadata_contract.sh" in body:
        pass_("security job runs metadata contract tests")
    else:
        fail_("security job runs metadata contract tests")
    if "uses: gitleaks/gitleaks-action" in body:
        fail_("security job does not depend on org-licensed gitleaks-action")
    else:
        pass_("security job does not depend on org-licensed gitleaks-action")
    if "oci session" in body.lower() or "github token validation" in body.lower():
        fail_("security job must not verify credentials against providers")
    else:
        pass_("security job does not verify credentials against providers")
    if "actions/checkout@" in body and re.search(
        r"actions/checkout@[0-9a-f]{40}", body
    ):
        pass_("security checkout action is SHA-pinned")
    else:
        fail_("security checkout action is SHA-pinned")
else:
    fail_("unable to isolate Security validation job body")

if "VERSION=8.30.1" in pin and "SHA256=" in pin and "linux_x64" in pin:
    pass_("gitleaks pin file names version, archive, and sha256")
else:
    fail_("gitleaks pin file names version, archive, and sha256")

gitleaks_toml = GITLEAKS_TOML.read_text(encoding="utf-8")
if "useDefault = true" in gitleaks_toml:
    pass_("gitleaks config extends upstream defaults")
else:
    fail_("gitleaks config extends upstream defaults")
if re.search(r"paths\s*=\s*\[[^\]]*(tests/|\*\.md|\*\.yml)", gitleaks_toml):
    fail_("gitleaks config must not blanket-ignore tests/docs/yaml")
else:
    pass_("gitleaks config does not blanket-ignore tests/docs/yaml")

if SECURITY_DOC.is_file():
    security_doc = SECURITY_DOC.read_text(encoding="utf-8")
    required = (
        "Security validation",
        "Gitleaks",
        "check-sensitive-metadata",
        "synthetic",
        "allowlist",
        "rotate",
        "history",
    )
    missing = [item for item in required if item.lower() not in security_doc.lower()]
    if missing:
        fail_(f"security runbook missing {missing}")
    else:
        pass_("security runbook covers CI, fixtures, allowlists, and incidents")
else:
    fail_("docs/REPOSITORY_SECURITY.md exists")

if "Security validation" in unreleased and "Gitleaks" in unreleased:
    pass_("CHANGELOG [Unreleased] records the security CI")
else:
    fail_("CHANGELOG [Unreleased] records the security CI")

if unix_home("example") in unreleased or home_prefix in unreleased:
    # Generic /home/<operator>/ is acceptable; concrete users are not.
    concrete = re.findall(re.escape(home_prefix) + r"([A-Za-z0-9._-]+)/", unreleased)
    bad = [user for user in concrete if user not in {"example", "test-user", "ubuntu", "oci"}]
    if bad:
        fail_("CHANGELOG [Unreleased] still contains a concrete home username")
    else:
        pass_("CHANGELOG [Unreleased] does not encode a concrete home username")
else:
    pass_("CHANGELOG [Unreleased] does not encode a concrete home username")

print(f"Summary: PASS={PASS} FAIL={FAIL}")
raise SystemExit(1 if FAIL else 0)
PY

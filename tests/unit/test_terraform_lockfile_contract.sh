#!/usr/bin/env bash
# Static contract: Terraform provider lockfile is tracked and internally consistent.
# Does not contact OCI, initialize a live backend, or run terraform plan/apply.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 <<'PY'
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(".").resolve()
LOCK = ROOT / "terraform/.terraform.lock.hcl"
VERSIONS = ROOT / "terraform/versions.tf"
GITIGNORE = ROOT / ".gitignore"

if not LOCK.is_file():
    raise SystemExit("terraform/.terraform.lock.hcl must exist")

ignored = subprocess.run(
    ["git", "check-ignore", "-v", "terraform/.terraform.lock.hcl"],
    check=False,
    capture_output=True,
    text=True,
)
if ignored.returncode == 0:
    raise SystemExit(
        "terraform/.terraform.lock.hcl must remain tracked; gitignore matched: "
        + ignored.stdout.strip()
    )
print("PASS: terraform/.terraform.lock.hcl exists and is not gitignored")

dot_tf = subprocess.run(
    ["git", "check-ignore", "-v", "terraform/.terraform"],
    check=False,
    capture_output=True,
    text=True,
)
if dot_tf.returncode != 0:
    raise SystemExit("terraform/.terraform must remain gitignored")
print("PASS: terraform/.terraform remains gitignored")

gitignore = GITIGNORE.read_text(encoding="utf-8")
if "keep .terraform.lock.hcl tracked" not in gitignore:
    raise SystemExit(".gitignore must document that .terraform.lock.hcl stays tracked")
print("PASS: .gitignore documents tracked lockfile policy")

lock = LOCK.read_text(encoding="utf-8")
if 'provider "registry.terraform.io/oracle/oci"' not in lock:
    raise SystemExit("lockfile must select registry.terraform.io/oracle/oci")
if not re.search(r'(?m)^\s*version\s*=\s*"8\.26\.\d+"\s*$', lock):
    raise SystemExit("lockfile must pin oracle/oci 8.26.x")
if not re.search(r'(?m)^\s*constraints\s*=\s*"~> 8\.26\.0"\s*$', lock):
    raise SystemExit('lockfile constraints must remain "~> 8.26.0"')

h1 = re.findall(r'(?m)^\s*"h1:[^"]+"\s*,?\s*$', lock)
if len(h1) < 2:
    raise SystemExit(
        "lockfile must include at least two h1 hashes "
        "(linux_amd64 CI/control-node and linux_arm64 Cloud Shell)"
    )
zh = re.findall(r'(?m)^\s*"zh:[0-9a-f]+"\s*,?\s*$', lock)
if not zh:
    raise SystemExit("lockfile must include registry zh checksums from terraform providers lock")
print("PASS: lockfile selects oracle/oci 8.26.x with multi-platform h1 hashes")

versions = VERSIONS.read_text(encoding="utf-8")
if not re.search(r'(?m)^\s*source\s*=\s*"oracle/oci"\s*$', versions):
    raise SystemExit("terraform/versions.tf must require source oracle/oci")
if not re.search(r'(?m)^\s*version\s*=\s*"~> 8\.26\.0"\s*$', versions):
    raise SystemExit('terraform/versions.tf must keep version = "~> 8.26.0"')
if not re.search(r'(?m)^\s*required_version\s*=\s*"~> 1\.15\.0"\s*$', versions):
    raise SystemExit('terraform/versions.tf must keep required_version = "~> 1.15.0"')
print("PASS: versions.tf constraints match the tracked lockfile policy")
print("PASS: Terraform provider lockfile contract")
PY

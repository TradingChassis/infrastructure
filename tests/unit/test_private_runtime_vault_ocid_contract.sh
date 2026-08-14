#!/usr/bin/env bash
# Static regression for private-runtime Vault OCID shape validation.
# Compiles the role-owned pattern against synthetic identifiers only.
# Does not SSH, contact OCI, or use live Vault OCIDs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
TASKS = ROOT / "ansible/roles/private_runtime_config/tasks/main.yml"
DEFAULTS = ROOT / "ansible/roles/private_runtime_config/defaults/main.yml"
CHANGELOG = ROOT / "CHANGELOG.md"
README = ROOT / "ansible/README.md"
WORKFLOW = ROOT / ".github/workflows/repository-validation.yml"

tasks = TASKS.read_text(encoding="utf-8")
defaults = DEFAULTS.read_text(encoding="utf-8")
changelog = CHANGELOG.read_text(encoding="utf-8")
unreleased = changelog.split("## [0.1.0]", 1)[0]
readme = README.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")

OLD_REGEX = r"^ocid1\\.vault\\.oc1\\.[a-z0-9-]+\\.[a-z0-9]+$"
if OLD_REGEX in tasks:
    raise SystemExit("old oversimplified vault OCID regex must not remain in tasks")
if "ocid1.vault.oc1.<region>.<unique>" in tasks and "ocid1.vault.oc1.<region>..<unique>" not in tasks:
    raise SystemExit("fail_msg must describe the empty future-use (double-dot) OCID shape")

pattern_match = re.search(
    r"^private_runtime_config_vault_ocid_pattern:\s+'([^']+)'\s*$",
    defaults,
    re.M,
)
if pattern_match is None:
    raise SystemExit("defaults must define private_runtime_config_vault_ocid_pattern")
pattern = pattern_match.group(1)
compiled = re.compile(pattern)
if "is match(private_runtime_config_vault_ocid_pattern)" not in tasks:
    raise SystemExit("shape assert must use private_runtime_config_vault_ocid_pattern")
if '(private_runtime_config_vault_id.split(\'.\'))[1] == "vault"' not in tasks:
    raise SystemExit("shape assert must require exact OCID resource type vault")

UNIQUE_A = "a" * 60
UNIQUE_B = "b" * 60


def ocid(resource: str, region: str, unique: str, future: str = "") -> str:
    return f"ocid1.{resource}.oc1.{region}.{future}.{unique}"


accept = (
    ocid("vault", "eu-frankfurt-1", UNIQUE_A),
    ocid("vault", "us-phoenix-1", UNIQUE_B),
    ocid("vault", "eu-frankfurt-1", UNIQUE_A, future="reserved"),
)
reject = {
    "old five-component shape": f"ocid1.vault.oc1.eu-frankfurt-1.{UNIQUE_A}",
    "vaultsecret": ocid("vaultsecret", "eu-frankfurt-1", UNIQUE_A),
    "key": ocid("key", "eu-frankfurt-1", UNIQUE_A),
    "secret": ocid("secret", "eu-frankfurt-1", UNIQUE_A),
    "instance": ocid("instance", "eu-frankfurt-1", UNIQUE_A),
    "empty unique": "ocid1.vault.oc1.eu-frankfurt-1..",
    "malformed region": ocid("vault", "frankfurt", UNIQUE_A),
    "uppercase region": ocid("vault", "EU-FRANKFURT-1", UNIQUE_A),
    "empty region": f"ocid1.vault.oc1..{UNIQUE_A}",
    "prefix junk": f"X{ocid('vault', 'eu-frankfurt-1', UNIQUE_A)}",
    "suffix junk": f"{ocid('vault', 'eu-frankfurt-1', UNIQUE_A)}.extra",
    "leading whitespace": f" {ocid('vault', 'eu-frankfurt-1', UNIQUE_A)}",
    "trailing whitespace": f"{ocid('vault', 'eu-frankfurt-1', UNIQUE_A)} ",
}

for value in accept:
    if compiled.fullmatch(value) is None:
        raise SystemExit(f"pattern must accept synthetic Vault OCID: {value}")
print("PASS: role pattern accepts regional Vault OCIDs with empty or present future-use")

for label, value in reject.items():
    if compiled.fullmatch(value) is not None:
        raise SystemExit(f"pattern must reject {label}: {value}")
print("PASS: role pattern rejects non-vault, malformed, and old five-component OCIDs")

forbidden = [
    line.strip().strip("- ").strip('"')
    for line in defaults.split("private_runtime_config_forbidden_input_substrings:", 1)[1].split(
        "private_runtime_config_secret_provider_classes:", 1
    )[0].splitlines()
    if line.strip().startswith("- ")
]
if "example" not in forbidden or "placeholder" not in forbidden:
    raise SystemExit("forbidden input substrings must still reject placeholders")
placeholder = ocid("vault", "eu-frankfurt-1", "example")
if compiled.fullmatch(placeholder) is None:
    raise SystemExit("placeholder unique still has vault shape; substring deny-list must remain")
if "private_runtime_config_forbidden_input_substrings" not in tasks:
    raise SystemExit("placeholder substring assert must remain")
print("PASS: placeholder Vault-shaped values remain fail-closed via substring deny-list")

shape_pos = tasks.find("- name: Assert private OCI Vault ID has a vault OCID shape")
region_shape_pos = tasks.find("- name: Assert private OCI region has a plausible identifier shape")
region_match_pos = tasks.find("- name: Assert Vault OCID region matches operator OCI region")
runtime_pos = tasks.find("- name: Ensure dedicated Kubernetes Ansible module runtime")
mutate_pos = tasks.find("kubernetes.core.")
if min(shape_pos, region_shape_pos, region_match_pos) < 0:
    raise SystemExit("vault/region shape and region-match asserts must exist")
if not (shape_pos < region_shape_pos < region_match_pos < runtime_pos < mutate_pos):
    raise SystemExit("Vault OCID and region asserts must fail closed before kubernetes.core mutation")
if "(private_runtime_config_vault_id.split('.'))[3] == private_runtime_config_oci_region" not in tasks:
    raise SystemExit("Vault OCID region component must equal private_runtime_config_oci_region")
if "no_log: true" not in tasks[region_match_pos:runtime_pos]:
    raise SystemExit("region-match assert must keep no_log: true")
print("PASS: fail-closed ordering and Vault/region consistency assert")

if "does not prove that the Vault exists" not in tasks and "identifier shape only" not in tasks:
    raise SystemExit("shape fail_msg must not claim Vault existence")
if "oci " in tasks.lower() and "command:" in tasks[shape_pos:runtime_pos]:
    raise SystemExit("must not add OCI CLI lookup to private-runtime validation")
print("PASS: shape validation remains local and does not claim Vault existence")

live_like = re.findall(r"ocid1\.vault\.oc1\.[a-z]{2}-[a-z0-9]+-[0-9]+\.\.[a-z0-9]{20,}", changelog + readme + tasks + defaults)
for token in live_like:
    unique = token.rsplit(".", 1)[-1]
    if unique not in {UNIQUE_A, UNIQUE_B} and len(set(unique)) > 2:
        raise SystemExit(f"must not embed a live-like Vault OCID: {token}")
print("PASS: no live-like Vault OCID committed")

for needle in (
    "ocid1.vault.oc1",
    "future-use",
    "not yet live proven",
):
    if needle.lower() not in unreleased.lower() and needle not in unreleased:
        raise SystemExit(f"CHANGELOG [Unreleased] must record {needle}")
if "private-runtime-config" not in unreleased and "private runtime" not in unreleased.lower():
    raise SystemExit("CHANGELOG [Unreleased] must record the private-runtime validation failure")
print("PASS: CHANGELOG records the Vault OCID validation failure and Git fix")

if "test_private_runtime_vault_ocid_contract.sh" not in workflow:
    raise SystemExit("CI must run the Vault OCID contract test")
if "ocid1.vault.oc1.eu-test-1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" in workflow:
    raise SystemExit("CI syntax-check extra-var must not keep the old five-component Vault OCID")
if "ocid1.vault.oc1.eu-test-1..aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" not in workflow:
    raise SystemExit("CI syntax-check extra-var must use the empty future-use Vault OCID shape")
print("PASS: CI enforces the Vault OCID contract")
print("PASS: private-runtime Vault OCID contract")
PY

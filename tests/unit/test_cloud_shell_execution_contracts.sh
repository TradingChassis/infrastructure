#!/usr/bin/env bash
# Static regression tests for Cloud Shell execution-readiness contracts.
# Does not contact OCI, initialize backends, or run terraform plan/apply.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 <<'PY'
from __future__ import annotations

import re
import tempfile
from pathlib import Path

ROOT = Path(".").resolve()

CANONICAL_AUTH_FILES = (
    "docs/V2_CLEAN_ROOM_DEPLOYMENT.md",
    "terraform/backend.hcl.example",
    "terraform/terraform.tfvars.example",
    "tools/check-cloud-shell-readiness",
)


def ssh_public_key_uses_function(tfvars_text: str) -> bool:
    return bool(
        re.search(
            r"(?m)^\s*ssh_public_key\s*=.*\b(file|pathexpand|templatefile|abspath|dirname)\s*\(",
            tfvars_text,
        )
    )


def assert_literal_ssh_public_key_placeholder(tfvars_text: str, label: str) -> None:
    if ssh_public_key_uses_function(tfvars_text):
        raise SystemExit(f"{label}: ssh_public_key must not use Terraform functions")
    if not re.search(
        r'(?m)^\s*ssh_public_key\s*=\s*"<contents-of-~/\.ssh/tradingchassis\.pub>"\s*$',
        tfvars_text,
    ):
        raise SystemExit(f"{label}: expected literal ssh_public_key placeholder")


def bash_fences(text: str) -> list[str]:
    return re.findall(r"```bash\n(.*?)```", text, flags=re.S)


def main() -> None:
    example = (ROOT / "terraform/terraform.tfvars.example").read_text(encoding="utf-8")
    assert_literal_ssh_public_key_placeholder(example, "terraform.tfvars.example")
    print("PASS: committed terraform.tfvars.example uses literal ssh_public_key")

    bad = re.sub(
        r'(?m)^\s*ssh_public_key\s*=\s*".*"\s*$',
        'ssh_public_key = file("${pathexpand("~/.ssh/tradingchassis.pub")}")',
        example,
        count=1,
    )
    if not ssh_public_key_uses_function(bad):
        raise SystemExit("negative fixture did not embed illegal function call")
    try:
        assert_literal_ssh_public_key_placeholder(bad, "negative-fixture")
    except SystemExit:
        print("PASS: illegal file()/pathexpand() ssh_public_key assignment is rejected")
    else:
        raise SystemExit("negative fixture must fail the tfvars ssh_public_key contract")

    with tempfile.TemporaryDirectory(prefix="tfvars-contract-") as tmp:
        sanitized = Path(tmp) / "sanitized.tfvars"
        content = example
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
            content = content.replace(old, new)
        if ssh_public_key_uses_function(content):
            raise SystemExit("sanitized temp tfvars unexpectedly contains functions")
        if "s/<.*$//" not in content:
            raise SystemExit("sanitized tfvars must retain the documented curl/sed comment")
        sanitized.write_text(content, encoding="utf-8")
        print("PASS: sanitized temp var-file keeps literal ssh_public_key")

    if not re.search(r'(?m)^\s*oci_auth\s*=\s*"APIKey"\s*$', example):
        raise SystemExit("terraform.tfvars.example must set oci_auth = \"APIKey\"")
    if 'oci_auth                = "SecurityToken"' in example:
        raise SystemExit("terraform.tfvars.example must not select SecurityToken")
    print("PASS: terraform.tfvars.example selects APIKey")

    backend_example = (ROOT / "terraform/backend.hcl.example").read_text(encoding="utf-8")
    if not re.search(r'(?m)^\s*auth\s*=\s*"APIKey"\s*$', backend_example):
        raise SystemExit('backend.hcl.example must set auth = "APIKey"')
    if not re.search(r'(?m)^\s*config_file_profile\s*=\s*"tradingchassis"\s*$', backend_example):
        raise SystemExit("backend.hcl.example must set config_file_profile = tradingchassis")
    if re.search(r'(?m)^\s*auth\s*=\s*"SecurityToken"\s*$', backend_example):
        raise SystemExit("backend.hcl.example must not set auth = SecurityToken")
    if "tradingchassis/backend-test/" in backend_example:
        raise SystemExit("backend.hcl.example must not use the disposable backend-test key")
    if not re.search(
        r'(?m)^\s*key\s*=\s*"tradingchassis/production/terraform.tfstate"\s*$',
        backend_example,
    ):
        raise SystemExit("backend.hcl.example must keep the production-style example key")
    print("PASS: backend.hcl.example selects APIKey / tradingchassis")

    runbook = (ROOT / "docs/V2_CLEAN_ROOM_DEPLOYMENT.md").read_text(encoding="utf-8")
    helper = (ROOT / "tools/check-cloud-shell-readiness").read_text(encoding="utf-8")
    if "python3.12" not in helper:
        raise SystemExit("check-cloud-shell-readiness must require python3.12")
    if re.search(r"(?m)^require_cmd python3$", helper):
        raise SystemExit("check-cloud-shell-readiness must not treat generic python3 as the Ansible interpreter")
    print("PASS: check-cloud-shell-readiness requires python3.12")

    for label, text in (
        ("terraform/backend.hcl.example", backend_example),
        ("terraform/terraform.tfvars.example", example),
        ("tools/check-cloud-shell-readiness", helper),
    ):
        if "oci session authenticate" in text:
            raise SystemExit(f"{label}: canonical path must not instruct oci session authenticate")
        if "--auth security_token" in text:
            raise SystemExit(f"{label}: canonical path must not use --auth security_token")

    for fence in bash_fences(runbook):
        if "oci session authenticate" in fence:
            raise SystemExit("runbook bash example must not contain oci session authenticate")
        if "--auth security_token" in fence:
            raise SystemExit("runbook bash example must not contain --auth security_token")
        if "SUPPRESS_LABEL_WARNING" in fence:
            raise SystemExit("runbook must not suppress OCI_API_KEY label warnings")
    print("PASS: canonical Cloud Shell path no longer uses SecurityToken session auth")

    identity_needles = (
        "--config-file \"$HOME/.oci/config\"",
        "--profile tradingchassis",
        "--auth api_key",
    )
    for needle in identity_needles:
        if needle not in runbook:
            raise SystemExit(f"runbook missing APIKey CLI identity token: {needle}")

    ns_block = runbook.split("oci os ns get", 1)[1].split("```", 1)[0]
    bucket_block = runbook.split("oci os bucket get", 1)[1].split("```", 1)[0]
    for needle in ("--profile tradingchassis", "--auth api_key"):
        if needle not in ns_block:
            raise SystemExit(f"oci os ns get block missing {needle}")
    for needle in ("--profile tradingchassis", "--auth api_key", "--region"):
        if needle not in bucket_block:
            raise SystemExit(f"oci os bucket get block missing {needle}")
    if "instance_obo_user" not in runbook:
        raise SystemExit("runbook must still distinguish Cloud Shell built-in instance_obo_user")
    if "OCI_CLI_AUTH" not in runbook:
        raise SystemExit("runbook must document OCI_CLI_AUTH precedence")
    print("PASS: Object Storage preflight uses APIKey profile tradingchassis")

    for needle in (
        "TF_VERSION=1.15.8",
        "$HOME/bin",
        "SHA256SUMS",
        "aarch64|arm64",
        "x86_64|amd64",
        "releases.hashicorp.com/terraform",
    ):
        if needle not in runbook:
            raise SystemExit(f"runbook missing Terraform install contract token: {needle}")
    if "sudo" in "\n".join(bash_fences(runbook)) and "terraform_" in "\n".join(bash_fences(runbook)):
        # Allow sudo only if unrelated; Terraform install fence must not use sudo.
        for fence in bash_fences(runbook):
            if "TF_VERSION=1.15.8" in fence and "sudo" in fence:
                raise SystemExit("Terraform install must not require sudo")
    print("PASS: Terraform 1.15.8 user-local install contract is documented")

    for needle in (
        "NoPublicAccess",
        "Versioning Enabled",
        "oci os bucket create",
        "OPERATOR BOOTSTRAP ACTION",
        "**not** create it",
    ):
        if needle not in runbook:
            raise SystemExit(f"runbook missing state-bucket bootstrap token: {needle}")
    if "tradingchassis/backend-test/" in runbook and "production" not in runbook:
        raise SystemExit("runbook must not promote backend-test as the production key")
    print("PASS: external state-bucket bootstrap contract is documented")

    forbidden_live = (
        "BEGIN PRIVATE KEY",
        "BEGIN RSA PRIVATE KEY",
    )
    for path in CANONICAL_AUTH_FILES:
        text = (ROOT / path).read_text(encoding="utf-8")
        for token in forbidden_live:
            if token in text:
                raise SystemExit(f"{path} must not contain live credential/identifier token: {token}")
        if re.search(r"ocid1\.user\.oc1\.[a-z0-9]+", text, flags=re.I):
            raise SystemExit(f"{path} must not contain a live user OCID")
        if re.search(r"ocid1\.tenancy\.oc1\.(?!\.example)[a-z0-9]+", text, flags=re.I):
            raise SystemExit(f"{path} must not contain a live tenancy OCID")
    print("PASS: committed examples contain no live OCI identifiers or private keys")

    if "First V2 clean-room deployment: not yet executed" not in runbook:
        raise SystemExit("runbook must still mark first clean-room deployment as not yet executed")
    print("PASS: first clean-room deployment remains not yet executed")

    if "source \"$HOME/.venvs/tradingchassis-ansible/bin/activate\"" not in runbook:
        raise SystemExit("runbook must require the Cloud Shell tradingchassis-ansible venv")
    if "ANSIBLE_CONFIG=\"$PWD/ansible/ansible.cfg\"" not in runbook:
        raise SystemExit("runbook must set ANSIBLE_CONFIG to the repository ansible.cfg")
    if "ansible/playbooks/site.yml" not in runbook:
        raise SystemExit("runbook must use ansible/playbooks/site.yml")
    if "ansible/inventory/local.yml" not in runbook:
        raise SystemExit("runbook must use ansible/inventory/local.yml")
    print("PASS: Cloud Shell Ansible venv and ANSIBLE_CONFIG contract is documented")

    print("PASS: Cloud Shell execution contract unit tests")


if __name__ == "__main__":
    main()
PY

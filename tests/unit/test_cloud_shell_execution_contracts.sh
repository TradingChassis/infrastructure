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


def main() -> None:
    example = (ROOT / "terraform/terraform.tfvars.example").read_text(encoding="utf-8")
    assert_literal_ssh_public_key_placeholder(example, "terraform.tfvars.example")
    print("PASS: committed terraform.tfvars.example uses literal ssh_public_key")

    # Reproduce the previously missed failure mode.
    bad = example
    bad = re.sub(
        r'(?m)^\s*ssh_public_key\s*=\s*".*"\s*$',
        'ssh_public_key = file("${pathexpand("~/.ssh/tradingchassis.pub")}")',
        bad,
        count=1,
    )
    if not ssh_public_key_uses_function(bad):
        raise SystemExit("negative fixture did not embed illegal function call")
    if not re.search(r'(?m)^\s*ssh_public_key\s*=\s*file\s*\(', bad):
        raise SystemExit("negative fixture missing file() assignment")
    try:
        assert_literal_ssh_public_key_placeholder(bad, "negative-fixture")
    except SystemExit:
        print("PASS: illegal file()/pathexpand() ssh_public_key assignment is rejected")
    else:
        raise SystemExit("negative fixture must fail the tfvars ssh_public_key contract")

    # Prove a sanitized literal var-file is free of function-call syntax for this field.
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
        if not re.search(r'(?m)^\s*ssh_public_key\s*=\s*"ssh-ed25519 ', content):
            raise SystemExit("sanitized temp tfvars missing literal ssh_public_key content")
        sanitized.write_text(content, encoding="utf-8")
        print(
            "PASS: sanitized temp var-file keeps literal ssh_public_key "
            f"(wrote {sanitized.name}; no OCI/Terraform plan invoked)"
        )

    runbook = (ROOT / "docs/V2_CLEAN_ROOM_DEPLOYMENT.md").read_text(encoding="utf-8")
    backend_example = (ROOT / "terraform/backend.hcl.example").read_text(encoding="utf-8")
    for label, text in (
        ("docs/V2_CLEAN_ROOM_DEPLOYMENT.md", runbook),
        ("terraform/backend.hcl.example", backend_example),
        ("terraform/terraform.tfvars.example", example),
    ):
        if "oci session authenticate" in text and "--region-id" in text:
            raise SystemExit(f"{label}: must not use --region-id with oci session authenticate")
    if not re.search(r"oci session authenticate[\s\S]{0,200}--region\b", runbook):
        raise SystemExit("runbook must document oci session authenticate with --region")
    print("PASS: canonical oci session authenticate uses --region (no --region-id)")

    for needle in (
        "oci os ns get",
        "oci os bucket get",
        "--profile tradingchassis",
        "--auth security_token",
    ):
        if needle not in runbook:
            raise SystemExit(f"runbook missing Object Storage SecurityToken preflight token: {needle}")
    ns_block = runbook.split("oci os ns get", 1)[1].split("```", 1)[0]
    bucket_block = runbook.split("oci os bucket get", 1)[1].split("```", 1)[0]
    for needle in ("--profile tradingchassis", "--auth security_token"):
        if needle not in ns_block:
            raise SystemExit(f"oci os ns get block missing {needle}")
    for needle in ("--profile tradingchassis", "--auth security_token", "--region"):
        if needle not in bucket_block:
            raise SystemExit(f"oci os bucket get block missing {needle}")
    if "instance_obo_user" not in runbook:
        raise SystemExit("runbook must still distinguish Cloud Shell built-in instance_obo_user")
    print("PASS: Object Storage preflight uses SecurityToken profile tradingchassis")

    print("PASS: Cloud Shell execution contract unit tests")


if __name__ == "__main__":
    main()
PY

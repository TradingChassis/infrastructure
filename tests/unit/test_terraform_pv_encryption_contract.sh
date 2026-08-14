#!/usr/bin/env bash
# Static regression for the OCI PV in-transit encryption contract.
# Inspects production Terraform blocks only.
# No OCI provider, no remote backend, no credentials, no root plan/apply.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
TERRAFORM_DIR = ROOT / "terraform"
INSTANCE_RESOURCE = 'resource "oci_core_instance" "node"'
ATTACHMENT_RESOURCE = 'resource "oci_core_volume_attachment" "scratch"'
PV_TRUE = "is_pv_encryption_in_transit_enabled = true"
PV_FALSE = "is_pv_encryption_in_transit_enabled = false"


def extract_hcl_block(source: str, marker: str, label: str) -> str:
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"missing {label}")
    brace = source.find("{", start)
    if brace < 0:
        raise SystemExit(f"{label} has no opening brace")
    depth = 0
    for index, char in enumerate(source[brace:], start=brace):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise SystemExit(f"{label} is unclosed")


def strip_hcl_comments(text: str) -> str:
    stripped_lines = []
    for line in text.splitlines():
        stripped_lines.append(re.sub(r"#.*$", "", line))
    return "\n".join(stripped_lines)


def assignment_true(block: str, name: str) -> bool:
    return bool(
        re.search(rf'(?m)^\s*{re.escape(name)}\s*=\s*true\s*$', block)
    )


def assignment_false(block: str, name: str) -> bool:
    return bool(
        re.search(rf'(?m)^\s*{re.escape(name)}\s*=\s*false\s*$', block)
    )


def quoted_assignment(block: str, name: str, value: str) -> bool:
    return bool(
        re.search(
            rf'(?m)^\s*{re.escape(name)}\s*=\s*"{re.escape(value)}"\s*$',
            block,
        )
    )


def main() -> None:
    tf_files = sorted(TERRAFORM_DIR.glob("*.tf"))
    if not tf_files:
        raise SystemExit("no terraform/*.tf files found")
    joined = "\n".join(path.read_text(encoding="utf-8") for path in tf_files)
    compute = (TERRAFORM_DIR / "compute.tf").read_text(encoding="utf-8")
    storage = (TERRAFORM_DIR / "storage.tf").read_text(encoding="utf-8")

    instance = extract_hcl_block(compute, INSTANCE_RESOURCE, INSTANCE_RESOURCE)
    attachment = extract_hcl_block(
        storage, ATTACHMENT_RESOURCE, ATTACHMENT_RESOURCE
    )
    instance_code = strip_hcl_comments(instance)
    attachment_code = strip_hcl_comments(attachment)
    production_code = strip_hcl_comments(joined)

    launch_options = extract_hcl_block(
        instance_code, "launch_options", "oci_core_instance.node launch_options"
    )
    if not assignment_true(launch_options, "is_pv_encryption_in_transit_enabled"):
        raise SystemExit(
            "oci_core_instance.node launch_options must set "
            "is_pv_encryption_in_transit_enabled = true"
        )
    if assignment_false(launch_options, "is_pv_encryption_in_transit_enabled"):
        raise SystemExit(
            "oci_core_instance.node must not disable PV encryption in transit"
        )
    print("PASS: instance launch_options enables PV encryption in transit")

    if not quoted_assignment(attachment_code, "attachment_type", "paravirtualized"):
        raise SystemExit(
            "oci_core_volume_attachment.scratch must remain paravirtualized"
        )
    print("PASS: scratch attachment type remains paravirtualized")

    if not assignment_true(attachment_code, "is_pv_encryption_in_transit_enabled"):
        raise SystemExit(
            "oci_core_volume_attachment.scratch must set "
            "is_pv_encryption_in_transit_enabled = true"
        )
    if assignment_false(attachment_code, "is_pv_encryption_in_transit_enabled"):
        raise SystemExit(
            "oci_core_volume_attachment.scratch must not disable PV encryption"
        )
    print("PASS: scratch attachment keeps PV encryption in transit enabled")

    false_matches = [
        path.name
        for path in tf_files
        if PV_FALSE in strip_hcl_comments(path.read_text(encoding="utf-8"))
    ]
    if false_matches:
        raise SystemExit(
            "production Terraform must not assign "
            f"{PV_FALSE} (found in {', '.join(false_matches)})"
        )
    if PV_TRUE not in instance_code or PV_TRUE not in attachment_code:
        raise SystemExit("instance and attachment PV encryption assignments drifted")
    if "is_pv_encryption_in_transit_enabled" not in production_code:
        raise SystemExit("PV encryption contract missing from production Terraform")
    print("PASS: instance and attachment PV encryption settings are consistent")
    print("PASS: Terraform PV encryption contract")


if __name__ == "__main__":
    main()
PY

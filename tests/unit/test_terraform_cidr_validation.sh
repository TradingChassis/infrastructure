#!/usr/bin/env bash
# Isolated regression for Terraform subnet-in-VCN CIDR containment.
# Evaluates the production variable blocks with concrete values.
# No OCI provider, no remote backend, no credentials, no root plan/apply.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

if ! command -v terraform >/dev/null 2>&1; then
  printf 'FAIL: terraform is required on PATH\n' >&2
  exit 1
fi

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
TERRAFORM_DIR = ROOT / "terraform"
ERROR_NEEDLE = "fully contained within vcn_cidr"
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def extract_variable_block(source: str, name: str) -> str:
    marker = f'variable "{name}"'
    start = source.find(marker)
    if start < 0:
        raise SystemExit(f"missing variable {name!r} in terraform/variables.tf")
    brace = source.find("{", start)
    if brace < 0:
        raise SystemExit(f"variable {name!r} has no opening brace")
    depth = 0
    for index, char in enumerate(source[brace:], start=brace):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1].rstrip() + "\n"
    raise SystemExit(f"variable {name!r} is unclosed")


def run_terraform(args: list[str], cwd: Path, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["terraform", *args],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def plan(cwd: Path, env: dict[str, str], vcn_cidr: str, subnet_cidr: str) -> subprocess.CompletedProcess[str]:
    return run_terraform(
        [
            "plan",
            "-input=false",
            "-lock=false",
            "-no-color",
            f"-var=vcn_cidr={vcn_cidr}",
            f"-var=subnet_cidr={subnet_cidr}",
        ],
        cwd,
        env,
    )


def assert_accepted(cwd: Path, env: dict[str, str], vcn_cidr: str, subnet_cidr: str, label: str) -> None:
    result = plan(cwd, env, vcn_cidr, subnet_cidr)
    if result.returncode != 0:
        raise SystemExit(
            f"{label}: expected acceptance of {subnet_cidr} inside {vcn_cidr}\n"
            f"{result.stdout}{result.stderr}"
        )
    if "cidrcontains" in result.stderr or "unknown function" in result.stderr:
        raise SystemExit(f"{label}: unsupported CIDR function leaked into evaluation")
    print(f"PASS: {label}")


def readable_output(result: subprocess.CompletedProcess[str]) -> str:
    combined = ANSI_RE.sub("", f"{result.stdout}{result.stderr}")
    return re.sub(r"\s+", " ", combined)


def assert_rejected(cwd: Path, env: dict[str, str], vcn_cidr: str, subnet_cidr: str, label: str) -> None:
    result = plan(cwd, env, vcn_cidr, subnet_cidr)
    combined = readable_output(result)
    if result.returncode == 0:
        raise SystemExit(f"{label}: expected rejection of {subnet_cidr} vs {vcn_cidr}")
    if "Call to unknown function" in combined or "cidrcontains" in combined:
        raise SystemExit(f"{label}: rejected for the unsupported-function defect, not containment")
    if ERROR_NEEDLE not in combined:
        raise SystemExit(
            f"{label}: rejection did not use the containment error message\n"
            f"{result.stdout}{result.stderr}"
        )
    print(f"PASS: {label}")


def main() -> None:
    tf_files = sorted(TERRAFORM_DIR.glob("*.tf"))
    if not tf_files:
        raise SystemExit("no terraform/*.tf files found")
    joined = "\n".join(path.read_text(encoding="utf-8") for path in tf_files)
    if re.search(r"\bcidrcontains\s*\(", joined):
        raise SystemExit("terraform/*.tf must not call unsupported cidrcontains()")
    print("PASS: terraform/*.tf does not call cidrcontains()")

    variables = (TERRAFORM_DIR / "variables.tf").read_text(encoding="utf-8")
    subnet_block = extract_variable_block(variables, "subnet_cidr")
    vcn_block = extract_variable_block(variables, "vcn_cidr")
    condition_start = subnet_block.find("condition")
    condition = subnet_block[condition_start:]
    for needle in (
        "cidrhost(var.vcn_cidr, 0)",
        "cidrhost(var.vcn_cidr, -1)",
        "cidrhost(var.subnet_cidr, 0)",
        "cidrhost(var.subnet_cidr, -1)",
        "16777216",
        "alltrue(",
        "can(cidrnetmask(var.subnet_cidr))",
        "can(cidrnetmask(var.vcn_cidr))",
        "try(",
    ):
        if needle not in condition:
            raise SystemExit(f"subnet_cidr validation missing {needle}")
    for forbidden in ("startswith(", "cidrcontains(", '"10.0"', "'10.0'"):
        if forbidden in condition:
            raise SystemExit(f"subnet_cidr validation must not use {forbidden}")
    print("PASS: production validation uses numeric IPv4 first/last containment")

    fixture_env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith("TF_VAR_")
    }
    fixture_env["TF_IN_AUTOMATION"] = "1"
    fixture_env["TF_INPUT"] = "0"

    with tempfile.TemporaryDirectory(prefix="tf-cidr-validation-") as tmp:
        fixture = Path(tmp)
        (fixture / "versions.tf").write_text(
            'terraform {\n  required_version = "~> 1.15.0"\n}\n',
            encoding="utf-8",
        )
        (fixture / "variables.tf").write_text(
            f"{vcn_block}\n{subnet_block}",
            encoding="utf-8",
        )
        (fixture / "outputs.tf").write_text(
            'output "ok" {\n  value = true\n}\n',
            encoding="utf-8",
        )
        fixture_env["TF_DATA_DIR"] = str(fixture / ".terraform")

        init = run_terraform(
            ["init", "-backend=false", "-input=false", "-lock=false", "-no-color"],
            fixture,
            fixture_env,
        )
        if init.returncode != 0:
            raise SystemExit(f"fixture terraform init failed\n{init.stdout}{init.stderr}")
        if "oracle/oci" in f"{init.stdout}{init.stderr}":
            raise SystemExit("fixture init must not load the OCI provider")
        print("PASS: isolated fixture initialized without OCI provider or backend")

        assert_accepted(fixture, fixture_env, "10.0.0.0/16", "10.0.1.0/24", "valid 10.0.1.0/24 inside 10.0.0.0/16")
        assert_rejected(fixture, fixture_env, "10.0.0.0/16", "10.1.0.0/24", "invalid 10.1.0.0/24 outside 10.0.0.0/16")
        assert_accepted(fixture, fixture_env, "10.0.0.0/16", "10.0.0.0/16", "subnet equal to VCN is contained")
        assert_rejected(fixture, fixture_env, "10.0.0.0/16", "10.0.0.0/15", "wider child prefix is not contained")
        assert_rejected(fixture, fixture_env, "10.0.0.0/16", "not-a-cidr", "malformed subnet CIDR is rejected")
        assert_accepted(fixture, fixture_env, "172.16.0.0/12", "172.16.5.0/24", "valid 172.16.5.0/24 inside 172.16.0.0/12")
        assert_accepted(fixture, fixture_env, "192.168.0.0/16", "192.168.10.0/24", "valid 192.168.10.0/24 inside 192.168.0.0/16")
        assert_rejected(fixture, fixture_env, "192.168.0.0/16", "10.0.1.0/24", "10.0.1.0/24 outside 192.168.0.0/16")

        broken = Path(tmp) / "broken"
        broken.mkdir()
        (broken / "versions.tf").write_text(
            'terraform {\n  required_version = "~> 1.15.0"\n}\n',
            encoding="utf-8",
        )
        (broken / "variables.tf").write_text(
            """
variable "vcn_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  type = string
  validation {
    condition = cidrcontains(var.vcn_cidr, cidrhost(var.subnet_cidr, 0))
    error_message = "unsupported function fixture"
  }
}

output "ok" {
  value = true
}
""",
            encoding="utf-8",
        )
        broken_env = dict(fixture_env)
        broken_env["TF_DATA_DIR"] = str(broken / ".terraform")
        broken_init = run_terraform(
            ["init", "-backend=false", "-input=false", "-lock=false", "-no-color"],
            broken,
            broken_env,
        )
        if broken_init.returncode != 0:
            raise SystemExit(
                f"broken-fixture init failed\n{broken_init.stdout}{broken_init.stderr}"
            )
        broken_plan = plan(broken, broken_env, "10.0.0.0/16", "10.0.1.0/24")
        broken_text = f"{broken_plan.stdout}{broken_plan.stderr}"
        if broken_plan.returncode == 0:
            raise SystemExit("cidrcontains fixture must fail on Terraform 1.15")
        if "cidrcontains" not in broken_text and "unknown function" not in broken_text:
            raise SystemExit(
                "cidrcontains fixture did not fail as the live blocker did\n"
                f"{broken_text}"
            )
        print("PASS: restored cidrcontains() is detected by concrete evaluation")

    print("PASS: Terraform CIDR containment regression")


if __name__ == "__main__":
    main()
PY

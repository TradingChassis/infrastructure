#!/usr/bin/env python3
"""Normalize the OCI Ubuntu cloud-image IPv4 FORWARD REJECT.

This helper never probes or mutates live kernel firewall tables. It only
inspects/rewrites a supplied iptables-restore file.

It removes exactly one kind of rule:

  -A FORWARD -j REJECT --reject-with icmp-host-prohibited

It preserves:

  - OCI INPUT REJECT
  - InstanceServices chain and rules
  - OUTPUT jump to InstanceServices
  - all unrelated lines and ordering

It refuses to modify an unexpected/non-OCI firewall file.
It does not create a rules file when the path is absent.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

EXIT_OK = 0
EXIT_UNEXPECTED = 2
EXIT_USAGE = 3

FORWARD_REJECT = "-A FORWARD -j REJECT --reject-with icmp-host-prohibited"
INPUT_REJECT = "-A INPUT -j REJECT --reject-with icmp-host-prohibited"
BACKUP_SUFFIX = ".tradingchassis-oci-forward.bak"


class NormalizeError(Exception):
    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


def split_lines(text: str) -> list[str]:
    if text == "":
        return []
    parts = text.splitlines()
    if text.endswith(("\n", "\r\n")):
        return parts + [""]
    return parts


def join_lines(lines: list[str], original: str) -> str:
    newline = "\r\n" if "\r\n" in original else "\n"
    if lines and lines[-1] == "":
        return newline.join(lines[:-1]) + newline
    return newline.join(lines)


def stripped(line: str) -> str:
    return line.strip()


def is_supported_oci_cloud_image_rules(text: str) -> tuple[bool, str]:
    lines = [stripped(line) for line in text.splitlines() if stripped(line)]
    if "CLOUD_IMG" not in text:
        return False, "missing CLOUD_IMG marker"
    if "Oracle Cloud Infrastructure" not in text:
        return False, "missing Oracle Cloud Infrastructure marker"
    if "*filter" not in lines:
        return False, "missing *filter table"
    if not any(line.startswith(":FORWARD") for line in lines):
        return False, "missing FORWARD chain"
    if not any(line.startswith(":InstanceServices") for line in lines):
        return False, "missing InstanceServices chain"
    if INPUT_REJECT not in lines:
        return False, "missing exact INPUT REJECT"
    if not any(
        line.startswith("-A OUTPUT") and line.endswith("-j InstanceServices")
        for line in lines
    ):
        return False, "missing OUTPUT jump to InstanceServices"
    if "COMMIT" not in lines:
        return False, "missing COMMIT"
    return True, "supported OCI cloud-image baseline"


def normalize_rules_text(text: str) -> tuple[str, int]:
    supported, reason = is_supported_oci_cloud_image_rules(text)
    if not supported:
        raise NormalizeError(
            "error: refusing to modify unexpected firewall file "
            f"({reason})",
            EXIT_UNEXPECTED,
        )
    original_lines = split_lines(text)
    kept: list[str] = []
    removed = 0
    for line in original_lines:
        if line == "":
            kept.append(line)
            continue
        if stripped(line) == FORWARD_REJECT:
            removed += 1
            continue
        kept.append(line)
    return join_lines(kept, text), removed


def normalize_rules_file(path: Path, write: bool) -> str:
    if not path.exists():
        return "absent"
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise NormalizeError(
            f"error: cannot read {path}: {exc}",
            EXIT_USAGE,
        ) from exc

    new_text, removed = normalize_rules_text(text)
    if removed == 0:
        return "unchanged"
    if not write:
        return "removed"
    backup = path.with_name(path.name + BACKUP_SUFFIX)
    try:
        if not backup.exists():
            backup.write_text(text, encoding="utf-8")
        tmp = path.with_name(path.name + ".tradingchassis.tmp")
        if tmp.exists():
            tmp.unlink()
        tmp.write_text(new_text, encoding="utf-8")
        os.replace(tmp, path)
    except OSError as exc:
        raise NormalizeError(
            f"error: cannot write normalized firewall file: {exc}",
            EXIT_USAGE,
        ) from exc
    return "removed"


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Remove the exact OCI cloud-image unconditional IPv4 FORWARD "
            "REJECT from an iptables-restore file. Never flushes chains."
        )
    )
    parser.add_argument(
        "--rules-file",
        required=True,
        help="Path to iptables rules.v4. Absent file is a safe no-op.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Inspect and report without writing the file.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        action = normalize_rules_file(Path(args.rules_file), write=not args.dry_run)
    except NormalizeError as exc:
        print(str(exc), file=sys.stderr)
        return exc.code
    print(action)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

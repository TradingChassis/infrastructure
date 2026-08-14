#!/usr/bin/env python3
"""Verify MicroK8s-owned Calico UFW interface allowances.

MicroK8s, not Ansible, writes the four Calico interface UFW rules when it
detects enabled UFW. This helper only inspects persisted UFW user rules.
It does not call ufw, iptables, or nft and does not mutate any file.

Required functional allowances, IPv4 and IPv6:

  allow in on vxlan.calico
  allow out on vxlan.calico
  allow in on cali+
  allow out on cali+

Comments and other presentation metadata are ignored.
"""

from __future__ import annotations

import argparse
import shlex
import sys
from pathlib import Path

EXIT_OK = 0
EXIT_UNEXPECTED = 2
EXIT_USAGE = 3

REQUIRED = (
    ("ufw-user-input", "-i", "vxlan.calico"),
    ("ufw-user-output", "-o", "vxlan.calico"),
    ("ufw-user-input", "-i", "cali+"),
    ("ufw-user-output", "-o", "cali+"),
)


class VerifyError(Exception):
    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


def _strip_comment_match(tokens: tuple[str, ...]) -> tuple[str, ...]:
    kept: list[str] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if (
            token == "-m"
            and index + 1 < len(tokens)
            and tokens[index + 1] == "comment"
        ):
            index += 2
            if index < len(tokens) and tokens[index] == "--comment":
                index += 2
            elif index < len(tokens) and tokens[index].startswith("--comment="):
                index += 1
            continue
        if token == "--comment":
            index += 2
            continue
        if token.startswith("--comment="):
            index += 1
            continue
        kept.append(token)
        index += 1
    return tuple(kept)


def _append_semantics(text: str) -> list[tuple[str, ...]]:
    found: list[tuple[str, ...]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith("-A "):
            continue
        try:
            tokens = tuple(shlex.split(line, posix=True, comments=False))
        except ValueError as exc:
            raise VerifyError(
                f"error: refusing to parse malformed UFW rule {line!r}",
                EXIT_UNEXPECTED,
            ) from exc
        if len(tokens) < 3 or tokens[0] != "-A":
            raise VerifyError(
                f"error: refusing to parse unexpected UFW rule {line!r}",
                EXIT_UNEXPECTED,
            )
        found.append(_strip_comment_match(tokens))
    return found


def _rule_allows_interface(
    tokens: tuple[str, ...],
    chain: str,
    iface_flag: str,
    iface: str,
) -> bool:
    if len(tokens) < 2 or tokens[0] != "-A" or tokens[1] != chain:
        return False
    adjacent = set(zip(tokens, tokens[1:]))
    return (iface_flag, iface) in adjacent and ("-j", "ACCEPT") in adjacent


def verify_user_rules(text: str, label: str) -> None:
    present = _append_semantics(text)
    missing = [
        f"{iface_flag} {iface} on {chain}"
        for chain, iface_flag, iface in REQUIRED
        if not any(
            _rule_allows_interface(tokens, chain, iface_flag, iface)
            for tokens in present
        )
    ]
    if missing:
        raise VerifyError(
            "error: missing MicroK8s Calico UFW allowances in "
            + label
            + ": "
            + ", ".join(missing),
            EXIT_UNEXPECTED,
        )


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify MicroK8s-owned Calico UFW interface allowances. "
            "Read-only. Does not call ufw or mutate files."
        )
    )
    parser.add_argument(
        "--user-rules",
        required=True,
        help="Path to /etc/ufw/user.rules",
    )
    parser.add_argument(
        "--user6-rules",
        required=True,
        help="Path to /etc/ufw/user6.rules",
    )
    return parser.parse_args(argv)


def _read_rules(path: Path) -> str:
    if not path.exists():
        raise VerifyError(
            f"error: {path} is required to verify Calico UFW allowances",
            EXIT_UNEXPECTED,
        )
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise VerifyError(
            f"error: cannot read {path}: {exc}",
            EXIT_USAGE,
        ) from exc


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        verify_user_rules(_read_rules(Path(args.user_rules)), args.user_rules)
        verify_user_rules(_read_rules(Path(args.user6_rules)), args.user6_rules)
    except VerifyError as exc:
        print(str(exc), file=sys.stderr)
        return exc.code
    print("ok")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

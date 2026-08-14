#!/usr/bin/env python3
"""Normalize OCI Ubuntu cloud-image IPv4 filter rules for MicroK8s.

This helper never probes or mutates live kernel firewall tables. It only
inspects/rewrites a supplied iptables-save file, or plans runtime INPUT
ordering from a supplied `iptables-nft -S INPUT` dump.

Persistent file contract:

  1. Remove the exact OCI cloud-image FORWARD REJECT, if present:
     -A FORWARD -j REJECT --reject-with icmp-host-prohibited
  2. Insert exactly one MicroK8s pod → node-local API allow and exactly
     one MicroK8s pod → node-local kubelet allow immediately before the
     OCI catch-all INPUT REJECT, in that canonical order.
  3. Preserve that INPUT REJECT, InstanceServices, SSH, and unrelated lines.

Runtime planner contract:

  Each required pod → host TCP allow must exist exactly once and, when the
  OCI INPUT REJECT is present, appear before it. Relative order of the two
  allows is not a runtime correctness requirement, so sequential `-I INPUT`
  cannot create a reordering loop.

It refuses to modify an unexpected/non-OCI firewall file.
It does not create a rules file when the path is absent.
It does not delete the OCI INPUT REJECT.
"""

from __future__ import annotations

import argparse
import ipaddress
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


def validate_pod_cidr(value: str) -> str:
    raw = value.strip()
    try:
        network = ipaddress.IPv4Network(raw, strict=True)
    except (ValueError, ipaddress.AddressValueError, ipaddress.NetmaskValueError) as exc:
        raise NormalizeError(
            f"error: invalid MicroK8s pod CIDR {value!r}: {exc}",
            EXIT_USAGE,
        ) from exc
    if network.prefixlen > 24:
        raise NormalizeError(
            f"error: MicroK8s pod CIDR {raw} is narrower than /24; "
            "refusing an accidentally host-specific range",
            EXIT_USAGE,
        )
    return str(network)


def validate_tcp_port(value: str, label: str) -> str:
    raw = value.strip()
    if not raw.isdigit():
        raise NormalizeError(
            f"error: invalid MicroK8s {label} port {value!r}",
            EXIT_USAGE,
        )
    port = int(raw)
    if port < 1 or port > 65535:
        raise NormalizeError(
            f"error: invalid MicroK8s {label} port {value!r}",
            EXIT_USAGE,
        )
    return str(port)


def host_tcp_ports(apiserver_port: str, kubelet_port: str) -> tuple[str, str]:
    api = validate_tcp_port(apiserver_port, "API")
    kubelet = validate_tcp_port(kubelet_port, "kubelet")
    if api == kubelet:
        raise NormalizeError(
            "error: MicroK8s API and kubelet ports must be distinct",
            EXIT_USAGE,
        )
    return api, kubelet


def build_allow_line(pod_cidr: str, port: str) -> str:
    cidr = validate_pod_cidr(pod_cidr)
    validated_port = validate_tcp_port(port, "host TCP")
    return f"-A INPUT -s {cidr} -p tcp -m tcp --dport {validated_port} -j ACCEPT"


def build_allow_lines(
    pod_cidr: str, apiserver_port: str, kubelet_port: str
) -> tuple[str, str]:
    cidr = validate_pod_cidr(pod_cidr)
    api, kubelet = host_tcp_ports(apiserver_port, kubelet_port)
    return (
        f"-A INPUT -s {cidr} -p tcp -m tcp --dport {api} -j ACCEPT",
        f"-A INPUT -s {cidr} -p tcp -m tcp --dport {kubelet} -j ACCEPT",
    )


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
    if not any(line.startswith(":INPUT") for line in lines):
        return False, "missing INPUT chain"
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


def normalize_rules_text(
    text: str, pod_cidr: str, apiserver_port: str, kubelet_port: str
) -> tuple[str, str]:
    supported, reason = is_supported_oci_cloud_image_rules(text)
    if not supported:
        raise NormalizeError(
            "error: refusing to modify unexpected firewall file "
            f"({reason})",
            EXIT_UNEXPECTED,
        )
    allows = build_allow_lines(pod_cidr, apiserver_port, kubelet_port)
    allow_set = set(allows)
    original_lines = split_lines(text)
    reject_count = sum(
        1
        for line in original_lines
        if line != "" and stripped(line) == INPUT_REJECT
    )
    if reject_count != 1:
        raise NormalizeError(
            "error: refusing to modify firewall file with "
            f"{reject_count} catch-all INPUT REJECT rules",
            EXIT_UNEXPECTED,
        )
    rebuilt: list[str] = []
    for line in original_lines:
        if line != "" and stripped(line) == FORWARD_REJECT:
            continue
        if line != "" and stripped(line) in allow_set:
            continue
        if line != "" and stripped(line) == INPUT_REJECT:
            rebuilt.extend(allows)
            rebuilt.append(line)
            continue
        rebuilt.append(line)
    new_text = join_lines(rebuilt, text)
    if new_text == text:
        return new_text, "unchanged"
    return new_text, "changed"


def normalize_rules_file(
    path: Path,
    pod_cidr: str,
    apiserver_port: str,
    kubelet_port: str,
    write: bool,
) -> str:
    if not path.exists():
        return "absent"
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise NormalizeError(
            f"error: cannot read {path}: {exc}",
            EXIT_USAGE,
        ) from exc

    new_text, action = normalize_rules_text(
        text, pod_cidr, apiserver_port, kubelet_port
    )
    if action == "unchanged":
        return "unchanged"
    if not write:
        return "changed"
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
    return "changed"


def _input_append_lines(save_text: str) -> list[str]:
    lines: list[str] = []
    for raw in save_text.splitlines():
        line = stripped(raw)
        if not line or line.startswith("#"):
            continue
        if line.startswith("-A INPUT"):
            lines.append(line)
    return lines


def _allow_is_correct(
    rules: list[str], allow: str, reject_idx: int | None
) -> bool:
    allow_idxs = [i for i, line in enumerate(rules) if line == allow]
    if len(allow_idxs) != 1:
        return False
    if reject_idx is None:
        return True
    return allow_idxs[0] < reject_idx


def plan_input_runtime(
    save_text: str,
    pod_cidr: str,
    apiserver_port: str,
    kubelet_port: str,
) -> tuple[str, tuple[str, ...]]:
    api, kubelet = host_tcp_ports(apiserver_port, kubelet_port)
    api_allow, kubelet_allow = build_allow_lines(
        pod_cidr, apiserver_port, kubelet_port
    )
    rules = _input_append_lines(save_text)
    reject_idxs = [i for i, line in enumerate(rules) if line == INPUT_REJECT]
    if len(reject_idxs) > 1:
        raise NormalizeError(
            "error: refusing runtime INPUT plan with "
            f"{len(reject_idxs)} catch-all INPUT REJECT rules",
            EXIT_UNEXPECTED,
        )
    reject_idx = reject_idxs[0] if reject_idxs else None
    # Insert with iptables-nft -I INPUT (prepend). When both allows are
    # missing, insert kubelet first then API so the live-proven API allow
    # remains at INPUT position 1.
    insert_order = (
        (kubelet, kubelet_allow),
        (api, api_allow),
    )
    needed = tuple(
        port
        for port, allow in insert_order
        if not _allow_is_correct(rules, allow, reject_idx)
    )
    if not needed:
        return "unchanged", ()
    return "ensure", needed


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Normalize OCI cloud-image IPv4 filter rules for MicroK8s. "
            "Never flushes chains and never deletes the INPUT REJECT."
        )
    )
    parser.add_argument(
        "--rules-file",
        help="Path to iptables rules.v4. Absent file is a safe no-op.",
    )
    parser.add_argument(
        "--plan-input-runtime",
        action="store_true",
        help=(
            "Read iptables-nft -S INPUT from stdin and print unchanged "
            "or ensure plus host TCP ports to insert. Does not execute iptables."
        ),
    )
    parser.add_argument(
        "--pod-cidr",
        required=True,
        help="MicroK8s pod IPv4 CIDR used as the INPUT allow source.",
    )
    parser.add_argument(
        "--apiserver-port",
        required=True,
        help="MicroK8s Kubernetes API server TCP port.",
    )
    parser.add_argument(
        "--kubelet-port",
        required=True,
        help="MicroK8s kubelet TCP port.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Inspect and report without writing the file.",
    )
    return parser.parse_args(argv)


def render_plan(action: str, ports: tuple[str, ...]) -> str:
    if action == "unchanged":
        return "unchanged"
    return "ensure\n" + "\n".join(ports)


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        if args.plan_input_runtime:
            if args.rules_file:
                raise NormalizeError(
                    "error: --plan-input-runtime does not take --rules-file",
                    EXIT_USAGE,
                )
            action, ports = plan_input_runtime(
                sys.stdin.read(),
                args.pod_cidr,
                args.apiserver_port,
                args.kubelet_port,
            )
            print(render_plan(action, ports))
            return EXIT_OK
        if not args.rules_file:
            raise NormalizeError(
                "error: --rules-file is required unless "
                "--plan-input-runtime is set",
                EXIT_USAGE,
            )
        action = normalize_rules_file(
            Path(args.rules_file),
            args.pod_cidr,
            args.apiserver_port,
            args.kubelet_port,
            write=not args.dry_run,
        )
    except NormalizeError as exc:
        print(str(exc), file=sys.stderr)
        return exc.code
    print(action)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

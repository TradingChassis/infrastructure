#!/usr/bin/env python3
"""Normalize OCI Ubuntu cloud-image IPv4 filter rules for MicroK8s.

Persistent file contract:

  1. Remove the exact OCI cloud-image FORWARD REJECT, if present:
     -A FORWARD -j REJECT --reject-with icmp-host-prohibited
  2. Insert exactly one MicroK8s pod → node-local API allow and exactly
     one MicroK8s pod → node-local kubelet allow immediately before the
     OCI catch-all INPUT REJECT, in that canonical order.
  3. Preserve that INPUT REJECT, InstanceServices, SSH, and unrelated lines.

Runtime contract:

  Planning from supplied iptables-nft -S dumps never mutates kernel tables.
  --apply-runtime inspects and mutates only /usr/sbin/iptables-nft using
  argv-form semantic specs. It never flushes INPUT/OUTPUT/FORWARD, never
  calls iptables-legacy, and never restores a whole table.

  Owned INPUT rules from the normalized persistent file are placed as a
  contiguous prefix ahead of later UFW jumps. The exact OCI FORWARD REJECT
  is deleted when present. The OUTPUT InstanceServices jump and
  InstanceServices chain rules are restored when missing.

It refuses to modify an unexpected/non-OCI firewall file.
It does not create a rules file when the path is absent.
It does not delete the OCI INPUT REJECT.
"""

from __future__ import annotations

import argparse
import ipaddress
import os
import subprocess
import sys
from pathlib import Path

EXIT_OK = 0
EXIT_UNEXPECTED = 2
EXIT_USAGE = 3

FORWARD_REJECT = "-A FORWARD -j REJECT --reject-with icmp-host-prohibited"
INPUT_REJECT = "-A INPUT -j REJECT --reject-with icmp-host-prohibited"
BACKUP_SUFFIX = ".tradingchassis-oci-forward.bak"
IPTABLES_NFT = "/usr/sbin/iptables-nft"


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
    is_append = _chain_append_lines(text, "InstanceServices")
    if not is_append:
        raise NormalizeError(
            "error: refusing to modify firewall file with no "
            "InstanceServices rules",
            EXIT_UNEXPECTED,
        )
    if len(is_append) != len(set(is_append)):
        raise NormalizeError(
            "error: refusing to modify firewall file with duplicate "
            "InstanceServices rules",
            EXIT_UNEXPECTED,
        )
    output_jumps = [
        line
        for line in _chain_append_lines(text, "OUTPUT")
        if line.endswith("-j InstanceServices")
    ]
    if len(output_jumps) != 1:
        raise NormalizeError(
            "error: refusing to modify firewall file with "
            f"{len(output_jumps)} OUTPUT InstanceServices jumps",
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


def _chain_append_lines(save_text: str, chain: str) -> list[str]:
    prefix = f"-A {chain}"
    lines: list[str] = []
    for raw in save_text.splitlines():
        line = stripped(raw)
        if not line or line.startswith("#"):
            continue
        if line.startswith(prefix + " ") or line == prefix:
            lines.append(line)
    return lines


def _spec_argv(append_line: str, action: str) -> tuple[str, ...]:
    parts = append_line.split()
    if len(parts) < 3 or parts[0] != "-A":
        raise NormalizeError(
            f"error: refusing to parse unexpected iptables spec {append_line!r}",
            EXIT_UNEXPECTED,
        )
    return (action, parts[1], *parts[2:])


def desired_runtime_contract(
    persistent_text: str, pod_cidr: str, apiserver_port: str, kubelet_port: str
) -> tuple[list[str], str, list[str]]:
    normalized, _action = normalize_rules_text(
        persistent_text, pod_cidr, apiserver_port, kubelet_port
    )
    input_rules = _chain_append_lines(normalized, "INPUT")
    is_rules = _chain_append_lines(normalized, "InstanceServices")
    output_jumps = [
        line
        for line in _chain_append_lines(normalized, "OUTPUT")
        if line.endswith("-j InstanceServices")
    ]
    if sum(1 for line in input_rules if line == INPUT_REJECT) != 1:
        raise NormalizeError(
            "error: refusing runtime plan without exactly one INPUT REJECT",
            EXIT_UNEXPECTED,
        )
    if len(output_jumps) != 1:
        raise NormalizeError(
            "error: refusing runtime plan with "
            f"{len(output_jumps)} OUTPUT InstanceServices jumps",
            EXIT_UNEXPECTED,
        )
    if not is_rules:
        raise NormalizeError(
            "error: refusing runtime plan with no InstanceServices rules",
            EXIT_UNEXPECTED,
        )
    if len(input_rules) != len(set(input_rules)):
        raise NormalizeError(
            "error: refusing runtime plan with duplicate owned INPUT rules",
            EXIT_UNEXPECTED,
        )
    if len(is_rules) != len(set(is_rules)):
        raise NormalizeError(
            "error: refusing runtime plan with duplicate InstanceServices rules",
            EXIT_UNEXPECTED,
        )
    return input_rules, output_jumps[0], is_rules


def plan_filter_runtime(
    persistent_text: str,
    pod_cidr: str,
    apiserver_port: str,
    kubelet_port: str,
    *,
    input_save: str,
    forward_save: str,
    output_save: str,
    instanceservices_save: str | None,
) -> tuple[str, list[tuple[str, ...]]]:
    required_input, output_jump, required_is = desired_runtime_contract(
        persistent_text, pod_cidr, apiserver_port, kubelet_port
    )
    owned_input = set(required_input)
    live_input = _chain_append_lines(input_save, "INPUT")
    live_forward = _chain_append_lines(forward_save, "FORWARD")
    live_output = _chain_append_lines(output_save, "OUTPUT")
    ops: list[tuple[str, ...]] = []

    expected_is = set(required_is)
    if instanceservices_save is None:
        ops.append(("-N", "InstanceServices"))
        for line in required_is:
            ops.append(_spec_argv(line, "-A"))
    else:
        live_is = _chain_append_lines(instanceservices_save, "InstanceServices")
        unexpected = [line for line in live_is if line not in expected_is]
        if unexpected:
            raise NormalizeError(
                "error: refusing runtime plan with unexpected "
                "InstanceServices rules",
                EXIT_UNEXPECTED,
            )
        if live_is != required_is:
            for line in live_is:
                ops.append(_spec_argv(line, "-D"))
            for line in required_is:
                ops.append(_spec_argv(line, "-A"))

    live_is_jumps = [
        line for line in live_output if line.endswith("-j InstanceServices")
    ]
    if any(line != output_jump for line in live_is_jumps):
        raise NormalizeError(
            "error: refusing runtime plan with unexpected OUTPUT "
            "InstanceServices jump",
            EXIT_UNEXPECTED,
        )
    jump_count = sum(1 for line in live_output if line == output_jump)
    if jump_count == 0:
        ops.append(_spec_argv(output_jump, "-I"))
    elif jump_count > 1:
        for _extra in range(jump_count - 1):
            ops.append(_spec_argv(output_jump, "-D"))

    prefix_len = len(required_input)
    input_ok = (
        live_input[:prefix_len] == required_input
        and all(line not in owned_input for line in live_input[prefix_len:])
    )
    if not input_ok:
        for line in live_input:
            if line in owned_input:
                ops.append(_spec_argv(line, "-D"))
        for line in reversed(required_input):
            ops.append(_spec_argv(line, "-I"))

    if FORWARD_REJECT in live_forward:
        ops.append(_spec_argv(FORWARD_REJECT, "-D"))

    for op in ops:
        if op[0] in {"-F", "-X", "--flush"} or "restore" in op[0]:
            raise NormalizeError(
                "error: refusing destructive nft filter operation",
                EXIT_UNEXPECTED,
            )
    if not ops:
        return "unchanged", []
    return "changed", ops


def _nft(args: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [IPTABLES_NFT, *args],
        check=False,
        capture_output=True,
        text=True,
    )


def collect_live_filter_saves() -> tuple[str, str, str, str | None]:
    input_proc = _nft(("-S", "INPUT"))
    forward_proc = _nft(("-S", "FORWARD"))
    output_proc = _nft(("-S", "OUTPUT"))
    if input_proc.returncode != 0:
        raise NormalizeError(
            f"error: cannot inspect nft INPUT: {input_proc.stderr.strip()}",
            EXIT_USAGE,
        )
    if forward_proc.returncode != 0:
        raise NormalizeError(
            f"error: cannot inspect nft FORWARD: {forward_proc.stderr.strip()}",
            EXIT_USAGE,
        )
    if output_proc.returncode != 0:
        raise NormalizeError(
            f"error: cannot inspect nft OUTPUT: {output_proc.stderr.strip()}",
            EXIT_USAGE,
        )
    is_proc = _nft(("-S", "InstanceServices"))
    is_save = None if is_proc.returncode != 0 else is_proc.stdout
    return input_proc.stdout, forward_proc.stdout, output_proc.stdout, is_save


def apply_filter_runtime(
    rules_path: Path,
    pod_cidr: str,
    apiserver_port: str,
    kubelet_port: str,
    *,
    execute: bool,
) -> str:
    if not rules_path.exists():
        raise NormalizeError(
            f"error: {rules_path} is required for runtime firewall reconciliation",
            EXIT_UNEXPECTED,
        )
    try:
        persistent = rules_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise NormalizeError(
            f"error: cannot read {rules_path}: {exc}",
            EXIT_USAGE,
        ) from exc
    input_save, forward_save, output_save, is_save = collect_live_filter_saves()
    action, ops = plan_filter_runtime(
        persistent,
        pod_cidr,
        apiserver_port,
        kubelet_port,
        input_save=input_save,
        forward_save=forward_save,
        output_save=output_save,
        instanceservices_save=is_save,
    )
    if action == "unchanged" or not execute:
        return action
    for op in ops:
        proc = _nft(op)
        if proc.returncode != 0:
            raise NormalizeError(
                "error: iptables-nft "
                + " ".join(op)
                + f" failed: {proc.stderr.strip()}",
                EXIT_USAGE,
            )
    return "changed"


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Normalize OCI cloud-image IPv4 filter rules for MicroK8s. "
            "Never flushes chains and never deletes the INPUT REJECT."
        )
    )
    parser.add_argument(
        "--rules-file",
        help=(
            "Path to iptables rules.v4. Persist mode: absent file is a "
            "safe no-op. --apply-runtime: absent file fails closed."
        ),
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
        "--apply-runtime",
        action="store_true",
        help=(
            "Reconcile the nft-compatible filter table from the persistent "
            "OCI/MicroK8s contract using /usr/sbin/iptables-nft argv specs. "
            "Does not flush tables or restore a whole table."
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
        if args.plan_input_runtime and args.apply_runtime:
            raise NormalizeError(
                "error: --plan-input-runtime and --apply-runtime are "
                "mutually exclusive",
                EXIT_USAGE,
            )
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
        if args.apply_runtime:
            action = apply_filter_runtime(
                Path(args.rules_file),
                args.pod_cidr,
                args.apiserver_port,
                args.kubelet_port,
                execute=not args.dry_run,
            )
            print(action)
            return EXIT_OK
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

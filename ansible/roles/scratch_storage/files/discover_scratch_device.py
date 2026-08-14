#!/usr/bin/env python3
"""Read-only fail-closed scratch-disk discovery from lsblk JSON.

This helper never probes the local machine and never runs lsblk. It only
inspects JSON that the caller already captured. It never formats, mounts,
wipes, or mutates devices.

Supported reference topology:
  - Ubuntu OCI root disk with the root filesystem on a partition
  - optional EFI/boot partitions on that same root disk
  - exactly one additional unpartitioned whole-disk scratch volume

This is not a universal multi-volume, LVM, or device-mapper discovery system.
Size is diagnostic only and is never used as the identity criterion.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

EXIT_OK = 0
EXIT_ZERO = 1
EXIT_AMBIGUOUS = 2
EXIT_USAGE = 3

SYSTEM_MOUNTS = frozenset({"/", "/boot", "/boot/efi", "/boot/firmware", "/efi"})
PARTITION_TYPES = frozenset(
    {"part", "crypt", "lvm", "mpath", "raid", "raid0", "raid1", "raid5", "raid10"}
)
SKIP_TYPES = frozenset({"loop", "rom"})


class DiscoveryError(Exception):
    def __init__(self, message: str, code: int) -> None:
        super().__init__(message)
        self.code = code


def normalize_mounts(node: dict[str, Any]) -> list[str]:
    raw = node.get("mountpoints")
    if raw is None:
        single = node.get("mountpoint")
        raw = [single] if single else []
    mounts: list[str] = []
    if not isinstance(raw, list):
        raw = [raw]
    for item in raw:
        if item is None:
            continue
        text = str(item).strip()
        if text:
            mounts.append(text)
    return mounts


def device_path(node: dict[str, Any]) -> str | None:
    path = node.get("path")
    if isinstance(path, str) and path.strip():
        return os.path.normpath(path.strip())
    ident = node.get("kname") or node.get("name")
    if isinstance(ident, str) and ident.strip():
        name = ident.strip()
        if name.startswith("/dev/"):
            return os.path.normpath(name)
        return os.path.normpath(f"/dev/{name}")
    return None


def flatten(nodes: list[dict[str, Any]], parent: dict[str, Any] | None = None) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for node in nodes:
        item = dict(node)
        item["_parent"] = parent
        result.append(item)
        children = node.get("children") or []
        if isinstance(children, list):
            result.extend(flatten(children, item))
    return result


def collect_mounts(node: dict[str, Any]) -> list[str]:
    mounts = list(normalize_mounts(node))
    for child in node.get("children") or []:
        if isinstance(child, dict):
            mounts.extend(collect_mounts(child))
    return mounts


def has_partition_children(node: dict[str, Any]) -> bool:
    for child in node.get("children") or []:
        if not isinstance(child, dict):
            continue
        child_type = str(child.get("type") or "").lower()
        if child_type in PARTITION_TYPES:
            return True
    return False


def is_skipped_device(node: dict[str, Any]) -> bool:
    node_type = str(node.get("type") or "").lower()
    name = str(node.get("name") or "").lower()
    kname = str(node.get("kname") or "").lower()
    return (
        node_type in SKIP_TYPES
        or name.startswith("loop")
        or kname.startswith("loop")
        or name.startswith("sr")
        or kname.startswith("sr")
    )


def whole_disk(node: dict[str, Any]) -> dict[str, Any] | None:
    current: dict[str, Any] | None = node
    seen: set[int] = set()
    while current is not None:
        ident = id(current)
        if ident in seen:
            return None
        seen.add(ident)
        if str(current.get("type") or "").lower() == "disk":
            return current
        parent = current.get("_parent")
        current = parent if isinstance(parent, dict) else None
    return None


def find_node_by_path(nodes: list[dict[str, Any]], target: str) -> dict[str, Any] | None:
    wanted = os.path.normpath(target)
    for node in nodes:
        path = device_path(node)
        if path is not None and path == wanted:
            return node
    return None


def diagnostic_line(node: dict[str, Any], reason: str) -> str:
    path = device_path(node) or "<unresolved>"
    node_type = str(node.get("type") or "unknown")
    mounts = ",".join(collect_mounts(node)) or "-"
    fstype = str(node.get("fstype") or "-")
    size = node.get("size")
    size_text = str(size) if size not in (None, "") else "-"
    return (
        f"  {path} type={node_type} mounts={mounts} fstype={fstype} "
        f"size={size_text} {reason}"
    )


def select_candidate(
    payload: dict[str, Any],
    root_source: str,
    expected_mount: str,
) -> str:
    blockdevices = payload.get("blockdevices")
    if not isinstance(blockdevices, list):
        raise DiscoveryError(
            "error: lsblk JSON is missing a blockdevices list",
            EXIT_USAGE,
        )

    nodes = flatten(blockdevices)
    root_source_path = os.path.normpath(root_source.strip())
    expected = os.path.normpath(expected_mount.strip())
    if not root_source_path:
        raise DiscoveryError("error: root filesystem source is empty", EXIT_USAGE)
    if not expected:
        raise DiscoveryError("error: expected mount path is empty", EXIT_USAGE)

    root_node = find_node_by_path(nodes, root_source_path)
    if root_node is None:
        raise DiscoveryError(
            "error: cannot resolve root filesystem source "
            f"{root_source_path} in lsblk JSON; supported topology is an "
            "Ubuntu partitioned root disk plus one unpartitioned scratch disk",
            EXIT_ZERO,
        )

    root_disk = whole_disk(root_node)
    if root_disk is None:
        raise DiscoveryError(
            "error: cannot resolve the whole-disk parent for root source "
            f"{root_source_path}; LVM/device-mapper root is not a claimed "
            "reference topology",
            EXIT_ZERO,
        )

    excluded_disks: set[str] = set()
    root_disk_path = device_path(root_disk)
    if root_disk_path:
        excluded_disks.add(root_disk_path)

    for node in nodes:
        mounts = set(collect_mounts(node))
        if mounts.intersection(SYSTEM_MOUNTS):
            parent_disk = whole_disk(node)
            parent_path = device_path(parent_disk) if parent_disk is not None else None
            if parent_path:
                excluded_disks.add(parent_path)

    eligible: list[dict[str, Any]] = []
    excluded_lines: list[str] = []
    inspected_disks = 0

    for node in nodes:
        if str(node.get("type") or "").lower() != "disk":
            continue
        inspected_disks += 1
        path = device_path(node)
        if is_skipped_device(node):
            excluded_lines.append(diagnostic_line(node, "excluded=loop_or_rom"))
            continue
        if path is None:
            excluded_lines.append(diagnostic_line(node, "excluded=unresolved_path"))
            continue
        if path in excluded_disks:
            excluded_lines.append(diagnostic_line(node, "excluded=root_or_boot"))
            continue
        if has_partition_children(node):
            excluded_lines.append(diagnostic_line(node, "excluded=has_partitions"))
            continue
        unexpected = [
            mount
            for mount in collect_mounts(node)
            if os.path.normpath(mount) != expected
        ]
        if unexpected:
            excluded_lines.append(diagnostic_line(node, "excluded=unexpected_mount"))
            continue
        eligible.append(node)

    eligible_paths = []
    for node in eligible:
        path = device_path(node)
        if path is None:
            raise DiscoveryError(
                "error: eligible scratch candidate could not be resolved safely",
                EXIT_ZERO,
            )
        eligible_paths.append(path)

    unique_paths = sorted(set(eligible_paths))
    details = [
        f"root_source={root_source_path}",
        f"root_disk={root_disk_path or '<unresolved>'}",
        f"expected_mount={expected}",
        f"whole_disks_inspected={inspected_disks}",
        f"eligible_count={len(unique_paths)}",
        "eligible:",
    ]
    if unique_paths:
        details.extend(f"  {path}" for path in unique_paths)
    else:
        details.append("  (none)")
    details.append("devices:")
    details.extend(excluded_lines)
    details.extend(diagnostic_line(node, "eligible") for node in eligible)

    if len(unique_paths) == 0:
        raise DiscoveryError(
            "error: scratch device auto-discovery failed: 0 eligible candidates\n"
            + "\n".join(details),
            EXIT_ZERO,
        )
    if len(unique_paths) != 1:
        raise DiscoveryError(
            "error: scratch device auto-discovery failed: "
            f"{len(unique_paths)} eligible candidates (ambiguous)\n"
            + "\n".join(details),
            EXIT_AMBIGUOUS,
        )

    return unique_paths[0]


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Select the unique eligible non-root whole disk from lsblk JSON. "
            "Fails closed when zero or multiple candidates exist."
        )
    )
    parser.add_argument(
        "--root-source",
        required=True,
        help="Resolved root filesystem source path from findmnt/readlink",
    )
    parser.add_argument(
        "--expected-mount",
        default="/mnt/scratch",
        help="Allowed existing scratch mount path for idempotent discovery",
    )
    parser.add_argument(
        "--lsblk-json",
        help="Path to lsblk --json output. Defaults to stdin. Never runs lsblk.",
    )
    return parser.parse_args(argv)


def load_payload(lsblk_json: str | None) -> dict[str, Any]:
    if lsblk_json:
        try:
            with open(lsblk_json, encoding="utf-8") as handle:
                raw = handle.read()
        except OSError as exc:
            raise DiscoveryError(
                f"error: cannot read lsblk JSON file: {exc}",
                EXIT_USAGE,
            ) from exc
    else:
        if sys.stdin.isatty():
            raise DiscoveryError(
                "error: lsblk JSON must be provided on stdin or via --lsblk-json; "
                "this helper never probes host block devices itself",
                EXIT_USAGE,
            )
        raw = sys.stdin.read()
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise DiscoveryError(
            f"error: invalid lsblk JSON: {exc}",
            EXIT_USAGE,
        ) from exc
    if not isinstance(payload, dict):
        raise DiscoveryError("error: lsblk JSON root must be an object", EXIT_USAGE)
    return payload


def main(argv: list[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        payload = load_payload(args.lsblk_json)
        candidate = select_candidate(payload, args.root_source, args.expected_mount)
    except DiscoveryError as exc:
        print(str(exc), file=sys.stderr)
        return exc.code
    print(candidate)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

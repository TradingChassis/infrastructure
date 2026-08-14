#!/usr/bin/env bash
# Static and synthetic regression for Ansible scratch-device discovery.
# Never probes host block devices, never formats/mounts, never contacts OCI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
HELPER = (
    ROOT
    / "ansible/roles/scratch_storage/files/discover_scratch_device.py"
)
TASKS = ROOT / "ansible/roles/scratch_storage/tasks/main.yml"
DEFAULTS = ROOT / "ansible/roles/scratch_storage/defaults/main.yml"
OUTPUTS = ROOT / "terraform/outputs.tf"
RENDERER = ROOT / "tools/render-ansible-inventory"
WORKFLOW = ROOT / ".github/workflows/repository-validation.yml"


def load_helper():
    spec = importlib.util.spec_from_file_location("discover_scratch_device", HELPER)
    if spec is None or spec.loader is None:
        raise SystemExit("unable to load discovery helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_helper()


def disk(
    name: str,
    *,
    fstype=None,
    mounts=None,
    size=161061273600,
    children=None,
    node_type="disk",
    uuid=None,
):
    return {
        "name": name,
        "kname": name,
        "path": f"/dev/{name}",
        "type": node_type,
        "pkname": None,
        "mountpoints": mounts if mounts is not None else [None],
        "fstype": fstype,
        "uuid": uuid,
        "size": size,
        **({"children": children} if children else {}),
    }


def part(name: str, pkname: str, mounts, fstype="ext4"):
    return {
        "name": name,
        "kname": name,
        "path": f"/dev/{name}",
        "type": "part",
        "pkname": pkname,
        "mountpoints": mounts,
        "fstype": fstype,
        "uuid": None,
        "size": 1,
    }


def payload(*devices):
    return {"blockdevices": list(devices)}


ROOT_DISK = disk(
    "sda",
    size=53687091200,
    children=[
        part("sda1", "sda", ["/"]),
        part("sda15", "sda", ["/boot/efi"], fstype="vfat"),
    ],
)
LOOP = disk("loop0", node_type="loop", mounts=["/snap/core/1"], fstype="squashfs", size=1)
ROM = disk("sr0", node_type="rom", size=0)


def select(tree, root_source="/dev/sda1", expected_mount="/mnt/scratch"):
    return helper.select_candidate(tree, root_source, expected_mount)


def expect_error(tree, code, root_source="/dev/sda1"):
    try:
        select(tree, root_source=root_source)
    except helper.DiscoveryError as exc:
        if exc.code != code:
            raise SystemExit(f"expected exit {code}, got {exc.code}: {exc}") from exc
        return str(exc)
    raise SystemExit("expected DiscoveryError")


def run_cli(tree, root_source="/dev/sda1") -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "lsblk.json"
        path.write_text(json.dumps(tree), encoding="utf-8")
        return subprocess.run(
            [
                sys.executable,
                str(HELPER),
                "--root-source",
                root_source,
                "--expected-mount",
                "/mnt/scratch",
                "--lsblk-json",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )


# --- synthetic discovery scenarios ---

tree_a = payload(
    ROOT_DISK,
    disk("sdb", fstype=None, mounts=[None]),
    LOOP,
    ROM,
)
if select(tree_a) != "/dev/sdb":
    raise SystemExit("SCENARIO A: expected unique blank data disk /dev/sdb")
print("PASS: SCENARIO A root+blank data disk selects the data disk")

tree_b = payload(
    ROOT_DISK,
    disk(
        "sdb",
        fstype="ext4",
        mounts=["/mnt/scratch"],
        uuid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    ),
)
if select(tree_b) != "/dev/sdb":
    raise SystemExit("SCENARIO B: expected mounted scratch disk /dev/sdb")
print("PASS: SCENARIO B mounted expected scratch remains discoverable")

tree_c = payload(ROOT_DISK, LOOP, ROM)
message_c = expect_error(tree_c, helper.EXIT_ZERO)
if "0 eligible candidates" not in message_c:
    raise SystemExit(f"SCENARIO C: missing zero-candidate diagnostic: {message_c}")
print("PASS: SCENARIO C root disk only fails closed")

tree_d = payload(
    ROOT_DISK,
    disk("sdb"),
    disk("sdc"),
)
message_d = expect_error(tree_d, helper.EXIT_AMBIGUOUS)
if "2 eligible candidates" not in message_d:
    raise SystemExit(f"SCENARIO D: missing ambiguity diagnostic: {message_d}")
print("PASS: SCENARIO D two eligible data disks fails closed")

tree_e = payload(disk("sda", mounts=["/"], fstype="ext4", size=53687091200))
message_e = expect_error(tree_e, helper.EXIT_ZERO, root_source="/dev/sda")
if "0 eligible candidates" not in message_e:
    raise SystemExit(f"SCENARIO E: root-only whole disk must not be selected: {message_e}")
print("PASS: SCENARIO E candidate resolving to root disk fails")

tree_f = payload(ROOT_DISK, disk("sdb", fstype="ext4", mounts=["/srv/other"]))
message_f = expect_error(tree_f, helper.EXIT_ZERO)
if "unexpected_mount" not in message_f:
    raise SystemExit(f"SCENARIO F: expected unexpected_mount exclusion: {message_f}")
print("PASS: SCENARIO F unexpected mount excluded from auto-discovery")

tree_g = payload(ROOT_DISK, disk("sdb", fstype="xfs", mounts=[None]))
if select(tree_g) != "/dev/sdb":
    raise SystemExit("SCENARIO G: unexpected filesystem must still be discoverable")
print("PASS: SCENARIO G unexpected filesystem is discovered for downstream guard")

tree_partitioned = payload(
    ROOT_DISK,
    disk("sdb", children=[part("sdb1", "sdb", [None])]),
)
message_p = expect_error(tree_partitioned, helper.EXIT_ZERO)
if "has_partitions" not in message_p:
    raise SystemExit(f"partitioned extra disk must fail closed: {message_p}")
print("PASS: partitioned extra disk is not an eligible whole-disk candidate")

cli_a = run_cli(tree_a)
if cli_a.returncode != 0 or cli_a.stdout.strip() != "/dev/sdb":
    raise SystemExit(f"CLI A failed: rc={cli_a.returncode} out={cli_a.stdout!r} err={cli_a.stderr!r}")
cli_d = run_cli(tree_d)
if cli_d.returncode != helper.EXIT_AMBIGUOUS:
    raise SystemExit(f"CLI D expected ambiguous rc, got {cli_d.returncode}")
cli_c = run_cli(tree_c)
if cli_c.returncode != helper.EXIT_ZERO:
    raise SystemExit(f"CLI C expected zero-candidate rc, got {cli_c.returncode}")
print("PASS: discovery helper CLI exit codes match fail-closed contract")


# --- repository contract ---

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


outputs = read(OUTPUTS)
if re.search(r'(?m)^output\s+"scratch_volume_device"\s*\{', outputs):
    raise SystemExit("terraform/outputs.tf must not expose scratch_volume_device")
for required_output in (
    'output "scratch_volume_id"',
    'output "scratch_volume_attachment_id"',
    'output "scratch_volume_attachment_type"',
    'output "instance_public_ip"',
):
    if required_output not in outputs:
        raise SystemExit(f"terraform/outputs.tf missing {required_output}")
print("PASS: Terraform no longer exposes canonical scratch_volume_device")

renderer = read(RENDERER)
if "raw_output scratch_volume_device" in renderer or "scratch_volume_device" in renderer:
    raise SystemExit("render-ansible-inventory must not require scratch_volume_device")
if "instance_public_ip" not in renderer:
    raise SystemExit("render-ansible-inventory must still consume instance_public_ip")
if "scratch_storage_device_path" not in renderer:
    raise SystemExit("renderer must document optional scratch_storage_device_path override")
print("PASS: render-ansible-inventory no longer requires scratch_volume_device")

defaults = read(DEFAULTS)
if not re.search(r'(?m)^scratch_storage_device_path:\s*""\s*$', defaults):
    raise SystemExit("scratch_storage_device_path default must remain empty")
if re.search(r'(?m)^scratch_storage_allow_format:\s*true\s*$', defaults):
    raise SystemExit("BLOCKER: scratch_storage_allow_format default must not be true")
if not re.search(r'(?m)^scratch_storage_allow_format:\s*false\s*$', defaults):
    raise SystemExit("scratch_storage_allow_format default must remain false")
print("PASS: empty override is canonical; formatting default remains false")

tasks = read(TASKS)
if "scratch_storage_device_path | length > 0" in tasks and "Assert scratch device path is provided" in tasks:
    raise SystemExit("role must not require scratch_storage_device_path")
if "scratch_storage_override_supplied" not in tasks:
    raise SystemExit("role must inspect optional override")
if "Discover unique eligible scratch candidate" not in tasks:
    raise SystemExit("role must run automatic discovery when override is empty")
if "Set effective scratch candidate path from explicit override" not in tasks:
    raise SystemExit("explicit override must remain supported")
if "Assert scratch candidate is not the root or boot device" not in tasks:
    raise SystemExit("downstream root-device collision guard is missing")
if "scratch_storage_allow_format | bool" not in tasks:
    raise SystemExit("formatting must remain explicitly gated")
if "Create scratch filesystem when authorized and absent" not in tasks:
    raise SystemExit("formatting task is missing")
if not re.search(
    r"Create scratch filesystem when authorized and absent[\s\S]*scratch_storage_allow_format \| bool",
    tasks,
):
    raise SystemExit("formatting task must remain conditional on scratch_storage_allow_format | bool")
if "Assert unexpected existing filesystem is not overwritten" not in tasks:
    raise SystemExit("unexpected filesystem guard is missing")
if "Assert scratch candidate is not mounted elsewhere" not in tasks:
    raise SystemExit("unexpected mount-location guard is missing")
if 'src: "UUID={{ scratch_storage_filesystem_uuid.stdout | trim }}"' not in tasks:
    raise SystemExit("persistent mount must remain UUID-based")
if "discover_scratch_device.py" not in tasks:
    raise SystemExit("role must invoke the fail-closed discovery helper")
discovery_stage = tasks.split("- name: Stat scratch candidate path")[0]
for token in (
    "mkfs",
    "wipefs",
    "community.general.filesystem",
    "ansible.posix.mount",
    "blkdiscard",
    "parted",
    "fdisk",
):
    if token in discovery_stage:
        raise SystemExit(f"discovery stage must not contain {token}")
print("PASS: Ansible override, discovery, root, filesystem, mount, and UUID guards")

helper_src = read(HELPER)
if re.search(r"\b(subprocess|os\.system|os\.popen|Popen)\b", helper_src):
    raise SystemExit("discovery helper must not spawn processes")
for token in (
    "mkfs",
    "wipefs",
    "fdisk",
    "parted",
    "umount",
    "blkdiscard",
    "pvcreate",
    "vgcreate",
    "lvcreate",
):
    if re.search(rf"\b{token}\b", helper_src):
        raise SystemExit(f"discovery helper must not invoke destructive command {token}")
if re.search(r"""(?:/bin/mount|\bmount\s+-|['\"]mount['\"])""", helper_src):
    raise SystemExit("discovery helper must not invoke mount(8)")
if re.search(r"""(?:/bin/dd|\bdd\s+|['\"]dd['\"])""", helper_src):
    raise SystemExit("discovery helper must not invoke dd")
if "lsblk" in helper_src and "never runs lsblk" not in helper_src:
    raise SystemExit("discovery helper must not run lsblk itself")
if "/dev/sdb" in helper_src or "/dev/vdb" in helper_src or "150G" in helper_src:
    raise SystemExit("discovery helper must not hard-code live device names or sizes")
print("PASS: discovery helper is read-only and not hard-coded to a live device")

implementation_files = (
    TASKS,
    DEFAULTS,
    OUTPUTS,
    RENDERER,
    HELPER,
)
forbidden_live = (
    "/dev/sdb",
    "/dev/vdb",
    "/dev/oracleoci/",
    "wwn-0x",
    "scsi-0ATA",
    "150G",
    "130.61.",
    "132.145.",
    "10.0.1.31",
    "frt2nffgchiv",
    "BEGIN PRIVATE KEY",
)
for path in implementation_files:
    text = read(path)
    for needle in forbidden_live:
        if needle in text:
            raise SystemExit(f"{path.relative_to(ROOT)} must not contain {needle}")
print("PASS: implementation files contain no live device/WWN/IP/OCID hard-codes")

workflow = read(WORKFLOW)
if "test_ansible_scratch_device_discovery_contract.sh" not in workflow:
    raise SystemExit("CI must run the scratch device discovery contract test")
if "must not require Terraform output" not in workflow:
    raise SystemExit("CI must reject renderer scratch_volume_device")
if re.search(
    r'"instance_public_ip",\s*"scratch_volume_device"',
    workflow,
):
    raise SystemExit("CI must not still require scratch_volume_device as a renderer needle")
print("PASS: CI enforces the new discovery contract")

compile_proc = subprocess.run(
    [sys.executable, "-m", "py_compile", str(HELPER)],
    check=False,
    capture_output=True,
    text=True,
)
if compile_proc.returncode != 0:
    raise SystemExit(f"helper py_compile failed: {compile_proc.stderr}")
print("PASS: discovery helper py_compile")
print("PASS: Ansible scratch device discovery contract")
PY

# Ansible

## Purpose

Ansible manages host configuration and bootstrap for the V2 reference platform.

## Ownership

Ansible owns or will own:

```text
host baseline
scratch filesystem and mount
explicit host firewall
MicroK8s installation and host configuration
Argo CD bootstrap
```

Ansible does **not** own:

```text
OCI network/compute/storage/IAM resources
long-lived Kubernetes application desired state
```

Terraform owns cloud infrastructure.
Argo CD owns long-lived Kubernetes desired state.

## Current scope

```text
Host baseline contract validation is implemented.
Scratch filesystem validation, guarded formatting, and UUID-based mounting are implemented.
No MicroK8s or host firewall enforcement is implemented yet.
```

Project layout:

```text
ansible/
├── ansible.cfg
├── requirements.yml
├── inventory/
│   └── example.yml
├── playbooks/
│   └── site.yml
├── roles/
│   ├── host_baseline/
│   └── scratch_storage/
└── README.md
```

## Host baseline

The `host_baseline` role:

* validates the supported Ubuntu reference host contract
* validates the ARM64 reference architecture
* does not configure MicroK8s yet
* does not reproduce the V1 blanket iptables reset

Supported contract (provider-neutral):

```text
distribution: Ubuntu
major version: 24
architecture: aarch64 or arm64
```

Cloud provider details such as OCI shape, VCN, NSG, and Block Volume APIs remain Terraform responsibilities.

### Python and snap prerequisites

Ubuntu 24.04 server cloud images commonly provide `python3`, which Ansible needs on the target.
V1 also requires `snap` for MicroK8s installation.
Neither package installation nor snap enablement is performed by this role.
Presence of `python3` and `snap`/`snapd` remains a live bootstrap prerequisite to verify on the reference host before later MicroK8s scopes.

## Scratch storage ownership

```text
Terraform:
OCI block volume and attachment identity

Ansible:
device validation
filesystem lifecycle guard
persistent UUID mount

Argo CD later:
Kubernetes storage contract
```

The `scratch_storage` role manages the host path:

```text
/mnt/scratch
```

Persistent mount uses filesystem UUID.

`scratch_device_path` must come from the Terraform scratch attachment output during approved live execution.
V1 hardcoded a Linux device path.
V2 consumes the Terraform attachment identity and validates the target before any destructive operation.

### Safety

```text
scratch_allow_format defaults to false.
```

```text
An existing filesystem of an unexpected type is never overwritten automatically.
```

Additional fail-closed checks:

* missing or non-block scratch device
* scratch candidate equals the root filesystem or its parent disk
* scratch candidate mounted at an unexpected path
* unexpected source already mounted at `/mnt/scratch`

V1 also created `/mnt/scratch/data` with UID/GID `1000`.
That application-oriented ownership is not confirmed as a durable platform contract and is deferred.

The known V1 gap between the host scratch mount and Kubernetes `microk8s-hostpath` PVCs remains outside this role and is deferred to Argo CD.

## Firewall decision

```text
The V1 blanket iptables reset is intentionally not reproduced.
The host firewall will be defined from verified MicroK8s networking requirements.
```

```text
Firewall policy is deferred until the MicroK8s networking requirements
are implemented and verified. The V1 blanket flush is not a V2 requirement.
```

## Inventory safety

`inventory/example.yml` is a non-live structural example.
It uses an RFC 5737 documentation address and must never be used as production inventory.

Terraform provides infrastructure outputs such as instance and scratch attachment identifiers, including `scratch_volume_device`.
A later scope will define the approved Terraform-to-Ansible inventory handoff.
This repository does not generate inventory from Terraform and does not define dynamic inventory.

## V1 migration strategy

```text
Existing Bash scripts remain the V1 fallback until each corresponding Ansible/Argo CD replacement has independent validation evidence.
```

```text
Bash behavior is migrated by intent, not line-by-line.
```

Examples:

```text
iptables flush → explicit firewall redesign
hardcoded block device → Terraform attachment identity + guarded validation
runtime kubectl patches → declarative GitOps state
```

## Validation

Static validation only:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook --syntax-check \
  -i ansible/inventory/example.yml \
  ansible/playbooks/site.yml
```

Pinned collections:

```text
ansible.posix 2.2.2
community.general 13.2.0
```

## Live execution

```text
Live Ansible execution is intentionally not defined by this foundation scope.
```

## Evidence

```text
Static CI validation does not prove successful host convergence.
```

# Ansible Foundation

## Purpose

Ansible manages host configuration and bootstrap for the V2 reference platform.

## Ownership

Ansible will later own:

```text
host baseline
explicit host firewall
scratch filesystem and mount
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
Foundation only.
No host configuration is implemented yet.
```

Project layout:

```text
ansible/
├── ansible.cfg
├── inventory/
│   └── example.yml
├── playbooks/
│   └── site.yml
├── roles/          # reserved for later role scopes; not populated yet
└── README.md
```

## Inventory safety

`inventory/example.yml` is a non-live structural example.
It uses an RFC 5737 documentation address and must never be used as production inventory.

Terraform provides infrastructure outputs such as instance and scratch attachment identifiers.
A later scope will define the approved Terraform-to-Ansible inventory handoff.
This foundation does not generate inventory from Terraform and does not define dynamic inventory.

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
hardcoded block device → safe storage discovery
runtime kubectl patches → declarative GitOps state
```

## Validation

Static validation only:

```bash
ansible-lint ansible/
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook --syntax-check \
  -i ansible/inventory/example.yml \
  ansible/playbooks/site.yml
```

## Live execution

```text
Live Ansible execution is intentionally not defined by this foundation scope.
```

Static ansible-lint and syntax checks do not constitute successful host convergence.

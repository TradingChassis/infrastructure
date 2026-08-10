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
MicroK8s installation, required addons, readiness, and an explicit UFW host firewall policy are implemented.
Argo CD bootstrap and the GitOps root Application handoff are implemented.
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
│   ├── scratch_storage/
│   ├── microk8s/
│   └── argocd_bootstrap/
└── README.md
```

Playbook order:

```text
host_baseline
scratch_storage
microk8s
argocd_bootstrap
```

## Host baseline

The `host_baseline` role:

* validates the supported Ubuntu reference host contract
* validates the ARM64 reference architecture
* does not configure MicroK8s
* does not reproduce the V1 blanket iptables reset

Supported contract (provider-neutral):

```text
distribution: Ubuntu
major version: 24
architecture: aarch64 or arm64
```

Cloud provider details such as OCI shape, VCN, NSG, and Block Volume APIs remain Terraform responsibilities.

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

`scratch_storage_device_path` must come from the Terraform scratch attachment output during approved live execution.
V1 hardcoded a Linux device path.
V2 consumes the Terraform attachment identity and validates the target before any destructive operation.

### Safety

```text
scratch_storage_allow_format defaults to false.
```

```text
An existing filesystem of an unexpected type is never overwritten automatically.
```

## MicroK8s

The `microk8s` role:

* ensures `snapd` and `ufw` packages are present
* installs MicroK8s from the pinned snap channel `1.29/stable`
* waits for readiness with `microk8s status --wait-ready`
* enables only the verified V1-required addons when missing
* applies an explicit UFW host firewall policy before relying on MicroK8s networking

Required addons:

```text
dns
hostpath-storage
metrics-server
helm
```

Canonical currently documents `helm` as installing Helm 3.
`helm3` remains a transition alias and is not used by this role.

Addon convergence checks each required addon with `microk8s status --addon` and enables only addons reported as `disabled`.

## Firewall redesign

```text
V1 flushed the host firewall and set permissive policies.
V2 does not reproduce this behavior.
```

```text
Cloud ingress policy and host firewall policy remain separate layers.
```

Technology choice: **UFW**, using Canonical MicroK8s troubleshooting guidance for Calico on Ubuntu.

Implemented host policy:

```text
default incoming: deny
default outgoing: allow
default routed: allow
allow TCP/22 (SSH)
allow in/out on vxlan.calico
allow in/out on cali+
UFW enabled
```

Not opened on the host firewall:

```text
Kubernetes API (16443/tcp)
kubelet
cluster-agent
dqlite
Calico VXLAN UDP to the Internet
NodePort range 30000-32767
```

SSH remote source restriction remains the OCI NSG `ssh_ingress_cidr` responsibility.
The host firewall allows TCP/22 for defense in depth without duplicating operator CIDR policy.

UFW is never reset and existing unmanaged rules are not blanket-deleted.

## Argo CD bootstrap

```text
Ansible owns only initial Argo CD bootstrap.
Argo CD owns long-lived Kubernetes desired state after bootstrap.
```

```text
The V1 CRD deletion and runtime repo-server patch are intentionally not reproduced.
```

The `argocd_bootstrap` role:

* ensures the `argocd` namespace
* installs Argo CD via the pinned community Helm chart `argo-cd` `8.2.7`
* pins Argo CD application image tag `v3.0.23`
* configures `kustomize.buildOptions: --enable-helm` declaratively in Helm values
* waits for server, repo-server, and application-controller readiness
* applies the GitOps root Application from `argocd/root-app.yaml`

Compatibility evidence:

```text
Argo CD 3.0 tested Kubernetes versions include v1.29
(source: argoproj/argo-cd v3.0.23 docs/operator-manual/tested-kubernetes-versions.md).
Argo CD 3.3+ tested matrices no longer list Kubernetes 1.29, so V1's v3.3.0 pin is not retained.
```

Root Application contract:

```text
Ansible → Argo CD → root Application → child Applications under argocd/
```

Child Application manifests remain Git-owned under `argocd/` and are selected by `argocd/kustomization.yaml`.
Their controller namespace is `argocd` so the Argo CD instance can reconcile them.

## Deferred

```text
Kubernetes scratch StorageClass binding to /mnt/scratch
Secrets Store CSI / OCI provider
Prometheus Operator CRD ownership / monitoring app ownership cleanup
runtime VAULT_ID / OCI_REGION Application patch cleanup
```

Next CSI scope gates:

```text
The OCI Secrets Store CSI provider must be verified for linux/arm64
before deployment to the Ampere A1 reference node.
```

```text
Secrets Store CSI Driver and OCI provider versions must be selected
for compatibility with the current MicroK8s 1.29 release line.
```

The known V1 gap between the host scratch mount and Kubernetes `microk8s-hostpath` PVCs remains open until the Argo CD storage scope.

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
iptables flush → explicit UFW policy from verified MicroK8s requirements
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
kubernetes.core 6.5.0
```

## Live execution

```text
Live Ansible execution is intentionally not defined by this foundation scope.
```

## Evidence

```text
Static CI validation does not prove successful host convergence.
```

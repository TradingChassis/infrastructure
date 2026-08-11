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
private runtime configuration materialization (explicit opt-in playbook)
```

Ansible does **not** own:

```text
OCI network/compute/storage/IAM resources
long-lived Kubernetes application desired state
Secrets Store CSI Driver / OCI provider installation
```

Terraform owns cloud infrastructure.
Argo CD owns long-lived Kubernetes desired state, including the Secrets Store CSI
Driver and OCI Vault provider.
Ansible may materialize only private-config-dependent Kubernetes objects
(`tradingchassis-runtime-config` and the three SecretProviderClass resources)
through an explicit non-default playbook.

## Current scope

```text
Host baseline contract validation is implemented.
Scratch filesystem validation, guarded formatting, and UUID-based mounting are implemented.
MicroK8s installation, required addons, readiness, and an explicit UFW host firewall policy are implemented.
Argo CD bootstrap and the GitOps root Application handoff are implemented.
Private runtime configuration materialization is implemented as an explicit opt-in playbook only.
```

Project layout:

```text
ansible/
├── ansible.cfg
├── requirements.yml
├── inventory/
│   └── example.yml
├── playbooks/
│   ├── site.yml
│   └── private-runtime-config.yml
├── roles/
│   ├── host_baseline/
│   ├── scratch_storage/
│   ├── microk8s/
│   ├── argocd_bootstrap/
│   └── private_runtime_config/
└── README.md
```

Canonical `site.yml` playbook order:

```text
host_baseline
scratch_storage
microk8s
argocd_bootstrap
```

`private_runtime_config` is intentionally **not** included in `site.yml`.
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

## Private runtime configuration

```text
VAULT_ID   → private_runtime_config_vault_id
OCI_REGION → private_runtime_config_oci_region
```

Private values stay outside the public repository. Operators map them into Ansible
variables for an explicit playbook run. The role does not read `.env`, tfvars,
kubeconfigs from the workspace, or discover secrets automatically.

The `private_runtime_config` role:

* fail-closed validates Vault OCID shape (`ocid1.vault...`) and OCI region shape
* requires the SecretProviderClass CRD already installed by Argo CD `oci-secrets`
* requires application namespaces `postgres`, `mlflow`, and `monitoring` to exist
* materializes Secret `tradingchassis-runtime-config` in namespace `mlflow` with key `OCI_REGION`
* materializes exactly three SecretProviderClass resources with `authType: instance`
* renders literal `vaultId` from `private_runtime_config_vault_id` (no Git placeholder)
* uses `kubernetes.core` with the MicroK8s kubeconfig contract (no shell kubectl)
* sets `no_log: true` on tasks that handle private values

Explicit playbook only (example syntax for the dedicated cutover scope):

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i <approved-inventory> \
  -e private_runtime_config_vault_id="$VAULT_ID" \
  -e private_runtime_config_oci_region="$OCI_REGION" \
  ansible/playbooks/private-runtime-config.yml
```

Do **not** run that playbook against a cluster while Argo CD is still
reconciling the V1 SecretProviderClass resources, except as part of the
separately defined and controlled V2 ownership handoff. The same SPC
identities (`postgres-secret-bundle`, `mlflow-secret-bundle`,
`monitoring-secret-bundle`) exist in the active V1 overlays today.

### Preparation (current repository state)

```text
site.yml unchanged (role not auto-run)
active apps/*/kustomization.yaml still → overlays/v1
Argo CD remains authoritative for the V1 SecretProviderClass resources
prepared overlays/v2 remain inactive
private-runtime-config playbook exists but is not executed automatically
therefore no active dual ownership exists
V1 scripts/08-runtime.sh and inject-runtime-values.sh remain usable
no live cutover has occurred
```

### Future ownership handoff (deferred)

```text
The playbook and V2 overlays are preparation only.
Exact live ownership handoff sequencing is deferred to a dedicated cutover scope.
That procedure must transfer SecretProviderClass ownership from the V1 Argo tree
to Ansible without leaving both reconcilers authoritative for the same objects.
It must account for Argo prune behavior, sync timing, resource continuity,
SPC consumer availability, and rollback. This repository scope does not define
or validate that live sequence.
```

Ownership invariant:

```text
At no steady-state point may Argo CD and Ansible both be authoritative
for the same SecretProviderClass resources.
```

### Post-cutover steady state (target, not active)

```text
active apps/*/kustomization.yaml → overlays/v2 (no Git-owned SPCs)
Ansible owns the three SecretProviderClass resources and the runtime Secret
Argo owns workloads, CSI Driver, and OCI provider
V1 runtime Application patching is no longer required
```

Idempotency design (statically designed; live second-converge validation deferred):

```text
first run creates Secret and three SPCs
identical second run is designed for changed=0
changed OCI_REGION updates the runtime Secret
changed VAULT_ID updates the three SecretProviderClass resources
```

Update behavior notes:

```text
OCI_REGION Secret updates do not rewrite environment variables inside already
running MLflow pods. A controlled rollout/reconciliation is required later.
VAULT_ID SecretProviderClass updates change desired CSI configuration; automatic
volume remount/reload behavior is not claimed without live evidence.
```

## Deferred

```text
Kubernetes scratch StorageClass binding to /mnt/scratch
Prometheus Operator CRD ownership / monitoring app ownership cleanup
canonical site.yml activation of private_runtime_config
explicit V1→V2 overlay cutover
runtime VAULT_ID / OCI_REGION Application patch script retirement
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
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook --syntax-check \
  -i ansible/inventory/example.yml \
  -e private_runtime_config_vault_id=ocid1.vault.oc1.eu-test-1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  -e private_runtime_config_oci_region=eu-test-1 \
  ansible/playbooks/private-runtime-config.yml
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

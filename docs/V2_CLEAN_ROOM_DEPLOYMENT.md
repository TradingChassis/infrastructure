# V2 Clean-Room Deployment

## Purpose

This document is the **canonical operator runbook** for deploying a fresh TradingChassis
V2 environment from this repository.

It describes the intended path:

```text
Terraform
→ Terraform outputs
→ SSH / Ansible inventory
→ site.yml
→ Argo CD bootstrap
→ wait for OCI secrets platform
→ private-runtime-config.yml
→ acceptance checks
```

This document describes the intended V2 clean-room deployment path.

It does **not** document the legacy V1 bootstrap path
or the historical in-place SPC ownership handoff.

For the historical in-place SecretProviderClass ownership procedure (fallback only),
see [`RUNTIME_SPC_OWNERSHIP_CUTOVER.md`](RUNTIME_SPC_OWNERSHIP_CUTOVER.md).

---

## Status: implementation in progress

```text
Status: implementation in progress
Evidence class: confirmed from repository (not live-validated)
```

The V2 clean-room workflow is **not fully executable end-to-end yet** until remaining
Phase-A implementation scopes are merged and live-validated.

Known remaining blockers at the time this runbook was written:

```text
- Kubernetes scratch storage is not yet bound to /mnt/scratch.
- Active postgres/mlflow/monitoring shims still select overlays/v1.
- OCI secrets bootstrap ordering is still being hardened.
```

Do **not** declare clean-room acceptance complete while those gaps remain.
Do **not** treat CI static validation as proof of a successful live rebuild.

---

## Ownership model

```text
Terraform
  owns OCI cloud resources (network, compute, scratch volume attachment, IAM)

Ansible
  owns host configuration and initial bootstrap
  plus narrowly scoped private runtime materialization

Argo CD
  owns long-lived Kubernetes desired state
  (including Secrets Store CSI Driver and OCI provider via oci-secrets)

GitHub Actions
  owns static repository validation only
```

Do **not** duplicate ownership. Example anti-patterns:

```text
Do not install CSI Driver / OCI provider with Bash while Argo owns oci-secrets.
Do not keep Git-owned SecretProviderClass resources and Ansible-owned SPCs
authoritative for the same objects in steady state.
Do not let Terraform manage long-lived Kubernetes application manifests.
```

---

## Intentional external dependencies

A V2 clean-room rebuild recreates Terraform-managed OCI infrastructure and the host /
GitOps bootstrap. It does **not** necessarily recreate every dependency.

| Dependency | Classification |
| --- | --- |
| OCI Vault resource | externally supplied / referenced (`oci_vault_id`) |
| OCI Vault secret contents | preserved external (operator / tenancy managed) |
| GitHub repository `TradingChassis/infrastructure` | preserved external GitOps source |
| Container registries / images / Helm charts | preserved external |
| Operator SSH keypair | private operator input |
| Operator OCI credentials (for Terraform) | private operator input |

Terraform does **not** manage Vault lifecycle or secret values in the current source.

---

## Current V1 cluster

Any historical live V1 cluster is **reference / fallback only** for the clean-room strategy.

The V2 path must not depend on that cluster.
Do **not** execute the multi-phase in-place SPC handoff as part of clean-room deployment.

---

## Operator prerequisites

Install and prepare on the **operator machine** (not inside the future cluster):

| Requirement | Source / note |
| --- | --- |
| Git | clone this repository |
| Terraform | `~> 1.15.0` (`terraform/versions.tf`); CI uses `1.15.8` |
| Ansible | collections from `ansible/requirements.yml`; CI uses `ansible-core==2.21.2` for validation |
| Python 3 | required by Ansible; CI validation uses `3.12` |
| OCI authentication | method supported by the Terraform OCI provider (see below) |
| SSH private key or SSH agent | matching the public key passed to Terraform as `ssh_public_key` |
| Private deployment inputs | Terraform variables + `VAULT_ID` / `OCI_REGION` for Ansible |

Do not commit private values, tfvars, state, or kubeconfigs.

### Ansible collections

From the repository root:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

Pinned collections (`ansible/requirements.yml`):

```text
ansible.posix 2.2.2
community.general 13.2.0
kubernetes.core 6.5.0
```

---

## Terraform authentication

The OCI provider configuration in this repository sets only:

```hcl
provider "oci" {
  region = var.oci_region
}
```

Credentials are supplied by the execution environment and are never committed.

The operator must configure an OCI authentication method supported by the
Terraform OCI provider before `plan` / `apply` (for example API key configuration
or equivalent provider-supported environment credentials).

This runbook does not prescribe a single auth file layout and does not inspect
local credentials.

---

## Terraform inputs

Prepare **local** variable values (for example a gitignored `*.tfvars` file or
`TF_VAR_*` environment variables). Do **not** commit tfvars.

### Required (no defaults)

| Variable | Class | Purpose |
| --- | --- | --- |
| `oci_region` | private deployment / region config | Provider region |
| `oci_compartment_id` | private deployment | Compartment for network/compute/storage |
| `oci_tenancy_id` | private deployment | Tenancy for Dynamic Group / IAM policy |
| `oci_vault_id` | private deployment (reference) | External Vault OCID (not secret contents) |
| `oci_vault_compartment_id` | private deployment | Compartment for secret-bundle read policy |
| `ssh_ingress_cidr` | private deployment | CIDR allowed to SSH into the compute NSG |
| `ssh_public_key` | operator credential material (public) | Instance `authorized_keys` |

### Optional / defaulted (public or sizing)

| Variable | Default (source) |
| --- | --- |
| `name_prefix` | `tradingchassis` |
| `vcn_cidr` | `10.0.0.0/16` |
| `subnet_cidr` | `10.0.1.0/24` |
| `vcn_dns_label` | `tcvcn` |
| `subnet_dns_label` | `compute` |
| `compute_ocpus` | `4` |
| `compute_memory_gbs` | `24` |
| `boot_volume_size_gbs` | `50` |
| `scratch_volume_size_gbs` | `150` |
| `instance_hostname_label` | `tcnode` |
| `compute_operating_system` | `Canonical Ubuntu` |
| `compute_operating_system_version` | `24.04` |

---

## Terraform state model

```text
For the initial single-operator clean-room validation,
Terraform state is local unless the operator explicitly configures otherwise.
```

- Local state must **not** be committed (`.gitignore` covers `terraform.tfstate*`).
- Back up local state appropriately for the proof environment.
- A shared remote backend remains a future team-operability improvement and is
  **not** required by current source for the first solo proof.
- Do not add remote backend configuration as part of following this runbook.

---

## Terraform execution

From the repository root, review every plan before apply:

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan
terraform -chdir=terraform apply
```

`terraform plan` must be reviewed before `apply`.

Static CI validates `fmt`, `init -backend=false`, and `validate` only.
Live `plan` / `apply` are operator actions and are **not** CI-proven.

---

## Terraform outputs used by the next stage

After a successful apply, read outputs from the Terraform working directory.

| Output | Role for Ansible / operator |
| --- | --- |
| `instance_public_ip` | SSH / `ansible_host` for the reference node |
| `scratch_volume_device` | Ansible `scratch_storage_device_path` |
| `instance_private_ip` | informational (private address) |
| `instance_id` | informational / IAM correlation |
| `vault_id` | echoes configured Vault reference (not a secret value) |
| `vcn_id`, `subnet_id`, `compute_nsg_id`, scratch/IAM IDs | cloud inventory / diagnostics |

Example (prints infrastructure identifiers only; does not print credentials):

```bash
terraform -chdir=terraform output instance_public_ip
terraform -chdir=terraform output scratch_volume_device
```

---

## Explicit Terraform → Ansible handoff contract

This repository does **not** generate Ansible inventory from Terraform and does
**not** ship a dynamic inventory plugin.

The approved contract is a **manual**, fully documented handoff:

```text
Terraform outputs
→ operator-local Ansible inventory (gitignored / outside Git)
→ ansible-playbook with explicit -e values where required
```

| Terraform / operator source | Ansible / inventory input |
| --- | --- |
| Terraform output `instance_public_ip` | inventory `ansible_host` |
| Operator-supplied SSH username | inventory `ansible_user` |
| Operator SSH agent or private key (local) | SSH connection (do not commit keys) |
| Terraform output `scratch_volume_device` | extra var `scratch_storage_device_path` |
| First-use formatting decision (operator) | extra var `scratch_storage_allow_format` |

### SSH username

Terraform selects Canonical Ubuntu 24.04 for `VM.Standard.A1.Flex`.
The repository does **not** hardcode an SSH username in Terraform or Ansible defaults.

Treat `ansible_user` as an **operator-supplied** inventory value.
For the current Ubuntu platform image, operators commonly use `ubuntu`; confirm
against the instance image / cloud-init behavior in your tenancy before relying
on that value.

Privilege escalation: roles set `become: true` on host-mutating tasks.
`ansible.cfg` does not enable become globally; per-task become remains the contract.

### Scratch device and format gate

```text
Terraform provisions and attaches the scratch volume.
Terraform exposes the OCI-assigned device path as output scratch_volume_device.
The operator passes that value to Ansible as scratch_storage_device_path.
```

Role defaults (`ansible/roles/scratch_storage/defaults/main.yml`):

```text
scratch_storage_device_path: ""          # required at live execution
scratch_storage_allow_format: false      # fail-closed
scratch_storage_mount_path: /mnt/scratch
```

For a **newly provisioned empty** disk, set `scratch_storage_allow_format=true`
**only** for the intentional first filesystem creation after verifying the device
is the Terraform-managed scratch attachment.

Do **not** leave formatting permanently enabled as an operational habit.
Subsequent converges should keep `scratch_storage_allow_format=false` (default)
once the filesystem exists.

### Inventory example (non-live)

See [`ansible/inventory/example.yml`](../ansible/inventory/example.yml).
It uses RFC 5737 documentation addresses and placeholders only.
Copy the structure to an **operator-local** inventory file that is never committed
with real values.

---

## Ansible bootstrap sequence (`site.yml`)

Canonical playbook: `ansible/playbooks/site.yml`

Role order (source):

```text
host_baseline
scratch_storage
microk8s
argocd_bootstrap
```

`private_runtime_config` is **intentionally not** included in `site.yml`.

### Example first converge

Use `ANSIBLE_CONFIG` so paths resolve from `ansible/ansible.cfg`.
Replace placeholders; never commit real inventory or private device paths.

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i <operator-local-inventory> \
  ansible/playbooks/site.yml \
  -e scratch_storage_device_path='<terraform output scratch_volume_device>' \
  -e scratch_storage_allow_format=true
```

Set `scratch_storage_allow_format=true` only for the intentional first format of
an empty Terraform-managed scratch volume (see above).

### What successful `site.yml` means

```text
host baseline contract asserted (Ubuntu 24, ARM64)
scratch filesystem validated/mounted at /mnt/scratch (when inputs correct)
MicroK8s installed (channel 1.29/stable) with required addons
host UFW policy applied
Argo CD installed in namespace argocd
root Application from argocd/root-app.yaml submitted
```

Successful `site.yml` does **not** mean:

```text
all workloads are already Healthy
private runtime SecretProviderClass resources exist
V2 overlays are active
scratch Kubernetes PVCs already consume /mnt/scratch
```

---

## Argo CD bootstrap sequence

After Ansible applies the root Application:

```text
Ansible finishes bootstrap
→ Argo CD reconciles Application/root (namespace argocd)
→ child Applications under argocd/ appear
```

Child Applications selected by `argocd/kustomization.yaml` (confirmed from repository):

| Application | Destination namespace |
| --- | --- |
| `postgres` | `postgres` |
| `mlflow` | `mlflow` |
| `monitoring` | `monitoring` |
| `argo` | `argo` |
| `scratch-dev` | `dev` |
| `scratch-prod` | `prod` |
| `oci-secrets` | `kube-system` |

Root Application destination and Application CRs use namespace **`argocd`**
(V2 bootstrap contract). Do not assume the historical V1 `default` namespace.

All child Applications currently track `targetRevision: main` for this repository
(except `oci-secrets`, which tracks the Oracle chart revision `v0.5.0`).

---

## OCI secrets readiness gate

Argo owns the Secrets Store CSI Driver and OCI provider via Application `oci-secrets`.
Do **not** manually install those components for the V2 path.

Because bootstrap ordering is still being hardened, verify readiness **before**
running private runtime configuration.

### Required gates (live validation)

```text
CustomResourceDefinition secretproviderclasses.secrets-store.csi.x-k8s.io exists
Namespaces postgres, mlflow, and monitoring exist
Secrets Store CSI Driver is Ready
OCI Secrets Store CSI Provider is Ready
```

### Example read-only checks

Adjust access method to your operator practice (for example `microk8s kubectl`
on the host). These examples are verification only:

```bash
# SPC CRD present
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io

# Application namespaces present
kubectl get namespace postgres mlflow monitoring

# High-level Argo health (no secret values)
kubectl -n argocd get applications root oci-secrets postgres mlflow monitoring argo scratch-dev scratch-prod \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# CSI / provider pods in kube-system (names may vary; confirm Ready)
kubectl -n kube-system get pods
```

Do **not** dump SecretProviderClass `spec`, full YAML/JSON, or all annotations
as “safe metadata”. Serialized
`kubectl.kubernetes.io/last-applied-configuration` can contain private
deployment configuration such as `vaultId`.

---

## Private runtime configuration sequence

Playbook: `ansible/playbooks/private-runtime-config.yml`
Role: `private_runtime_config`
Not part of `site.yml`.

### Operator input mapping

Public example names in [`.env.example`](../.env.example):

```text
VAULT_ID
OCI_REGION
```

Ansible role variables (must be passed explicitly):

```text
VAULT_ID   → private_runtime_config_vault_id
OCI_REGION → private_runtime_config_oci_region
```

The role does **not** read `.env`, tfvars, or kubeconfigs from the workspace.
Do not invent automatic sourcing.

### Example invocation

`-e` on the command line is the current documented operator model.
Be aware that shell history and process listings may expose those values;
protect the operator environment accordingly. Do not commit the values.

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i <operator-local-inventory> \
  -e private_runtime_config_vault_id="$VAULT_ID" \
  -e private_runtime_config_oci_region="$OCI_REGION" \
  ansible/playbooks/private-runtime-config.yml
```

### Expected materialization (prepared V2 contract)

```text
Secret/tradingchassis-runtime-config in namespace mlflow (key OCI_REGION)
SecretProviderClass/postgres-secret-bundle in namespace postgres
SecretProviderClass/mlflow-secret-bundle in namespace mlflow
SecretProviderClass/monitoring-secret-bundle in namespace monitoring
authType: instance
vaultId rendered from private_runtime_config_vault_id (not ${VAULT_ID})
```

### Safe existence checks (no private values)

```bash
kubectl -n mlflow get secret tradingchassis-runtime-config
kubectl -n mlflow get secret tradingchassis-runtime-config \
  -o go-template='{{ range $k, $_ := .data }}{{ println $k }}{{ end }}'
# Expect key name only: OCI_REGION

kubectl -n postgres get secretproviderclass postgres-secret-bundle \
  -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace
kubectl -n mlflow get secretproviderclass mlflow-secret-bundle \
  -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace
kubectl -n monitoring get secretproviderclass monitoring-secret-bundle \
  -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace
```

Do **not** print `.data` values, `spec.parameters.vaultId`, or full SPC YAML/JSON.

---

## V2 overlay status (current transition)

```text
apps/postgres/kustomization.yaml  → overlays/v1   (active)
apps/mlflow/kustomization.yaml    → overlays/v1   (active)
apps/monitoring/kustomization.yaml → overlays/v1  (active)

apps/*/overlays/v2                → prepared only (inactive)
```

Therefore:

```text
the clean-room runbook cannot be considered executable end-to-end
until the coordinated V2 overlay activation scope is merged.
```

Do **not** run `scripts/inject-runtime-values.sh` or `scripts/08-runtime.sh` as
part of the **desired** V2 clean-room path.

While V1 overlays remain active, Git still owns SecretProviderClass placeholders
with `vaultId: ${VAULT_ID}`. Running `private-runtime-config.yml` against that
state outside a controlled ownership plan risks dual authority — see the
historical cutover document for that fallback procedure, not for clean-room.

### Intended post-activation steady state (prepared source)

When V2 overlays are activated in a dedicated scope:

```text
V2 overlays contain no Git-owned SecretProviderClass resources.
private_runtime_config creates the three SPCs and the runtime Secret.
MLflow reads AWS_DEFAULT_REGION from Secret tradingchassis-runtime-config key OCI_REGION.
No scripts/inject-runtime-values.sh execution is required for steady state.
```

---

## Scratch Kubernetes limitation (current blocker)

```text
The current Kubernetes scratch PVC path is not yet bound to /mnt/scratch.
Do not declare clean-room acceptance complete until the dedicated scratch-storage
scope is merged and live-validated.
```

Host mount via Ansible and cloud volume via Terraform are implemented.
Binding Kubernetes `microk8s-hostpath` scratch PVCs to the OCI-backed mount is a
separate Phase-A scope.

---

## Idempotency acceptance

After a successful first deployment, run the Ansible bootstrap again (same inventory,
`scratch_storage_allow_format=false` once the filesystem exists) and assess whether
the second converge performs **no destructive or unintended changes**.

Do not require an exact `changed=0` task count unless live evidence for every
role supports that claim. Prefer:

```text
no destructive reformatting
no unintended firewall reset
no Argo CD reinstall churn beyond idempotent module behavior
```

The private runtime role is designed for idempotent second runs when inputs are
unchanged; that design is statically described and **not** live-proven by this
document.

---

## Live validation boundary

| Layer | Evidence today |
| --- | --- |
| Terraform fmt / init `-backend=false` / validate | statically validated by CI |
| Ansible lint / syntax-check | statically validated by CI |
| Kustomize / Helm GitOps renders / contracts | statically validated by CI |
| Terraform apply | must be proven during first clean-room deployment |
| SSH reachability / Ansible converge | must be proven live |
| MicroK8s Ready / Argo reconciliation | must be proven live |
| Vault retrieval / workload health | must be proven live |
| Scratch PVC binding to `/mnt/scratch` | not yet implemented |

---

## Clean-room acceptance checklist

Mark each item only with live evidence. None of these are claimed proven by this document.

| Check | Live-only? |
| --- | --- |
| Terraform apply succeeded | yes |
| Instance reachable over SSH from operator CIDR | yes |
| Ansible first `site.yml` converge succeeded | yes |
| Kubernetes node Ready | yes |
| Architecture ARM64 / MicroK8s `1.29` line as intended | yes |
| `/mnt/scratch` mounted from Terraform scratch volume | yes |
| Argo CD Application `root` exists in namespace `argocd` | yes |
| Child Applications exist: `oci-secrets`, `postgres`, `mlflow`, `monitoring`, `argo`, `scratch-dev`, `scratch-prod` | yes |
| `oci-secrets` Synced/Healthy | yes |
| Secrets Store CSI Driver Ready | yes |
| OCI provider Ready | yes |
| SPC CRD present | yes |
| Namespaces `postgres` / `mlflow` / `monitoring` present | yes |
| `private-runtime-config.yml` succeeded (after V2 overlay activation) | yes |
| Three SPCs exist (names only; no spec dumps) | yes |
| Secret `tradingchassis-runtime-config` exists with key `OCI_REGION` | yes |
| PostgreSQL Healthy | yes |
| MLflow Healthy | yes |
| Monitoring Synced + Healthy | yes |
| Argo Workflows Healthy | yes |
| Scratch PVCs use intended OCI-backed storage at `/mnt/scratch` | yes — **blocked until scratch K8s scope** |
| No V1 runtime injection (`inject-runtime-values.sh`) executed for this deployment | yes |
| Second Ansible converge shows no destructive/unintended changes | yes |

---

## Related documents

| Document | Role |
| --- | --- |
| This file | **Primary** V2 clean-room deployment path |
| [`RUNTIME_SPC_OWNERSHIP_CUTOVER.md`](RUNTIME_SPC_OWNERSHIP_CUTOVER.md) | Historical / in-place SPC ownership fallback — **not** the primary V2 path |
| [`VERSION_1_BASELINE.md`](../VERSION_1_BASELINE.md) | Historical V1 baseline |
| [`terraform/README.md`](../terraform/README.md) | Terraform ownership and cloud layer |
| [`ansible/README.md`](../ansible/README.md) | Ansible ownership and playbooks |
| [`argocd/README.md`](../argocd/README.md) | Argo CD applications and overlay transition notes |

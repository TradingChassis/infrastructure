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
→ private-runtime-config.yml
   (bounded platform readiness waits, then mutation)
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
- First real clean-room deployment has not yet been executed.
- Post-proof V1 cleanup has not started.
```

Terraform remote state status:

```text
implemented / statically validated / awaiting first live OCI initialization
```

OCI Cloud Shell execution readiness status:

```text
defined / statically validated / awaiting live operator proof
```

V2 runtime overlay status:

```text
implemented / V2 active / awaiting live validation
```

OCI secrets bootstrap ordering status:

```text
implemented / awaiting live validation
```

Scratch Kubernetes binding status:

```text
implemented / awaiting live validation
```

Repository manifests bind scratch-dev/scratch-prod to the OCI-backed `/mnt/scratch`
filesystem via static hostPath PersistentVolumes. This is **not** live-validated.

Do **not** declare clean-room acceptance complete while remaining gaps above remain,
or while scratch binding / OCI secrets platform readiness / V2 runtime consumers
lack live evidence.
Do **not** treat CI static validation as proof of a successful live rebuild.

---

## Ownership model

```text
Terraform
  owns OCI cloud resources (network, compute, scratch volume attachment, IAM)

Ansible
  owns host configuration and initial bootstrap
  plus narrowly scoped private runtime materialization
  plus /mnt/scratch mount and scratch workload host directories

Argo CD
  owns long-lived Kubernetes desired state
  (including Secrets Store CSI Driver and OCI provider via oci-secrets,
   and scratch StorageClass/static PVs/PVCs)

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

The **recommended** operator environment is OCI Cloud Shell.
Other machines may follow the same contracts if they provide a supported
Terraform OCI authentication method, outbound network access, and SSH.

| Requirement | Source / note |
| --- | --- |
| Git | clone this repository under `$HOME` (persistent in Cloud Shell) |
| Terraform | `~> 1.15.0` (`terraform/versions.tf`); CI uses `1.15.8` |
| Ansible | install pinned collections from `ansible/requirements.yml`; CI validates with `ansible-core==2.21.2` / Python `3.12` |
| Python 3 | required by Ansible |
| OCI CLI | pre-authenticated in Cloud Shell for CLI only; Terraform needs a separate supported auth mode |
| SSH keypair | operator-local ed25519 keypair (public key → Terraform, private key → Ansible) |
| Private deployment inputs | `backend.hcl`, `terraform.tfvars`, private-runtime extra-vars file |

Do not commit private values, tfvars, state, kubeconfigs, or SSH private keys.

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

Cloud Shell may ship an Ansible package whose version differs from CI.
For reproducibility, create a Python virtualenv under persistent `$HOME` and install
`ansible-core==2.21.2` before installing collections.

---

## Cloud Shell environment facts

```text
Cloud Shell VM          = ephemeral
$HOME                   = persistent encrypted storage
OCI CLI                 = pre-authenticated for CLI use
OCI CLI config/token    = outside home under /etc/oci (do not modify/copy)
OCI CLI auth            = instance_obo_user + delegation_token
OCI CLI profile/region  = follows Console region selected when the shell starts
Cloud Shell public IP   = dynamic across sessions (stable within one session)
Public internet access  = requires Cloud Shell Public Network (or equivalent);
                          OCI Service Network alone is insufficient for GitHub,
                          Terraform Registry, Ansible Galaxy, and public SSH
```

Clone and store operator files under `$HOME`, never under ephemeral `/tmp`, so a
session restart can resume.

---

## Authentication: Cloud Shell CLI vs Terraform

### Built-in Cloud Shell OCI CLI auth

Cloud Shell configures the OCI CLI conceptually as:

```text
OCI_CLI_AUTH=instance_obo_user
OCI_CLI_CONFIG_FILE=/etc/oci/config
OCI_CLI_PROFILE=<console-selected-region>
```

plus a service-managed `delegation_token` under `/etc/oci`.

This proves **OCI CLI** access. It does **not** automatically prove Terraform access.

### Terraform supported auth (backend and provider)

Native Terraform `backend "oci"` and the `oracle/oci` provider support modes such as:

```text
APIKey
SecurityToken
InstancePrincipal
InstancePrincipalWithCerts
ResourcePrincipal
OKEWorkloadIdentity
```

They do **not** document Cloud Shell `instance_obo_user` / delegation-token auth as a
Terraform authentication mode.

```text
CAN NATIVE TERRAFORM OCI BACKEND DIRECTLY USE CLOUD SHELL BUILT-IN AUTH?
NO

CAN OCI TERRAFORM PROVIDER DIRECTLY USE CLOUD SHELL BUILT-IN instance_obo_user AUTH?
NO
```

Do not use `InstancePrincipal` merely because Cloud Shell runs on an OCI VM.
That VM is service-managed and is not automatically an instance principal in the
operator tenancy.

### Canonical Cloud Shell Terraform auth strategy

```text
SecurityToken via oci session authenticate
→ same profile for backend + provider
```

Create/refresh a short-lived session token in the operator home config
(not `/etc/oci`):

```bash
# PREFLIGHT / SAFE TO RUN (creates/refreshes operator SecurityToken profile)
oci session authenticate \
  --profile-name tradingchassis \
  --region <oci-region>
```

Validate:

```bash
oci iam region list \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth security_token
```

Refresh before expiry (tokens are typically valid for about one hour):

```bash
oci session refresh --profile tradingchassis
```

If refresh fails after expiry, rerun `oci session authenticate` with the same
profile name.

Long Terraform applies that exceed the token lifetime will fail closed until the
token is refreshed. Keep stages interactive and resumable; do not background the
deploy.

API-key auth remains a supported portable alternative outside Cloud Shell, but
SecurityToken is the canonical Cloud Shell path for this repository.

Wire the non-secret auth selection into:

```text
terraform/backend.hcl
  auth = "SecurityToken"
  config_file_profile = "tradingchassis"

terraform/terraform.tfvars
  oci_auth = "SecurityToken"
  oci_config_file_profile = "tradingchassis"
```

Do not put private keys, security tokens, or delegation tokens into those files.

---

## Terraform inputs

Prepare **local** variable values from the committed example:

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edit placeholders; never commit terraform.tfvars
```

Backend location remains in `backend.hcl`, not tfvars.

### Required operator choices

| Variable | Purpose |
| --- | --- |
| `oci_auth` / `oci_config_file_profile` | SecurityToken selection for Cloud Shell |
| `oci_region` | Provider / deployment region |
| `oci_compartment_id` | Compartment for network/compute/storage |
| `oci_tenancy_id` | Tenancy for Dynamic Group / IAM policy |
| `oci_vault_id` | External Vault OCID (reference, not secret contents) |
| `oci_vault_compartment_id` | Compartment for secret-bundle read policy |
| `ssh_ingress_cidr` | CIDR allowed to SSH (must include current Cloud Shell egress) |
| `ssh_public_key` | Instance `authorized_keys` (public key only) |

### Safe repository defaults

| Variable | Default |
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

### Region concepts (do not conflate)

```text
Cloud Shell Console/session region
→ OCI CLI built-in profile only

backend.hcl region
→ Object Storage bucket region

terraform.tfvars oci_region
→ Terraform provider deployment region
```

They may match in a given deployment, but set each intentionally.

---

## Terraform state model

```text
Native OCI Object Storage backend
→ externally pre-existing state bucket
→ operator-local backend.hcl (partial configuration)
→ unique object key per environment or fork
```

- The state bucket is an **external foundation prerequisite**. Terraform does
  **not** create it and there is **no** bootstrap Terraform state.
- Enable Object Storage bucket versioning on that bucket before first live init
  (operational prerequisite / recovery control). `terraform init` does not verify
  versioning.
- Copy `terraform/backend.hcl.example` to the ignored `terraform/backend.hcl`
  and supply `bucket`, `namespace`, `region`, unique `key`, plus SecurityToken
  auth selection fields.
- Local state is **not** an operator deployment fallback. CI may use
  `terraform init -backend=false` for static validation only.
- No V2 state migration is required for the first V2 clean-room deployment.
- Details: [`terraform/README.md`](../terraform/README.md).

### Backend preflight (Cloud Shell / OCI CLI)

These commands are **PREFLIGHT / SAFE TO RUN** metadata checks. They do not create
buckets, enable versioning, or write objects.

They must use the same SecurityToken profile that Terraform will use.
Do **not** rely on Cloud Shell's built-in `instance_obo_user` identity for these
checks; that path does not prove Terraform backend/provider authentication.

```bash
# Namespace via SecurityToken profile tradingchassis
oci os ns get \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth security_token

# Bucket exists + versioning status (expect versioning = Enabled)
# Use the backend Object Storage region from backend.hcl, not merely the
# Cloud Shell Console start region.
oci os bucket get \
  --namespace-name <object-storage-namespace> \
  --bucket-name <existing-state-bucket> \
  --region <backend-region> \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth security_token \
  --query 'data.versioning' \
  --raw-output
```

Required Object Storage capabilities for state + native locking include
operations corresponding to:

```text
OBJECT_INSPECT / OBJECT_CREATE / OBJECT_DELETE / OBJECT_READ
```

(or the equivalent Get/Put/Delete/Head/multipart object operations). Exact IAM
policy remains an external prerequisite and is not provisioned by this Terraform
root. Live `terraform init` is the backend connectivity gate.

---

## SSH key strategy

Generate an operator-local ed25519 keypair under persistent Cloud Shell home:

```bash
# PREFLIGHT / SAFE TO RUN
mkdir -p ~/.ssh
chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/tradingchassis -C "tradingchassis-cloud-shell"
chmod 600 ~/.ssh/tradingchassis
chmod 644 ~/.ssh/tradingchassis.pub
```

Project default: use a passphrase-protected key and load it into `ssh-agent`
for Ansible practicality:

```bash
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/tradingchassis
```

Terraform receives only the public-key **content** as a literal
`ssh_public_key` string (variable definition files cannot call `file()` /
`pathexpand()`). After generating the keypair, either paste the single line from
`~/.ssh/tradingchassis.pub` into ignored `terraform.tfvars`, or export:

```bash
export TF_VAR_ssh_public_key="$(cat "$HOME/.ssh/tradingchassis.pub")"
```

Never commit private keys. Never put the private key into Terraform inputs.

### SSH ingress and Cloud Shell egress

```text
CAN A FRESH CLOUD SHELL SESSION SSH TO THE NEW VM UNDER THE CURRENT NETWORK RULES?
DEPENDS ON OPERATOR INPUT
```

Terraform requires `ssh_ingress_cidr` with no repository default.
Cloud Shell's public IP can change between sessions.

Before plan/apply (and again after opening a new Cloud Shell session if needed):

```bash
# PREFLIGHT / SAFE TO RUN
curl -s checkip.dyndns.org | sed -e 's/.*Current IP Address: //' -e 's/<.*$//'
# set ssh_ingress_cidr to that address as /32 (or another justified CIDR)
```

Cloud Shell must use **Public Network** (or equivalent public-internet
connectivity) before this workflow. OCI Service Network alone is not sufficient
for:

```text
GitHub clone / pull
Terraform Registry provider download
Ansible Galaxy collection install
SSH to the VM public IP
public egress IP discovery used for ssh_ingress_cidr
```

### First SSH connection

After apply, prefer an explicit first connect that accepts a new host key without
disabling host-key checking globally:

```bash
ssh -o StrictHostKeyChecking=accept-new \
  -i ~/.ssh/tradingchassis \
  ubuntu@<instance_public_ip>
```

Canonical image contract is Canonical Ubuntu 24.04 → `ansible_user=ubuntu`.

Privilege escalation: roles set `become: true` on host-mutating tasks.
`ansible.cfg` does not enable become globally; per-task become remains the contract.

---

## Terraform execution

### Operator init / plan / apply

```text
FIRST LIVE DEPLOYMENT — DO NOT RUN DURING READINESS IMPLEMENTATION
```

```bash
cd terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
# edit both files

terraform init -backend-config=backend.hcl
terraform validate
terraform plan -out=terraform.tfplan
# review the plan carefully
terraform apply terraform.tfplan
```

No `-backend=false`, no `-auto-approve`, no local-state fallback.

If the first live init creates `.terraform.lock.hcl`, do not delete it reflexively;
review it as a potential follow-up repository commit after successful clean-room
proof. Do not invent lock hashes in advance.

Static CI validates `fmt`, backend/Cloud Shell contracts, `init -backend=false`,
and `validate` only.

---

## Terraform outputs used by the next stage

| Output | Role for Ansible / operator |
| --- | --- |
| `instance_public_ip` | SSH / inventory `ansible_host` |
| `scratch_volume_device` | Ansible `scratch_storage_device_path` |
| `instance_private_ip` | informational |
| `instance_id` | informational / IAM correlation |
| `vault_id` | echoes configured Vault reference (not secret contents) |
| other network/scratch/IAM IDs | diagnostics |

Targeted reads only (do not dump full state):

```bash
terraform -chdir=terraform output -raw instance_public_ip
terraform -chdir=terraform output -raw scratch_volume_device
```

---

## Explicit Terraform → Ansible handoff contract

Deterministic handoff helper (read-only):

```bash
# After a successful apply (LIVE DEPLOYMENT STAGE)
./tools/render-ansible-inventory
```

This writes the ignored file `ansible/inventory/local.yml` with:

```text
instance_public_ip     → ansible_host
ubuntu (default)       → ansible_user
~/.ssh/tradingchassis  → ansible_ssh_private_key_file
```

and prints `scratch_volume_device` for the first-converge extra var.

| Terraform / operator source | Ansible input |
| --- | --- |
| output `instance_public_ip` | inventory `ansible_host` |
| Ubuntu 24.04 image contract | inventory `ansible_user=ubuntu` |
| `~/.ssh/tradingchassis` | inventory `ansible_ssh_private_key_file` |
| output `scratch_volume_device` | `-e scratch_storage_device_path=...` |
| first-use formatting decision | `-e scratch_storage_allow_format=true` (first converge only) |

The helper must not embed Vault IDs, OCI regions, or credentials.

### Scratch device and format gate

```text
FIRST CONVERGE
→ pass scratch_storage_device_path from Terraform
→ set scratch_storage_allow_format=true only after verifying the device

SECOND CONVERGE
→ keep scratch_storage_allow_format=false (default)
→ do not reformat
```

Role defaults remain fail-closed (`scratch_storage_allow_format: false`).

### Inventory example (non-live)

See [`ansible/inventory/example.yml`](../ansible/inventory/example.yml).
Generated runtime inventory is `ansible/inventory/local.yml` (gitignored).

---

## Canonical Cloud Shell operator sequence

This is the authoritative ordered workflow. Stages marked
`PREFLIGHT / SAFE TO RUN` may be exercised during readiness preparation.
Stages marked `FIRST LIVE DEPLOYMENT` must wait for the dedicated clean-room
execution and are **not** part of this readiness implementation.

```text
1. Open OCI Cloud Shell (Console region chosen intentionally; enable Public Network)
2. Confirm public-network/internet reachability for GitHub, registries, and SSH
3. git clone <repo> under $HOME && cd infrastructure
4. ./tools/check-cloud-shell-readiness
5. oci session authenticate --profile-name tradingchassis --region <oci-region>
6. Verify SecurityToken profile (oci iam region list --profile tradingchassis --auth security_token)
7. Verify external state bucket exists and versioning=Enabled using SecurityToken profile
8. cp terraform/backend.hcl.example terraform/backend.hcl  # edit location + SecurityToken fields
9. cp terraform/terraform.tfvars.example terraform/terraform.tfvars  # edit inputs
10. Create ~/.ssh/tradingchassis ed25519 keypair; ssh-add; set ssh_public_key literal or TF_VAR_ssh_public_key
11. Set ssh_ingress_cidr to current Cloud Shell public IP /32
12. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform init -backend-config=backend.hcl
13. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform validate
14. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform plan -out=terraform.tfplan
15. Review plan
16. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform apply terraform.tfplan
17. Read targeted outputs; ./tools/render-ansible-inventory
18. Install ansible-core==2.21.2 in $HOME venv if needed; ansible-galaxy install -r ansible/requirements.yml
19. SSH with StrictHostKeyChecking=accept-new to ubuntu@instance_public_ip
20. FIRST LIVE DEPLOYMENT: ansible-playbook site.yml with device path + allow_format=true
21. FIRST LIVE DEPLOYMENT: ansible-playbook private-runtime-config.yml -e @ansible/extra-vars/private-runtime.yml
22. Verify Argo Applications / CSI DaemonSets / SPC existence via ssh + microk8s kubectl
23. Run acceptance checks (secret-safe) and a second site.yml converge without formatting
```

Local static helper (no OCI mutation):

```bash
./tools/check-cloud-shell-readiness
```

Session restart resume:

```text
cd $HOME/.../infrastructure
oci session refresh --profile tradingchassis   # or re-authenticate
reuse backend.hcl, terraform.tfvars, SSH keypair
recompute ssh_ingress_cidr if Cloud Shell public IP changed, then plan/apply if needed
terraform init -backend-config=backend.hcl if required
continue from the interrupted stage
```

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
Use the generated ignored inventory; never commit real inventory.

```bash
DEVICE="$(terraform -chdir=terraform output -raw scratch_volume_device)"

ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i ansible/inventory/local.yml \
  ansible/playbooks/site.yml \
  -e scratch_storage_device_path="$DEVICE" \
  -e scratch_storage_allow_format=true
```

Set `scratch_storage_allow_format=true` only for the intentional first format of
an empty Terraform-managed scratch volume (see above).

Second converge (idempotency) must omit formatting opt-in:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i ansible/inventory/local.yml \
  ansible/playbooks/site.yml \
  -e scratch_storage_device_path="$DEVICE"
```

### What successful `site.yml` means

```text
host baseline contract asserted (Ubuntu 24, ARM64)
scratch filesystem validated/mounted at /mnt/scratch (when inputs correct)
scratch workload directories /mnt/scratch/dev and /mnt/scratch/prod present on the mount
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
| `scratch-storage` | `kube-system` (cluster-scoped SC/PV) |
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

### Ordering contract (implemented / awaiting live validation)

```text
Application sync-wave:
  oci-secrets              = -1
  postgres/mlflow/monitoring = 1
  independent apps         = default (unset)

private-runtime-config.yml:
  bounded waits for platform prerequisites
  then materializes runtime Secret + SPCs
```

Application sync-wave annotations order **Application CR create/sync** inside the
root App-of-Apps reconciliation. They give `oci-secrets` a deterministic head
start. They do **not** guarantee that `oci-secrets` is Healthy before consumer
Applications begin reconciling.

Runtime readiness for private materialization is enforced by
`ansible/roles/private_runtime_config` with bounded, condition-based waits.

### Required gates (enforced by private-runtime-config.yml)

```text
CustomResourceDefinition secretproviderclasses.secrets-store.csi.x-k8s.io exists
CSIDriver secrets-store.csi.k8s.io exists
DaemonSet kube-system/oci-secrets-secrets-store-csi-driver is Ready
DaemonSet kube-system/oci-secrets-store-csi-driver-provider is Ready
Namespaces postgres, mlflow, and monitoring exist
```

Default bound: 36 attempts × 10 seconds (~6 minutes) per prerequisite.
Do **not** insert manual `sleep` timing between `site.yml` and
`private-runtime-config.yml`.

These gates prove **platform infrastructure readiness**. They do **not** prove
OCI Vault retrieval, CSI mounts, or synced Secret contents.

### Optional read-only verification

Adjust access method to your operator practice (for example `microk8s kubectl`
on the host). These examples are optional verification only:

```bash
# SPC CRD present
kubectl get crd secretproviderclasses.secrets-store.csi.x-k8s.io

# Application namespaces present
kubectl get namespace postgres mlflow monitoring

# High-level Argo health (no secret values)
kubectl -n argocd get applications root oci-secrets scratch-storage postgres mlflow monitoring argo scratch-dev scratch-prod \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# Stable platform DaemonSets (not generated Pod names)
kubectl -n kube-system get daemonset \
  oci-secrets-secrets-store-csi-driver \
  oci-secrets-store-csi-driver-provider
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

Public example names in [`.env.example`](../.env.example) may be used as a
staging reminder only:

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

### Example invocation (history-safe)

Prefer an ignored extra-vars file over inline `-e` values that enter shell history:

```bash
cp ansible/extra-vars/private-runtime.yml.example \
   ansible/extra-vars/private-runtime.yml
# edit placeholders; never commit private-runtime.yml

ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i ansible/inventory/local.yml \
  -e @ansible/extra-vars/private-runtime.yml \
  ansible/playbooks/private-runtime-config.yml
```

### Expected materialization (active V2 contract)

```text
Secret/tradingchassis-runtime-config in namespace mlflow (key OCI_REGION)
SecretProviderClass/postgres-secret-bundle in namespace postgres
SecretProviderClass/mlflow-secret-bundle in namespace mlflow
SecretProviderClass/monitoring-secret-bundle in namespace monitoring
authType: instance
vaultId rendered from private_runtime_config_vault_id (not ${VAULT_ID})
```

### Safe existence checks (no private values)

Run verification on the VM over SSH (preferred; avoid exporting kubeconfig to
Cloud Shell unless necessary):

```bash
ssh -i ~/.ssh/tradingchassis ubuntu@$(terraform -chdir=terraform output -raw instance_public_ip) \
  'sudo microk8s kubectl -n mlflow get secret tradingchassis-runtime-config'

ssh -i ~/.ssh/tradingchassis ubuntu@$(terraform -chdir=terraform output -raw instance_public_ip) \
  'sudo microk8s kubectl -n mlflow get secret tradingchassis-runtime-config -o go-template='"'"'{{ range $k, $_ := .data }}{{ println $k }}{{ end }}'"'"''
# Expect key name only: OCI_REGION

ssh -i ~/.ssh/tradingchassis ubuntu@$(terraform -chdir=terraform output -raw instance_public_ip) \
  'sudo microk8s kubectl -n postgres get secretproviderclass postgres-secret-bundle -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace'
```

Do **not** print `.data` values, `spec.parameters.vaultId`, or full SPC YAML/JSON.

---

## V2 overlay status (active / awaiting live validation)

```text
apps/postgres/kustomization.yaml   → overlays/v2   (active)
apps/mlflow/kustomization.yaml     → overlays/v2   (active)
apps/monitoring/kustomization.yaml → overlays/v2   (active)

apps/*/overlays/v1                 → historical fallback (inactive)
```

Active V2 overlays contain **no** Git-owned SecretProviderClass resources.
`private_runtime_config` owns the three SPCs and `tradingchassis-runtime-config`.
MLflow reads `AWS_DEFAULT_REGION` from Secret `tradingchassis-runtime-config`
key `OCI_REGION`.

The canonical clean-room path does **not** run
`scripts/inject-runtime-values.sh` or `scripts/08-runtime.sh`.
Those scripts remain historical V1 fallback only.

PostgreSQL MLflow-init Job bootstrap:

```text
mounts SecretProviderClass postgres-secret-bundle (CSI)
keeps bounded Job retries (backoffLimit + activeDeadlineSeconds)
waits with bounded pg_isready before idempotent DB init
```

Temporary absence of `postgres-secret` during early Argo reconciliation must not
leave a permanently failed Job that requires manual recreation.
Live consumer health remains to be proven on the first clean-room deployment.

---

## Scratch Kubernetes binding (implemented / awaiting live validation)

```text
Terraform provisions the OCI scratch block volume (default size_in_gbs=150; OCI block-volume GB = 1024 MiB / GiB-equivalent)
→ Ansible mounts it at /mnt/scratch and creates /mnt/scratch/dev and /mnt/scratch/prod
→ Argo Application scratch-storage owns StorageClass tradingchassis-scratch and static PVs
→ scratch-dev / scratch-prod PVCs bind deterministically via volumeName + claimRef
```

Design notes (statically validated; not live-proven):

```text
hostPath static PVs (not local PersistentVolumes): single-node MicroK8s, no hostname affinity
dev path:  /mnt/scratch/dev
prod path: /mnt/scratch/prod
capacity:  70Gi + 70Gi Kubernetes accounting (= 140Gi aggregate)
backing:   Terraform OCI size_in_gbs=150 (OCI block-volume GB = 1024 MiB / GiB-equivalent)
headroom:  nominal ~10 Gi before filesystem overhead; PV capacity is NOT a quota
reclaim:   Retain (Kubernetes PV deletion must not imply cloud volume deletion)
quota:     PV capacity is NOT a filesystem quota on the shared ext4 volume
fail-closed hostPath type Directory: missing subdirs after a failed remount refuse the volume
```

Do not declare clean-room acceptance complete until live validation confirms PVC binding
and that workloads consume `/mnt/scratch/*` rather than the root filesystem.

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
| Terraform fmt / backend contract / init `-backend=false` / validate | statically validated by CI |
| Ansible lint / syntax-check | statically validated by CI |
| Kustomize / Helm GitOps renders / contracts | statically validated by CI |
| Scratch PVC binding to `/mnt/scratch` | implemented in Git; must be proven live |
| OCI secrets Application sync-wave + Ansible readiness gate | implemented in Git; must be proven live |
| Terraform apply | must be proven during first clean-room deployment |
| SSH reachability / Ansible converge | must be proven live |
| MicroK8s Ready / Argo reconciliation | must be proven live |
| Vault retrieval / workload health | must be proven live |

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
| Child Applications exist: `oci-secrets`, `scratch-storage`, `postgres`, `mlflow`, `monitoring`, `argo`, `scratch-dev`, `scratch-prod` | yes |
| `oci-secrets` Synced/Healthy | yes |
| Secrets Store CSI Driver Ready | yes |
| OCI provider Ready | yes |
| SPC CRD present | yes |
| Namespaces `postgres` / `mlflow` / `monitoring` present | yes |
| `private-runtime-config.yml` succeeded | yes |
| Three SPCs exist (names only; no spec dumps) | yes |
| Secret `tradingchassis-runtime-config` exists with key `OCI_REGION` | yes |
| PostgreSQL Healthy | yes |
| MLflow Healthy | yes |
| Monitoring Synced + Healthy | yes |
| Argo Workflows Healthy | yes |
| Scratch PVCs Bound to `/mnt/scratch/dev` and `/mnt/scratch/prod` | yes — **awaiting live validation** |
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

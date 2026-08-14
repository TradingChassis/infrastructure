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
First V2 clean-room deployment: not yet executed
```

Cloud Shell operator prerequisites:

```text
partially live validated / authentication and backend bootstrap live validated
```

The V2 clean-room workflow is **not** a completed live rebuild. Remaining
operator work is the first real clean-room deployment and later post-proof V1
cleanup.

Known remaining blockers:

```text
- First real clean-room deployment has not yet been executed.
- Production Terraform init/plan/apply against the production state key is not live proven.
- Post-proof V1 cleanup has not started.
```

Terraform remote state status:

```text
implemented / native OCI backend init with APIKey live proven against an empty
backend-test key / production state write and locking not yet live proven
```

OCI Cloud Shell execution readiness status:

```text
APIKey/tradingchassis CLI + Terraform provider + native backend init live proven
preinstalled Cloud Shell Terraform is not new enough (install 1.15.8 user-locally)
SecurityToken via oci session authenticate is NOT the Cloud Shell path
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

### Live snapshot (2026-08-12) — execution evidence, not architecture

This snapshot is dated operator evidence from the first Cloud Shell
execution-readiness exercise. It is **not** a permanent architecture
requirement and is **not** a teardown procedure.

Observed historical compute/storage:

```text
instance-vps-argocd          TERMINATED
historical boot volume       TERMINATED
historical scratch volume    TERMINATED
historical VNIC attachment   DETACHED
```

Remaining observed V1-era network names (do not delete in this workflow):

```text
VCN-ManagedSecrets
Public-Subnet-ManagedSecrets
Internet Gateway VCN-ManagedSecrets
VCN default route table
VCN default security list
```

No NSG, NAT gateway, service gateway, reserved public IP, or load balancer was
observed in that inventory.

Remaining observed V1-era IAM names (no collision with V2 Terraform names
`tradingchassis-instance-principal` / `tradingchassis-vault-secret-bundles`):

```text
dynamic group instance-temp-dynamic-group-rule
policy instance-temp-policy
```

Persistent V2 foundation that must **not** be treated as V1 teardown:

```text
compartment ManagedSecrets
Vault rnd-infra-setup-vault (ACTIVE)
required Secret names (metadata only; values not recorded here)
dedicated Terraform state bucket tradingchassis-terraform-state
  (NoPublicAccess, Versioning Enabled; namespace is tenancy-specific)
```

Do not reuse an existing application/`data` bucket as Terraform state.

---

## Operator prerequisites

The **recommended** operator environment is OCI Cloud Shell.
Other machines may follow the same contracts if they provide a supported
Terraform OCI authentication method, outbound network access, and SSH.

| Requirement | Source / note |
| --- | --- |
| Git | clone this repository under `$HOME` (persistent in Cloud Shell) |
| Terraform | `~> 1.15.0` (`terraform/versions.tf`); install **1.15.8** under `$HOME/bin` (do not trust Cloud Shell preinstall) |
| Ansible | install pinned collections from `ansible/requirements.yml`; CI validates with `ansible-core==2.21.2` / Python `3.12` |
| Python 3 | required by Ansible |
| OCI CLI | Cloud Shell built-in CLI is `instance_obo_user` convenience only; Terraform uses `$HOME/.oci` APIKey profile `tradingchassis` |
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
Cloud Shell architecture = aarch64 (linux_arm64)
$HOME                   = persistent encrypted storage
OCI CLI                 = pre-authenticated for CLI convenience only
OCI CLI binary          = typically /home/oci/bin/oci
OCI CLI config/token    = outside home under /etc/oci (do not modify/copy)
OCI CLI auth            = instance_obo_user + delegation_token
OCI CLI profile/region  = follows Console region selected when the shell starts
Preinstalled Terraform  = may be too old (live Cloud Shell observed 1.5.7)
Required Terraform      = ~> 1.15.0 (install 1.15.8 user-locally under $HOME/bin)
Cloud Shell public IP   = dynamic across sessions (stable within one session)
Public internet access  = requires Cloud Shell Public Network (or equivalent);
                          OCI Service Network alone is insufficient for GitHub,
                          HashiCorp Terraform releases / Terraform Registry,
                          Ansible Galaxy, and public SSH
```

Clone and store operator files under `$HOME`, never under ephemeral `/tmp`, so a
session restart can resume.

Do **not** assume the Cloud Shell preinstalled Terraform binary satisfies
`required_version ~> 1.15.0`. Install the repository-supported version into
`$HOME/bin` (see below).

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

This proves **OCI CLI convenience** access. It is **not** the TradingChassis
Terraform backend/provider identity.

Do **not** copy, modify, or extract `/etc/oci/config` or the delegation token.
Do **not** feed `instance_obo_user` to Terraform.

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

`SecurityToken` remains a supported portable provider/backend mode in Terraform,
but it is **not** the canonical Cloud Shell path. Live Cloud Shell testing of
`oci session authenticate` failed with `404 NotAuthorizedOrNotFound` /
`Calling principal is not allowed or not found` while the shell was already
authenticated as `instance_obo_user`. Do not engineer around that failure.

### Canonical Cloud Shell Terraform auth strategy

```text
APIKey via $HOME/.oci/config profile tradingchassis
→ same profile for OCI CLI Terraform-identity preflights
→ native OCI Terraform backend
→ OCI Terraform provider
```

Operator-local files (never commit):

```text
$HOME/.oci/config                         (mode 0600)
$HOME/.oci/tradingchassis_api_key.pem     (mode 0600)
```

Conceptual profile (placeholders only; use live operator values locally):

```text
[tradingchassis]
user=<operator-user-ocid>
fingerprint=<api-key-fingerprint>
tenancy=<tenancy-ocid>
region=<oci-region>
key_file=<absolute-path-to-private-api-signing-key>
```

This API signing key authenticates the operator and Terraform to OCI APIs.
It is **not** the VM SSH keypair used later for Ubuntu/`ansible_user`.

### OCI CLI environment precedence

Cloud Shell exports `OCI_CLI_AUTH=instance_obo_user`. Specifying only
`--config-file` and `--profile tradingchassis` is **not** enough: the CLI still
follows `OCI_CLI_AUTH` and looks for a delegation token.

Every OCI CLI command that must prove the Terraform identity therefore uses
explicit API-key auth:

```bash
# PREFLIGHT / SAFE TO RUN (read-only identity check)
oci iam region list \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth api_key
```

Terraform itself is configured through `backend.hcl` and `oci_auth` /
`oci_config_file_profile`. Do **not** wrap Terraform in `env -u OCI_CLI_*`
unless a later live defect proves those CLI variables affect the provider or
backend. OCI CLI environment variables are not automatically the Terraform
auth contract.

Wire the non-secret auth selection into:

```text
terraform/backend.hcl
  auth = "APIKey"
  config_file_profile = "tradingchassis"

terraform/terraform.tfvars
  oci_auth = "APIKey"
  oci_config_file_profile = "tradingchassis"
```

Do not put private keys, fingerprints, tokens, or live OCIDs into those files.

### API signing key bootstrap

One-time operator action. Do **not** replace `/etc/oci/config`.

```bash
# PREFLIGHT / SAFE TO RUN (local key generation; upload is a Console mutation)
mkdir -p "$HOME/.oci"
chmod 700 "$HOME/.oci"

openssl genrsa -out "$HOME/.oci/tradingchassis_api_key.pem" 2048
# Recommended trailing marker so OCI CLI does not warn about a missing label:
printf '\n%s\n' 'OCI_API_KEY' >> "$HOME/.oci/tradingchassis_api_key.pem"
openssl rsa -pubout \
  -in "$HOME/.oci/tradingchassis_api_key.pem" \
  -out "$HOME/.oci/tradingchassis_api_key_public.pem"

chmod 600 "$HOME/.oci/tradingchassis_api_key.pem"
chmod 600 "$HOME/.oci/config" 2>/dev/null || true
```

Then in the OCI Console, open the operator user → API Keys → paste the public
key. Record the fingerprint, user OCID, tenancy OCID, and region into
`$HOME/.oci/config` under `[tradingchassis]`. Point `key_file` at the private
signing key absolute path.

Do not use `SUPPRESS_LABEL_WARNING=True` as the canonical workaround.

Verify with the explicit `--auth api_key` command above. Do not commit the
generated files.

### User-local Terraform install (Cloud Shell)

Repository constraint: `required_version ~> 1.15.0` (`terraform/versions.tf`).
CI and the live Cloud Shell proof use **1.15.8**. Preinstalled Cloud Shell
Terraform may be 1.5.x and cannot initialize the native OCI backend.

Install user-locally. No sudo. Do not overwrite `/usr/bin`.

```bash
# PREFLIGHT / SAFE TO RUN (downloads HashiCorp release + SHA256SUMS; needs Public Network)
TF_VERSION=1.15.8
case "$(uname -m)" in
  aarch64|arm64) TF_ARCH=arm64 ;;
  x86_64|amd64)  TF_ARCH=amd64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$HOME/bin" "$HOME/tmp"
cd "$HOME/tmp"
curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_${TF_ARCH}.zip"
curl -fsSLO "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_SHA256SUMS"
sha256sum -c --ignore-missing "terraform_${TF_VERSION}_SHA256SUMS"
unzip -o "terraform_${TF_VERSION}_linux_${TF_ARCH}.zip" -d "$HOME/bin"
chmod 755 "$HOME/bin/terraform"

export PATH="$HOME/bin:$PATH"
command -v terraform
terraform version
```

Expect `command -v terraform` to resolve to `$HOME/bin/terraform` and
`Terraform v1.15.8` on `linux_arm64` in Cloud Shell. Prepend `$HOME/bin` for
the session; do not permanently edit shell startup files unless the operator
already manages PATH that way.

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
| `oci_auth` / `oci_config_file_profile` | APIKey + profile `tradingchassis` for Cloud Shell |
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
- The bucket must be private (`NoPublicAccess`). Do not reuse an arbitrary
  application or `data` bucket merely because it already exists.
- Copy `terraform/backend.hcl.example` to the ignored `terraform/backend.hcl`
  and supply `bucket`, `namespace`, `region`, unique `key`, plus APIKey
  auth selection fields.
- Production-style example key: `tradingchassis/production/terraform.tfstate`.
  Do not reuse a disposable `backend-test` key for production.
- Local state is **not** an operator deployment fallback. CI may use
  `terraform init -backend=false` for static validation only.
- No V2 state migration is required for the first V2 clean-room deployment.
- Details: [`terraform/README.md`](../terraform/README.md).

### External state-bucket bootstrap (operator mutation)

This is an **OPERATOR BOOTSTRAP ACTION**, not Terraform, Ansible, or GitOps.
The root must not contain `oci_objectstorage_bucket`. The bucket is not part of
the Terraform state it later stores and must survive infrastructure teardown.

Use the APIKey identity explicitly. GET first; CREATE only if absent; GET/VERIFY
after. Do not run these commands from CI.

```bash
# MUTATION BOUNDARY: create the dedicated state bucket only if it does not exist.
# Replace placeholders. Do not reuse an application/data bucket.
NS="$(oci os ns get \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth api_key \
  --query 'data' \
  --raw-output)"
BUCKET="<dedicated-state-bucket>"          # example name: tradingchassis-terraform-state
COMPARTMENT="<compartment-ocid>"
BACKEND_REGION="<backend-region>"

if oci os bucket get \
  --namespace-name "$NS" \
  --bucket-name "$BUCKET" \
  --region "$BACKEND_REGION" \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth api_key >/dev/null 2>&1
then
  echo "state bucket already exists: $BUCKET"
else
  oci os bucket create \
    --namespace-name "$NS" \
    --compartment-id "$COMPARTMENT" \
    --name "$BUCKET" \
    --region "$BACKEND_REGION" \
    --public-access-type NoPublicAccess \
    --versioning Enabled \
    --config-file "$HOME/.oci/config" \
    --profile tradingchassis \
    --auth api_key
fi

# PREFLIGHT / SAFE TO RUN (verify Versioning Enabled + NoPublicAccess)
oci os bucket get \
  --namespace-name "$NS" \
  --bucket-name "$BUCKET" \
  --region "$BACKEND_REGION" \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth api_key \
  --query '[data.versioning, data."public-access-type"]' \
  --raw-output
```

Expect versioning `Enabled` and public access `NoPublicAccess` before any
production `terraform init -backend-config=backend.hcl`.

### Backend preflight (Cloud Shell / OCI CLI)

These commands are **PREFLIGHT / SAFE TO RUN** metadata checks. They do not create
buckets, enable versioning, or write objects.

They must use the same APIKey profile that Terraform will use.
Do **not** rely on Cloud Shell's built-in `instance_obo_user` identity for these
checks; that path does not prove Terraform backend/provider authentication.

```bash
# Namespace via APIKey profile tradingchassis
oci os ns get \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth api_key

# Bucket exists + versioning status (expect versioning = Enabled)
# Use the backend Object Storage region from backend.hcl, not merely the
# Cloud Shell Console start region.
oci os bucket get \
  --namespace-name <object-storage-namespace> \
  --bucket-name <existing-state-bucket> \
  --region <backend-region> \
  --config-file "$HOME/.oci/config" \
  --profile tradingchassis \
  --auth api_key \
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
The VM SSH keypair is separate from the OCI API signing key.

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
HashiCorp Terraform releases download
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
| `scratch_volume_id` | diagnostics / correlation |
| `scratch_volume_attachment_id` | diagnostics / correlation |
| `scratch_volume_attachment_type` | diagnostics / correlation |
| `instance_private_ip` | informational |
| `instance_id` | informational / IAM correlation |
| `vault_id` | echoes configured Vault reference (not secret contents) |
| other network/scratch/IAM IDs | diagnostics |

Terraform does not expose a Linux scratch device path. Live paravirtualized
attachments leave `oci_core_volume_attachment.device` unset, so Ansible
performs fail-closed automatic scratch-device discovery on the host.

Targeted reads only (do not dump full state):

```bash
terraform -chdir=terraform output -raw instance_public_ip
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

Scratch device identification is Ansible fail-closed auto-discovery.
The renderer does not emit a Linux device path.

| Terraform / operator source | Ansible input |
| --- | --- |
| output `instance_public_ip` | inventory `ansible_host` |
| Ubuntu 24.04 image contract | inventory `ansible_user=ubuntu` |
| `~/.ssh/tradingchassis` | inventory `ansible_ssh_private_key_file` |
| unique eligible non-root whole disk | automatic scratch-device discovery |
| optional operator-verified path | `-e scratch_storage_device_path=...` (override only) |
| first-use formatting decision | `-e scratch_storage_allow_format=true` (first converge only) |

The helper must not embed Vault IDs, OCI regions, or credentials.

### Scratch device and format gate

```text
FIRST CONVERGE
→ automatic scratch-device discovery
→ set scratch_storage_allow_format=true only after reviewing that the
  discovered device is the intended blank Terraform-managed scratch volume
→ discovery alone does not authorize formatting

SECOND CONVERGE
→ keep scratch_storage_allow_format=false (default)
→ discovery remains idempotent for the expected UUID mount at /mnt/scratch
→ do not reformat
```

Auto-discovery fails closed when zero or more than one eligible non-root whole
disk exists. Kernel names are not a stable contract; persistent mounting stays
UUID-based.

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
2. Confirm public-network/internet reachability for GitHub, HashiCorp releases, registries, and SSH
3. git clone <repo> under $HOME && cd infrastructure
4. Install Terraform 1.15.8 under $HOME/bin; export PATH="$HOME/bin:$PATH"; terraform version
5. ./tools/check-cloud-shell-readiness
6. Create $HOME/.oci API signing key + [tradingchassis] profile (do not modify /etc/oci)
7. Verify APIKey identity (oci iam region list --config-file "$HOME/.oci/config" --profile tradingchassis --auth api_key)
8. GET/CREATE/VERIFY dedicated external state bucket (Versioning Enabled, NoPublicAccess)
9. cp terraform/backend.hcl.example terraform/backend.hcl  # edit location + APIKey fields
10. cp terraform/terraform.tfvars.example terraform/terraform.tfvars  # edit inputs
11. Create ~/.ssh/tradingchassis ed25519 keypair; ssh-add; set ssh_public_key literal or TF_VAR_ssh_public_key
12. Set ssh_ingress_cidr to current Cloud Shell public IP /32
13. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform init -backend-config=backend.hcl
14. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform validate
15. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform plan -out=terraform.tfplan
16. Review plan
17. FIRST LIVE DEPLOYMENT: terraform -chdir=terraform apply terraform.tfplan
18. Read targeted outputs; ./tools/render-ansible-inventory
19. Install ansible-core==2.21.2 in $HOME venv if needed; ansible-galaxy install -r ansible/requirements.yml
20. SSH with StrictHostKeyChecking=accept-new to ubuntu@instance_public_ip
21. FIRST LIVE DEPLOYMENT: ansible-playbook site.yml with automatic scratch-device discovery + allow_format=true after reviewing the blank scratch volume
22. FIRST LIVE DEPLOYMENT: ansible-playbook private-runtime-config.yml -e @ansible/extra-vars/private-runtime.yml
23. Verify Argo Applications / CSI DaemonSets / SPC existence via ssh + microk8s kubectl
24. Run acceptance checks (secret-safe) and a second site.yml converge without formatting
```

Local static helper (no OCI mutation):

```bash
./tools/check-cloud-shell-readiness
```

Session restart resume:

```text
cd $HOME/.../infrastructure
export PATH="$HOME/bin:$PATH"
reuse $HOME/.oci/config profile tradingchassis (APIKey)
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

### OCI cloud-image firewall (FORWARD + INPUT)

OCI Ubuntu 24.04 cloud images persist two IPv4 catch-all REJECT rules in
`/etc/iptables/rules.v4` (CLOUD_IMG / Oracle Cloud Infrastructure baseline).
Both load into the nft-compatible table ahead of UFW.

```text
1. FORWARD REJECT
   -A FORWARD -j REJECT --reject-with icmp-host-prohibited
   Blocks forwarded Pod → Kubernetes Service traffic with
   `no route to host`.
   V2 removes this exact rule only.

2. INPUT REJECT vs node-local API (retained REJECT)
   -A INPUT -j REJECT --reject-with icmp-host-prohibited
   On the single-node cluster, kube-proxy DNAT sends Pod → Kubernetes
   Service connections to the node-local kube-apiserver (tcp/16443).
   That packet hits INPUT, not FORWARD, and is rejected before UFW.
   V2 inserts one allow from microk8s_pod_cidr (10.1.0.0/16) to
   microk8s_apiserver_port (16443) immediately before this REJECT.

3. INPUT REJECT vs node-local kubelet (same retained REJECT)
   metrics-server scrapes the node-local kubelet (tcp/10250) from a Pod
   in the MicroK8s pod CIDR. That packet also hits INPUT before UFW.
   V2 inserts one allow from microk8s_pod_cidr (10.1.0.0/16) to
   microk8s_kubelet_port (10250) immediately before this REJECT.

4. UFW boot does not restore the normalized nft runtime
   Persistent /etc/iptables/rules.v4 survived reboot with the OCI
   baseline, both pod allows, INPUT REJECT, and InstanceServices.
   Runtime iptables-nft INPUT after reboot contained only UFW jumps.
   iptables-persistent/netfilter-persistent are not the owner; UFW is.
   V2 installs tradingchassis-oci-microk8s-firewall.service to
   reconcile the owned contract after ufw.service, without a
   whole-table restore. The unit is PartOf=ufw.service and
   WantedBy=ufw.service so a later UFW restart or start re-runs
   the same helper. RequiredBy the MicroK8s snap units so a failed
   boot reconcile keeps kubelite/containerd from starting. Live
   reboot proof of that unit is NOT yet established by this
   repository change.
```

UFW `DEFAULT_FORWARD_POLICY=ACCEPT` and UFW Calico interface allows do not
fix either rule while it still precedes the UFW chains.

Do not flush iptables tables, disable UFW, delete `rules.v4`, delete the OCI
INPUT REJECT, or rewrite InstanceServices from a template. Do not install
`iptables-persistent` / `netfilter-persistent` as a second full-table
manager alongside UFW.

Current-host live evidence after PR #54: the FORWARD REJECT is gone and INPUT
REJECT remains. After PR #55: the pod → API tcp/16443 allow exists before
INPUT REJECT and CoreDNS / calico-kube-controllers recovered on the current
host. After PR #56: the pod → kubelet tcp/10250 allow exists before INPUT
REJECT, metrics-server became Ready, and a second Ansible converge reported
`changed=0`. After that same host rebooted **without** Ansible, persistent
`rules.v4` still had the contract, but runtime iptables-nft INPUT was UFW-only
and the metrics API returned ServiceUnavailable. Finding 4 is implemented
here as `tradingchassis-oci-microk8s-firewall.service` and is **NOT yet**
live-reboot-proven by this repository change. The first live PR #57
converge failed while appending quoted Oracle InstanceServices comments;
runtime INPUT kept the pod allows and UFW, InstanceServices existed
empty, and the boot unit was not installed. Quoted iptables-save
tokenization is required before that apply can succeed. Live successful
quoted-token apply is **NOT yet** proven. The unit uses
`PartOf=ufw.service` and `RequiredBy` the MicroK8s snap units. None of
these current-host observations are clean-room rebuild proof.

### Example first converge

Use `ANSIBLE_CONFIG` so paths resolve from `ansible/ansible.cfg`.
Use the generated ignored inventory; never commit real inventory.

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i ansible/inventory/local.yml \
  ansible/playbooks/site.yml \
  -e scratch_storage_allow_format=true
```

Set `scratch_storage_allow_format=true` only for the intentional first format of
an empty Terraform-managed scratch volume after reviewing discovery (see above).
Automatic discovery does not authorize formatting.

Optional explicit override, only when intentionally justified:

```bash
-e scratch_storage_device_path=/operator-verified/path
```

Second converge (idempotency) must omit formatting opt-in and normally omit the
device-path override so discovery remains canonical:

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i ansible/inventory/local.yml \
  ansible/playbooks/site.yml
```

### What successful `site.yml` means

```text
host baseline contract asserted (Ubuntu 24, ARM64)
scratch filesystem validated/mounted at /mnt/scratch (when inputs correct)
scratch workload directories /mnt/scratch/dev and /mnt/scratch/prod present on the mount
MicroK8s installed (channel 1.29/stable) with required addons
host UFW policy applied (incoming deny, outgoing allow, routed allow, SSH, Calico)
OCI cloud-image unconditional IPv4 FORWARD REJECT removed from rules.v4 and nft FORWARD
OCI INPUT catch-all REJECT retained
narrow MicroK8s pod CIDR → tcp/16443 and tcp/10250 allows inserted before INPUT REJECT
tradingchassis-oci-microk8s-firewall.service enabled for post-UFW boot nft reconcile
SSH retained, UFW active, /mnt/scratch retained
Kubernetes node Ready
CoreDNS Ready
Calico kube-controllers Ready
metrics-server Ready
Argo CD installed in namespace argocd
root Application from argocd/root-app.yaml submitted
```

The MicroK8s system-pod Ready state above is the intended first MicroK8s
converge outcome after OCI FORWARD and INPUT firewall normalizations.
FORWARD REJECT removal was live-proven after PR #54. The INPUT pod-API allow
was live-proven on the current host after PR #55. The INPUT pod-kubelet allow
was live-proven on the current host after PR #56 before reboot. Automatic
post-reboot nft reconciliation is **NOT yet** live-proven. None of these
current-host observations are clean-room rebuild proof.

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
no reintroduction of the OCI unconditional IPv4 FORWARD REJECT
no deletion of the OCI catch-all INPUT REJECT
no Argo CD reinstall churn beyond idempotent module behavior
```

The second MicroK8s converge must remain idempotent once the OCI FORWARD
REJECT is gone, both pod → node-local API and kubelet allows already
precede INPUT REJECT, InstanceServices is present, and the boot firewall
unit is already enabled. That claim is statically designed and **NOT yet**
live-proven after a post-fix reboot.

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
| Cloud Shell built-in `instance_obo_user` OCI CLI | live proven (CLI convenience only) |
| APIKey / profile `tradingchassis` OCI CLI | live proven |
| Terraform 1.15.8 linux_arm64 in Cloud Shell (`$HOME/bin`) | live proven |
| OCI provider APIKey / `tradingchassis` data-source read | live proven (no resources) |
| Dedicated state bucket exists, NoPublicAccess, Versioning Enabled | live proven |
| Native OCI backend init with APIKey / empty backend-test key | live proven |
| Production state key write / locking / root plan / apply | **not yet live proven** |
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

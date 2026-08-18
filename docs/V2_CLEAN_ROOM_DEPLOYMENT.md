# V2 Clean-Room Deployment

## Purpose

This document is the **canonical operator runbook** for a Greenfield TradingChassis
V2 environment from this repository.

Do **not** create a second competing runbook (`FINAL_CLEAN_ROOM.md`,
`ACCEPTANCE.md`, `DEPLOYMENT_FINAL.md`, or equivalent). Consolidate here.

Canonical tools:

```text
tools/bootstrap-cloud-shell
→ tools/deploy-clean-room
→ tools/verify-clean-room
```

This document describes the current V2 clean-room operator contract.

It does **not** document the retired V1 bootstrap path as an active procedure
and does **not** document the historical in-place SPC ownership handoff as the
Greenfield path.

For the historical in-place SecretProviderClass ownership procedure (fallback only),
see [`RUNTIME_SPC_OWNERSHIP_CUTOVER.md`](RUNTIME_SPC_OWNERSHIP_CUTOVER.md).

---

## Current operator contract vs historical context

### CURRENT OPERATOR CONTRACT

```text
Fresh OCI Cloud Shell
→ fresh clone
→ ./tools/bootstrap-cloud-shell
→ operator-local inputs
→ ./tools/deploy-clean-room
→ APPLY gate if Terraform has an approved additive/change plan
→ FORMAT gate only for exact blank scratch discovery
→ full convergence
→ ./tools/verify-clean-room
→ no-drift / idempotency gates
→ REBOOT gate
→ reboot proof
→ post-reboot convergence
→ Terraform destroy acceptance
→ prove Terraform state empty
→ fresh post-destroy plan is create/add-only
→ external foundation remains intact
```

PASS and STOP are owned by those tools and by the explicit human gates below.
Do not treat GitHub Actions static validation as a live rebuild.

### HISTORICAL CONTEXT

Useful history, not the active procedure:

- V1 executable repository paths were retired in PR #73. Do not run
  `scripts/inject-runtime-values.sh` or `scripts/08-runtime.sh`.
- Incremental current-host firewall observations from earlier PRs were
  **NOT yet** a Greenfield rebuild; they informed the current Ansible contract.
- A legacy unused 2022 OCI network generation was independently audited as
  unused and removed. Objects not named by Version 2 Terraform must not be
  deleted as part of this workflow.
- Terraform destroy removes Terraform-owned disposable infrastructure only.
  The external state bucket (Versioning Enabled, NoPublicAccess) and the
  external Vault remain operator-managed foundation.

Do not copy live display names, OCIDs, namespaces, usernames, public IPs, or
host identifiers into this generic runbook.

---

## Canonical operator flow

The operator runs the tools. The tools inspect actual Terraform, Ansible, and
Kubernetes state. There is no custom persistent step-state machine.

| Step | Operator runs | Automation guarantees | Human gate | PASS / STOP |
| --- | --- | --- | --- | --- |
| 1 | Fresh Cloud Shell, Public Network, clone | — | — | STOP if GitHub / HashiCorp / Galaxy / SSH are unreachable |
| 2 | `./tools/bootstrap-cloud-shell` | Terraform 1.15.x, Python 3.12 venv, collections, example copies | HUMAN OPERATOR INPUT GATE after bootstrap | STOP if Python 3.12 / Terraform / venv contract fails |
| 3 | Complete gitignored inputs | Readiness checks reject placeholders in `--strict` | Operator completes files; do not infer values | STOP if placeholders remain |
| 4 | `./tools/deploy-clean-room` | Readiness, OCI preflight, Terraform init/validate/plan, inventory, Ansible, Argo, workloads | **APPLY** when the plan has additive/change actions; **FORMAT** only for the exact blank-scratch error | No-change plan skips APPLY. Destructive delete/replace STOP. Unrelated Ansible failure does not offer FORMAT. Deploy never reboots. |
| 5 | `./tools/verify-clean-room` | Terraform no-drift (never apply), SSH/scratch, Argo/workloads, `changed=0` second runs, boot-id capture | **REBOOT** | STOP on drift, non-zero changed, invalid Argo JSON, unchanged boot id, or declined REBOOT |
| 6 | Destroy acceptance (this runbook) | — | Inspect the saved destroy plan before apply | STOP if external foundation appears in the plan |

Do not duplicate every inner command the tools already run unless diagnosing a
STOP.

---

## Toolchain contract

| Tool | Contract |
| --- | --- |
| Python | **Python 3.12 required** for the dedicated automation environment. Cloud Shell's older default `python3` is **not** an acceptable fallback. `tools/bootstrap-cloud-shell` and `tools/check-cloud-shell-readiness` require `python3.12`. |
| Ansible | `ansible-core==2.21.2` in `$HOME/.venvs/tradingchassis-ansible`. Collections from `ansible/requirements.yml` (`ansible.posix 2.2.2`, `community.general 13.2.0`, `kubernetes.core 6.5.0`). Do not use Cloud Shell `/usr/bin/ansible-playbook` (Ansible **2.9**). |
| Terraform | `~> 1.15.0` (`terraform/versions.tf`). Canonical patch used by bootstrap and CI: **1.15.8** (`TF_VERSION=1.15.8`). Provider versions come from the tracked `terraform/.terraform.lock.hcl`. `.terraform/` stays local. |
| tmux | Recommended for Cloud Shell session durability. **Not a dependency.** Scripts warn when `TMUX` is unset; they do not install or start tmux. |

Do not invent hard deployment-duration SLAs.

Bootstrap installs user-local Terraform under `$HOME/bin` from
`releases.hashicorp.com/terraform`, verifies `SHA256SUMS`, and maps
`aarch64|arm64` → `arm64` and `x86_64|amd64` → `amd64`. No sudo. Do not trust
the Cloud Shell preinstall.

The dedicated venv is the control-node interpreter the tools use. For manual
diagnostics only:

```bash
source "$HOME/.venvs/tradingchassis-ansible/bin/activate"

cd "$HOME/infrastructure"

ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" \
  ansible-playbook \
  -i ansible/inventory/local.yml \
  ansible/playbooks/site.yml
```

If the clone path differs, run the same commands from the repository root.
Do **not** run bare `/usr/bin/ansible-playbook`.
Do **not** run `ansible-playbook site.yml` without the `ansible/playbooks/` path.
Do **not** omit `ANSIBLE_CONFIG`.
Do **not** point `-i` at `ansible/inventory/example.yml`.

---

## Operator-local private inputs

Gitignored. Never commit. Never paste real OCIDs, usernames, public IPs, secret
values, key material, or home paths into tracked docs.

Bootstrap copies the committed examples only when the destination is absent.
It does not overwrite completed files.

| File | Responsibility |
| --- | --- |
| `terraform/backend.hcl` | Remote state **location and auth selection** only. No deployment secrets. Dedicated Object Storage state bucket, namespace, region, unique key, `auth = "APIKey"`, `config_file_profile = "tradingchassis"`. |
| `terraform/terraform.tfvars` | OCI **deployment selectors**: region, compartment, tenancy, Vault identifiers, SSH ingress CIDR, SSH public-key content, optional sizing. Not backend location. |
| `ansible/extra-vars/private-runtime.yml` | Private runtime values consumed by Ansible `private-runtime-config.yml` (`private_runtime_config_vault_id`, `private_runtime_config_oci_region`). |

Examples remain placeholders in:

```text
terraform/backend.hcl.example
terraform/terraform.tfvars.example
ansible/extra-vars/private-runtime.yml.example
```

---

## Ownership model

### Terraform owns disposable OCI infrastructure

NETWORK

- VCN
- internet gateway
- custom route table
- custom security list
- subnet
- compute NSG
- NSG rules

COMPUTE

- instance

STORAGE

- scratch volume
- attachment

IAM

- instance-principal dynamic group
- Vault secret-bundle read policy

Terraform does **not** own host configuration, MicroK8s, Argo CD, or long-lived
Kubernetes resources.

### Ansible owns

- host configuration
- MicroK8s prerequisites/configuration
- scratch preparation/mount behavior
- private-runtime SecretProviderClass materialization

### Argo CD owns

- Kubernetes/GitOps applications
- OCI secrets provider installation (`oci-secrets`)
- workload reconciliation
- scratch StorageClass / static PVs / PVCs

### GitHub Actions owns

- static repository validation only

Do **not** duplicate ownership. Example anti-patterns:

```text
Do not install CSI Driver / OCI provider with Bash while Argo owns oci-secrets.
Do not keep Git-owned SecretProviderClass resources and Ansible-owned SPCs
authoritative for the same objects in steady state.
Do not let Terraform manage long-lived Kubernetes application manifests.
Do not let Ansible declaratively rewrite MicroK8s-owned Calico UFW
interface rules on vxlan.calico and cali+.
```

### External foundation (preserved; NOT lifecycle-owned by this Terraform root)

- OCI Vault
- Vault secret values
- Object Storage Terraform state bucket
- OCI API signing config/key
- SSH keypair
- GitHub repository
- tenancy
- compartment

**Destroy semantics:** `terraform destroy` of this root removes Terraform-owned
disposable infrastructure. It must **not** destroy external foundation.

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
Required Terraform      = ~> 1.15.0 (bootstrap installs TF_VERSION=1.15.8 under $HOME/bin)
Cloud Shell public IP   = dynamic across sessions (stable within one session)
Public internet access  = requires Cloud Shell Public Network (or equivalent);
                          OCI Service Network alone is insufficient for GitHub,
                          HashiCorp Terraform releases / Terraform Registry,
                          Ansible Galaxy, and public SSH
```

Clone and store operator files under `$HOME`, never under ephemeral `/tmp`.

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

`SecurityToken` remains a supported portable provider/backend mode in Terraform,
but it is **not** the canonical Cloud Shell path.

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

Conceptual profile (placeholders only):

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

`tools/deploy-clean-room` runs that identity preflight. Terraform itself is
configured through `backend.hcl` and `oci_auth` / `oci_config_file_profile`.
Do **not** wrap Terraform in `env -u OCI_CLI_*` unless a later live defect proves
those CLI variables affect the provider or backend.

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
`tools/bootstrap-cloud-shell` does **not** create this key.

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

Verify with the explicit `--auth api_key` command above. Do not commit the
generated files.

---

## Terraform inputs

Prepare **local** variable values from the committed example if bootstrap did
not already copy it:

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
  `terraform init -backend=false` for **static validation only**.
- Provider selection uses the tracked lockfile. Operator deploy never uses
  `-backend=false`.
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
root.

---

## SSH key strategy

Generate an operator-local ed25519 keypair under persistent Cloud Shell home
if it does not already exist. Bootstrap does not create this keypair.

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

Before deploy (and again after opening a new Cloud Shell session if needed):

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

Canonical image contract is Canonical Ubuntu 24.04 → `ansible_user=ubuntu`.

---

## Deploy contract (`tools/deploy-clean-room`)

This is the canonical Greenfield deploy. It inspects live state on every run.
It does **not** reboot. It does **not** remember APPLY/FORMAT from a previous
invocation.

Local static helper (no OCI mutation):

```bash
./tools/check-cloud-shell-readiness
```

Deploy uses `--strict` readiness.

### What the operator runs

```bash
./tools/deploy-clean-room
```

### What the automation guarantees

1. Dedicated Ansible venv present (`$HOME/.venvs/tradingchassis-ansible`).
2. `tools/check-cloud-shell-readiness --strict`.
3. Operator files present without angle-bracket placeholders:
   `terraform/backend.hcl`, `terraform/terraform.tfvars`,
   `ansible/extra-vars/private-runtime.yml`.
4. Read-only OCI APIKey identity preflight
   (`oci iam region list --config-file "$HOME/.oci/config" --profile tradingchassis --auth api_key`).
5. `terraform init -backend-config=backend.hcl` then `terraform validate`.
6. `terraform plan -detailed-exitcode` to a saved plan.
7. Plan exit handling:
   - `0` no changes → skip APPLY.
   - `1` plan failure → STOP.
   - `2` changes → inspect JSON; STOP if any action includes `delete` (including replace); otherwise show the saved plan and require exact **APPLY**.
8. After APPLY: a follow-up no-change plan. STOP if that plan is not no-change.
9. `./tools/render-ansible-inventory` writes ignored `ansible/inventory/local.yml`
   (`instance_public_ip` → `ansible_host`, `ubuntu`, `~/.ssh/tradingchassis`).
   The renderer does **not** emit a Linux device path. Scratch uses
   **automatic scratch-device discovery**. `scratch_storage_device_path` is an
   optional explicit override only, not a Terraform handoff.
10. Bounded SSH wait, then `ansible/playbooks/site.yml`.
11. Exact blank-scratch detection: FORMAT is offered only when the site log
    contains `The scratch volume has no filesystem. Set scratch_storage_allow_format=true`.
    Unrelated Ansible failures do **not** offer FORMAT.
12. Exact **FORMAT** gate, then one rerun with `-e scratch_storage_allow_format=true`.
13. `ansible/playbooks/private-runtime-config.yml` with `-e @ansible/extra-vars/private-runtime.yml`.
14. Bounded Argo wait, then bounded workload wait.
15. No reboot during deploy.

### Human gates

| Gate | Exact input | When |
| --- | --- | --- |
| APPLY | `APPLY` | Saved plan has additive/change actions and is not destructive |
| FORMAT | `FORMAT` | Fail-closed blank scratch condition is proven |

Any other input STOP. Discovery alone does not authorize formatting.
Role defaults remain `scratch_storage_allow_format: false`.

Inventory example (non-live): [`ansible/inventory/example.yml`](../ansible/inventory/example.yml).

---

## Argo convergence contract

`tools/deploy-clean-room` and `tools/verify-clean-room` evaluate

```text
sudo microk8s kubectl -n argocd get applications -o json
```

PASS (exit 0) only when **every** Application in that list is:

```text
Synced / Healthy
```

WAIT (retry inside the existing bounded window: 60 attempts × 15 seconds) for a
structurally valid set that is not yet entirely Synced + Healthy, including:

- Missing
- Progressing
- Degraded
- OutOfSync
- Unknown
- Suspended
- unset

Malformed JSON, an empty Application list, or a shape that cannot be evaluated
FAIL (exit 2) immediately.

Do **not** describe Degraded as immediate fail-fast during initial
reconciliation. The bounded waiter is the safety boundary; no non-final state
can PASS.

Child Applications selected by `argocd/kustomization.yaml`:

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

Root Application destination and Application CRs use namespace **`argocd`**.

Completed Kubernetes Jobs (`phase=Succeeded`) are acceptable where structurally
expected. CrashLoopBackOff / ImagePullBackOff-class waiting is unhealthy FAIL.

---

## Verify / idempotency / reboot (`tools/verify-clean-room`)

```bash
./tools/verify-clean-room
```

Verification never repairs Terraform drift and never formats scratch
(`scratch_storage_allow_format=true` is never passed).

### Pre-reboot

- Terraform init + no-change plan (never apply). Drift STOP.
- Render inventory, bounded SSH.
- Scratch mount present at `/mnt/scratch`.
- Argo Synced + Healthy (same waiter as deploy).
- Workloads healthy (Succeeded Jobs allowed).
- `private-runtime-config.yml` second run `changed=0`.
- `site.yml` second run `changed=0` without format authorization.
- Capture `/proc/sys/kernel/random/boot_id`.

### Human gate

Exact **REBOOT**. Any other input STOP; acceptance is incomplete; reboot is not
issued.

### Post-reboot

- Bounded host down, then bounded SSH return.
- Boot ID **must change**.
- MicroK8s ready (`microk8s status --wait-ready`).
- Scratch mount valid.
- Argo converged (Synced + Healthy).
- Workloads valid.

PASS only when all required gates pass.

---

## Resumability

Resumability derives from actual infrastructure state:

- Terraform state and plan
- Ansible idempotency
- Kubernetes / Argo state

There is **no** custom persistent step-state file. Rerunning the canonical tools
inspects current state and continues according to their contracts (skip APPLY on
no-change, skip FORMAT when scratch is already formatted, refuse destroy/replace
during deploy, require `changed=0` during verify).

Session restart:

```text
cd $HOME/.../infrastructure
export PATH="$HOME/bin:$PATH"
source "$HOME/.venvs/tradingchassis-ansible/bin/activate"
reuse $HOME/.oci/config profile tradingchassis (APIKey)
reuse backend.hcl, terraform.tfvars, SSH keypair
recompute ssh_ingress_cidr if Cloud Shell public IP changed
rerun tools/deploy-clean-room or tools/verify-clean-room from actual state
```

---

## Final clean-room acceptance / destroy

Documentation only in this repository change. Do not destroy from CI or from an
implementation task.

There is no destroy automation tool. The operator uses Terraform against the
same backend after verify has PASSed.

Do **not** hard-code a resource count such as "13 destroys" as the acceptance
contract. Actual Terraform state and the saved plan are authoritative.

### Before destroy

1. `terraform -chdir=terraform init -backend-config=backend.hcl`
2. `terraform -chdir=terraform state list` — inspect current managed addresses.
3. Confirm this state does **not** own:
   - the OCI Vault
   - Vault secret values / secret objects
   - the Object Storage Terraform state bucket
   - other external foundation
4. Obtain a no-drift plan (`terraform plan -detailed-exitcode` → 0). STOP on drift.
5. Create a **saved** destroy plan, for example:
   `terraform -chdir=terraform plan -destroy -out=destroy.tfplan`
6. Inspect the actual plan (`terraform show destroy.tfplan` and/or `-json`).

Acceptance requirement:

- the destroy plan contains only disposable Terraform-owned resources
  (network, compute, scratch volume/attachment, instance-principal IAM);
- STOP if Vault, secret lifecycle, the state bucket, or other external
  foundation appears.

### Apply destroy and prove emptiness

1. Apply the saved destroy plan (`terraform apply destroy.tfplan`).
2. Prove Terraform state is empty (`terraform state list` prints nothing).
3. Run a **fresh** post-destroy plan (not the saved destroy plan).
4. Prove it is create/add-only (no leftover managed objects; a subsequent apply
   would create the disposable root again).
5. Prove external foundation survives: Vault ACTIVE, secret values untouched,
   state bucket still present with Versioning Enabled and NoPublicAccess.

---

## Ansible `site.yml` internals

Canonical playbook: `ansible/playbooks/site.yml`

Role order (source):

```text
host_baseline
scratch_storage
microk8s
argocd_bootstrap
  imports ansible_k8s_runtime → /opt/tradingchassis/ansible-kubernetes
```

`argocd_bootstrap` installs Argo CD with Helm timeout `10m` (Helm 3 duration) and
applies the root Application through `kubernetes.core` using that dedicated
venv. It copies repository-owned `requirements.txt` onto the managed node at
`/opt/tradingchassis/ansible-k8s-runtime/requirements.txt` before remote pip.
It does not pip-install into Ubuntu system Python.

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
   V2 installs tradingchassis-oci-microk8s-firewall.service to
   reconcile the owned contract after ufw.service, without a
   whole-table restore. The unit is PartOf=ufw.service and
   WantedBy=ufw.service so a later UFW restart or start re-runs
   the same helper. RequiredBy the MicroK8s snap units so a failed
   boot reconcile keeps kubelite/containerd from starting.
```

Do not flush iptables tables, disable UFW, delete `rules.v4`, delete the OCI
INPUT REJECT, or rewrite InstanceServices from a template. Do not install
`iptables-persistent` / `netfilter-persistent` as a second full-table
manager alongside UFW.

Quoted Oracle CLOUD_IMG comments in `iptables-save` output are parsed as a
single argv element so InstanceServices reconciliation does not fail.

MicroK8s owns Calico UFW allowances on `vxlan.calico` and `cali+`. Ansible
verifies that contract after readiness and does not rewrite it.

### What successful `site.yml` means

```text
host baseline contract asserted (Ubuntu 24, ARM64)
scratch filesystem validated/mounted at /mnt/scratch (when inputs correct)
scratch workload directories /mnt/scratch/dev and /mnt/scratch/prod present on the mount
MicroK8s installed (channel 1.29/stable) with required addons
host UFW baseline applied (incoming deny, outgoing allow, routed allow, SSH)
MicroK8s-owned Calico UFW allowances on vxlan.calico and cali+ verified after ready
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

Successful `site.yml` does **not** mean:

```text
all workloads are already Healthy
private runtime SecretProviderClass resources exist
scratch Kubernetes PVCs already consume /mnt/scratch
```

Those are later deploy/verify gates.

---

## OCI secrets readiness gate

Argo owns the Secrets Store CSI Driver and OCI provider via Application `oci-secrets`.
Do **not** manually install those components for the V2 path.

### Ordering contract

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

Do **not** dump SecretProviderClass `spec`, full YAML/JSON, or all annotations
as “safe metadata”. Serialized
`kubectl.kubernetes.io/last-applied-configuration` can contain private
deployment configuration such as `vaultId`.

---

## Private runtime configuration

Playbook: `ansible/playbooks/private-runtime-config.yml`
Role: `private_runtime_config`
Not part of `site.yml`. Vault secret **values** remain external/operator-managed.
Private runtime SPC ownership remains Ansible. OCI secrets provider remains Argo-owned.

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

### Expected materialization (active V2 contract)

```text
Secret/tradingchassis-runtime-config in namespace mlflow (key OCI_REGION)
SecretProviderClass/postgres-secret-bundle in namespace postgres
SecretProviderClass/mlflow-secret-bundle in namespace mlflow
SecretProviderClass/monitoring-secret-bundle in namespace monitoring
authType: instance
vaultId rendered from private_runtime_config_vault_id (not ${VAULT_ID})
```

Do **not** print `.data` values, `spec.parameters.vaultId`, or full SPC YAML/JSON.

---

## PostgreSQL, monitoring, scratch, secrets

Active overlays:

```text
apps/postgres/kustomization.yaml   → overlays/v2
apps/mlflow/kustomization.yaml     → overlays/v2
apps/monitoring/kustomization.yaml → overlays/v2
```

Active V2 overlays contain **no** Git-owned SecretProviderClass resources.

Normal PostgreSQL convergence must **not** depend on an artificial "hurry"
deadline. The `init-mlflow-postgres` Job mounts CSI `postgres-secret-bundle`,
keeps bounded Job retries (`backoffLimit` + `activeDeadlineSeconds`), and waits
with bounded `pg_isready` before idempotent DB init.

Monitoring uses Server-Side Apply (`ServerSideApply=true` on the Monitoring
Application only) so Prometheus Operator CRDs that exceed the 262144-byte
client-side last-applied annotation limit can reconcile.

Scratch formatting remains fail-closed and only behind the exact FORMAT gate.

```text
Terraform provisions the OCI scratch block volume (default size_in_gbs=150)
→ Ansible mounts it at /mnt/scratch and creates /mnt/scratch/dev and /mnt/scratch/prod
→ Argo Application scratch-storage owns StorageClass tradingchassis-scratch and static PVs
→ scratch-dev / scratch-prod PVCs bind deterministically via volumeName + claimRef
```

```text
hostPath static PVs (not local PersistentVolumes): single-node MicroK8s, no hostname affinity
dev path:  /mnt/scratch/dev
prod path: /mnt/scratch/prod
capacity:  70Gi + 70Gi Kubernetes accounting (= 140Gi aggregate)
backing:   Terraform OCI size_in_gbs=150 (OCI block-volume GB = 1024 MiB / GiB-equivalent)
headroom:  nominal ~10 Gi before filesystem overhead; PV capacity is NOT a quota
reclaim:   Retain (Kubernetes PV deletion must not imply cloud volume deletion)
fail-closed hostPath type Directory: missing subdirs after a failed remount refuse the volume
```

---

## Related documents

| Document | Role |
| --- | --- |
| This file | **Canonical** V2 clean-room operator runbook |
| [`RUNTIME_SPC_OWNERSHIP_CUTOVER.md`](RUNTIME_SPC_OWNERSHIP_CUTOVER.md) | Historical / in-place SPC ownership fallback — **not** the primary V2 path |
| [`VERSION_1_BASELINE.md`](../VERSION_1_BASELINE.md) | Historical V1 baseline |
| [`terraform/README.md`](../terraform/README.md) | Terraform ownership and cloud layer |
| [`ansible/README.md`](../ansible/README.md) | Ansible ownership and playbooks |
| [`argocd/README.md`](../argocd/README.md) | Argo CD applications and overlay transition notes |

# Terraform Foundation

## Purpose

Terraform manages OCI cloud infrastructure for the Version 2 reference implementation.

## Ownership

Terraform owns:

- network
- compute
- storage (cloud volume and attachment)
- IAM (instance principal Dynamic Group and least-privilege Vault secret-bundle policy)
- cloud-level outputs

Terraform does **not** own:

- host configuration
- MicroK8s
- Argo CD bootstrap
- long-lived Kubernetes resources
- Vault lifecycle or secret values

Ansible will own host configuration and bootstrap.
Argo CD owns long-lived Kubernetes desired state.

## Network ownership

Terraform owns the OCI network foundation (VCN, subnet, internet routing, compute NSG).

## Compute ownership

Terraform owns the OCI Ampere ARM reference compute instance.

## Scratch storage

Logical storage role: `scratch`.

OCI implementation: a dedicated Block Volume attached to the reference compute instance.

```text
Reference layout:
boot volume:    50 GB (OCI size_in_gbs; block-volume GB = 1024 MiB / GiB-equivalent)
scratch volume: 150 GB (same OCI size_in_gbs convention)
combined:       200 GB
```

Kubernetes scratch accounting (Argo-managed static PVs) uses `70Gi + 70Gi = 140Gi`
against the default 150 OCI-GB scratch volume, leaving nominal headroom before
filesystem overhead. PV capacity is not a filesystem quota.

This sizing reflects the OCI reference profile and is not a guarantee of current Free Tier eligibility or zero cost.
Current OCI Free Tier / Always Free eligibility must be verified against the target tenancy and current Oracle terms before live apply.
Where Always Free storage allotments apply, boot volumes and block volumes count together toward the combined allowance (commonly documented as 200 GB total). Always Free Block Volume resources are home-region constrained per current Oracle Free Tier documentation.

### Ownership

```text
Terraform → volume and attachment
Ansible → filesystem and mount
Argo CD → Kubernetes storage contract
```

Terraform guarantees:

- a scratch block volume exists
- it is attached to the reference compute instance
- resource and attachment identifiers are exposed

Terraform does **not** promise a host Linux device path for paravirtualized attachments.
Live OCI `oci_core_volume_attachment.device` is not a usable Ansible handoff.

Ansible guarantees:

- fail-closed host-side discovery of the unique eligible non-root whole disk
- the expected attached volume is validated on the host before destructive work
- destructive formatting is guarded explicitly
- the filesystem is mounted persistently at the platform scratch path

### Device identification

Hardcoded host device assumptions such as `/dev/oracleoci/oraclevds`, `/dev/sdb`, or `/dev/vdb` are not treated as a stable architecture contract.

Ansible owns scratch-device discovery on the host. Kernel names and udev by-id
links are re-evaluated each run and are not encoded as Terraform outputs.
Persistent host mounting uses the filesystem UUID rather than a transient device path.

Attachment type: `paravirtualized`.
This is the simplest supported attachment for the Ubuntu ARM A1 Flex reference host and avoids Terraform-managed iSCSI login configuration.

Performance: `vpus_per_gb = 0` (Lower Cost) for a predictable, cost-conscious reference profile.
In-transit encryption for the paravirtualized attachment is enabled. The compute instance must set top-level `is_pv_encryption_in_transit_enabled = true`. A nested `launch_options` block that only enables PV encryption in transit is rejected by OCI (`400-InvalidParameter`) unless NetworkType is also set; this pin does not use `launch_options`. Platform encryption at rest remains the OCI default without introducing Vault/KMS resources in this scope.

### Known V1 storage gap (closed in V2 Git manifests)

The V1 host scratch mount and Kubernetes hostpath PVCs were not explicitly bound to the same storage path.
V2 binds scratch PVCs to `/mnt/scratch/dev` and `/mnt/scratch/prod` via Argo-managed static hostPath PersistentVolumes (`apps/scratch/platform`). Host mount and PVC binding are operator-verified by `tools/deploy-clean-room` / `tools/verify-clean-room`.
This Terraform scope only provisions the cloud-side volume and attachment.

## Instance principal access

Terraform now owns:

```text
Dynamic Group membership for the reference compute instance
IAM permission for OCI Vault secret-bundle reads
```

The Dynamic Group matches only the Terraform-managed reference compute instance (`instance.id`).
The IAM policy is created in the tenancy and grants:

```text
read secret-bundles
in compartment id <oci_vault_compartment_id>
```

### Least privilege

```text
The reference instance can read secret bundles only in the configured secret compartment.
It does not receive Vault, key, secret-management, or broad tenancy permissions.
```

V1 resolves secrets by name inside SecretProviderClass manifests. Secret OCIDs are not present in this repository, so compartment-scoped `read secret-bundles` is the minimal practical policy for this migration stage.
Further restriction to individual `target.secret.id` values remains a later hardening option once secret OCIDs are managed as explicit inputs.

### External Vault

```text
The Vault and secret values remain externally managed at this migration stage.
```

`oci_vault_id` is an infrastructure reference for later CSI / Argo CD configuration, not a secret value.

### Later ownership

```text
Terraform → OCI identity and access
Ansible/Argo CD later → CSI/provider/bootstrap and declarative Kubernetes secret consumption
```

## Current managed scope

```text
VCN
subnet
internet routing
network security group
SSH ingress policy
outbound policy
Ampere A1 Flex compute instance
public IPv4 for SSH access
scratch Block Volume
scratch volume attachment
instance principal Dynamic Group
least-privilege Vault secret-bundle IAM policy
```

## Terraform cloud-layer status

The cloud-side Terraform root owns the disposable OCI foundation:

```text
network
compute
scratch block storage
instance principal IAM
```

Provider selection is reproducible through the tracked `terraform/.terraform.lock.hcl`
(`oracle/oci` `~> 8.26.0`). `.terraform/` remains local and gitignored.

Remote state uses the native OCI Object Storage backend with an externally
supplied bucket. The bucket, Vault lifecycle, and Vault secret values are
external foundation and are **not** owned by this root.

Canonical operator workflow (not ad-hoc manual Terraform as the primary path):
[`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](../docs/V2_CLEAN_ROOM_DEPLOYMENT.md)
(`tools/bootstrap-cloud-shell` → `tools/deploy-clean-room` → `tools/verify-clean-room`).
Cloud Shell uses APIKey / profile `tradingchassis`, user-local Terraform 1.15.x
(canonical 1.15.8), and operator-local `backend.hcl` / `terraform.tfvars`.

## Reference compute profile

```text
Shape: VM.Standard.A1.Flex (OCI Ampere A1)
OS image: Canonical Ubuntu 24.04 LTS (ARM64 / aarch64 via platform image lookup)
Default sizing: 4 OCPUs, 24 GB memory, 50 GB boot volume
```

CPU, memory, and boot volume size are Terraform inputs.
These defaults describe the V2 OCI ARM reference profile for a single-node MicroK8s host.
They are **not** a guarantee of Always Free or Free Tier eligibility.

Idle Always Free A1 instances may be subject to Oracle reclamation conditions documented in current Free Tier terms.

## Image selection trade-off

The configuration selects the latest compatible Ubuntu 24.04 platform image for `VM.Standard.A1.Flex` (sorted by creation time descending).
This favors current security updates over immutable image pinning.
Because platform images rotate, a later plan may select a newer image OCID and propose instance replacement unless the operator pins or otherwise controls image changes.

## Availability Domain strategy

The first availability domain returned for the compartment is used for this single-node reference instance.
The scratch Block Volume uses the compute instance availability domain so volume and instance remain attachment-compatible.
OCI documents that availability-domain list order can change; this deterministic first-element choice is acceptable for a non-HA reference host and is not a multi-AD design.

## Security boundary

```text
OCI network security and the future host firewall are separate defense layers.
```

SSH ingress remains restricted by `ssh_ingress_cidr` on the compute NSG.
Application NodePorts are not exposed by Terraform.
Private SSH keys must never be stored in Terraform configuration, tfvars committed to Git, or GitHub Actions.

## Operator prerequisites (cloud layer)

Before a live deploy, the operator machine needs:

```text
Terraform ~> 1.15.0 (Cloud Shell: tools/bootstrap-cloud-shell installs 1.15.8 under $HOME/bin; do not trust preinstall)
tracked terraform/.terraform.lock.hcl (OCI provider selection; do not hand-write hashes)
an externally pre-existing dedicated OCI Object Storage state bucket
bucket Versioning Enabled and NoPublicAccess (operational prerequisite)
operator-local backend.hcl (from backend.hcl.example) with auth = "APIKey"
OCI APIKey authentication for both the OCI backend and the OCI provider
  (Cloud Shell: $HOME/.oci/config profile tradingchassis)
local private inputs for required variables (never commit tfvars)
SSH public key content for instance metadata (ssh_public_key literal or TF_VAR_ssh_public_key)
```

Canonical Cloud Shell path: paste the public-key line into ignored `terraform.tfvars`,
or export `TF_VAR_ssh_public_key="$(cat "$HOME/.ssh/tradingchassis.pub")"`.
Do not use Terraform functions inside `.tfvars` files.
Canonical deployment sequence:
[`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](../docs/V2_CLEAN_ROOM_DEPLOYMENT.md).

## Not yet managed

```text
host filesystem and mount state
Vault lifecycle and secret values
Secrets Store CSI Driver
OCI CSI provider
SecretProviderClass / Kubernetes Secrets
host firewall
MicroK8s
Argo CD
Kubernetes PV/PVC/StorageClass
Ansible inventory generation (produced by tools/render-ansible-inventory during deploy)
```

## Validation

Static validation (no live OCI API calls, no credentials required for formatting and configuration checks):

```bash
terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

`terraform init -backend=false` is **CI / static validation mode only**.
It initializes providers without contacting the OCI state bucket.
That step may download the pinned OCI provider from the public Terraform Registry
and is networked but non-mutating validation only.

`terraform validate` does not evaluate `subnet_cidr` containment against concrete
CIDR values. That contract is covered by
`tests/unit/test_terraform_cidr_validation.sh` using an isolated no-provider fixture.

Operator deployment must **not** use `-backend=false`.

Data sources such as images and availability domains are not resolved by `terraform validate`.

## Execution model

```text
CI / static validation:
fmt / backend contract checks / init -backend=false / validate only

Operator deployment (canonical tools, not ad-hoc Terraform):
prepare ignored backend.hcl and terraform.tfvars
tools/bootstrap-cloud-shell
tools/deploy-clean-room
  (init -backend-config=backend.hcl, plan, APPLY gate, Ansible, Argo)
tools/verify-clean-room
```

Live `plan` / `apply` is intentionally outside automated CI.
Credentials are supplied by the execution environment during approved live
operations and are never committed to this repository.

## Remote state

### Architecture

```text
backend type:      native OCI Object Storage (backend "oci")
state bucket:      EXTERNAL prerequisite (not Terraform-managed)
bootstrap state:   NONE
configuration:     partial backend config via terraform/backend.hcl
isolation:         unique object key / path-like prefix per environment or fork
locking:           native OCI backend locking
```

Terraform cannot rely on its own remote state to bootstrap the storage location
for that same state. Therefore the state bucket is intentionally external.

Do **not** create the state bucket with this Terraform root.
Do **not** introduce a second bootstrap Terraform root or bootstrap state.

### Operator configuration categories

Keep these separate:

```text
Backend configuration (backend.hcl)
→ bucket
→ namespace
→ region          (region that hosts / accesses the state bucket)
→ key

Terraform deployment inputs (tfvars / TF_VAR_*)
→ oci_region      (provider deployment region; may match, but is distinct)
→ compartment
→ SSH key
→ Vault references
→ sizing and network inputs
```

Backend `region` is not automatically the provider `var.oci_region`.
Supply each explicitly even when the values happen to match.

### First-time operator init

The canonical operator path is `tools/deploy-clean-room`, which initializes the
native backend. Ad-hoc Terraform is not the primary Greenfield path.

Equivalent backend initialization (what the tool runs):

```bash
terraform init -backend-config=backend.hcl
```

Copy `backend.hcl.example` to ignored `backend.hcl` (bootstrap does this when
the file is absent). Commit only `backend.hcl.example`.

### Object key and fork isolation

OCI Object Storage uses object names / prefixes, not real filesystem directories.
A path-like key such as `tradingchassis/production/terraform.tfstate` is one
object name. Multiple independent states may share one bucket when each uses a
unique key/prefix and IAM allows it.

```text
Each independent Terraform environment or fork must use a unique state object key.
```

Reusing the same `bucket + namespace + key` for unrelated clusters causes them to
operate on the same Terraform state. Forks and independent deployments should
normally choose their own prefix, for example:

```text
tradingchassis/production/terraform.tfstate   # example only
tradingchassis/development/terraform.tfstate  # example only
my-fork/production/terraform.tfstate          # example only
```

Terraform workspaces are not used for environment isolation in this repository.
`workspace_key_prefix` is intentionally unset.

### Fail-closed initialization

A normal operator:

```bash
terraform init -backend-config=backend.hcl
```

initializes the configured remote OCI backend. If the bucket does not exist,
cannot be reached, or authentication/authorization is invalid, initialization
must fail. There is **no** documented operator fallback to local state and no
deployment use of `-backend=false`.

CI is the only approved `-backend=false` exception, and only for static validation.

### Bucket versioning

Enable Object Storage bucket versioning (`Enabled`) and `NoPublicAccess` on a
**dedicated** external state bucket before the first live init. Do not reuse an
arbitrary application or `data` bucket. `terraform init` itself does not verify
versioning. Bucket creation is an operator bootstrap action; see
[`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](../docs/V2_CLEAN_ROOM_DEPLOYMENT.md).

### State sensitivity and access

Terraform state can contain sensitive infrastructure data. Restrict Object
Storage access to the operator identities that need it. Exact IAM policy for the
bucket is owned outside this Terraform root because the bucket is external.

### Authentication boundary

```text
Terraform OCI provider authentication
Terraform OCI backend authentication
```

Both need valid OCI access, but they are distinct components. Provider
configuration does not automatically configure the backend. Canonical Cloud
Shell path: `auth = "APIKey"` and `config_file_profile = "tradingchassis"` in
both `backend.hcl` and provider variables. Do not use Cloud Shell
`instance_obo_user` for Terraform. SecurityToken remains a portable alternative
outside that Cloud Shell path.

### Greenfield V2 state

Greenfield V2 uses this native backend with an operator-chosen unique key.
Do not run `terraform init -migrate-state` on the Greenfield path.

Future relocation of bucket/namespace/region/key requires deliberate Terraform
backend reconfiguration/migration and is outside the Greenfield deploy path.

### Evidence status

```text
Native OCI backend declaration: implemented / statically validated
Partial backend configuration:  implemented / statically validated
CI backend isolation:           implemented / statically validated
Tracked provider lockfile:      implemented / statically validated
APIKey backend init:            live proven
State locking:                  native OCI backend capability
Bucket versioning:              external prerequisite / operator-verified when Enabled
```

CI never writes remote state. Live init/plan/apply/destroy stay with the operator
tools and the destroy-acceptance procedure in the clean-room runbook.

## Outputs used by Ansible

After apply, the operator handoff uses at least:

| Output | Ansible / operator use |
| --- | --- |
| `instance_public_ip` | inventory `ansible_host` |
| `scratch_volume_id` | diagnostics / correlation |
| `scratch_volume_attachment_id` | diagnostics / correlation |
| `scratch_volume_attachment_type` | diagnostics / correlation |

Scratch Linux device identity is not a Terraform output. Ansible performs
fail-closed host-side discovery. `scratch_storage_device_path` remains an
optional explicit override, not a required Terraform handoff.

Full clean-room sequence: [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](../docs/V2_CLEAN_ROOM_DEPLOYMENT.md).

## Provider lock file

`terraform/.terraform.lock.hcl` is tracked. It records the selected `oracle/oci`
provider under `~> 8.26.0` with hashes for the Terraform execution platforms
this repository actually uses:

```text
linux_amd64  GitHub Actions (ubuntu-24.04) and Linux amd64 control nodes
linux_arm64  OCI Cloud Shell (aarch64)
```

`.terraform/` remains local and gitignored. Do not hand-write provider hashes.
Regenerate with backend-disabled locking, for example:

```bash
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform providers lock -platform=linux_amd64 -platform=linux_arm64
```

`terraform init -backend=false` is **CI / static validation only**.
Operator deployment always initializes the native OCI backend.

## Multi-cloud

OCI is the first reference implementation.
Provider-neutral contracts will be introduced only when backed by a real second implementation need.

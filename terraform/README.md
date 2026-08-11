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
boot volume:    50 GB
scratch volume: 150 GB
combined:       200 GB
```

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
- the OCI-assigned attachment device path is exposed for Ansible

Ansible guarantees:

- the expected attached volume is validated on the host before destructive work
- destructive formatting is guarded explicitly
- the filesystem is mounted persistently at the platform scratch path

### Device identification

Hardcoded host device assumptions such as `/dev/oracleoci/oraclevds`, `/dev/sdb`, or `/dev/vdb` are not treated as a stable architecture contract.

The scratch attachment exposes its OCI-assigned device path for the later Ansible storage contract.
That value comes from the attachment resource attribute after apply and must still be validated by Ansible before formatting or mounting.
Persistent host mounting uses the filesystem UUID rather than the transient device path.

Attachment type: `paravirtualized`.
This is the simplest supported attachment for the Ubuntu ARM A1 Flex reference host and avoids Terraform-managed iSCSI login configuration.

Performance: `vpus_per_gb = 0` (Lower Cost) for a predictable, cost-conscious reference profile.
In-transit encryption for the paravirtualized attachment is enabled. Platform encryption at rest remains the OCI default without introducing Vault/KMS resources in this scope.

### Known V1 storage gap

The V1 host scratch mount and Kubernetes hostpath PVCs were not explicitly bound to the same storage path.
V2 will close that gap later in the Ansible and Argo CD storage contracts. This Terraform scope only provisions the cloud-side volume and attachment.

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

After this IAM scope, the planned cloud-side Terraform migration layer is substantially complete:

```text
network
compute
scratch block storage
instance principal IAM
```

This is **not** a claim that Terraform is production-ready or live-validated.

Still open before collaborative live apply:

```text
.terraform.lock.hcl (if still absent)
remote state
approved OCI authentication
plan/review/apply workflow
live provisioning validation
```

The next planned implementation area after this cloud-side layer is Ansible foundation, not an unrelated Terraform feature expansion.

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

Before `plan` / `apply`, the operator machine needs:

```text
Terraform ~> 1.15.0
OCI authentication supported by the Terraform OCI provider
local private inputs for required variables (never commit tfvars)
SSH public key material for instance metadata (ssh_public_key)
```

Canonical deployment sequence including Ansible handoff:
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
Ansible inventory generation (manual handoff; see clean-room runbook)
```

## Validation

Static validation (no live OCI API calls, no credentials required for formatting and configuration checks):

```bash
terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

`terraform init -backend=false` may download the pinned OCI provider from the public Terraform Registry. That step is networked but non-mutating validation only.
Data sources such as images and availability domains are not resolved by `terraform validate`.

## Execution model

```text
CI:
fmt / init -backend=false / validate only

Future approved operator workflow:
init
plan
review
apply
```

Live `plan` / `apply` is intentionally outside automated CI.
Remote state and authentication must still be decided before collaborative live provisioning.
Credentials are supplied by the execution environment during approved live operations and are never committed to this repository.

## State

The repository currently uses backend-disabled initialization for static validation only.

For the **initial single-operator clean-room validation**, Terraform state is
**local** unless the operator explicitly configures otherwise. Local state must
not be committed (see `.gitignore`) and should be backed up appropriately for
the proof environment.

A shared remote state backend remains a future team-operability improvement and
is not required by current source for the first solo clean-room proof. Remote
state must still be selected before collaborative long-lived provisioning.

## Outputs used by Ansible

After apply, the operator handoff uses at least:

| Output | Ansible / operator use |
| --- | --- |
| `instance_public_ip` | inventory `ansible_host` |
| `scratch_volume_device` | extra var `scratch_storage_device_path` |

Full clean-room sequence: [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](../docs/V2_CLEAN_ROOM_DEPLOYMENT.md).

## Provider lock file

`.terraform.lock.hcl` should be committed once it can be generated in a controlled environment. Fabricated lock hashes must not be committed.
Until a verified lock file is committed, provider selection remains constrained by `versions.tf` only and carries a reproducibility residual risk.

## Multi-cloud

OCI is the first reference implementation.
Provider-neutral contracts will be introduced only when backed by a real second implementation need.

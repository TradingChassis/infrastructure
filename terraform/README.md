# Terraform Foundation

## Purpose

Terraform manages OCI cloud infrastructure for the Version 2 reference implementation.

## Ownership

Terraform owns:

- network
- compute
- storage (cloud volume and attachment)
- IAM (not yet provisioned)
- cloud-level outputs

Terraform does **not** own:

- host configuration
- MicroK8s
- Argo CD bootstrap
- long-lived Kubernetes resources

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

Ansible will later guarantee:

- the expected attached volume is resolved safely on the host
- destructive formatting is guarded explicitly
- the filesystem is mounted persistently at the platform scratch path

### Device identification

Host device names are not treated as a stable infrastructure contract.
Do not rely on paths such as `/dev/oracleoci/oraclevds`, `/dev/sdb`, or `/dev/vdb` as Terraform outputs or architecture contracts.

Attachment type: `paravirtualized`.
This is the simplest supported attachment for the Ubuntu ARM A1 Flex reference host and avoids Terraform-managed iSCSI login configuration. Ansible may still need to confirm the attached volume identity before formatting or mounting.

Performance: `vpus_per_gb = 0` (Lower Cost) for a predictable, cost-conscious reference profile.
In-transit encryption for the paravirtualized attachment is enabled. Platform encryption at rest remains the OCI default without introducing Vault/KMS resources in this scope.

### Known V1 storage gap

The V1 host scratch mount and Kubernetes hostpath PVCs were not explicitly bound to the same storage path.
V2 will close that gap later in the Ansible and Argo CD storage contracts. This Terraform scope only provisions the cloud-side volume and attachment.

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
```

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

## Not yet managed

```text
host filesystem and mount state
IAM
Vault
host firewall
MicroK8s
Argo CD
Kubernetes PV/PVC/StorageClass
Ansible inventory generation
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
A shared remote state backend must be selected before collaborative live provisioning.
Local state must not be committed or treated as the team source of truth.

## Provider lock file

`.terraform.lock.hcl` should be committed once it can be generated in a controlled environment. Fabricated lock hashes must not be committed.
Until a verified lock file is committed, provider selection remains constrained by `versions.tf` only and carries a reproducibility residual risk.

## Multi-cloud

OCI is the first reference implementation.
Provider-neutral contracts will be introduced only when backed by a real second implementation need.

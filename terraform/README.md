# Terraform Foundation

## Purpose

Terraform manages OCI cloud infrastructure for the Version 2 reference implementation.

## Ownership

Terraform owns:

- network
- compute
- storage (not yet provisioned)
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

Current OCI Free Tier / Always Free eligibility must be verified against the target tenancy and current Oracle terms before live apply.
Official Oracle documentation currently presents differing A1 free-allowance figures across pages (for example Always Free resource notes versus Ampere getting-started notes). Operators must confirm the allowance that applies to their account type before provisioning.

Always Free storage allotments, where applicable, count boot volumes and block volumes together. Scratch block storage is intentionally deferred and must be sized with the boot volume in a later storage scope.

Idle Always Free A1 instances may be subject to Oracle reclamation conditions documented in current Free Tier terms.

## Image selection trade-off

The configuration selects the latest compatible Ubuntu 24.04 platform image for `VM.Standard.A1.Flex` (sorted by creation time descending).
This favors current security updates over immutable image pinning.
Because platform images rotate, a later plan may select a newer image OCID and propose instance replacement unless the operator pins or otherwise controls image changes.

## Availability Domain strategy

The first availability domain returned for the compartment is used for this single-node reference instance.
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
scratch block storage
IAM
Vault
host firewall
MicroK8s
Argo CD
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

## Multi-cloud

OCI is the first reference implementation.
Provider-neutral contracts will be introduced only when backed by a real second implementation need.

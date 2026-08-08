# Terraform Foundation

## Purpose

Terraform manages OCI cloud infrastructure for the Version 2 reference implementation.

## Ownership

Terraform owns:

- network
- compute (not yet provisioned)
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

Terraform now owns the OCI network foundation.

## Current network scope

```text
VCN
subnet
internet routing
network security group
SSH ingress policy
outbound policy
```

The public subnet enables direct SSH reachability for the single-node reference implementation.
Public subnet does not mean unrestricted ingress.

Instance access policy is owned by the compute Network Security Group.
The subnet uses an intentionally empty security list so the VCN default security list is not treated as the central policy.

## Not yet managed

```text
compute
block storage
IAM
Vault
host firewall
MicroK8s
Argo CD
```

Application NodePorts present in Version 1 manifests (`30007`, `32120`, `30090`, `30500`) are intentionally not opened in this network scope.
Application exposure remains a later access-policy decision.
Access is expected to continue via SSH local port forwarding until that decision is made.

## Security boundary

```text
OCI network security and the future host firewall are separate defense layers.
```

Broad outbound access is an explicit bootstrap/runtime requirement, not an implicit default.
SSH ingress is restricted by the `ssh_ingress_cidr` input and must not default to the entire Internet.

Credentials are supplied by the execution environment during approved live operations and are never committed to this repository.

## Validation

Static validation (no live OCI API calls, no credentials required for formatting and configuration checks):

```bash
terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate
```

`terraform init -backend=false` may download the pinned OCI provider from the public Terraform Registry. That step is networked but non-mutating validation only.

## State

The repository currently uses backend-disabled initialization for static validation only.
A shared remote state backend must be selected before collaborative live provisioning.
Local state must not be committed or treated as the team source of truth.

A later decision will choose an approved remote backend (for example OCI Object Storage or another approved backend). No remote backend is configured in this foundation scope.

## Provider lock file

`.terraform.lock.hcl` should be committed once it can be generated in a controlled environment (for example after a verified CI or approved local Terraform run). Fabricated lock hashes must not be committed.
Until a verified lock file is committed, provider selection remains constrained by `versions.tf` only and carries a reproducibility residual risk.

## Live execution

Live `plan` / `apply` is intentionally outside automated CI.

## Multi-cloud

OCI is the first reference implementation.
Provider-neutral contracts will be introduced only when backed by a real second implementation need.

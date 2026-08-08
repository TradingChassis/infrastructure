# Terraform Foundation

## Purpose

Terraform manages OCI cloud infrastructure for the Version 2 reference implementation.

This directory currently contains only the foundation (version pins, provider configuration, and input variables). It does **not** provision OCI resources yet.

## Ownership

Terraform owns:

- network
- compute
- storage
- IAM
- cloud-level outputs

Terraform does **not** own:

- host configuration
- MicroK8s
- Argo CD bootstrap
- long-lived Kubernetes resources

Ansible will own host configuration and bootstrap.
Argo CD owns long-lived Kubernetes desired state.

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

## Live execution

Live `plan` / `apply` is intentionally outside automated CI.

Credentials are supplied by the execution environment during approved live operations and are never committed to this repository.

## Multi-cloud

OCI is the first reference implementation.
Provider-neutral contracts will be introduced only when backed by a real second implementation need.

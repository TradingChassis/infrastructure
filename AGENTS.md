# Agent entry point

Verify first. Fix only if confirmed.

This file is the short cross-agent entry point for TradingChassis infrastructure work.

## Canonical rule

Follow [`.cursor/rules/safe-infrastructure-development.mdc`](.cursor/rules/safe-infrastructure-development.mdc) for the full safety and workflow rules.

## Language

- Communicate with the user in German.
- Keep all repository content in English.

## Hard limits

- Do not perform live OCI, Terraform, Ansible, Kubernetes, Helm, MicroK8s, host-network, firewall, storage, package, or service operations.
- Do not read or output real secrets, credentials, private keys, Terraform state, tfvars, kubeconfigs, or vault material.
- Repository guardrails are not a security boundary and do not prove sandbox isolation.

## Ownership (summary)

- Terraform owns OCI resources.
- Ansible owns host configuration, storage, MicroK8s, and initial Argo CD bootstrap.
- Argo CD owns long-lived Kubernetes resources.

## Safe wrappers

- `./tools/check-agent-safety` — local, read-only safety self-check
- `./tools/validate-safe` — local static validation wrapper

## Git workflow

- Never work directly on `main`.
- One logical change per branch and pull request.
- Commit or push only when the current prompt explicitly authorizes it.

# Agent entry point

Verify first. Fix only if confirmed.

This file is the short cross-agent entry point for TradingChassis infrastructure
work. It is not a second copy of the Cursor rules.

## Canonical rules

Durable project invariants:
[`.cursor/rules/safe-infrastructure-development.mdc`](.cursor/rules/safe-infrastructure-development.mdc)

Implementation tasks:
[`.cursor/rules/implementation-workflow.mdc`](.cursor/rules/implementation-workflow.mdc)

Independent reviews:
[`.cursor/rules/review-workflow.mdc`](.cursor/rules/review-workflow.mdc)

Human-facing workflow:
[`docs/AI_AGENT_WORKFLOW.md`](docs/AI_AGENT_WORKFLOW.md)

## Language

- Respond in the language explicitly requested by the current task or prompt.
- If no response language is specified, use the language of the user's current request.
- Keep repository content in English unless the task explicitly requires otherwise.

## Hard limits

- Do not perform live OCI, Terraform, Ansible, Kubernetes, Helm, MicroK8s, host-network, firewall, storage, package, or service operations.
- Do not read or output real secrets, credentials, private keys, Terraform state, tfvars, kubeconfigs, or vault material.
- Repository guardrails are not a security boundary and do not prove sandbox isolation.

## Ownership (summary)

- Terraform owns OCI resources.
- Ansible owns host configuration, storage, MicroK8s, and initial Argo CD bootstrap.
- Argo CD owns long-lived Kubernetes resources.

## Git authorization

- Never work directly on `main`.
- One logical change per branch and pull request.
- Commit, push, pull-request creation, and merge only when the current task explicitly authorizes that action.
- An implementation task is not permission to commit, push, or merge.

## Safe wrappers

- `./tools/check-agent-safety` — local, read-only safety self-check
- `./tools/validate-safe` — local static validation wrapper
- `./tools/check-sensitive-metadata` — operator/live metadata hygiene (not a credential scanner)

Credential scanning runs in CI via pinned Gitleaks. See
[`docs/REPOSITORY_SECURITY.md`](docs/REPOSITORY_SECURITY.md).

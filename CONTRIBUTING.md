# Contributing

Thank you for your interest in contributing!

This repository focuses on cloud infrastructure for trading research.
Contributions should preserve clarity, explicitness, and reproducibility.

## Design Principles

- GitOps-first for long-lived Kubernetes resources reconciled by Argo CD
- No secrets in Git (ever)
- Prefer declarative manifests for application state; Version 1 still includes imperative host bootstrap scripts under `scripts/`
- Keep changes minimal and documented
- Single source of truth for each owned resource
- Avoid ad-hoc live cluster mutations outside an explicit architecture decision
- Multi-arch native
- Minimal but production-grade

## Agent and safety workflow

Verify first. Fix only if confirmed.

- User-facing communication is in German; all repository content must remain in English.
- Never work directly on `main`. Use a feature branch and open one logical scope per pull request.
- Prefer Ask/Plan modes or manually reviewed execution for risky work.
- Agents must not perform live OCI, Terraform, Ansible, or Kubernetes operations.
- Use `./tools/check-agent-safety` and `./tools/validate-safe` for local static checks after reviewing wrapper contents when they change.
- Classify evidence honestly (`live validated`, `CI validated`, `statically validated`, `statically identified`, `not yet validated`, `intentional behavior`, `planned`).
- Changes to `.cursor/**`, `.cursorignore`, `AGENTS.md`, safety wrappers, or their tests require extra review and a dedicated scope.
- Repository guardrails (rules, allow/deny lists, ignore files, and Auto-review instructions) are best-effort steering. They are not a hard security boundary and do not replace OS sandboxing or human review.

## Workflow

1. Fork the repository
2. Create a feature branch
3. Commit small, logical changes
4. Open a pull request with a clear description

## Commit Style

Use clear commit messages:

- `feat: add monitoring overlay`
- `fix: correct SecretProviderClass parameters`
- `docs: update bootstrap instructions`

## Testing

Before submitting:

- Prefer local static validation with `./tools/validate-safe` when changing safety or shell tooling
- `kustomize build` must succeed for manifest changes
- YAML must be valid

# Contributing

Thank you for your interest in contributing!

This repository focuses on cloud infrastructure for trading research.
Contributions should preserve clarity, explicitness, and reproducibility.

## Design Principles

- GitOps-first
- No secrets in Git (ever)
- Everything must be declarative
- Keep changes minimal and documented
- Single source of truth
- No imperative workflows
- Multi-arch native
- Minimal but production-grade

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

- `kustomize build` must succeed
- YAML must be valid

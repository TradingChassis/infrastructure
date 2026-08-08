# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Cursor and agent safety foundation (canonical rule, IDE/CLI permissions, Bugbot guidance)
- Secret and index protection via `.cursorignore` and expanded `.gitignore` patterns
- Local static safety self-check and validation wrappers (`tools/check-agent-safety`, `tools/validate-safe`) with unit tests
- Agent workflow documentation entry points (`AGENTS.md`, CONTRIBUTING and README notes)

### Fixed

- Resolved ShellCheck findings in the agent safety tooling without weakening validation behavior

## [0.1.0] - 2026-07-30

First documented public baseline of the first-generation architecture (Bash bootstrap, MicroK8s, Argo CD, and GitOps-managed platform applications). “Version 1” names that architecture generation and is not a SemVer `v1.0.0` tag.

### Added

- Bash-based host and MicroK8s bootstrap (`scripts/`)
- Argo CD Application definitions (`argocd/`)
- PostgreSQL workload manifests
- MLflow workload manifests
- Monitoring stack (kube-prometheus-stack and pushgateway)
- Argo Workflows Helm configuration
- Scratch PVC definitions for `dev` and `prod`
- OCI Vault integration via Secrets Store CSI Driver and OCI provider manifests
- `.env`-driven runtime injection of Vault ID and region into Argo CD Applications
- Example environment file (`.env.example`)

### Documentation

- First-generation architecture baseline (`VERSION_1_BASELINE.md`)
- Ownership boundaries between external OCI, Bash bootstrap, and Argo CD
- External OCI prerequisites and known limitations
- Planned Version 2 direction (Terraform, Ansible, Argo CD, GitHub Actions)
- README clarifications for the hybrid Bash + GitOps operating model

### Changed

- Removed hardcoded OCI Vault identifiers from committed manifests (placeholders patched at bootstrap)
- Bootstrap validates required environment variables before runtime injection
- Updated Code of Conduct enforcement contact address

### Known limitations

Compact summary; see `VERSION_1_BASELINE.md` for details and evidence gaps:

- Bootstrap is not designed for safe repeated execution
- Host iptables filtering is removed during bootstrap; effective exposure depends on external OCI network controls
- Scratch host mount is not demonstrably bound to `microk8s-hostpath` PVCs
- Runtime Application patches create cluster state not fully represented in Git
- Canonical Git `repoURL` requires verification
- Terraform and Ansible are not part of this release

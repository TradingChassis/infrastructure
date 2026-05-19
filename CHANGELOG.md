# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog
and this project adheres to Semantic Versioning.

## [Unreleased]

### Added
- MicroK8s bootstrap automation
- Argo CD GitOps deployment
- OCI Vault integration via Secrets Store CSI Driver
- PostgreSQL, MLflow, Monitoring stack
- Scratch persistent storage model
- .env-driven cluster bootstrap configuration
- automatic injection of cloud-specific values into manifests
- example environment file for reproducible setup

### Changed
- removed hardcoded OCI Vault identifiers from manifests
- bootstrap process now validates required environment variables

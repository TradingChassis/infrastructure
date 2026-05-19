# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- MicroK8s bootstrap automation
- Argo CD GitOps deployment
- OCI Vault integration via Secrets Store CSI Driver
- PostgreSQL, MLflow, and monitoring stack
- Scratch persistent storage model
- .env-driven cluster bootstrap configuration
- Automatic injection of cloud-specific values into manifests
- Example environment file for reproducible setup

### Changed

- Removed hardcoded OCI Vault identifiers from manifests
- Bootstrap process now validates required environment variables

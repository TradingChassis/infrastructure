# Security Policy

## Supported Versions

Only the latest version on the `main` branch is actively maintained.

Older commits and historical states of the repository may not receive security updates or patches.

## Reporting a Vulnerability

If you discover a security vulnerability, please **do not open a public GitHub issue**.

Instead, report it responsibly via:

- GitHub Security Advisories
- Direct contact with the repository owner (if necessary)

When submitting a report, please include:

- A clear description of the vulnerability
- Steps to reproduce (if applicable)
- Potential impact and affected components
- Any suggested mitigation or fix

Valid reports will be acknowledged in a timely manner and handled through responsible disclosure.

## Security Principles

This project follows a defense-in-depth infrastructure model:

- No secrets are stored in Git repositories
- All sensitive configuration is managed through OCI Vault
- Secrets are mounted securely using the CSI Secrets Store driver
- Access is controlled through OCI IAM and Instance Principals
- GitOps is used as the single source of truth
- Infrastructure changes are fully declarative and auditable

Dependency and base image updates should be applied regularly.

## Security Scope

This repository provisions and manages:

- Kubernetes bootstrap and cluster lifecycle (MicroK8s)
- GitOps application delivery via Argo CD
- Cloud secrets integration and secure configuration injection
- Network exposure controls (SSH-only public access)
- Persistent and ephemeral storage configuration

It does **not** provide:

- Application-level business logic or financial execution systems
- Hardened multi-node production Kubernetes clusters
- Publicly exposed services

This infrastructure is intended for controlled research and experimentation environments.

## Network & Access Model

- The VM is publicly reachable only via SSH
- All Kubernetes service ports are blocked at the cloud firewall level
- Internal services are accessed exclusively through SSH port forwarding
- Outbound connectivity is permitted for package and image retrieval

This minimizes the public attack surface while preserving developer usability.

## Dependency & Image Security

- Base OS and Kubernetes components should be kept updated
- Container images should be sourced from trusted registries
- Helm charts and manifests should be reviewed for security implications
- Vulnerable dependencies should be upgraded promptly

## Responsible Usage

Users are responsible for:

- Proper OCI IAM configuration
- Secure handling of SSH keys and access credentials
- Monitoring disk usage and resource exhaustion
- Applying additional security hardening when required

This repository is provided as infrastructure automation and makes no guarantees regarding security compliance for regulated or production-critical workloads.

## Disclosure Policy

Please allow reasonable time for investigation and remediation before public disclosure of any reported vulnerabilities.

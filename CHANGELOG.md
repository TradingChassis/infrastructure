# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Configured Terraform to use the native OCI Object Storage backend with an externally supplied state bucket and environment-specific object key.
- Defined the OCI Cloud Shell operator workflow for Terraform authentication, remote-state initialization, and deterministic Terraform-to-Ansible handoff.
- Activated the V2 runtime overlays for PostgreSQL, MLflow, and Monitoring, removing the active V1 runtime-injection dependency and hardening PostgreSQL bootstrap against delayed secret availability.
- Made the OCI secrets bootstrap path deterministic by ordering the platform Application ahead of secret consumers and gating private runtime materialization on CSI/provider readiness.
- Cursor and agent safety foundation (canonical rule, IDE/CLI permissions, Bugbot guidance)
- Secret and index protection via `.cursorignore` and expanded `.gitignore` patterns
- Local static safety self-check and validation wrappers (`tools/check-agent-safety`, `tools/validate-safe`) with unit tests
- Agent workflow documentation entry points (`AGENTS.md`, CONTRIBUTING and README notes)
- GitHub Actions repository validation for agent safety checks, unit tests, safe static validation, and ShellCheck
- Added the Terraform foundation for OCI infrastructure ownership and static CI validation
- Added Terraform-managed OCI network infrastructure for the V2 reference implementation
- Added Terraform-managed OCI Ampere ARM compute provisioning for the V2 reference implementation
- Added Terraform-managed OCI scratch block storage and compute attachment for the V2 reference implementation
- Added Terraform-managed OCI instance principal access for least-privilege Vault secret retrieval
- Added the Ansible foundation and CI validation for V2 host configuration and bootstrap development
- Added an Ansible host-baseline role that validates the supported V2 host contract without reproducing unsafe V1 firewall behavior.
- Added guarded Ansible scratch filesystem and UUID-based persistent mounting for the Terraform-managed OCI scratch volume, including the attachment device handoff output.
- Added idempotent MicroK8s host configuration with the V1-required addons and replaced the V1 blanket firewall reset with an explicit UFW host policy.
- Added idempotent Ansible bootstrap for Argo CD and the GitOps root application without reproducing V1 CRD deletion or runtime patching.
- Added Argo CD ownership for the pinned Secrets Store CSI Driver and ARM64-compatible OCI Vault provider.
- Prepared separate V1-compatible and inactive V2 application overlays for the private runtime-configuration migration without changing active GitOps ownership.
- Added an explicit Ansible private runtime-configuration playbook that materializes the deployment configuration Secret and SecretProviderClass resources without activating the V2 application overlays.
- Documented the controlled V1-to-V2 runtime SecretProviderClass ownership handoff and rollback procedure.
- Added temporary Argo CD prune protection to the three active V1 SecretProviderClass resources in preparation for the controlled runtime ownership handoff.
- Added the canonical V2 clean-room deployment runbook and explicit Terraform-to-Ansible bootstrap handoff.
- Bound scratch Kubernetes workloads to the dedicated OCI-backed `/mnt/scratch` filesystem for V2 clean-room deployments.

### Fixed

- Replaced the invalid Terraform-provided scratch device-path handoff with fail-closed host-side Ansible device discovery after live OCI paravirtualized attachments returned no device path.
- Aligned the OCI compute launch option with encrypted paravirtualized scratch volume attachments after the first live V2 apply exposed the mismatch.
- Replaced an unsupported Terraform CIDR containment validation that blocked the first real clean-room plan.
- Aligned the OCI Cloud Shell operator workflow with live-proven API-key authentication, user-local Terraform 1.15.8 bootstrap, and explicit OCI CLI `--auth api_key` preflights.
- Documented and validated the external dedicated OCI state-bucket prerequisite (Versioning Enabled, NoPublicAccess) without moving bucket ownership into Terraform.
- Resolved ShellCheck findings in the agent safety tooling without weakening validation behavior
- Hardened SPC inspection guidance to avoid exposing private deployment configuration through serialized last-applied annotations.
- Normalized the OCI Ubuntu cloud-image unconditional IPv4 FORWARD REJECT so MicroK8s pod/service forwarding is not blocked while OCI InstanceServices and INPUT protection remain.
- Inserted a narrow MicroK8s pod-CIDR INPUT allow for the node-local kube-apiserver port before the retained OCI catch-all INPUT REJECT so kube-proxy DNAT traffic is not dropped.
- Inserted a narrow MicroK8s pod-CIDR INPUT allow for the node-local kubelet port before the retained OCI catch-all INPUT REJECT so metrics-server scraping is not dropped.
- Reconcile the normalized OCI / MicroK8s nft-compatible host firewall at boot after UFW initializes, because persistent `rules.v4` survived reboot while runtime iptables-nft did not.
- Rebuild the owned INPUT prefix so required ACCEPT rules exist before the OCI catch-all REJECT is installed, retrigger that oneshot after `ufw.service` restarts or starts (`PartOf=` and `WantedBy=ufw.service`), and keep MicroK8s containerd/kubelite from starting when boot reconciliation fails (`RequiredBy`).
- Parse quoted OCI iptables-save comment arguments as a single argv element so runtime InstanceServices reconciliation does not fail on Oracle CLOUD_IMG comments. The first live apply reconstructed the empty InstanceServices chain; the second converge then failed because iptables-nft rendered implicit UDP matches as explicit `-m udp`.
- Compare OCI iptables rules with a narrow semantic key so `-p udp --dport 123` and `-p udp -m udp --dport 123` are treated as the same owned rule. After reboot without Ansible, OCI runtime reconciliation was unchanged; remaining post-reboot `changed=4` was Calico UFW comment re-ownership, not nft drift.
- Stopped Ansible from declaratively owning the four MicroK8s Calico UFW interface allowances (`vxlan.calico` and `cali+` in/out). MicroK8s writes those rules when it detects enabled UFW; Ansible verifies the functional persisted contract after MicroK8s is ready and does not require a particular comment. Live MicroK8s boot journals showed `daemon-kubelite` creating the four rules; the following role converge reported `changed=4` only because Ansible rewrote the same rules with TradingChassis comments. Post-fix Ansible `changed=0` is not yet live-proven.

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

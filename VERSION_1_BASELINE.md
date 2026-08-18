# Version 1 Baseline

This document is the **historical** record of the first-generation architecture
(“Version 1”) as evidenced by the repository contents at that generation.

Version 2 is now the **active architecture**. The canonical operator path is
[`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](docs/V2_CLEAN_ROOM_DEPLOYMENT.md). This
file does not describe how to deploy Version 2 and is not an executable
Version 1 fallback.

The project uses pre-1.0 semantic versioning until an intentional release cut.
“Version 1” names the architecture generation; it is **not** the same as a
SemVer tag such as `v1.0.0`. See `CHANGELOG.md` for published release history.

It is documentation only. It does **not** claim that this architecture generation is production-ready, fully declarative, or fully automated.

## Purpose

Version 1 provides a single-node research and backtesting platform baseline on an existing Ubuntu host. It:

- bootstraps an existing Ubuntu VM (host preparation is not provisioned by this repository),
- installs MicroK8s from snap,
- prepares host scratch storage on an expected OCI block device path,
- installs Secrets Store CSI and the OCI provider for Vault-backed secrets,
- installs Argo CD and registers Application resources,
- manages selected Kubernetes workloads through Argo CD from manifests in this repository.

Version 1 solves “bring up a usable single-node GitOps cluster on a prepared OCI VM,” not “provision OCI infrastructure as code.”

## Scope Boundaries

- Version 1 is a **single-node** platform baseline.
- It is **not** presented as a highly available or enterprise production platform.
- Version 2 was the planned follow-on to improve reproducibility and clear ownership without introducing unnecessary distributed-system complexity. That generation is now the active architecture; see `docs/V2_CLEAN_ROOM_DEPLOYMENT.md`.
- SemVer release tags track repository releases; they do not by themselves redefine the architecture generation names used in this document.

## Version 1 Ownership

| Area | Version 1 owner |
| --- | --- |
| Existing OCI resources (VM, network, block volume, Vault, IAM) | Manual / external |
| Host bootstrap (iptables reset) | Bash scripts (`scripts/01-system.sh`) |
| MicroK8s installation and addons | Bash scripts (`scripts/02-microk8s.sh`) |
| Host filesystem and mounts | Bash scripts (`scripts/03-storage.sh`) |
| Secrets Store CSI Driver install | Bash scripts (`scripts/04-secrets.sh`) |
| OCI CSI provider manifests apply | Bash scripts (`scripts/04-secrets.sh` → `infrastructure/oci-provider/`) |
| Prometheus Operator CRD bootstrap (subset) | Bash scripts (`scripts/05-monitoring.sh`) |
| Initial Argo CD installation and Helm-in-Kustomize config | Bash scripts (`scripts/06-argocd.sh`) |
| Argo CD Application registration | Bash scripts (`scripts/07-apps.sh` → `argocd/`) |
| Kubernetes application desired state under `apps/` | Argo CD |
| Runtime Vault ID and region injection | Bash scripts patching live Argo CD Applications (`scripts/08-runtime.sh`, `scripts/inject-runtime-values.sh`) |
| Validation | Manual |

## External Prerequisites

These prerequisites are required by Version 1 and are **not** provisioned by this repository:

- an existing Ubuntu VM with `sudo` privileges,
- `snap` available on the host,
- outbound network access for snap packages, Helm charts, container images, and remote install manifests,
- an OCI block device available at `/dev/oracleoci/oraclevds`,
- an OCI Vault containing the secret names referenced by `SecretProviderClass` manifests (see `README.md`),
- OCI IAM configured so the instance principal can read those Vault secrets,
- local environment variables from `.env` (see `.env.example`), loaded into the shell before bootstrap,
- a Git repository reachable at the `repoURL` configured in `argocd/*.yaml` (identity verification still required; see unresolved questions).

## Bootstrap Flow

Entry point: `scripts/bootstrap-cluster.sh` (run from the repository root after loading `.env`).

Order:

1. `scripts/01-system.sh` — flush host iptables rules and set default ACCEPT policies
2. `scripts/02-microk8s.sh` — install MicroK8s (`1.29/stable`) and enable `dns`, `hostpath-storage`, `metrics-server`, `helm`
3. `scripts/03-storage.sh` — validate, optionally format, and mount `/dev/oracleoci/oraclevds` at `/mnt/scratch`
4. `scripts/04-secrets.sh` — install Secrets Store CSI Driver (Helm chart version `1.4.8`) and apply `infrastructure/oci-provider/`
5. `scripts/05-monitoring.sh` — delete/create a subset of Prometheus Operator CRDs from a pinned remote tag
6. `scripts/06-argocd.sh` — install Argo CD from a pinned remote manifest tag and enable `--enable-helm` in Argo CD Kustomize build options
7. `scripts/07-apps.sh` — apply Application manifests from `argocd/`
8. `scripts/08-runtime.sh` → `scripts/inject-runtime-values.sh` — patch selected Applications with runtime Vault and region values

After bootstrap, Argo CD reconciles workload manifests from Git (`apps/` paths referenced by `argocd/*.yaml`), not from uncommitted local files.

For operational detail, NodePorts, secret names, and post-install checks, see `README.md`.

## What Argo CD Manages in Version 1

Argo CD Applications (registered by bootstrap) reconcile:

| Application | Source path | Destination namespace |
| --- | --- | --- |
| `postgres` | `apps/postgres` | `postgres` |
| `mlflow` | `apps/mlflow` | `mlflow` |
| `monitoring` | `apps/monitoring` | `monitoring` |
| `argo` | `apps/argo` | `argo` |
| `scratch-dev` | `apps/scratch/dev` | `dev` |
| `scratch-prod` | `apps/scratch/prod` | `prod` |

Current Application manifests use automated sync with prune and self-heal enabled.

Argo CD itself, the CSI Helm release, and the OCI provider DaemonSet applied during bootstrap are **not** managed as GitOps Applications in Version 1.

## Known Limitations

Documented from repository evidence:

- Bootstrap is intended for a fresh VM and is **not** designed for safe repeated execution (`README.md`).
- The bootstrap removes host-level iptables filtering (flush and default ACCEPT policies) and therefore relies on external OCI network controls whose effective configuration is not managed or validated by this repository (`scripts/01-system.sh`).
- Storage initialization can format `/dev/oracleoci/oraclevds` when no filesystem is detected (`scripts/03-storage.sh`).
- `/mnt/scratch` is mounted on the host, but scratch PVCs use `storageClassName: microk8s-hostpath` and do **not** demonstrably reference `/mnt/scratch` (`apps/scratch/*/pvc.yaml`, `README.md`).
- Runtime injection patches live Argo CD Application objects; resulting Vault and region configuration is not fully represented in committed Git manifests (`scripts/inject-runtime-values.sh`, placeholders such as `vaultId: ${VAULT_ID}` originally in `apps/*/secrets.yaml`; the V1 resource now resides under the transitional V1 overlay at `apps/*/overlays/v1/secrets.yaml`). Vault secret **values** are out of band; IAM instance-principal policies required for Vault access are not defined in this repository.
- Selected services expose NodePorts in manifests (see `README.md`). Host reachability of those ports depends on external OCI network controls, which this repository does not configure or verify.
- Images and external dependencies are not consistently pinned by immutable digest (for example floating tags such as `postgres:14` and `...-provider:latest`).
- Automated CI validation workflows are not present under `.github/workflows/`.
- Real OCI networking and IAM configuration live outside this repository and cannot be validated from Git alone.
- Prometheus Operator CRDs have overlapping ownership: bootstrap script creation and Helm `includeCRDs` in `apps/monitoring`.

## Unresolved Questions (Evidence Gaps)

These points are **not** confirmed as facts from the repository alone:

1. **Canonical repository URL** — Application manifests set `repoURL` to `https://github.com/TradingChassis/infrastructure`, while the local Git remote observed during baseline preparation may differ. The intended canonical remote must be verified before treating GitOps sync as authoritative.
2. **Argo CD install namespace** — bootstrap waits and patches resources in namespace `default`, while upstream Argo CD install manifests commonly target `argocd`. Live cluster behavior requires verification.
3. **Scratch storage intent** — whether `/mnt/scratch` is meant to back scratch PVCs, or whether hostpath on the root volume is intentional, requires an explicit architecture decision.
4. **Actual OCI NSG/Security List rules** — SECURITY and README describe an SSH-oriented access model; cloud firewall contents are not encoded in this repository.
5. **Terraform state backend and recovery targets** — not defined in Version 1; required before Version 2 OCI automation.

## Version 2 Direction (historical)

This section records the original Version 2 direction from the Version 1
baseline. Version 2 has since become the active architecture; the canonical
operator path is `docs/V2_CLEAN_ROOM_DEPLOYMENT.md`.

Version 1 achieved a usable single-node research cluster with GitOps-managed applications, but ownership was split across manual OCI setup, imperative Bash bootstrap, live Application patches, and Argo CD. That split limited reproducibility, idempotency, and auditability. Version 2 was needed to give each resource one clear owner and to move OCI and host lifecycle into reviewable automation.

Ownership boundaries planned from this baseline (not implemented by Version 1):

- **Terraform** owns OCI infrastructure (network, compute, storage attachments, IAM references, Vault references as appropriate).
- **Ansible** owns host configuration, filesystems/mounts, MicroK8s, and the one-time Argo CD / root Application bootstrap.
- **Argo CD** owns long-lived Kubernetes platform and application resources.
- **GitHub Actions** validates Terraform, Ansible, shell, and Kubernetes configuration; it does not own runtime infrastructure.
- Every resource should have **one** clear owner.

Version 2 was intended to preserve single-node clarity where appropriate and avoid unnecessary multi-node complexity unless requirements change. That single-node limit remains in the active architecture.

## Related Documents

- `README.md` — current operator overview
- [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](docs/V2_CLEAN_ROOM_DEPLOYMENT.md) — canonical Version 2 operator runbook
- `CHANGELOG.md` — change history and release tracking status
- `SECURITY.md` — vulnerability reporting and security policy
- `CONTRIBUTING.md` — contribution workflow

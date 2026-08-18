# TradingChassis Infrastructure GitOps Kubernetes Stack (MicroK8s + Argo CD)

Single-node infrastructure for quantitative research and backtesting on OCI.

## Architecture generations

| Generation | Role today | Path |
| --- | --- | --- |
| **Version 2** | **Current target** — Terraform → Ansible → Argo CD clean-room deploy | [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](docs/V2_CLEAN_ROOM_DEPLOYMENT.md) |
| **Version 1** | Historical record — not an executable repository path | [`VERSION_1_BASELINE.md`](VERSION_1_BASELINE.md) |

V2 ownership:

```text
Terraform  → OCI network, compute, scratch volume, instance-principal IAM
Ansible    → host baseline, scratch filesystem, MicroK8s, Argo CD bootstrap,
             optional private runtime materialization
Argo CD    → long-lived Kubernetes desired state (apps + oci-secrets)
GitHub Actions → static validation only
```

**Start here for a fresh environment:** [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](docs/V2_CLEAN_ROOM_DEPLOYMENT.md).

That runbook is the canonical operator contract:

```text
tools/bootstrap-cloud-shell → tools/deploy-clean-room → tools/verify-clean-room
```

GitHub Actions static validation is not live rebuild proof. Historical V1
executable paths are retired.

The historical in-place SecretProviderClass handoff document
([`docs/RUNTIME_SPC_OWNERSHIP_CUTOVER.md`](docs/RUNTIME_SPC_OWNERSHIP_CUTOVER.md))
is a fallback procedure, not the primary V2 path.

## What This Repository Provides

- Terraform-managed OCI reference infrastructure (network, compute, scratch storage, IAM)
- Ansible-managed host bootstrap (baseline, scratch mount, MicroK8s, Argo CD)
- GitOps-driven application reconciliation from manifests in this repository
- OCI Vault-backed secret delivery through Secrets Store CSI + OCI provider
- Predefined workloads: PostgreSQL, MLflow, monitoring stack, Argo Workflows, and scratch PVC overlays

## Architecture Overview

### Version 2 path (target)

See [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](docs/V2_CLEAN_ROOM_DEPLOYMENT.md) for the
canonical operator sequence (`tools/bootstrap-cloud-shell` →
`tools/deploy-clean-room` → `tools/verify-clean-room`).

### Version 1 (historical record only)

Version 1 Bash bootstrap and runtime-injection scripts are retired from this
repository. The historical generation is recorded in
[`VERSION_1_BASELINE.md`](VERSION_1_BASELINE.md). It is not an executable
deployment path.

Canonical operator automation:

```text
tools/bootstrap-cloud-shell → tools/deploy-clean-room → tools/verify-clean-room
```

### GitOps application layer (`apps/` and `argocd/`)

Argo CD reconciles component manifests and Helm-based Kustomizations from:

```text
apps/
argocd/
```

## Repository Layout

```text
.
├── apps/                  # Component manifests and Kustomize overlays
│   ├── argo/              # Argo Workflows Helm chart config
│   ├── mlflow/            # MLflow deployment + service + secrets bundle
│   ├── monitoring/        # kube-prometheus-stack Helm config + pushgateway
│   ├── postgres/          # PostgreSQL deployment/pvc/service + DB init job
│   └── scratch/           # scratch PVC overlays for dev/prod
├── argocd/                # Argo CD Application definitions
├── VERSION_1_BASELINE.md  # Version 1 ownership, limits, and V2 direction
├── CONTRIBUTING.md
├── SECURITY.md
└── README.md
```

## Prerequisites

- Ubuntu VM with sudo privileges
- `snap` available (used to install MicroK8s)
- Outbound network access from the VM to pull:
  - snap packages
  - Helm charts
  - container images
  - remote CRD/manifests (Prometheus Operator and Argo CD install URLs)
- OCI block device available at `/dev/oracleoci/oraclevds`
- OCI Vault containing all required secret names (see [Required OCI Vault secrets](#required-oci-vault-secrets))
- OCI IAM configured so the instance principal can read those vault secrets

## Configuration

Copy and edit environment variables:

```bash
cp .env.example .env
```

Load values into the current shell before bootstrap:

```bash
set -a
source .env
set +a
```

### Environment variables

| Variable | Required | Purpose | Used by |
| --- | --- | --- | --- |
| `VAULT_ID` | Yes | OCI Vault OCID used when materializing SecretProviderClass resources | `.env.example`, Ansible `private_runtime_config` extra-vars |
| `OCI_REGION` | Yes | Region value stored in `tradingchassis-runtime-config` / `OCI_REGION` for MLflow | `.env.example`, Ansible `private_runtime_config` extra-vars |

## Required OCI Vault Secrets

The following secret names are referenced directly by `SecretProviderClass` manifests and must exist in OCI Vault before bootstrap.

| Secret name | Used by | Purpose / expected value type | Source contract |
| --- | --- | --- | --- |
| `postgresdb-naming` | PostgreSQL | PostgreSQL database name (string) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `postgres-user` | PostgreSQL | PostgreSQL username (string) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `postgres-password` | PostgreSQL | PostgreSQL password (secret string) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `mlflowdb-naming` | PostgreSQL init job | MLflow database name in PostgreSQL (string) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `mlflow-user` | PostgreSQL init job | MLflow DB user (string) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `mlflow-password` | PostgreSQL init job | MLflow DB user password (secret string) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `mlflow-db-uri` | MLflow | Full backend store URI (secret string/URI) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `grafana-login-user` | Monitoring / Grafana | Grafana admin username (string) | `ansible/roles/private_runtime_config/defaults/main.yml` |
| `grafana-login-password` | Monitoring / Grafana | Grafana admin password (secret string) | `ansible/roles/private_runtime_config/defaults/main.yml` |

Do not commit secret values to Git.

### OCI Instance Principal and IAM note

All `SecretProviderClass` resources in this repository use `authType: instance`. The OCI provider DaemonSet also sets `OCI_RESOURCE_PRINCIPAL_VERSION`, indicating instance principal authentication.

This repository does not include OCI IAM policy text. You must configure OCI IAM policies so the instance principal can read the required vault secrets.

## V1 historical record

For **new V2 deployments**, use the canonical clean-room runbook:

```text
docs/V2_CLEAN_ROOM_DEPLOYMENT.md
```

Canonical operator automation:

```text
tools/bootstrap-cloud-shell → tools/deploy-clean-room → tools/verify-clean-room
```

The historical Version 1 Bash bootstrap is retired from this repository. See
[`VERSION_1_BASELINE.md`](VERSION_1_BASELINE.md) for that generation's
ownership and limits. It is not an executable fallback path.

## GitOps Source of Truth

After bootstrap, Argo CD reconciles from the `repoURL`, `targetRevision`, and `path` in `argocd/*.yaml`, not from uncommitted local files.

Current repository values in all Argo CD Application manifests:

- `repoURL`: `https://github.com/TradingChassis/infrastructure`
- `targetRevision`: `main`

If you operate from a fork or a different repository, update `argocd/*.yaml` before relying on Argo CD reconciliation.

Also verify `repoURL` matches the repository you intend to deploy in your environment.

## Deployed Applications and Services

### Argo CD Applications

| Application | Source path | Destination namespace | Purpose |
| --- | --- | --- | --- |
| `postgres` | `apps/postgres` | `postgres` | PostgreSQL backend and MLflow DB init job |
| `mlflow` | `apps/mlflow` | `mlflow` | MLflow tracking server |
| `monitoring` | `apps/monitoring` | `monitoring` | kube-prometheus-stack + pushgateway |
| `argo` | `apps/argo` | `argo` | Argo Workflows |
| `scratch-storage` | `apps/scratch/platform` | `kube-system` (cluster-scoped) | Scratch StorageClass + static PVs for `/mnt/scratch` |
| `scratch-dev` | `apps/scratch/dev` | `dev` | Scratch PVC overlay for dev namespace |
| `scratch-prod` | `apps/scratch/prod` | `prod` | Scratch PVC overlay for prod namespace |
| `oci-secrets` | Oracle chart / Argo Helm values | `kube-system` | Secrets Store CSI Driver + OCI provider |

### NodePort services configured in manifests

| Component | NodePort | Source |
| --- | --- | --- |
| Grafana | `30007` | `apps/monitoring/base/helm-values.yaml` |
| Argo Workflows server | `32120` | `apps/argo/helm-values.yaml` |
| Prometheus | `30090` | `apps/monitoring/base/helm-values.yaml` |
| MLflow | `30500` | `apps/mlflow/base/service.yaml` |

Access is typically done through SSH local port forwarding. Cloud firewall exposure is configured outside this repository, so verify your OCI NSG/Security List settings.

### Argo CD UI access (debugging)

**V2 (Ansible bootstrap):** Argo CD and Application CRs live in namespace `argocd`
(`ansible/roles/argocd_bootstrap`, `argocd/*.yaml`).

**V1 (historical Bash bootstrap):** Application objects were commonly managed in
namespace `default`. See [`VERSION_1_BASELINE.md`](VERSION_1_BASELINE.md).

Check where `argocd-server` service exists:

```bash
sudo microk8s kubectl get svc -A | rg argocd-server
```

V2 port-forward example:

```bash
sudo microk8s kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Historical V1 example if the server is still in `default`:

```bash
sudo microk8s kubectl -n default port-forward svc/argocd-server 8080:443
```

Open <https://localhost:8080> while the port-forward is active.

## Scratch Storage Model

### V2 contract

```text
Terraform → OCI scratch block volume (default 150 GB) + attachment
Ansible   → mount at /mnt/scratch; create /mnt/scratch/dev and /mnt/scratch/prod
Argo CD   → StorageClass tradingchassis-scratch + static hostPath PVs + namespace PVCs
```

- Application `scratch-storage` owns cluster-scoped `StorageClass`/`PersistentVolume` objects under `apps/scratch/platform`
- Applications `scratch-dev` / `scratch-prod` own namespaced `scratch-pvc` claims only
- PVCs use `storageClassName: tradingchassis-scratch` with deterministic `volumeName` binding
- Requests are `70Gi` + `70Gi` accounting capacity with headroom on the shared filesystem (not a quota)
- PostgreSQL remains on `microk8s-hostpath` and is intentionally out of this contract

### V1 historical note

Legacy V1 Bash storage bootstrap mounted `/mnt/scratch` while scratch PVCs used `microk8s-hostpath`. That gap is closed in the V2 Git manifests above. Operator verification of the mount and PVC binding is part of the canonical clean-room tools, not a hardcoded host device path.

## Post-Install Verification

Run these checks after bootstrap:

```bash
sudo microk8s status
sudo microk8s kubectl get applications -A
sudo microk8s kubectl get pods -A
sudo microk8s kubectl get svc -A
sudo microk8s kubectl get pvc -A
```

What to verify:

- MicroK8s reports ready status
- Argo CD `Application` resources exist for all six apps listed above
- Pods are created in namespaces: `default`, `postgres`, `mlflow`, `monitoring`, `argo`, `dev`, `prod`
- Expected NodePorts are present (`30007`, `32120`, `30090`, `30500`)
- PVCs exist for `postgres-pvc` and `scratch-pvc` (dev/prod)

## Common Operations and Reset Notes

### Apply changes after bootstrap

1. Edit manifests under `apps/` or `argocd/`
2. Commit and push to the repository/branch referenced by Argo CD Applications
3. Argo CD reconciles automatically (`automated.prune=true`, `selfHeal=true`)

### Full reset (destructive)

```bash
sudo snap remove microk8s --purge
sudo rm -rf /var/snap/microk8s/
sudo rm -rf ~/.kube/
```

After reset, also review manually:

- `/etc/fstab` UUID entries for `/mnt/scratch` (Ansible owns persistent mounting; kernel names such as `/dev/oracleoci/oraclevds` are not a stable contract)
- whether `/mnt/scratch` should be unmounted/cleaned
- whether attached block volume data should be preserved or re-formatted

## Development and Validation

From `CONTRIBUTING.md`:

- `kustomize build` should succeed
- YAML should be valid

Repository-specific build examples:

```bash
kustomize build apps/postgres
kustomize build apps/mlflow
kustomize build --enable-helm apps/monitoring
kustomize build --enable-helm apps/argo
kustomize build apps/scratch/dev
kustomize build apps/scratch/prod
```

`--enable-helm` is required for components that use `helmCharts` in Kustomization.

## Security Notes

- No secrets are stored in Git
- Secret retrieval is done via OCI Vault + CSI provider
- Instance principal authentication is expected by current manifests
- Public network exposure rules are configured in OCI, not in this repository
- CI Security validation scans for credential leaks and operator/live metadata hygiene; see [`docs/REPOSITORY_SECURITY.md`](docs/REPOSITORY_SECURITY.md)

For vulnerability reporting and security policy, see `SECURITY.md`.

## Out of Scope / Limitations

- Multi-node Kubernetes production setups
- Managed Kubernetes providers
- Public service exposure configuration
- Application business logic and trade execution systems
- Vault lifecycle and Vault secret **values** (referenced by Terraform / consumed via CSI; not provisioned as secret contents here)

Additional Version 1 limitations and evidence gaps are listed in [`VERSION_1_BASELINE.md`](VERSION_1_BASELINE.md).
The V2 clean-room operator procedure is [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](docs/V2_CLEAN_ROOM_DEPLOYMENT.md).

## AI-Assisted Development

This repository includes Cursor and agent guardrails for AI-assisted work. Start at [`AGENTS.md`](AGENTS.md). The human-facing workflow is [`docs/AI_AGENT_WORKFLOW.md`](docs/AI_AGENT_WORKFLOW.md). These guardrails are an additional protection layer; they do not replace OS sandboxing, operating-system permissions, manual confirmation, or Git review.

## Additional Documentation

- [`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](docs/V2_CLEAN_ROOM_DEPLOYMENT.md) — **canonical V2 clean-room operator runbook**
- [`docs/REPOSITORY_SECURITY.md`](docs/REPOSITORY_SECURITY.md) — repository security CI and metadata hygiene
- [`docs/RUNTIME_SPC_OWNERSHIP_CUTOVER.md`](docs/RUNTIME_SPC_OWNERSHIP_CUTOVER.md) — historical in-place SPC handoff (fallback only)
- `terraform/README.md` / `ansible/README.md` / `argocd/README.md` — layer ownership
- `VERSION_1_BASELINE.md` for Version 1 ownership, limitations, and Version 2 direction
- `AGENTS.md` for the cross-agent safety entry point
- [`docs/AI_AGENT_WORKFLOW.md`](docs/AI_AGENT_WORKFLOW.md) for the Cursor/AI-assisted implementation and review workflow
- `CONTRIBUTING.md` for contribution workflow
- `SECURITY.md` for vulnerability reporting and security model
- `CHANGELOG.md` for tracked changes

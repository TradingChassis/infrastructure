# TradingChassis Infrastructure GitOps Kubernetes Stack (MicroK8s + Argo CD)

Declarative infrastructure for quantitative research and backtesting on a single OCI VM.

This repository bootstraps a single-node MicroK8s cluster and then manages workloads through Argo CD Applications.

## What This Repository Provides

- Bootstrap automation for MicroK8s, Argo CD, CSI secrets integration, and baseline workloads
- GitOps-driven application reconciliation from manifests in this repository
- OCI Vault-backed secret delivery through Secrets Store CSI + OCI provider
- Predefined workloads: PostgreSQL, MLflow, monitoring stack, Argo Workflows, and scratch PVC overlays

## Architecture Overview

### Host bootstrap layer (`scripts/`)

`scripts/bootstrap-cluster.sh` runs these stages in order:

1. `01-system.sh`: flushes host iptables rules and sets ACCEPT policies
2. `02-microk8s.sh`: installs MicroK8s (`1.29/stable`) via snap and enables addons
3. `03-storage.sh`: validates/formats/mounts `/dev/oracleoci/oraclevds` at `/mnt/scratch`
4. `04-secrets.sh`: installs Secrets Store CSI Driver and OCI provider manifests
5. `05-monitoring.sh`: installs Prometheus Operator CRDs
6. `06-argocd.sh`: installs Argo CD and enables `--enable-helm` in Argo CD Kustomize build options
7. `07-apps.sh`: applies all Argo CD Application manifests from `argocd/`
8. `08-runtime.sh`: injects runtime values (vault and region patching)

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
├── infrastructure/
│   └── oci-provider/      # OCI CSI provider DaemonSet/RBAC
├── scripts/               # Bootstrap and runtime-injection scripts
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
| `VAULT_ID` | Yes | OCI Vault OCID used in `SecretProviderClass` patches | `.env.example`, `scripts/inject-runtime-values.sh` |
| `OCI_REGION` | Yes | Region value injected as `AWS_DEFAULT_REGION` into MLflow deployment patch | `.env.example`, `scripts/inject-runtime-values.sh` |
| `ARGO_NS` | No (default: `default`) | Namespace where Argo CD `Application` resources are patched | `scripts/inject-runtime-values.sh` |

## Required OCI Vault Secrets

The following secret names are referenced directly by `SecretProviderClass` manifests and must exist in OCI Vault before bootstrap.

| Secret name | Used by | Purpose / expected value type | Source manifest |
| --- | --- | --- | --- |
| `postgresdb-naming` | PostgreSQL | PostgreSQL database name (string) | `apps/postgres/secrets.yaml` |
| `postgres-user` | PostgreSQL | PostgreSQL username (string) | `apps/postgres/secrets.yaml` |
| `postgres-password` | PostgreSQL | PostgreSQL password (secret string) | `apps/postgres/secrets.yaml` |
| `mlflowdb-naming` | PostgreSQL init job | MLflow database name in PostgreSQL (string) | `apps/postgres/secrets.yaml` |
| `mlflow-user` | PostgreSQL init job | MLflow DB user (string) | `apps/postgres/secrets.yaml` |
| `mlflow-password` | PostgreSQL init job | MLflow DB user password (secret string) | `apps/postgres/secrets.yaml` |
| `mlflow-db-uri` | MLflow | Full backend store URI (secret string/URI) | `apps/mlflow/secrets.yaml` |
| `grafana-login-user` | Monitoring / Grafana | Grafana admin username (string) | `apps/monitoring/secrets.yaml` |
| `grafana-login-password` | Monitoring / Grafana | Grafana admin password (secret string) | `apps/monitoring/secrets.yaml` |

Do not commit secret values to Git.

### OCI Instance Principal and IAM note

All `SecretProviderClass` resources in this repository use `authType: instance`. The OCI provider DaemonSet also sets `OCI_RESOURCE_PRINCIPAL_VERSION`, indicating instance principal authentication.

This repository does not include OCI IAM policy text. You must configure OCI IAM policies so the instance principal can read the required vault secrets.

## Bootstrap / Installation

> Bootstrap is intended for a fresh VM.
> Re-running on an existing cluster is not supported by this repository flow.

Run:

```bash
chmod +x scripts/*
./scripts/bootstrap-cluster.sh
```

Important operational behavior during bootstrap:

- `01-system.sh` flushes iptables and sets default ACCEPT policies
- `03-storage.sh` may format `/dev/oracleoci/oraclevds` if it has no filesystem
- `03-storage.sh` appends an `/etc/fstab` mount entry for the scratch device
- `07-apps.sh` waits only for Argo CD `Application` objects `postgres` and `mlflow` to exist (not all applications to become healthy)

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
| `scratch-dev` | `apps/scratch/dev` | `dev` | Scratch PVC overlay for dev namespace |
| `scratch-prod` | `apps/scratch/prod` | `prod` | Scratch PVC overlay for prod namespace |

### NodePort services configured in manifests

| Component | NodePort | Source |
| --- | --- | --- |
| Grafana | `30007` | `apps/monitoring/helm-values.yaml` |
| Argo Workflows server | `32120` | `apps/argo/helm-values.yaml` |
| Prometheus | `30090` | `apps/monitoring/helm-values.yaml` |
| MLflow | `30500` | `apps/mlflow/service.yaml` |

Access is typically done through SSH local port forwarding. Cloud firewall exposure is configured outside this repository, so verify your OCI NSG/Security List settings.

### Argo CD UI access (debugging)

This repository installs Argo CD during bootstrap and manages `Application` objects in namespace `default`.

Check where `argocd-server` service exists:

```bash
sudo microk8s kubectl get svc -A | rg argocd-server
```

If it is in `default`, port-forward locally:

```bash
sudo microk8s kubectl -n default port-forward svc/argocd-server 8080:443
```

Open <https://localhost:8080> while the port-forward is active.

## Scratch Storage Model

### What the repository currently does

- `scripts/03-storage.sh` mounts OCI block storage at `/mnt/scratch` and creates `/mnt/scratch/data`
- `apps/scratch/dev/pvc.yaml` and `apps/scratch/prod/pvc.yaml` create `scratch-pvc` claims in namespaces `dev` and `prod`
- Both scratch PVCs use `storageClassName: microk8s-hostpath` with `142.5Gi` requests
- This repository does not define a `PersistentVolume` object for scratch; only PVCs are defined

### Important distinction

The repository mounts `/mnt/scratch` on the host, but scratch PVC manifests use the MicroK8s hostpath storage class and do not explicitly reference `/mnt/scratch`.

Maintainer confirmation recommended: verify whether this is the intended storage architecture for scratch workloads in your environment.

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

- `/etc/fstab` entries added for `/dev/oracleoci/oraclevds`
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

For vulnerability reporting and security policy, see `SECURITY.md`.

## Out of Scope / Limitations

- Multi-node Kubernetes production setups
- Managed Kubernetes providers
- Public service exposure configuration
- Application business logic and trade execution systems

## Additional Documentation

- `CONTRIBUTING.md` for contribution workflow
- `SECURITY.md` for vulnerability reporting and security model
- `CHANGELOG.md` for tracked changes

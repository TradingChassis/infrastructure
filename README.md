# TradingChassis Infrastructure GitOps Kubernetes Stack (MicroK8s + Argo CD)

![License](https://img.shields.io/badge/license-MIT-green)

Declarative infrastructure for quantitative research and backtesting on a single OCI VM.

This repository bootstraps a single-node MicroK8s cluster and hands over ongoing operations to Argo CD. After the initial setup, workloads are managed from Git manifests in this repository.

## What This Project Is

This repo provides the infrastructure layer for a quant research platform, with a focus on reproducibility and explicit operational boundaries.

It combines:

- MicroK8s for Kubernetes on one host
- Argo CD for GitOps-based application lifecycle management
- OCI Vault integration for secret delivery
- A split storage model for system data and research artifacts
- Predefined workload manifests for core research services

## What Problem It Solves

Small research environments often accumulate:

- Manual Kubernetes changes that are hard to audit
- Secrets spread across scripts, manifests, and local files
- Drift between expected and actual cluster state
- Overly complex multi-node setups for single-node needs

This stack addresses those issues with:

- GitOps-first cluster lifecycle management
- Declarative application definitions in Git
- OCI Vault-backed secret injection via CSI
- Clear storage boundaries (boot volume vs. scratch volume)

## Core Capabilities

- One-shot bootstrap for host prerequisites and base cluster setup
- GitOps-managed workloads through Argo CD `Application` resources
- Runtime patching of vault and region values from environment variables
- Built-in workloads for PostgreSQL, MLflow, monitoring, Argo Workflows, and scratch PVCs
- SSH-forwarded access model with NodePort services not exposed publicly

## Architecture Overview

### Host Layer (Bootstrap Phase)

Installed once by `scripts/bootstrap-cluster.sh`:

- MicroK8s
- Secrets Store CSI Driver
- OCI Secrets Store Provider ([custom multi-arch image](https://github.com/TradingChassis/oci-secrets-store-csi-driver-provider/pkgs/container/oci-secrets-store-csi-driver-provider))
- Argo CD
- Scratch block volume formatting and mounting

### Cluster Layer (GitOps Managed)

Managed through Argo CD from repository manifests:

- PostgreSQL (MLflow metadata backend)
- MLflow
- Prometheus + Grafana (via Helm chart)
- Argo Workflows (via Helm chart)
- Scratch PersistentVolumeClaim overlays

Primary declarative sources:

```text
apps/
argocd/
```

## Repository Structure

```text
.
├── apps/                  # Workload manifests and Helm values
│   ├── argo/
│   ├── mlflow/
│   ├── monitoring/
│   ├── postgres/
│   └── scratch/
├── argocd/                # Argo CD Application resources
├── infrastructure/        # Infrastructure components (OCI provider manifests)
│   └── oci-provider/
├── scripts/               # Bootstrap and runtime-injection scripts
├── CONTRIBUTING.md
├── SECURITY.md
└── README.md
```

## Prerequisites

- Ubuntu VM
- Attached block volume for scratch storage at `/dev/oracleoci/oraclevds`
- OCI Instance Principal configured on the VM
- OCI Vault created with required secrets
- Repository cloned on the target VM

## Installation and Setup

### 1) Configure environment values

```bash
cp .env.example .env
```

Set values in `.env`:

```env
VAULT_ID=ocid1.vault.oc1.eu-frankfurt-1.xxxxx
OCI_REGION=eu-frankfurt-1
```

Load the variables:

```bash
set -a
source .env
set +a
```

### 2) Run bootstrap (fresh VM only)

> Bootstrap is intended as a one-shot process.
> Re-running on an existing cluster is not supported.
> For a clean rerun, use [Full reset](#full-reset) first.

```bash
chmod +x scripts/*
./scripts/bootstrap-cluster.sh
```

Bootstrap sequence:

1. Host preparation and iptables reset
2. MicroK8s installation and base addons
3. Scratch disk formatting/mounting
4. CSI driver and OCI provider installation
5. Monitoring CRDs installation
6. Argo CD installation and configuration
7. Argo `Application` registration
8. Runtime value injection (vault ID / OCI region)

## Usage Model

After bootstrap, update manifests in Git and let Argo CD reconcile.

1. Edit YAML or Helm values under `apps/<component>/`
2. Commit and push changes
3. Argo CD syncs desired state automatically

The intended workflow is declarative and Git-driven; avoid manual imperative drift where possible.

## Service Access

Services use NodePort internally, while OCI network rules keep them private:

- SSH (port 22) is the only externally exposed port
- Service NodePorts are blocked externally
- Access happens through SSH local forwarding

Example SSH config:

```bash
Host vps
    HostName <IP>
    User ubuntu
    IdentityFile ~/.ssh/<key>
    LocalForward 30007 localhost:30007   # Grafana
    LocalForward 32120 localhost:32120   # Argo Workflows
    LocalForward 30090 localhost:30090   # Prometheus
    LocalForward 30500 localhost:30500   # MLflow
```

## Configuration Notes

### OCI secrets integration (required)

- Secrets are stored in OCI Vault (not in Git)
- Secret names must match references in manifests
- Secrets are mounted through `SecretProviderClass` resources
- Authentication uses OCI Instance Principals

### Runtime value injection

`scripts/inject-runtime-values.sh` patches Argo CD applications with:

- `VAULT_ID` for relevant `SecretProviderClass` objects
- `OCI_REGION` as `AWS_DEFAULT_REGION` for the MLflow deployment

If you change app names, deployment names, or secret class names, review this script.

## Storage Model

### Boot volume (VM root disk)

- Stores OS and Kubernetes system data
- Stores PostgreSQL data used by MLflow metadata
- Typically sized to minimal OCI boot requirements

### Scratch block volume (`/mnt/scratch`)

- Dedicated for data-heavy workloads (backtesting data, artifacts, intermediates)
- Mounted and prepared during bootstrap
- Exposed to workloads through PVC manifests in `apps/scratch/`
- Single-node hostPath-backed behavior; not a multi-node storage model

### Reuse scratch data on a new VM

On old VM:

```bash
sudo microk8s kubectl delete namespace scratch
sudo microk8s kubectl delete pv scratch-pv
sudo umount /mnt/scratch/
```

Then detach the volume and attach it to the new VM with the same device path, run bootstrap, and verify PV/PVC naming alignment.

## Monitoring Persistence Notes

Prometheus is configured with local ephemeral storage by default:

- No dedicated PV configured for Prometheus metrics
- Metrics are lost on pod restart or node reboot

Check disk usage regularly:

```bash
df -h /
sudo du -h --max-depth=1 /var/snap/microk8s/common/var/
```

## Security Model

- No secrets committed to Git
- OCI firewall controls (NSGs/Security Lists) with SSH-only public ingress
- Internal service access through SSH forwarding
- Declarative Git history for infrastructure changes

For vulnerability reporting and policy details, see `SECURITY.md`.

## Project Status

### Operational

- MicroK8s bootstrap
- Argo CD GitOps layer
- OCI secrets integration
- PostgreSQL
- Scratch storage model

### Experimental

- Monitoring stack tuning
- Argo Workflows pipelines
- Higher-level research workflows

## Intended Audience and Scope

Good fit for:

- Quant research and backtesting infrastructure
- GitOps experimentation on a single node
- Reproducible self-managed environment setups

Out of scope:

- Multi-node production clusters
- Managed Kubernetes platforms
- Publicly exposed application services

## Additional Documentation

- `CONTRIBUTING.md` for contribution workflow and quality expectations
- `SECURITY.md` for vulnerability reporting and security scope
- `CHANGELOG.md` for tracked repository changes

## Full Reset

Use this when you need to recreate the cluster from scratch.

```bash
sudo snap remove microk8s --purge
sudo rm -rf /var/snap/microk8s/
sudo rm -rf ~/.kube/
```

# TradingChassis Infrastructure GitOps Kubernetes Stack (MicroK8s + Argo CD)

![License](https://img.shields.io/badge/license-MIT-green)

Declarative GitOps-based infrastructure stack for quantitative research and backtesting.

Provisions and manages a single-node Kubernetes cluster on Oracle Cloud Infrastructure (OCI) using MicroK8s and Argo CD. All workloads are managed declaratively via GitOps after a one-time bootstrap.

Designed for reproducible research infrastructure with explicit storage, secret management, and operational boundaries.

## What is this?

This repository defines a fully declarative infrastructure layer for a quantitative trading research platform.

It bootstraps:

- A single-node MicroK8s Kubernetes cluster
- GitOps management via Argo CD
- Integrated experiment tracking, monitoring, orchestration
- Explicit local storage model
- OCI-native secret integration

After bootstrap, all cluster state is managed through Git via Argo CD.

No imperative Kubernetes workflows are required.

## What does it solve?

Research infrastructure often suffers from:

- Manual Kubernetes management
- Secret sprawl
- Mixed imperative and declarative workflows
- Poor reproducibility
- Overengineered multi-node setups for small research workloads

This stack provides:

- GitOps-first cluster lifecycle
- Strict secret isolation via OCI Vault
- Explicit storage boundaries (boot vs scratch)
- Fully declarative application management
- Minimal single-node production-grade design

It enables structured research infrastructure without managed Kubernetes complexity.

## Architecture Overview

The system is divided into two clear layers.

### Host Layer (Bootstrap Phase)

Installed once via bootstrap script:

- MicroK8s
- Secrets Store CSI Driver
- OCI Secrets Store Provider [custom multi-arch image](https://github.com/TradingChassis/oci-secrets-store-csi-driver-provider/pkgs/container/oci-secrets-store-csi-driver-provider)
- Argo CD
- Scratch Block Volume formatting and mounting

### Cluster Layer (GitOps Managed)

Managed exclusively via Argo CD:

- PostgreSQL (MLflow metadata)
- MLflow
- Prometheus + Grafana
- Argo Workflows
- Scratch PersistentVolume

All workloads are defined declaratively in:

```
apps/
argocd/
```

## Core Stack

- [MicroK8s](https://microk8s.io) (Kubernetes distribution)
- [Argo CD](https://argo-cd.readthedocs.io) (GitOps continuous delivery)
- [PostgreSQL](https://www.postgresql.org) (metadata & experiment storage)
- [MLflow](https://mlflow.org) (experiment tracking & model registry)
- [Prometheus](https://prometheus.io) + [Grafana](https://grafana.com) (monitoring & observability)
- [Argo Workflows](https://argoproj.github.io/workflows) (batch & pipeline execution)
- [Oracle Cloud Infrastructure](https://cloud.oracle.com) (compute, networking, secrets, storage)

## Repository Structure

```
.
├── apps/
│   ├── argo/
│   ├── mlflow/
│   ├── monitoring/
│   ├── postgres/
│   └── scratch/
├── argocd/
├── infrastructure/
│   └── oci-provider/
├── scripts/
├── CONTRIBUTING.md
└── README.md
```

## Quickstart (Fresh VM)

### Requirements

- Ubuntu VM
- Attached Block Volume for Scratch (`/dev/oracleoci/oraclevds`)
- OCI Instance Principal configured
- Repository cloned onto the VM
- OCI Vault with predefined secrets

### Environment Configuration

Create environment file:

```bash
cp .env.example .env
```

Configure:

```env
VAULT_ID=ocid1.vault.oc1.eu-frankfurt-1.xxxxx
OCI_REGION=eu-frankfurt-1
```

Load environment:

```bash
set -a
source .env
set +a
```

### Bootstrap the Cluster

> ⚠ Bootstrap is one-shot only.
> Run on a fresh VM or perform a [full reset](#full-reset).
> Re-running on an existing cluster is not supported.
> All subsequent changes must occur via GitOps.

```bash
chmod +x scripts/*
./scripts/bootstrap-cluster.sh
```

Installs:

- MicroK8s
- CSI Driver
- OCI Provider
- Argo CD

Deploys:

- PostgreSQL
- MLflow
- Monitoring
- Argo Workflows
- Scratch PV/PVC

## Service Access Model

Kubernetes services are exposed internally as NodePorts.

OCI network configuration:

- Only SSH (port 22) allowed externally
- All service ports blocked externally
- Access exclusively via SSH local port forwarding

Example SSH configuration:

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

This enables development access while preventing public exposure.

## Storage Model

Explicit separation between system storage and workload storage.

### Boot Volume (VM Root Disk)

- ~47 GB (minimum OCI size)
- Hosts:

  - Operating system
  - Kubernetes system data
  - PostgreSQL database

MLflow metadata persists in local PostgreSQL backed by boot volume.

### Scratch Block Volume

- 153 GB (≈142.5 GiB)
- Mounted at:

```
/mnt/scratch
```

Intended for:

- Backtesting data
- Research artifacts
- Large intermediate datasets

Exposed via PersistentVolume / PersistentVolumeClaim.

⚠ Single-node only (hostPath-based).

### Reusing Scratch Storage

Old VM:

```bash
sudo microk8s kubectl delete namespace scratch
sudo microk8s kubectl delete pv scratch-pv
sudo umount /mnt/scratch/
```

Detach volume.

New VM:

1. Attach volume with same device name
2. Run bootstrap
3. Ensure PV/PVC names match
4. Data reused automatically

### Full Reset

```bash
sudo snap remove microk8s --purge
sudo rm -rf /var/snap/microk8s/
sudo rm -rf ~/.kube/
```

## OCI Secrets Integration (Required)

All sensitive configuration is stored in OCI Vault.

Requirements:

- OCI Vault must exist
- Secrets must be created in advance
- Secret names must match Helm/YAML references

Secrets retrieved using:

- Secrets Store CSI Driver
- OCI Provider (custom multi-arch image)
- Instance Principal authentication

Secrets defined via `SecretProviderClass`.

No secrets stored in Git.

## Monitoring & Persistence Model

Prometheus runs with ephemeral local storage by default.

- Metrics stored inside pod filesystem
- No PersistentVolume configured
- Data lost on pod restart or node reboot

Intended for lightweight research environments.

### Storage Monitoring

Because metrics are local:

```bash
df -h /
sudo du -h --max-depth=1 /var/snap/microk8s/common/var/
```

Used to track disk usage and prevent exhaustion.

## Why Oracle Cloud Infrastructure?

OCI selected primarily for ARM free tier:

- 4 vCPU ARM VM
- 24 GB RAM
- ~200 GB free storage

Suitable for:

- Single-node Kubernetes research clusters
- Persistent external storage
- Zero-cost experimentation

Boot volume kept minimal; scratch volume handles data-heavy workloads.

## Updating the Platform

1. Modify YAML / Helm values in `apps/<component>/`
2. Commit & push
3. Argo CD auto-syncs

No manual `kubectl` required.

## Security Model

- No secrets in Git
- Public VM with OCI firewall (NSGs / Security Lists)
- Only SSH exposed
- All service ports closed externally
- Egress allowed
- Secrets in OCI Vault

## Design Principles

- GitOps-first
- Single source of truth
- Declarative workflows only
- Multi-arch native
- Minimal but production-grade

## Project Status

**Operational**

- MicroK8s bootstrap
- Argo CD GitOps layer
- OCI secrets integration
- PostgreSQL
- Scratch storage model

**Experimental**

- Monitoring stack
- Argo Workflows pipelines
- Higher-level research workflows

## Who is this for?

- Quant research & backtesting
- GitOps Kubernetes experimentation
- Reproducible infrastructure setups

Not intended for multi-node production clusters or managed Kubernetes platforms.

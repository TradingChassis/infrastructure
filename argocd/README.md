# Argo CD GitOps Applications

## Ownership

Argo CD owns all long-lived Kubernetes desired state managed from this directory.
The root Application (`root-app.yaml`) is applied once by Ansible bootstrap and
subsequently manages child Applications via the Kustomization.

## Application overlay transition

Workload Applications for `postgres`, `mlflow`, and `monitoring` keep their Argo
CD paths at `apps/<app>`. Those entry points are shims that still render the
**V1-compatible overlays**.

```text
apps/<app>/kustomization.yaml  → overlays/v1   (active)
apps/<app>/overlays/v2         → prepared only (inactive)
```

The active V1 overlays retain SecretProviderClass placeholders with
`vaultId: ${VAULT_ID}` so the existing V1 runtime injection scripts continue to
have valid patch targets.

The prepared V2 overlays intentionally omit SecretProviderClass resources.
Private deployment configuration (`VAULT_ID`, `OCI_REGION`) stays outside the
public repository. An explicit opt-in Ansible playbook
(`ansible/playbooks/private-runtime-config.yml`, role `private_runtime_config`)
is prepared to materialize those objects later. That playbook is **not** part
of `site.yml` and is **not** executed automatically.

Prepared-state semantics:

```text
Argo CD actively owns the V1 SecretProviderClass resources today.
The Ansible playbook exists but is not run by default.
Therefore no active dual ownership exists.
```

Do **not** execute the private runtime-configuration playbook while Argo CD is
still reconciling those V1 SecretProviderClass resources, except as part of the
separately defined and controlled ownership handoff. At no steady-state point
may Argo CD and Ansible both be authoritative for the same SecretProviderClass
resources.

Primary V2 fresh deployment path:

```text
docs/V2_CLEAN_ROOM_DEPLOYMENT.md
```

Historical in-place cutover sequencing (fallback only):

```text
docs/RUNTIME_SPC_OWNERSHIP_CUTOVER.md
```

No live cutover has occurred; active GitOps paths still resolve to
`overlays/v1`, and V1 runtime injection remains usable.

MLflow V2 prepares `AWS_DEFAULT_REGION` via
`secretKeyRef` to `tradingchassis-runtime-config` / `OCI_REGION`. Because Secret
references are namespace-scoped and the MLflow Deployment runs in `mlflow`, the
private runtime-configuration role is prepared to create
`tradingchassis-runtime-config` in the `mlflow` namespace during the controlled
handoff (not during routine V1 operation).

## Scratch storage platform

```text
Application scratch-storage → apps/scratch/platform
  StorageClass tradingchassis-scratch
  PersistentVolume scratch-dev-pv  → hostPath /mnt/scratch/dev
  PersistentVolume scratch-prod-pv → hostPath /mnt/scratch/prod

Application scratch-dev  → apps/scratch/dev  (PVC scratch-pvc)
Application scratch-prod → apps/scratch/prod (PVC scratch-pvc)
```

Static hostPath PVs are used for the single-node MicroK8s reference host.
`persistentVolumeReclaimPolicy: Retain` keeps Kubernetes object deletion from
implying destruction of the OCI-backed host filesystem contents.
This binding is implemented in Git and awaits live clean-room validation.

## OCI Secrets Platform

Ownership map:

```text
Terraform:  instance-principal IAM (dynamic group, policy, vault reference)
Argo CD:    Secrets Store CSI Driver + OCI Secrets Store CSI Provider
            application workloads (active V1 overlays today)
Ansible:    explicit private runtime config playbook (Secret + SPC instances)
            prepared only; not in site.yml; not auto-executed
Later:      activate V2 overlays (no Git-owned SecretProviderClass)
```

### Compatibility baseline

| Component             | Version / Reference                                                |
|-----------------------|--------------------------------------------------------------------|
| MicroK8s              | 1.29/stable                                                        |
| CSI Driver            | 1.3.3 (vendored dependency in Oracle chart)                        |
| OCI Provider chart    | Oracle v0.5.0 compatibility line                                   |
| Provider image        | TradingChassis multi-arch build (linux/amd64, linux/arm64)         |
| Deployed image pin    | Source git-SHA tag (repository:tag rendered by Oracle chart)       |
| Supply-chain digest   | sha256:a04180e28fe6a6b55b1dea934baae174ee1e02ddbb6142157ab706dec0ca180b |

### ARM64

The TradingChassis provider image is used because the reference node is ARM64
(OCI Ampere A1). The recorded multi-arch manifest includes `linux/arm64`.
Upstream Oracle v0.5.0 does not publish a multi-architecture container artifact.

### Fork provenance

```text
upstream baseline:  Oracle v0.5.0
fork purpose:       multi-architecture image publication for amd64 and arm64
fork repo:          https://github.com/TradingChassis/oci-secrets-store-csi-driver-provider
```

The fork is a controlled downstream compatibility patch, not a permanent vendor
replacement. Upstream PR #60 (v0.5.1) is not synced in this migration scope.

### MicroK8s kubelet root directory

MicroK8s uses `/var/snap/microk8s/common/var/lib/kubelet` instead of the generic
Kubernetes default `/var/lib/kubelet`. The CSI Driver Helm values configure this
path explicitly.

### Image pinning strategy

The Oracle Helm chart `v0.5.0` exposes `provider.image.repository` and
`provider.image.tag` and renders `repository:tag`. It does not provide a
first-class digest field, so the workload is deployed with:

```text
ghcr.io/tradingchassis/oci-secrets-store-csi-driver-provider:1f9ef4b6e123c2914edf842d77483d7ee174bf0a
```

That source git-SHA tag is the runtime deployment identity. Registry tags are
not cryptographically immutable. CI independently verifies that this exact tag
resolves to the recorded multi-architecture manifest digest
`sha256:a04180e28fe6a6b55b1dea934baae174ee1e02ddbb6142157ab706dec0ca180b`
with platforms `linux/amd64` and `linux/arm64`. Kubernetes is not deploying
`image@sha256:...` for this chart.

### Bootstrap ordering

Root App-of-Apps Application sync-wave contract:

```text
oci-secrets                 sync-wave = -1
postgres / mlflow / monitoring  sync-wave = 1
scratch / argo              default (unset)
```

What this guarantees:

```text
Application CR create/sync ordering inside the root sync
oci-secrets gets a deterministic head start over secret consumers
```

What this does **not** guarantee:

```text
oci-secrets becomes Healthy before consumer Applications start syncing
CSI mounts succeed
Vault retrieval succeeds
```

Runtime platform readiness for private materialization is enforced by
`ansible/roles/private_runtime_config` (bounded waits for the SPC CRD,
CSIDriver, CSI Driver DaemonSet, and OCI provider DaemonSet) before creating
the runtime Secret and SecretProviderClass resources.

Canonical operator sequence: `docs/V2_CLEAN_ROOM_DEPLOYMENT.md`.

### Deferred

- Explicit live cutover from overlays/v1 to overlays/v2 (see
  `docs/RUNTIME_SPC_OWNERSHIP_CUTOVER.md`)
- Activation of `private_runtime_config` inside the canonical Ansible converge
- Runtime VAULT_ID / OCI_REGION script retirement (scripts/08-runtime.sh)
- Activation of prepared V2 application overlays

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
public repository and will be materialized by Ansible during a later explicit
cutover. No live cutover has occurred.

MLflow V2 prepares `AWS_DEFAULT_REGION` via
`secretKeyRef` to `tradingchassis-runtime-config` / `OCI_REGION`. That
Kubernetes Secret is not created in this repository scope.

## OCI Secrets Platform

Ownership map:

```text
Terraform:  instance-principal IAM (dynamic group, policy, vault reference)
Argo CD:    Secrets Store CSI Driver + OCI Secrets Store CSI Provider
            application workloads (active V1 overlays today)
Later:      Ansible private deployment config (runtime Secret + SPC instances)
            activate V2 overlays (no Git-owned SecretProviderClass)
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

### Bootstrap ordering risk

On a fresh cluster the root Application may sync workload Applications that
consume Secrets Store CSI in parallel with `oci-secrets`. Pods can fail until
the CSI Driver and OCI provider become Ready. This is a partially confirmed
operational bootstrap risk and is deferred until the SecretProviderClass /
application-consumer migration, where ordering can be addressed without
expanding this platform-ownership change.

### Deferred

- Ansible private deployment-config role (Secret + SecretProviderClass materialization)
- Explicit live cutover from overlays/v1 to overlays/v2
- Runtime VAULT_ID / OCI_REGION script retirement (scripts/08-runtime.sh)
- Bootstrap sync ordering for CSI consumers

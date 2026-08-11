# Argo CD GitOps Applications

## Ownership

Argo CD owns all long-lived Kubernetes desired state managed from this directory.
The root Application (`root-app.yaml`) is applied once by Ansible bootstrap and
subsequently manages child Applications via the Kustomization.

## OCI Secrets Platform

Ownership map:

```text
Terraform:  instance-principal IAM (dynamic group, policy, vault reference)
Argo CD:    Secrets Store CSI Driver + OCI Secrets Store CSI Provider
Later:      SecretProviderClass and application secret consumption
```

### Compatibility baseline

| Component             | Version / Reference                                                |
|-----------------------|--------------------------------------------------------------------|
| MicroK8s              | 1.29/stable                                                        |
| CSI Driver            | 1.3.3 (vendored dependency in Oracle chart)                        |
| OCI Provider chart    | Oracle v0.5.0 compatibility line                                   |
| Provider image        | TradingChassis multi-arch build (linux/amd64, linux/arm64)         |
| Image pin             | Immutable git-SHA tag resolving to verified multi-arch manifest     |

### ARM64

The TradingChassis provider image is used because the reference node is ARM64
(OCI Ampere A1). The pinned image manifest includes `linux/arm64`. Upstream
Oracle v0.5.0 does not publish a multi-architecture container artifact.

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

The Oracle Helm chart template renders images as `repository:tag`. It does not
support first-class digest pinning. The provider image is pinned using the
immutable git-SHA tag (`1f9ef4b...`) which resolves to the verified multi-arch
manifest digest `sha256:a04180e28fe6a6b55b1dea934baae174ee1e02ddbb6142157ab706dec0ca180b`.

### Deferred

- Application-specific SecretProviderClass migration
- Runtime VAULT_ID / OCI_REGION cleanup (scripts/08-runtime.sh)

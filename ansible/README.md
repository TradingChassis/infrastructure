# Ansible

## Purpose

Ansible manages host configuration and bootstrap for the V2 reference platform.

## Ownership

Ansible owns or will own:

```text
host baseline
scratch filesystem and mount
explicit host firewall
MicroK8s installation and host configuration
Argo CD bootstrap
private runtime configuration materialization (explicit opt-in playbook)
```

Ansible does **not** own:

```text
OCI network/compute/storage/IAM resources
long-lived Kubernetes application desired state
Secrets Store CSI Driver / OCI provider installation
```

Terraform owns cloud infrastructure.
Argo CD owns long-lived Kubernetes desired state, including the Secrets Store CSI
Driver and OCI Vault provider.
Ansible may materialize only private-config-dependent Kubernetes objects
(`tradingchassis-runtime-config` and the three SecretProviderClass resources)
through an explicit non-default playbook.

## Current scope

```text
Host baseline contract validation is implemented.
Scratch filesystem validation, guarded formatting, and UUID-based mounting are implemented.
MicroK8s installation, required addons, readiness, OCI forwarding-firewall
normalization, a narrow pod → node-local API INPUT allow, and an explicit UFW
host firewall policy are implemented.
Argo CD bootstrap and the GitOps root Application handoff are implemented.
Private runtime configuration materialization is implemented as an explicit opt-in playbook only.
```

Project layout:

```text
ansible/
├── ansible.cfg
├── requirements.yml
├── inventory/
│   └── example.yml
├── playbooks/
│   ├── site.yml
│   └── private-runtime-config.yml
├── roles/
│   ├── host_baseline/
│   ├── scratch_storage/
│   ├── microk8s/
│   ├── argocd_bootstrap/
│   └── private_runtime_config/
└── README.md
```

Canonical `site.yml` playbook order:

```text
host_baseline
scratch_storage
microk8s
argocd_bootstrap
```

`private_runtime_config` is intentionally **not** included in `site.yml`.
## Host baseline

The `host_baseline` role:

* validates the supported Ubuntu reference host contract
* validates the ARM64 reference architecture
* does not configure MicroK8s
* does not reproduce the V1 blanket iptables reset

Supported contract (provider-neutral):

```text
distribution: Ubuntu
major version: 24
architecture: aarch64 or arm64
```

Cloud provider details such as OCI shape, VCN, NSG, and Block Volume APIs remain Terraform responsibilities.

## Scratch storage ownership

```text
Terraform:
OCI block volume and attachment identity

Ansible:
fail-closed host-side device discovery
device validation
filesystem lifecycle guard
persistent UUID mount

Argo CD later:
Kubernetes storage contract
```

The `scratch_storage` role manages the host path:

```text
/mnt/scratch
```

Persistent mount uses filesystem UUID.

Canonical device identity is fail-closed host-side auto-discovery of the unique
eligible non-root whole disk. This matches the reference architecture of exactly
one Terraform-managed scratch data volume. Auto-discovery fails if zero or more
than one eligible disk exists. It is not a universal multi-volume system.

`scratch_storage_device_path` is an optional explicit override. When omitted,
discovery runs. When provided, the path still passes every root, filesystem, and
mount guard. Do not default it to `/dev/sdb`, `/dev/vdb`, or an OCI by-id value.

Live paravirtualized OCI attachments do not provide a usable
`oci_core_volume_attachment.device` Linux path, so Terraform is not the device
handoff.

V1 hardcoded a Linux device path. V2 discovers the candidate on the host and
validates it before any destructive operation.

Supported discovery topology is the Ubuntu OCI reference host: root filesystem
on a partitioned boot disk, plus one unpartitioned whole-disk scratch volume.
LVM/device-mapper root is not a claimed discovery topology and fails closed.

### Safety

```text
scratch_storage_allow_format defaults to false.
Automatic discovery never authorizes formatting by itself.
```

```text
An existing filesystem of an unexpected type is never overwritten automatically.
```

## MicroK8s

The `microk8s` role:

* ensures `snapd` and `ufw` packages are present
* normalizes the OCI Ubuntu cloud-image IPv4 FORWARD REJECT and inserts
  narrow MicroK8s pod → node-local API and kubelet INPUT allows before the
  OCI INPUT REJECT
* reconciles that same nft-compatible contract into the running
  iptables-nft table after UFW is enabled
* installs and enables `tradingchassis-oci-microk8s-firewall.service` so
  the contract is restored automatically after reboot
* installs MicroK8s from the pinned snap channel `1.29/stable`
* waits for readiness with `microk8s status --wait-ready`
* enables only the verified V1-required addons when missing
* applies an explicit UFW host firewall policy before relying on MicroK8s networking

Required addons:

```text
dns
hostpath-storage
metrics-server
helm
```

Canonical currently documents `helm` as installing Helm 3.
`helm3` remains a transition alias and is not used by this role.

Addon convergence checks each required addon with `microk8s status --addon` and enables only addons reported as `disabled`.

## Firewall redesign

```text
V1 flushed the host firewall and set permissive policies.
V2 does not reproduce this behavior.
```

```text
Cloud ingress policy and host firewall policy remain separate layers.
```

Technology choice: **UFW**, using Canonical MicroK8s troubleshooting guidance for Calico on Ubuntu.

Implemented host policy:

```text
default incoming: deny
default outgoing: allow
default routed: allow
allow TCP/22 (SSH)
allow in/out on vxlan.calico
allow in/out on cali+
UFW enabled
```

Not opened on the host firewall to the Internet / UFW public policy:

```text
Kubernetes API (16443/tcp) from non-pod sources
kubelet (10250/tcp) from non-pod sources
cluster-agent
dqlite
Calico VXLAN UDP to the Internet
NodePort range 30000-32767
```

SSH remote source restriction remains the OCI NSG `ssh_ingress_cidr` responsibility.
The host firewall allows TCP/22 for defense in depth without duplicating operator CIDR policy.

UFW is never reset and existing unmanaged rules are not blanket-deleted.

### OCI cloud-image firewall incompatibilities

OCI Ubuntu cloud images persist two IPv4 catch-all REJECT rules in
`/etc/iptables/rules.v4` (CLOUD_IMG / Oracle Cloud Infrastructure baseline).
Both load into the nft-compatible table **ahead of** later UFW chains: an
unconditional IPv4 FORWARD REJECT and an unconditional IPv4 INPUT REJECT.

#### 1. Unconditional FORWARD REJECT

```text
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
```

That rule precedes later MicroK8s/Calico FORWARD ACCEPT rules. Forwarded
Pod → Kubernetes Service traffic then fails with `no route to host` even when:

```text
net.ipv4.ip_forward = 1
UFW DEFAULT_FORWARD_POLICY=ACCEPT (routed default allow)
the Kubernetes Service ClusterIP and backing endpoint are valid
```

`DEFAULT_FORWARD_POLICY=ACCEPT` is therefore not sufficient while the earlier
unconditional FORWARD REJECT remains.

V2 Ansible **removes only** that exact FORWARD rule.

#### 2. Unconditional INPUT REJECT vs node-local API

The OCI INPUT catch-all is **retained**:

```text
-A INPUT -j REJECT --reject-with icmp-host-prohibited
```

On the single-node MicroK8s cluster, kube-proxy DNAT rewrites Pod connections
to the Kubernetes Service onto the node-local kube-apiserver port. That packet
then hits the host **INPUT** chain, not FORWARD. The OCI INPUT REJECT sits
before UFW, so UFW Calico-interface allows never see the traffic.

V2 Ansible inserts a narrow allow **immediately before** the INPUT REJECT:

```text
-A INPUT -s 10.1.0.0/16 -p tcp -m tcp --dport 16443 -j ACCEPT
```

`16443` is the MicroK8s kube-apiserver port (`microk8s_apiserver_port`).

#### 3. Unconditional INPUT REJECT vs node-local kubelet

The same retained INPUT REJECT also blocks Pod → node-local kubelet traffic.
metrics-server scrapes `https://<node>:10250/metrics/resource` from a Pod in
the MicroK8s pod CIDR. That packet is node-local INPUT, not FORWARD, and is
rejected before UFW.

V2 Ansible inserts a second narrow allow immediately before the INPUT REJECT:

```text
-A INPUT -s 10.1.0.0/16 -p tcp -m tcp --dport 10250 -j ACCEPT
```

`10250` is the MicroK8s kubelet/kubelite port (`microk8s_kubelet_port`).

Persistent canonical order immediately before the retained REJECT:

```text
-A INPUT -s 10.1.0.0/16 -p tcp -m tcp --dport 16443 -j ACCEPT
-A INPUT -s 10.1.0.0/16 -p tcp -m tcp --dport 10250 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
```

`10.1.0.0/16` is the canonical MicroK8s 1.29/stable Calico pod CIDR
(`microk8s_pod_cidr`). These are role defaults, not live Pod, Service, or
node addresses.

The INPUT catch-all REJECT remains for unrelated host traffic. The Kubernetes
API and kubelet are still not opened on UFW or OCI NSGs to the Internet.

#### 4. UFW boot initialization does not restore the normalized nft runtime

`/etc/iptables/rules.v4` survives reboot. UFW is the active host firewall
owner and initializes its own iptables-nft chains at boot
(`ufw.service`, `Before=network-pre.target`). On the current host,
`iptables-persistent` / `netfilter-persistent` are not installed, and UFW
does not reload the normalized OCI/MicroK8s contract from `rules.v4`.

Live reboot evidence after PR #56, without running Ansible afterward:

```text
persistent rules.v4 still contained the OCI baseline, both pod allows,
the INPUT REJECT, the OUTPUT InstanceServices jump, and InstanceServices
runtime nft INPUT contained only UFW jumps (policy DROP)
Pod CIDR → tcp/16443 and tcp/10250 were absent
OCI RELATED/ESTABLISHED, ICMP, loopback, SSH, and INPUT REJECT were absent
InstanceServices chain and OUTPUT jump were absent
metrics API returned ServiceUnavailable
```

V2 does **not** install `iptables-persistent` / `netfilter-persistent`.
A whole-table `iptables-restore` would race with or replace UFW chains.

Instead, Ansible installs `tradingchassis-oci-microk8s-firewall.service`:
a oneshot that runs the same helper `--apply-runtime` after `ufw.service`
and before `network-pre.target` plus MicroK8s
`snap.microk8s.daemon-containerd.service` /
`snap.microk8s.daemon-kubelite.service`. It reconciles only the owned
OCI/MicroK8s nft contract (INPUT prefix, FORWARD REJECT absence,
InstanceServices). It does not flush tables and does not restore a whole
table.

The `microk8s` role still applies the same runtime reconciliation during
converge. The boot unit does not replace that. Post-reboot proof of this
boot unit is **not** claimed by repository tests.

#### Shared safety properties

Persistent and runtime normalization run in the `microk8s` role before
MicroK8s install/readiness. Persist rewrite happens before UFW enable.
Runtime `--apply-runtime` happens after UFW enable so it sees the UFW
chains the boot path also sees.

`--apply-runtime` uses `/usr/sbin/iptables-nft` with exact argv specs. It
never flushes INPUT/OUTPUT/FORWARD, never calls iptables-legacy, and never
restores a whole table. Owned INPUT rules from the normalized persistent
file are placed as a contiguous prefix ahead of later UFW jumps. The exact
OCI FORWARD REJECT is deleted when present. The OUTPUT InstanceServices
jump and InstanceServices chain rules are restored from that same
persistent baseline. Relative order of the two pod-host allows is not a
correctness requirement of the older INPUT-only planner; the boot/runtime
filter planner canonicalizes the full owned INPUT prefix once, then is a
no-op.

Do not flush iptables tables (`iptables -F` / `-X` / nft flush), disable UFW,
install `iptables-persistent` as a second full-table manager, delete
`/etc/iptables/rules.v4`, delete the OCI INPUT REJECT, or rewrite
InstanceServices from a template. Unexpected/non-OCI `rules.v4` files fail
closed. Duplicate catch-all INPUT REJECT rules fail closed. An absent
`rules.v4` is a persist no-op and does not create an incomplete firewall
file; boot/runtime apply fails closed if that file is missing.

The second MicroK8s converge must remain idempotent after FORWARD REJECT is
gone, both pod-host allows already precede INPUT REJECT, InstanceServices
is present, and the boot unit is already enabled.

Preserved on purpose:

```text
OCI INPUT REJECT
OCI InstanceServices chain and 169.254.0.0/16 metadata/DNS/DHCP/iSCSI rules
OUTPUT jump to InstanceServices
SSH INPUT accept
UFW incoming deny / outgoing allow / routed allow
UFW SSH and Calico interface rules
```

## Argo CD bootstrap

```text
Ansible owns only initial Argo CD bootstrap.
Argo CD owns long-lived Kubernetes desired state after bootstrap.
```

```text
The V1 CRD deletion and runtime repo-server patch are intentionally not reproduced.
```

The `argocd_bootstrap` role:

* ensures the `argocd` namespace
* installs Argo CD via the pinned community Helm chart `argo-cd` `8.2.7`
* pins Argo CD application image tag `v3.0.23`
* configures `kustomize.buildOptions: --enable-helm` declaratively in Helm values
* waits for server, repo-server, and application-controller readiness
* applies the GitOps root Application from `argocd/root-app.yaml`

Compatibility evidence:

```text
Argo CD 3.0 tested Kubernetes versions include v1.29
(source: argoproj/argo-cd v3.0.23 docs/operator-manual/tested-kubernetes-versions.md).
Argo CD 3.3+ tested matrices no longer list Kubernetes 1.29, so V1's v3.3.0 pin is not retained.
```

Root Application contract:

```text
Ansible → Argo CD → root Application → child Applications under argocd/
```

Child Application manifests remain Git-owned under `argocd/` and are selected by `argocd/kustomization.yaml`.
Their controller namespace is `argocd` so the Argo CD instance can reconcile them.

## Scratch storage (Argo)

```text
scratch-storage  → apps/scratch/platform  (StorageClass + static PVs)
scratch-dev      → apps/scratch/dev       (PVC only)
scratch-prod     → apps/scratch/prod      (PVC only)
```

Cluster-scoped scratch objects have exactly one owner (`scratch-storage`).
Dev/prod Applications must not duplicate StorageClass or PersistentVolume manifests.
Host directories `/mnt/scratch/dev` and `/mnt/scratch/prod` are created by Ansible after
a verified `/mnt/scratch` mount. Live binding evidence remains open.

## Private runtime configuration

```text
VAULT_ID   → private_runtime_config_vault_id
OCI_REGION → private_runtime_config_oci_region
```

Private values stay outside the public repository. Operators map them into Ansible
variables for an explicit playbook run. The role does not read `.env`, tfvars,
kubeconfigs from the workspace, or discover secrets automatically.

The `private_runtime_config` role:

* fail-closed validates Vault OCID shape (`ocid1.vault...`) and OCI region shape
* performs bounded, condition-based waits for Argo-owned OCI secrets platform readiness:
  * SecretProviderClass CRD
  * CSIDriver `secrets-store.csi.k8s.io`
  * DaemonSet `kube-system/oci-secrets-secrets-store-csi-driver`
  * DaemonSet `kube-system/oci-secrets-store-csi-driver-provider`
* waits for application namespaces `postgres`, `mlflow`, and `monitoring` (Argo CreateNamespace)
* only then materializes Secret `tradingchassis-runtime-config` in namespace `mlflow` with key `OCI_REGION`
* materializes exactly three SecretProviderClass resources with `authType: instance`
* renders literal `vaultId` from `private_runtime_config_vault_id` (no Git placeholder)
* uses `kubernetes.core` with the MicroK8s kubeconfig contract (no shell kubectl)
* sets `no_log: true` on tasks that handle private values
* does **not** validate live OCI Vault retrieval before SPC creation

Explicit playbook only (example syntax for the dedicated cutover scope):

```bash
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i <approved-inventory> \
  -e private_runtime_config_vault_id="$VAULT_ID" \
  -e private_runtime_config_oci_region="$OCI_REGION" \
  ansible/playbooks/private-runtime-config.yml
```

Do **not** run that playbook against a cluster while Argo CD is still
reconciling historical V1 SecretProviderClass resources as the active desired
state. Active V2 overlays omit those Git-owned SPCs; the same SPC identities
(`postgres-secret-bundle`, `mlflow-secret-bundle`,
`monitoring-secret-bundle`) remain only in inactive V1 overlays.

### Preparation (current repository state)

```text
site.yml unchanged (role not auto-run)
active apps/*/kustomization.yaml → overlays/v2
Ansible owns the three SecretProviderClass resources and the runtime Secret
after private-runtime-config.yml is executed
historical overlays/v1 remain inactive fallback artifacts
private-runtime-config playbook exists but is not executed automatically
V1 scripts/08-runtime.sh and inject-runtime-values.sh are historical only
```

### Future ownership notes

Canonical historical in-place procedure (fallback only; not Greenfield):

```text
docs/RUNTIME_SPC_OWNERSHIP_CUTOVER.md
```

That cutover document is a **historical / in-place fallback** procedure.
The primary V2 fresh-environment path is
`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`.

```text
Active V2 overlays omit Git-owned SPCs.
private_runtime_config materializes the three SPCs and runtime Secret.
V1 runtime Application patching is not part of the clean-room path.
```

Ownership invariant:

```text
At no steady-state point may Argo CD and Ansible both be authoritative
for the same SecretProviderClass resources.
```

### Post-activation steady state (active)

```text
active apps/*/kustomization.yaml → overlays/v2 (no Git-owned SPCs)
Ansible owns the three SecretProviderClass resources and the runtime Secret
Argo owns workloads, CSI Driver, and OCI provider
V1 runtime Application patching is no longer required for Greenfield
```
Idempotency design (statically designed; live second-converge validation deferred):

```text
first run creates Secret and three SPCs
identical second run is designed for changed=0
changed OCI_REGION updates the runtime Secret
changed VAULT_ID updates the three SecretProviderClass resources
```

Update behavior notes:

```text
OCI_REGION Secret updates do not rewrite environment variables inside already
running MLflow pods. A controlled rollout/reconciliation is required later.
VAULT_ID SecretProviderClass updates change desired CSI configuration; automatic
volume remount/reload behavior is not claimed without live evidence.
```

## Deferred

```text
Prometheus Operator CRD ownership / monitoring app ownership cleanup
canonical site.yml activation of private_runtime_config
post-proof V1 overlay and runtime-injection script cleanup
```
Kubernetes scratch binding to `/mnt/scratch` is implemented under `apps/scratch/**`
(Argo-owned StorageClass/PVs/PVCs) with Ansible creating `/mnt/scratch/dev` and
`/mnt/scratch/prod` after a verified mount. Live clean-room validation remains open.
## Inventory and Terraform handoff

`inventory/example.yml` is a non-live structural example.
It uses an RFC 5737 documentation address and must never be used as production inventory.

Canonical operator handoff:

```text
terraform output instance_public_ip   → inventory ansible_host
ubuntu (Ubuntu 24.04 image contract)  → inventory ansible_user
~/.ssh/tradingchassis                 → ansible_ssh_private_key_file
Ansible fail-closed auto-discovery    → scratch candidate
optional -e scratch_storage_device_path → explicit override only
```

Render the ignored runtime inventory after apply:

```bash
./tools/render-ansible-inventory
```

Canonical sequence, Cloud Shell auth, wait gates, and acceptance checklist:
[`docs/V2_CLEAN_ROOM_DEPLOYMENT.md`](../docs/V2_CLEAN_ROOM_DEPLOYMENT.md).

## Bootstrap sequence (operator)

1. **First:** `ansible/playbooks/site.yml` (host → scratch → MicroK8s → Argo bootstrap).
2. **Second:** `ansible/playbooks/private-runtime-config.yml` (explicit opt-in only).
   The role waits for OCI secrets platform readiness and application namespaces
   with a bounded retry loop; do not insert manual sleep timing.

`private_runtime_config` is intentionally **not** in `site.yml`.

Active application shims point at `overlays/v2`. The private-runtime playbook
supplies the SecretProviderClass resources and `tradingchassis-runtime-config`
consumed by those overlays. Do not treat V1 `scripts/inject-runtime-values.sh`
as part of the desired V2 path.

## V1 migration strategy

```text
Existing Bash scripts remain the V1 fallback until each corresponding Ansible/Argo CD replacement has independent validation evidence.
```

```text
Bash behavior is migrated by intent, not line-by-line.
```

Examples:

```text
iptables flush → explicit UFW policy from verified MicroK8s requirements
hardcoded block device → Terraform attachment identity + guarded validation
runtime kubectl patches → declarative GitOps state
```

## Validation

Static validation only:

```bash
ansible-galaxy collection install -r ansible/requirements.yml
ANSIBLE_CONFIG=ansible/ansible.cfg ansible-lint ansible/
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook --syntax-check \
  -i ansible/inventory/example.yml \
  ansible/playbooks/site.yml
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook --syntax-check \
  -i ansible/inventory/example.yml \
  -e private_runtime_config_vault_id=ocid1.vault.oc1.eu-test-1.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  -e private_runtime_config_oci_region=eu-test-1 \
  ansible/playbooks/private-runtime-config.yml
./tests/unit/test_ansible_scratch_device_discovery_contract.sh
./tests/unit/test_ansible_oci_forward_reject_contract.sh
```

Pinned collections:

```text
ansible.posix 2.2.2
community.general 13.2.0
kubernetes.core 6.5.0
```

## Live execution

```text
The V2 live operator sequence is now defined by docs/V2_CLEAN_ROOM_DEPLOYMENT.md.
```

```text
site.yml                 → host bootstrap stage (through Argo CD root Application)
private-runtime-config.yml → separate later stage after OCI secrets readiness
```

The sequence is documented but has **not** yet been proven by the first clean-room
live deployment. Static CI validation does not prove successful host convergence.

## Evidence

```text
Static CI validation does not prove successful host convergence.
```

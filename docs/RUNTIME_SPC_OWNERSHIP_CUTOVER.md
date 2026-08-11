# Runtime SPC Ownership Cutover

## Purpose

This runbook documents the future controlled handoff of the three
SecretProviderClass resources from Argo CD ownership to Ansible ownership.

It does not authorize or perform the cutover.

All live operator actions below are procedure design only. They are **not**
live-validated by this document and must not be executed until the dedicated
cutover scope has passed independent review and live preconditions are met.

## Scope

### In scope

Applications:

```text
postgres
mlflow
monitoring
```

Resources:

```text
SecretProviderClass/postgres-secret-bundle   (namespace postgres)
SecretProviderClass/mlflow-secret-bundle     (namespace mlflow)
SecretProviderClass/monitoring-secret-bundle (namespace monitoring)
Secret/tradingchassis-runtime-config         (namespace mlflow, key OCI_REGION)
```

Git switch surface (future cutover PR only):

```text
apps/postgres/kustomization.yaml
apps/mlflow/kustomization.yaml
apps/monitoring/kustomization.yaml
```

Ansible materialization (future controlled cutover only):

```text
ansible/playbooks/private-runtime-config.yml
```

### Out of scope

```text
CSI Driver ownership
OCI Provider ownership
Terraform changes
scratch storage
monitoring CRD cleanup
Bash script retirement
release / versioning
site.yml activation of private_runtime_config
```

## Preconditions

Every item marked **requires live validation** must pass before Phase 4.

| Precondition | Evidence class |
|---|---|
| Current V1 Applications Synced/Healthy | requires live validation |
| `oci-secrets` Application Synced/Healthy | requires live validation |
| Secrets Store CSI Driver Ready | requires live validation |
| OCI Secrets Store CSI Provider Ready | requires live validation |
| CRD `secretproviderclasses.secrets-store.csi.x-k8s.io` exists | requires live validation |
| Namespaces `postgres`, `mlflow`, `monitoring` exist | requires live validation |
| Instance-principal IAM for Vault secret-bundle reads available | requires live validation |
| Private `VAULT_ID` available outside Git | operator-private |
| Private `OCI_REGION` available outside Git | operator-private |
| Live SPC identities match the three names above | requires live validation |
| Effective Argo resource-tracking method and live tracking metadata inspected | requires live validation |
| Rollback path prepared and understood | requires live validation |
| Automation original state recorded for restore | requires live validation |

Repository pins Argo CD application image `v3.0.23` via Ansible bootstrap
(**confirmed from repository**). Live freeze/sync CLI syntax must be verified
against that line before use (**requires live validation**).

## Current ownership

**confirmed from repository:**

```text
Argo CD
→ Application path apps/<app>
→ automated.prune = true
→ selfHeal = true
→ active shims apps/*/kustomization.yaml → overlays/v1
→ Git-owned SecretProviderClass resources with vaultId: ${VAULT_ID}

Ansible private-runtime-config
→ role and explicit playbook exist
→ not included in ansible/playbooks/site.yml
→ must not be executed during normal V1 operation

Prepared overlays/v2
→ workloads only
→ no Git-owned SecretProviderClass
→ MLflow expects Secret/tradingchassis-runtime-config key OCI_REGION
```

Merely having the Ansible playbook in Git does **not** create active dual
ownership.

V1 runtime injection (`scripts/08-runtime.sh` →
`scripts/inject-runtime-values.sh`) remains the V1 fallback for Vault ID /
region Application patches until after a successful cutover.

## Target ownership

Steady state after a successful controlled cutover:

```text
Argo CD:
- CSI Driver (oci-secrets)
- OCI Provider (oci-secrets)
- workloads via overlays/v2
- no SecretProviderClass ownership

Ansible:
- Secret/tradingchassis-runtime-config
- SecretProviderClass/postgres-secret-bundle
- SecretProviderClass/mlflow-secret-bundle
- SecretProviderClass/monitoring-secret-bundle
```

## Safety invariants

1. Argo CD and Ansible must not both be authoritative for the same
   SecretProviderClass resources in steady state.
2. Do not run `private-runtime-config.yml` while Argo still reconciles V1 SPCs
   outside this controlled handoff.
3. Do not remove temporary `Prune=false` protection before Argo tracking has
   been safely relinquished.
4. Do not print private values (`VAULT_ID`, `OCI_REGION`, Secret data, SPC
   `vaultId` contents after materialization).
5. This runbook is not live evidence and does not authorize execution.

## Evidence classification

Use these labels throughout:

```text
confirmed from repository
confirmed from Argo CD documentation
requires live validation
```

Upstream Argo CD 3.0 docs used for procedure design (not live proof):

- Automated sync / prune / selfHeal:
  https://argo-cd.readthedocs.io/en/release-3.0/user-guide/auto_sync/
- Sync options (`Prune=false` vs `Delete=false`):
  https://argo-cd.readthedocs.io/en/release-3.0/user-guide/sync-options/
- Resource tracking (default annotation method):
  https://argo-cd.readthedocs.io/en/release-3.0/user-guide/resource_tracking/

## Reconciliation / prune / tracking (do not conflate)

| Concept | Mechanism | What it controls |
|---|---|---|
| Reconciliation control | Temporarily disable Application automated sync / selfHeal | Prevents Argo from mutating live objects during the handoff window |
| Prune protection | `argocd.argoproj.io/sync-options: Prune=false` on each SPC | Prevents deletion when the resource leaves Git desired state |
| Ownership / tracking | Remove effective Argo tracking metadata after V2 success | Ends Argo authority so Ansible is the sole owner |

Notes (**confirmed from Argo CD documentation**):

- Disabling automation alone does **not** prevent pruning during a manual sync
  that includes prune.
- `Prune=false` is not the same as `Delete=false` (`Delete=false` retains
  resources when the Application itself is deleted).
- This repository does not set `application.resourceTrackingMethod`. Argo CD
  3.0 documentation defaults to annotation tracking, but the live method and
  exact metadata must be inspected before removal.

## Handoff state machine

### STATE 0 — V1 active

```text
Argo automation:     on (prune + selfHeal)
Git desired SPC:     yes (overlays/v1)
live SPC:            Argo-managed (plus optional V1 injection patches)
Argo tracking:       present
Ansible authority:   no
rollback:            n/a (baseline)
```

### STATE 1 — frozen

```text
Argo automation:     off for postgres/mlflow/monitoring
Git desired SPC:     yes (overlays/v1)
live SPC:            unchanged
Argo tracking:       present
Ansible authority:   no
rollback:            restore recorded automation
```

### STATE 2 — prune-protected V1

```text
Argo automation:     off
Git desired SPC:     yes, with temporary Prune=false (later cutover prep)
live SPC:            Prune=false reconciled
Argo tracking:       present
Ansible authority:   no
rollback:            remove Prune=false / restore V1; restore automation
```

### STATE 3 — Ansible materialized

```text
Argo automation:     off (mandatory; prevents selfHeal fight)
Git desired SPC:     still V1 until Phase 5
live SPC:            Ansible-written literal vaultId
live Secret:         tradingchassis-runtime-config present
Argo tracking:       still present
Ansible authority:   temporary under freeze (not steady state)
rollback:            restore V1 shim if already switched; else V1 sync + injection
```

### STATE 4 — V2 desired / protected SPCs retained

```text
Argo automation:     off
Git desired SPC:     none (overlays/v2)
live SPC:            retained because Prune=false is active
Argo tracking:       may still be present (orphaned/managed until cleaned)
Ansible authority:   content owner under freeze
rollback:            restore V1 shims + controlled sync (+ injection if needed)
```

### STATE 5 — Ansible sole owner (target steady state)

```text
Argo automation:     on
Git desired SPC:     none
live SPC:            present
Argo tracking:       none
Prune=false:         removed
Ansible authority:   yes (sole)
rollback:            more complex; see post-handoff rollback
```

---

## Phase 0 — Capture baseline evidence

**requires live validation** · do not print secret contents

Capture and store offline evidence for:

```text
Application sync/health for postgres, mlflow, monitoring, oci-secrets
automation / prune / selfHeal settings (record exact original values)
SPC existence, names, namespaces
SPC tracking metadata (labels/annotations) without dumping private fields
Pod Ready status in postgres/mlflow/monitoring
CSI Driver / OCI provider health
presence or absence of Secret/tradingchassis-runtime-config (name only)
```

Example inspection patterns (live operator action; adjust to cluster access):

```bash
# Application high-level state (no secret values)
kubectl -n argocd get applications postgres mlflow monitoring oci-secrets \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status

# SPC inventory (names only)
kubectl get secretproviderclass -A \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name

# Tracking inspection: metadata only (never dump spec / parameters / vaultId)
# Repeat for mlflow-secret-bundle and monitoring-secret-bundle.
kubectl -n postgres get secretproviderclass postgres-secret-bundle \
  -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace
kubectl -n postgres get secretproviderclass postgres-secret-bundle \
  -o go-template='LABELS:{{"\n"}}{{range $k,$v := .metadata.labels}}{{printf "  %s=%s\n" $k $v}}{{end}}ANNOTATIONS:{{"\n"}}{{range $k,$v := .metadata.annotations}}{{printf "  %s=%s\n" $k $v}}{{end}}'
```

Inspect **all** labels and annotations on each SPC. Determine the live effective
Argo resource-tracking method and identify the **actual** tracking metadata
before any later removal. Do not assume a single annotation or label is
sufficient.

Record the effective tracking method from live Argo configuration
(for example `argocd-cm` `application.resourceTrackingMethod` if set).
If unset, treat Argo CD 3.0 default annotation tracking as a hypothesis only
until confirmed against live objects.

## Phase 1 — Freeze Argo reconciliation

**live operator action** · **requires live validation**

Freeze automatic mutation for:

```text
postgres
mlflow
monitoring
```

Why:

```text
selfHeal must not revert Ansible writes
auto-prune must not race the Git switch
```

Record the original automation state before changing anything.

Illustrative CLI pattern for Argo CD 3.0.x (verify against the live binary /
pinned `v3.0.23` line before use):

```bash
# Example only — live operator action
argocd app set postgres --sync-policy none
argocd app set mlflow --sync-policy none
argocd app set monitoring --sync-policy none
```

Equivalent approved API/object edits that clear `spec.syncPolicy.automated`
are acceptable if they achieve the same freeze and are recorded for restore.

Do **not** permanently change `argocd/*-app.yaml` in Git as part of documenting
this procedure. Temporary live freeze is the cutover control plane action.

Gate:

```text
Confirm automated sync is inactive for all three Applications.
If freeze did not take effect → STOP CUTOVER
```

## Phase 2 — Apply prune protection

Temporary protection annotation (**confirmed from Argo CD documentation**):

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-options: Prune=false
```

Apply to:

```text
postgres-secret-bundle
mlflow-secret-bundle
monitoring-secret-bundle
```

Architecture preference: place `Prune=false` on the three V1 SPC manifests in a
**later, dedicated cutover-preparation Git change**, sync while still on
`overlays/v1`, and verify the annotation is live before ownership transfer.

This documentation file does **not** add that annotation to active manifests.

Gate:

```text
Prune=false must be live on all three SPCs before Phase 4.
If any SPC lacks protection → STOP CUTOVER
```

## Phase 3 — Validate handoff prerequisites

Before `private-runtime-config` may execute, prove:

```text
Applications frozen
Prune=false live on all 3 SPCs
SPC CRD present
namespaces postgres/mlflow/monitoring present
CSI Driver / OCI provider healthy
private VAULT_ID / OCI_REGION ready (outside Git)
effective tracking method identified
baseline + rollback evidence captured
```

If any check fails:

```text
STOP CUTOVER
```

## Phase 4 — Materialize private runtime configuration

The playbook must **not** be run before the freeze and prune-protection gates.

Conceptual execution (no real inventory or private values in Git):

```bash
# Example only — live operator action during controlled cutover
ANSIBLE_CONFIG=ansible/ansible.cfg \
  ansible-playbook \
  -i <approved-inventory> \
  -e private_runtime_config_vault_id="$VAULT_ID" \
  -e private_runtime_config_oci_region="$OCI_REGION" \
  ansible/playbooks/private-runtime-config.yml
```

Expected objects:

```text
Secret/tradingchassis-runtime-config in mlflow (key OCI_REGION)
SecretProviderClass/postgres-secret-bundle
SecretProviderClass/mlflow-secret-bundle
SecretProviderClass/monitoring-secret-bundle
authType: instance preserved
vaultId rendered from private input (not the Git placeholder)
```

### Phase 4 validation (no private value disclosure)

**requires live validation**

```bash
# Secret exists and exposes the expected key name only
kubectl -n mlflow get secret tradingchassis-runtime-config
kubectl -n mlflow get secret tradingchassis-runtime-config \
  -o go-template='{{ range $k, $_ := .data }}{{ println $k }}{{ end }}'
# Expect key name: OCI_REGION
# Do not print .data values.

# SPCs exist
kubectl -n postgres get secretproviderclass postgres-secret-bundle
kubectl -n mlflow get secretproviderclass mlflow-secret-bundle
kubectl -n monitoring get secretproviderclass monitoring-secret-bundle

# vaultId is no longer the Git placeholder; do not print the actual value
for ns_name in postgres/postgres-secret-bundle mlflow/mlflow-secret-bundle monitoring/monitoring-secret-bundle; do
  ns="${ns_name%/*}"; name="${ns_name#*/}"
  if kubectl -n "$ns" get secretproviderclass "$name" \
      -o jsonpath='{.spec.parameters.vaultId}' | grep -Fq '${VAULT_ID}'; then
    echo "FAIL: $ns/$name still has Git placeholder vaultId"
    exit 1
  fi
  echo "PASS: $ns/$name vaultId is not the Git placeholder"
done

# authType remains instance
kubectl get secretproviderclass -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.parameters.authType}{"\n"}{end}'
```

If Ansible partially fails → **STOP CUTOVER** and follow failure modes / rollback.

## Phase 5 — Switch Git desired state to V2

Future small auditable Git change (not this documentation PR):

```text
apps/postgres/kustomization.yaml   resources: [overlays/v2]
apps/mlflow/kustomization.yaml     resources: [overlays/v2]
apps/monitoring/kustomization.yaml resources: [overlays/v2]
```

Application `path:` values remain `apps/<app>` (**confirmed from repository**).

## Phase 6 — Controlled Argo sync

**live operator action** · **requires live validation**

After the V2 desired-state merge, perform a controlled sync of the three
Applications while freeze remains in effect.

Expected conceptual state (not live-proven):

```text
Argo desired state: no SPC resources
live cluster:       SPCs remain because temporary Prune=false is active
workloads:          reconcile against overlays/v2
```

### MLflow-specific notes

V2 MLflow expects:

```text
AWS_DEFAULT_REGION
  ← secretKeyRef.name: tradingchassis-runtime-config
  ← secretKeyRef.key:  OCI_REGION
```

- Deployment must reconcile against V2.
- Pods must be recreated/rolled so the env reference becomes effective.
- An existing Pod does **not** pick up new Secret-backed env merely because the
  Secret object changed.

Do not print the region value.

## Phase 7 — Transfer final ownership / remove tracking

Most sensitive phase.

After V2 workloads are healthy and rollback evidence remains available:

1. Re-confirm the effective live tracking method and the exact tracking
   metadata on each SPC.
2. Remove **only** the verified Argo tracking metadata from the three SPCs.
3. Confirm Argo no longer treats the SPCs as authoritative/managed.
4. **Only then** remove temporary `Prune=false` protection.

Hard safety invariant:

```text
Do not remove Prune=false before Argo tracking has been safely relinquished.
```

Otherwise Argo may prune the SPC during the handoff.

Example tracking annotation used by Argo CD 3.0 documentation
(example only — verify live before removal):

```text
argocd.argoproj.io/tracking-id
```

Do not remove arbitrary labels/annotations. Do not assume the documentation
default without live confirmation.

Target after Phase 7:

```text
Argo desired SPC: none
Argo tracking:    none
Ansible owner:    yes
```

## Phase 8 — Re-enable automation

Only after:

```text
V2 desired state synced
SPCs healthy and present
tracking removed
Ansible sole owner
workloads healthy
```

Restore the previously recorded:

```text
automated sync
prune
selfHeal
```

settings for `postgres`, `mlflow`, and `monitoring`.

Verify the restored Application automation state (**requires live validation**).

## Phase 9 — Post-cutover validation

**requires live validation**

Completion evidence:

```text
postgres Ready
mlflow Ready
monitoring Ready
CSI volumes mount successfully
Kubernetes Secrets synchronized for consumers as expected
MLflow runtime configuration usable (without printing region/secret values)
Argo Applications Synced/Healthy
SPCs still exist
SPCs no longer Argo-tracked
Ansible second converge changed=0 for private-runtime-config
```

### Vault validation without disclosing values

Prefer consumer readiness and mount success. Do **not**:

```text
kubectl get secret -o yaml
base64 decode of secret data
echo of Vault contents / VAULT_ID / OCI_REGION
```

---

## Rollback procedure

### Preferred rollback before tracking removal (States 1–4)

```text
keep or re-apply freeze as needed
→ restore apps/*/kustomization.yaml to overlays/v1
→ controlled sync
→ restore V1 Argo SPC desired state
→ rerun V1 runtime injection (scripts/08-runtime.sh / inject-runtime-values.sh) if required
→ validate workloads
→ restore automation
```

Do not automatically delete `tradingchassis-runtime-config` unless it blocks
rollback; V1 does not require that Secret.

### State-specific rollback summary

| State | Trigger examples | Git | Argo | SPC owner after rollback | V1 injection? | Rerun Ansible? |
|---|---|---|---|---|---|---|
| 1 freeze | freeze incomplete / abort | V1 | restore automation | Argo | no | no |
| 2 prune-protected | annotation missing / abort | V1 | sync; drop Prune=false if needed | Argo | maybe | no |
| 3 Ansible-written | Ansible partial fail | V1 | sync under freeze then restore | Argo (heal) | if vaultId reverted to placeholder path | no (unless retrying cutover) |
| 4 V2 desired | V2 sync/workload fail | restore V1 shims | controlled sync | Argo | yes if needed | no |
| 5 final ownership | post-handoff failure | see below | freeze first | complex | yes after re-adopt | prevent Ansible reconcile during V1 restore |

### Post-handoff rollback (State 5)

More complex; **not live-validated**.

Conceptual direction:

```text
freeze postgres/mlflow/monitoring
→ switch Git shims back to overlays/v1
→ controlled sync so Argo recreates/re-adopts V1 SPC desired state
→ confirm Argo tracking is restored
→ restore V1 runtime injection if required
→ ensure Ansible is not reconciling SPCs while V1 mode is restored
→ validate
→ restore automation only after healthy V1
```

## Failure modes

| Failure | Stop condition | Rollback direction |
|---|---|---|
| Argo freeze did not take effect | automation still active | do not run Ansible; fix freeze |
| `Prune=false` missing on one SPC | Phase 3 gate fail | STOP; apply protection; do not switch V2 |
| Effective Argo resource tracking method cannot be determined | Phase 3 / Phase 7 gate fail | STOP CUTOVER; do not remove tracking metadata; do not proceed to final ownership transfer; investigate live Argo tracking configuration/state; remain in last safe frozen/protected state (or roll back to that state) |
| Ansible validation fails | Phase 4 gate fail | remain frozen on V1; fix inputs |
| Ansible apply partially fails | not all objects present | STOP; V1 sync heal; fix; retry later |
| SPC CRD absent | Phase 3 gate fail | restore `oci-secrets`; STOP |
| namespace absent | Phase 3 gate fail | STOP; let Argo create namespaces first |
| V2 sync fails | Phase 6 fail | restore V1 shims + sync |
| SPC pruned unexpectedly | missing protection / tracking error | emergency V1 restore; treat as incident |
| CSI mount fails | consumer unhealthy | rollback toward last healthy state |
| Vault retrieval fails | secret sync/mount fail | do not remove tracking; rollback/fix IAM/CSI |
| MLflow region Secret missing | Deployment/Pod fail | ensure Secret; rollout; or rollback to V1 |
| workload rollout fails | Phase 6/9 fail | rollback to V1 before Phase 7 |
| tracking removal incorrect | Argo still authoritative or prune risk | keep `Prune=false`; reassess; do not unfreeze |
| automation not re-enabled | post-success drift risk | re-apply recorded automation after validation |

## Completion criteria

Cutover may be considered complete only when all are true
(**requires live validation**):

```text
overlays/v2 active in Git for postgres/mlflow/monitoring
Argo Synced/Healthy without owning SPCs
three SPCs present and untracked by Argo
Ansible sole SPC owner; second converge changed=0
temporary Prune=false protection has been removed from all three SPCs
tradingchassis-runtime-config present with key OCI_REGION
authType remains instance
workloads Ready with CSI mounts
V1 injection no longer required for this cluster
automation restored and verified
```

## Deferred cleanup

After successful live cutover and soak period (separate scopes):

```text
retire routine use of scripts/08-runtime.sh and inject-runtime-values.sh
decide whether V1 overlays remain as emergency rollback artifacts
optional site.yml activation of private_runtime_config (explicit decision)
monitoring CRD ownership cleanup
scratch storage Kubernetes binding
```

Do not perform those cleanups in the cutover itself.

#!/usr/bin/env bash
# Static regression for Monitoring Argo CD Server-Side Apply.
# Parses the real Application and Helm chart manifests.
# Does not contact a cluster, Helm repo, or live Argo CD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(sys.argv[1]).resolve()
MONITORING_APP = ROOT / "argocd/monitoring-app.yaml"
MONITORING_KUSTOMIZE = ROOT / "apps/monitoring/base/kustomization.yaml"
ARGOCD_DIR = ROOT / "argocd"
CHANGELOG = ROOT / "CHANGELOG.md"
WORKFLOW = ROOT / ".github/workflows/repository-validation.yml"

FORBIDDEN_SYNC_OPTIONS = (
    "Replace=true",
    "Force=true",
    "ClientSideApplyMigration=false",
    "Validate=false",
)


def load_yaml(path: Path) -> dict:
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict):
        raise SystemExit(f"{path} must be a YAML mapping")
    return doc


def sync_policy(doc: dict) -> dict:
    return (doc.get("spec") or {}).get("syncPolicy") or {}


def sync_options(doc: dict) -> list[str]:
    opts = sync_policy(doc).get("syncOptions") or []
    if not isinstance(opts, list):
        raise SystemExit("syncOptions must be a list")
    return [str(item) for item in opts]


def automated(doc: dict) -> dict:
    return sync_policy(doc).get("automated") or {}


monitoring = load_yaml(MONITORING_APP)
if monitoring.get("kind") != "Application":
    raise SystemExit("argocd/monitoring-app.yaml must be an Application")
if (monitoring.get("metadata") or {}).get("name") != "monitoring":
    raise SystemExit("Monitoring Application metadata.name must be monitoring")
print("PASS: Monitoring Application exists")

auto = automated(monitoring)
if auto.get("prune") is not True:
    raise SystemExit("Monitoring automated.prune must remain true")
print("PASS: automated.prune remains true")
if auto.get("selfHeal") is not True:
    raise SystemExit("Monitoring automated.selfHeal must remain true")
print("PASS: automated.selfHeal remains true")

opts = sync_options(monitoring)
if "CreateNamespace=true" not in opts:
    raise SystemExit("Monitoring must keep CreateNamespace=true")
print("PASS: CreateNamespace=true remains present")
if "ServerSideApply=true" not in opts:
    raise SystemExit("Monitoring must enable ServerSideApply=true")
print("PASS: ServerSideApply=true is enabled for Monitoring")

for forbidden in FORBIDDEN_SYNC_OPTIONS:
    if forbidden in opts:
        raise SystemExit(f"Monitoring must not enable {forbidden}")
print("PASS: Replace=true, Force=true, and ClientSideApplyMigration=false are absent")

kustomize = load_yaml(MONITORING_KUSTOMIZE)
charts = kustomize.get("helmCharts") or []
if not isinstance(charts, list):
    raise SystemExit("apps/monitoring/base/kustomization.yaml helmCharts must be a list")
stack = [
    chart
    for chart in charts
    if isinstance(chart, dict) and chart.get("name") == "kube-prometheus-stack"
]
if len(stack) != 1:
    raise SystemExit("monitoring base must keep exactly one kube-prometheus-stack helmChart")
chart = stack[0]
if chart.get("includeCRDs") is not True:
    raise SystemExit("kube-prometheus-stack must keep includeCRDs: true")
print("PASS: kube-prometheus-stack includeCRDs remains true")
if chart.get("version") != "72.6.2":
    raise SystemExit("kube-prometheus-stack version 72.6.2 must remain")
if chart.get("repo") != "https://prometheus-community.github.io/helm-charts":
    raise SystemExit("kube-prometheus-stack repo must remain")
if chart.get("releaseName") != "prometheus-stack":
    raise SystemExit("kube-prometheus-stack releaseName must remain")
if chart.get("namespace") != "monitoring":
    raise SystemExit("kube-prometheus-stack namespace must remain monitoring")
if chart.get("valuesFile") != "helm-values.yaml":
    raise SystemExit("kube-prometheus-stack valuesFile must remain helm-values.yaml")
print("PASS: required monitoring chart/version configuration remains")

other_ssa = []
for path in sorted(ARGOCD_DIR.glob("*.yaml")):
    if path.name == "kustomization.yaml":
        continue
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or doc.get("kind") != "Application":
        continue
    name = (doc.get("metadata") or {}).get("name")
    if name == "monitoring":
        continue
    if "ServerSideApply=true" in sync_options(doc):
        other_ssa.append(f"{path.name}:{name}")
if other_ssa:
    raise SystemExit(
        "ServerSideApply=true must stay Monitoring-scoped; found on "
        + ", ".join(other_ssa)
    )
print("PASS: Server-Side Apply is scoped to Monitoring only")

changelog = CHANGELOG.read_text(encoding="utf-8")
unreleased = changelog.split("## [0.1.0]", 1)[0]
if "ServerSideApply=true" not in unreleased:
    raise SystemExit("Unreleased CHANGELOG must record Monitoring ServerSideApply=true")
if "262144" not in unreleased:
    raise SystemExit("Unreleased CHANGELOG must record the annotation size failure")
if "not yet live proven" not in unreleased:
    raise SystemExit("Unreleased CHANGELOG must not claim live Monitoring sync proof")
if "Monitoring is now live Synced" in unreleased or "now live Synced / Healthy" in unreleased:
    raise SystemExit("CHANGELOG must not claim live Monitoring Synced/Healthy")
print("PASS: CHANGELOG records the SSA fix without claiming live sync")

workflow = WORKFLOW.read_text(encoding="utf-8")
if "./tests/unit/test_monitoring_server_side_apply_contract.sh" not in workflow:
    raise SystemExit("GitOps validation must run this Monitoring SSA contract test")
required_names = (
    "Static repository checks",
    "Security validation",
    "Terraform validation",
    "Ansible validation",
    "GitOps validation",
)
for name in required_names:
    if f"name: {name}" not in workflow:
        raise SystemExit(f"required check name {name!r} must remain")
print("PASS: GitOps CI wires this test and required check names remain")
PY

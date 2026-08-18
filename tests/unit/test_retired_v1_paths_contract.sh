#!/usr/bin/env bash
# Fail-closed contract: retired V1 executable repository paths must stay gone.
# Static only. Does not mutate infrastructure.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
from pathlib import Path
import re
import sys

ROOT = Path(sys.argv[1]).resolve()

retired = (
    "apps/mlflow/overlays/v1",
    "apps/monitoring/overlays/v1",
    "apps/postgres/overlays/v1",
    "infrastructure/oci-provider",
    "scripts/01-system.sh",
    "scripts/02-microk8s.sh",
    "scripts/03-storage.sh",
    "scripts/04-secrets.sh",
    "scripts/05-monitoring.sh",
    "scripts/06-argocd.sh",
    "scripts/07-apps.sh",
    "scripts/08-runtime.sh",
    "scripts/bootstrap-cluster.sh",
    "scripts/inject-runtime-values.sh",
)

found = [rel for rel in retired if (ROOT / rel).exists()]
if found:
    raise SystemExit(f"retired V1 executable paths must not reappear: {found}")
print("PASS: retired V1 overlay, bootstrap, and oci-provider paths are absent")

for shim in (
    "apps/postgres/kustomization.yaml",
    "apps/mlflow/kustomization.yaml",
    "apps/monitoring/kustomization.yaml",
):
    text = (ROOT / shim).read_text(encoding="utf-8")
    if "overlays/v2" not in text:
        raise SystemExit(f"{shim} must select overlays/v2")
    if re.search(r"(?m)^\s*-\s+overlays/v1\s*$", text):
        raise SystemExit(f"{shim} must not keep overlays/v1 as the active resource")
print("PASS: active application entry points remain V2-only")
print("PASS: retired V1 path contract")
PY

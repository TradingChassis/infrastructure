#!/usr/bin/env bash
# Static regression for Argo CD Helm duration and kubernetes.core Python runtime.
# Does not SSH, run Helm, pip-install on the host, or contact a cluster.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

python3 - "$ROOT" <<'PY'
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve()
ARGO_TASKS = ROOT / "ansible/roles/argocd_bootstrap/tasks/main.yml"
ARGO_DEFAULTS = ROOT / "ansible/roles/argocd_bootstrap/defaults/main.yml"
RUNTIME_TASKS = ROOT / "ansible/roles/ansible_k8s_runtime/tasks/main.yml"
RUNTIME_DEFAULTS = ROOT / "ansible/roles/ansible_k8s_runtime/defaults/main.yml"
REQUIREMENTS = ROOT / "ansible/roles/ansible_k8s_runtime/files/requirements.txt"
PRIVATE_TASKS = ROOT / "ansible/roles/private_runtime_config/tasks/main.yml"
SITE = ROOT / "ansible/playbooks/site.yml"
RUNBOOK = ROOT / "docs/V2_CLEAN_ROOM_DEPLOYMENT.md"
ANSIBLE_README = ROOT / "ansible/README.md"
CHANGELOG = ROOT / "CHANGELOG.md"
WORKFLOW = ROOT / ".github/workflows/repository-validation.yml"
CLOUD_HELPER = ROOT / "tools/check-cloud-shell-readiness"

argo_tasks = ARGO_TASKS.read_text(encoding="utf-8")
argo_defaults = ARGO_DEFAULTS.read_text(encoding="utf-8")
runtime_tasks = RUNTIME_TASKS.read_text(encoding="utf-8")
runtime_defaults = RUNTIME_DEFAULTS.read_text(encoding="utf-8")
requirements = REQUIREMENTS.read_text(encoding="utf-8")
private_tasks = PRIVATE_TASKS.read_text(encoding="utf-8")
site = SITE.read_text(encoding="utf-8")
runbook = RUNBOOK.read_text(encoding="utf-8")
readme = ANSIBLE_README.read_text(encoding="utf-8")
changelog = CHANGELOG.read_text(encoding="utf-8")
unreleased = changelog.split("## [0.1.0]", 1)[0]
workflow = WORKFLOW.read_text(encoding="utf-8")
helper = CLOUD_HELPER.read_text(encoding="utf-8")


def task_block(text: str, name: str) -> str:
    marker = f"- name: {name}"
    idx = text.find(marker)
    if idx < 0:
        raise SystemExit(f"missing task {name!r}")
    rest = text[idx + len(marker) :]
    nxt = re.search(r"(?m)^\s*- name: ", rest)
    return rest if nxt is None else rest[: nxt.start()]


def top_level_yaml_list(text: str, key: str) -> list[str]:
    """Parse a top-level YAML list without requiring PyYAML."""
    match = re.search(rf"(?m)^{re.escape(key)}:[ \t]*(.*)$", text)
    if match is None:
        raise SystemExit(f"missing {key}")
    inline = match.group(1).strip()
    if inline.startswith("#"):
        inline = ""
    if inline == "":
        items: list[str] = []
        for line in text[match.end() :].splitlines():
            stripped = line.strip()
            if stripped == "" or stripped.startswith("#"):
                continue
            if re.match(r"^\S", line):
                break
            item = re.match(r"^\s+-\s+([^#\n]+?)(?:\s+#.*)?\s*$", line)
            if item is None:
                raise SystemExit(f"unrecognized {key} list item: {line!r}")
            value = item.group(1).strip().strip("'\"")
            if value:
                items.append(value)
        return items
    if inline.startswith("[") and inline.endswith("]"):
        inner = inline[1:-1].strip()
        if not inner:
            return []
        return [part.strip().strip("'\"") for part in inner.split(",") if part.strip()]
    raise SystemExit(f"{key} must be a YAML list")


helm_block = task_block(argo_tasks, "Install Argo CD Helm release")
if "kubernetes.core.helm:" not in helm_block:
    raise SystemExit("Helm install must use kubernetes.core.helm")
if re.search(r"(?m)^\s+wait_timeout:", helm_block):
    raise SystemExit("Helm install must not use deprecated wait_timeout")
if not re.search(r'(?m)^\s+timeout:\s+"\{\{\s*argocd_bootstrap_helm_timeout\s*\}\}"\s*$', helm_block):
    raise SystemExit("Helm install must pass timeout: argocd_bootstrap_helm_timeout")
if "| int" in helm_block:
    raise SystemExit("Helm timeout must not be coerced with | int")
if "wait: true" not in helm_block:
    raise SystemExit("Helm install must keep wait: true")
print("PASS: Helm task uses duration timeout, not wait_timeout")

timeout_match = re.search(
    r'(?m)^argocd_bootstrap_helm_timeout:\s+"([^"]+)"\s*$', argo_defaults
)
if timeout_match is None:
    raise SystemExit("argocd_bootstrap_helm_timeout must be a quoted duration string")
if not re.fullmatch(r"[1-9][0-9]*[smh]", timeout_match.group(1)):
    raise SystemExit(
        f"Helm timeout {timeout_match.group(1)!r} is not a Helm 3 duration such as 10m"
    )
k8s_timeout = re.search(
    r"(?m)^argocd_bootstrap_k8s_wait_timeout:\s+(\d+)\s*$", argo_defaults
)
if k8s_timeout is None:
    raise SystemExit("argocd_bootstrap_k8s_wait_timeout must be an unquoted integer")
if "argocd_bootstrap_wait_timeout" in argo_defaults or "argocd_bootstrap_wait_timeout" in argo_tasks:
    raise SystemExit("legacy argocd_bootstrap_wait_timeout must not remain")
print("PASS: Helm duration and k8s integer wait_timeout are distinct")

for name in (
    "Wait for Argo CD server deployment",
    "Wait for Argo CD repo-server deployment",
    "Wait for Argo CD application-controller",
):
    block = task_block(argo_tasks, name)
    if "kubernetes.core.k8s:" not in block:
        raise SystemExit(f"{name} must use kubernetes.core.k8s")
    if "argocd_bootstrap_k8s_wait_timeout | int" not in block:
        raise SystemExit(f"{name} must keep integer k8s wait_timeout")
    if re.search(r"(?m)^\s+timeout:", block):
        raise SystemExit(f"{name} must not use Helm timeout on kubernetes.core.k8s")
print("PASS: kubernetes.core.k8s waits keep integer wait_timeout")

if "name: ansible_k8s_runtime" not in argo_tasks:
    raise SystemExit("argocd_bootstrap must import ansible_k8s_runtime")
if "name: ansible_k8s_runtime" not in private_tasks:
    raise SystemExit("private_runtime_config must import ansible_k8s_runtime")
if "python3-kubernetes" in argo_tasks or "python3-kubernetes" in private_tasks:
    raise SystemExit("roles must not apt-install python3-kubernetes as the module runtime")
print("PASS: both Kubernetes roles share ansible_k8s_runtime")

for label, text in (
    ("argocd_bootstrap", argo_tasks),
    ("private_runtime_config", private_tasks),
):
    interp = text.find('ansible_python_interpreter: "{{ ansible_k8s_runtime_python }}"')
    if interp < 0:
        raise SystemExit(f"{label} must set ansible_python_interpreter to the dedicated venv")
    module_hits = [
        m.start()
        for m in re.finditer(
            r"(?m)^\s+kubernetes\.core\.(k8s|k8s_info|helm):",
            text,
        )
    ]
    if not module_hits:
        raise SystemExit(f"{label} must still use kubernetes.core modules")
    if interp > min(module_hits):
        raise SystemExit(f"{label} kubernetes.core tasks must run after the dedicated interpreter is set")
    if re.search(r"(?m)^ansible_python_interpreter:", text):
        raise SystemExit(f"{label} must not set a role-global ansible_python_interpreter")
print("PASS: kubernetes.core tasks use the dedicated interpreter without a global override")

apt_packages = top_level_yaml_list(runtime_defaults, "ansible_k8s_runtime_apt_packages")
if "python3-venv" not in apt_packages:
    raise SystemExit("ansible_k8s_runtime_apt_packages must include python3-venv")
if "python3-pip" in apt_packages:
    raise SystemExit(
        "ansible_k8s_runtime_apt_packages must not include python3-pip; "
        "python3-venv supplies stdlib venv/ensurepip for the dedicated runtime"
    )
forbidden_apt = (
    "python3-wheel",
    "python3-pip-whl",
    "python3-setuptools-whl",
    "pipx",
)
for pkg in forbidden_apt:
    if pkg in apt_packages:
        raise SystemExit(
            f"ansible_k8s_runtime_apt_packages must not explicitly manage {pkg}"
        )
if apt_packages != ["python3-venv"]:
    raise SystemExit(
        "ansible_k8s_runtime_apt_packages must be exactly [python3-venv], "
        f"got {apt_packages!r}"
    )
apt_block = task_block(
    runtime_tasks, "Ensure python3-venv is present for the Kubernetes module runtime"
)
if "ansible.builtin.apt:" not in apt_block:
    raise SystemExit("python3-venv must be installed with ansible.builtin.apt")
if 'name: "{{ ansible_k8s_runtime_apt_packages }}"' not in apt_block:
    raise SystemExit("apt task must install ansible_k8s_runtime_apt_packages")
print("PASS: runtime apt packages are python3-venv only, not system python3-pip")

if "kubernetes.core." in runtime_tasks:
    raise SystemExit("ansible_k8s_runtime must not itself call kubernetes.core")
if "/usr/bin/python3 -m venv" not in runtime_tasks:
    raise SystemExit("runtime role must create the venv with stdlib venv")
pip_install_block = task_block(
    runtime_tasks, "Install pinned Kubernetes Python dependencies into the dedicated venv"
)
if "virtualenv_command: /usr/bin/python3 -m venv" not in pip_install_block:
    raise SystemExit("dedicated venv must be created with /usr/bin/python3 -m venv")
if "virtualenv_site_packages: false" not in runtime_tasks:
    raise SystemExit("runtime venv must not include system site-packages")
if "virtualenv: \"{{ ansible_k8s_runtime_venv }}\"" not in pip_install_block:
    raise SystemExit("pip install must target the dedicated virtualenv")
if "--break-system-packages" in runtime_tasks or "--break-system-packages" in argo_tasks:
    raise SystemExit("must not use pip --break-system-packages")
if "get-pip.py" in runtime_tasks:
    raise SystemExit("must not bootstrap pip with get-pip.py")
if re.search(r"(?m)^\s+executable:\s+/usr/bin/pip", runtime_tasks):
    raise SystemExit("must not pip-install Kubernetes libraries with system pip")
for match in re.finditer(r"(?m)^- name: (.+)$", runtime_tasks):
    block = task_block(runtime_tasks, match.group(1))
    if "ansible.builtin.pip:" not in block:
        continue
    if "virtualenv:" not in block:
        raise SystemExit(f"{match.group(1)} must not pip-install into system Python")
if "/opt/tradingchassis/ansible-kubernetes" not in runtime_defaults:
    raise SystemExit("dedicated venv path must be /opt/tradingchassis/ansible-kubernetes")
print("PASS: dedicated venv is isolated from system Python")

kube_pin = None
have_yaml = False
have_jsonpatch = False
for line in requirements.splitlines():
    stripped = line.strip()
    if stripped.startswith("#") or not stripped:
        continue
    if stripped.startswith("kubernetes=="):
        kube_pin = stripped.split("==", 1)[1]
    elif stripped.startswith("PyYAML=="):
        have_yaml = True
    elif stripped.startswith("jsonpatch=="):
        have_jsonpatch = True
    elif "==" not in stripped:
        raise SystemExit(f"runtime requirement must be pinned: {stripped}")
if kube_pin is None:
    raise SystemExit("requirements.txt must pin kubernetes==")
parts = [int(p) for p in kube_pin.split(".")[:3]]
while len(parts) < 3:
    parts.append(0)
if tuple(parts) < (24, 2, 0):
    raise SystemExit(f"kubernetes pin {kube_pin} is below kubernetes.core 6.5.0 minimum 24.2.0")
if kube_pin != "29.0.0":
    raise SystemExit(f"requirements.txt must pin kubernetes==29.0.0, got {kube_pin!r}")
if "kubernetes==29.0.0" not in requirements:
    raise SystemExit("requirements.txt must keep kubernetes==29.0.0")
if "PyYAML==6.0.2" not in requirements:
    raise SystemExit("requirements.txt must keep PyYAML==6.0.2")
if "jsonpatch==1.33" not in requirements:
    raise SystemExit("requirements.txt must keep jsonpatch==1.33")
if not have_yaml or not have_jsonpatch:
    raise SystemExit("requirements.txt must pin PyYAML and jsonpatch")
if "24.2.0" not in runtime_defaults:
    raise SystemExit("runtime defaults must record kubernetes.core minimum 24.2.0")
print(f"PASS: Kubernetes Python client pin {kube_pin} satisfies >= 24.2.0")

copy_block = task_block(runtime_tasks, "Materialize pinned Kubernetes runtime requirements")
pip_install_block = task_block(runtime_tasks, "Install pinned Kubernetes Python dependencies into the dedicated venv")
if "ansible.builtin.copy:" not in copy_block:
    raise SystemExit("runtime role must materialize requirements with ansible.builtin.copy")
if "ansible.builtin.pip:" not in pip_install_block:
    raise SystemExit("runtime role must install requirements with ansible.builtin.pip")
copy_pos = runtime_tasks.find("- name: Materialize pinned Kubernetes runtime requirements")
pip_pos = runtime_tasks.find("- name: Install pinned Kubernetes Python dependencies into the dedicated venv")
if copy_pos < 0 or pip_pos < 0 or copy_pos >= pip_pos:
    raise SystemExit("requirements copy must happen before ansible.builtin.pip")
if not re.search(r'(?m)^\s+src:\s+requirements\.txt\s*$', copy_block):
    raise SystemExit("copy src must be role files/requirements.txt via Ansible file lookup")
if "role_path" in copy_block:
    raise SystemExit("copy src must not construct a controller role_path")
if not re.search(
    r'(?m)^\s+dest:\s+"\{\{\s*ansible_k8s_runtime_requirements_path\s*\}\}"\s*$',
    copy_block,
):
    raise SystemExit("copy dest must be the managed-node requirements path variable")
if 'requirements: "{{ ansible_k8s_runtime_requirements_path }}"' not in pip_install_block:
    raise SystemExit("pip must consume the managed-node requirements path, not a controller path")
for forbidden in (
    "role_path",
    "playbook_dir",
    "ansible/roles/ansible_k8s_runtime/files/requirements.txt",
):
    if forbidden in pip_install_block:
        raise SystemExit(f"pip requirements must not reference controller path token {forbidden!r}")
if re.search(r"/(?:home|Users)/[^/<>\s]+/", pip_install_block):
    raise SystemExit("pip requirements must not reference an absolute operator home path")
if re.search(r"(?i)(?:[A-Za-z]:\\|\\\\)Users\\", pip_install_block):
    raise SystemExit("pip requirements must not reference a Windows user home path")
if "role_path" in runtime_defaults:
    raise SystemExit("runtime defaults must not point pip at {{ role_path }}")
if "ansible_k8s_runtime_requirements_file" in runtime_defaults or "ansible_k8s_runtime_requirements_file" in runtime_tasks:
    raise SystemExit("legacy controller-side ansible_k8s_runtime_requirements_file must be removed")
req_dir_match = re.search(
    r"(?m)^ansible_k8s_runtime_requirements_dir:\s+(\S+)\s*$", runtime_defaults
)
if req_dir_match is None:
    raise SystemExit("runtime defaults must define ansible_k8s_runtime_requirements_dir")
req_dir = req_dir_match.group(1).strip('"')
if req_dir != "/opt/tradingchassis/ansible-k8s-runtime":
    raise SystemExit(
        "requirements directory must be /opt/tradingchassis/ansible-k8s-runtime, "
        f"got {req_dir!r}"
    )
if not req_dir.startswith("/"):
    raise SystemExit("requirements directory must be an absolute managed-node path")
if req_dir.startswith("/opt/tradingchassis/ansible-kubernetes"):
    raise SystemExit("requirements file must not live inside the venv directory")
if 'ansible_k8s_runtime_requirements_path: "{{ ansible_k8s_runtime_requirements_dir }}/requirements.txt"' not in runtime_defaults:
    raise SystemExit("managed-node requirements path must be the copied dest file")
dir_pos = runtime_tasks.find(
    "- name: Ensure managed-node Kubernetes runtime requirements directory exists"
)
if dir_pos < 0 or dir_pos >= copy_pos:
    raise SystemExit("requirements directory must exist before copy")
if re.search(r"rm\s+-rf\s+.*(ansible-kubernetes|/opt/tradingchassis)", runtime_tasks):
    raise SystemExit("runtime role must not recreate the venv by deleting it")
for match in re.finditer(r"(?m)^- name: (.+)$", runtime_tasks):
    block = task_block(runtime_tasks, match.group(1))
    if "state: absent" in block and (
        "ansible_k8s_runtime_venv" in block
        or "/opt/tradingchassis/ansible-kubernetes" in block
    ):
        raise SystemExit("runtime role must not delete the dedicated venv")
print("PASS: requirements are copied to the managed node before remote pip")

if re.search(r"(?m)^-\s+role:\s+ansible_k8s_runtime\s*$", site):
    raise SystemExit("site.yml must not globally switch the host to the Kubernetes venv role as a play role")
if "argocd_bootstrap" not in site:
    raise SystemExit("site.yml must still include argocd_bootstrap")
if "private_runtime_config" in site:
    raise SystemExit("site.yml must not activate private_runtime_config")
print("PASS: site.yml ownership and role order remain intact")

for needle in (
    'source "$HOME/.venvs/tradingchassis-ansible/bin/activate"',
    'ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg"',
    "ansible/playbooks/site.yml",
    "ansible/inventory/local.yml",
    "/usr/bin/ansible-playbook",
    "2.9",
):
    if needle not in runbook:
        raise SystemExit(f"runbook missing Cloud Shell contract token: {needle}")
if re.search(r"(?m)FIRST LIVE DEPLOYMENT: ansible-playbook site\.yml\b", runbook):
    raise SystemExit("runbook must not keep the bare ansible-playbook site.yml invocation")
print("PASS: Cloud Shell runbook requires the dedicated venv and repository Ansible config")

if "tradingchassis-ansible" not in helper:
    raise SystemExit("check-cloud-shell-readiness must name the Cloud Shell Ansible venv")
if "2.9" not in helper:
    raise SystemExit("check-cloud-shell-readiness must reject Cloud Shell Ansible 2.9")
print("PASS: Cloud Shell helper records the Ansible 2.9 / venv contract")

if "ansible_k8s_runtime" not in readme:
    raise SystemExit("ansible/README.md must document ansible_k8s_runtime")
if "10m" not in readme and "Helm 3" not in readme:
    raise SystemExit("ansible/README.md must document the Helm duration contract")
print("PASS: Ansible README documents the Kubernetes module runtime")

for needle in (
    "600",
    "22.6.0",
    "10m",
    "ansible-kubernetes",
    "Could not open requirements file",
    "ansible-k8s-runtime",
    "python3-wheel",
    "python3-venv",
):
    if needle not in unreleased:
        raise SystemExit(f"CHANGELOG [Unreleased] must record {needle}")
if "not yet live" not in unreleased.lower() and "not yet live proven" not in unreleased.lower():
    raise SystemExit("CHANGELOG [Unreleased] must not overclaim live Argo proof")
print("PASS: CHANGELOG records the live Helm/client failure and Git fix")

if "test_ansible_k8s_runtime_contract.sh" not in workflow:
    raise SystemExit("CI must run the Kubernetes runtime contract test")
print("PASS: CI enforces the Kubernetes runtime contract")

forbidden_v1 = (
    "scripts/bootstrap-cluster.sh",
    "scripts/inject-runtime-values.sh",
    "scripts/01-system.sh",
    "scripts/02-microk8s.sh",
    "scripts/03-storage.sh",
    "scripts/04-secrets.sh",
    "scripts/05-monitoring.sh",
    "scripts/06-argocd.sh",
    "scripts/07-apps.sh",
    "scripts/08-runtime.sh",
    "infrastructure/oci-provider",
)
for token in forbidden_v1:
    if token in argo_tasks or token in runtime_tasks:
        raise SystemExit(f"must not introduce V1 script {token}")
print("PASS: no V1 bootstrap script dependency")
print("PASS: Ansible Kubernetes module runtime contract")
PY

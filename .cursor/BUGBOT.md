# Bugbot review focus

Bugbot reviews pull requests. It must not treat live cluster or OCI state as confirmed.

## High-priority checks

- Secrets, credentials, private keys, Terraform state, and real OCIDs committed or leaked
- Terraform / Ansible / Argo CD ownership conflicts for the same resource
- Destructive storage, firewall, network, and host operations
- Unpinned or loosely pinned Terraform providers, modules, and GitHub Actions
- Ansible non-idempotent tasks and broad error suppression
- Kubernetes RBAC gaps, weak security contexts, NodePorts, mutable image tags, and Secret handling
- Unsafe GitHub Actions permissions and `pull_request_target` misuse
- CI jobs that execute live infrastructure commands
- Weakening or bypassing Safety files, allow/deny lists, ignore rules, or their tests
- Claims that exceed static or CI evidence (for example presenting syntax checks as live validation)

## Review stance

- Prefer concrete file evidence over assumed runtime behavior.
- Flag speculative “fixes” that are not justified by the diff.
- Keep findings concise and actionable.

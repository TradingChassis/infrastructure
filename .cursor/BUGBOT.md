# Bugbot review focus

Bugbot reviews pull requests. It must not treat live cluster or OCI state as confirmed.

Bugbot must not autofix, commit, push, merge, or perform live infrastructure operations.

Independent review procedure lives in `.cursor/rules/review-workflow.mdc`. This file is the Bugbot focus list, not a second copy of that procedure.

## High-priority checks

- Secrets, credentials, private keys, Terraform state, and real OCIDs committed or leaked
- Operator/live metadata leakage: real operator usernames, personal absolute home paths, copied shell prompts containing identities, unnecessary live environment identifiers, likely copied public host IPs
- Exact real identities or leaked values embedded in tests as denylist fixtures instead of synthetic class examples
- Terraform / Ansible / Argo CD ownership conflicts for the same resource
- Destructive storage, firewall, network, and host operations
- Unpinned or loosely pinned Terraform providers, modules, and GitHub Actions
- Ansible non-idempotent tasks and broad error suppression
- Kubernetes RBAC gaps, weak security contexts, NodePorts, mutable image tags, and Secret handling
- Unsafe GitHub Actions permissions and `pull_request_target` misuse
- CI jobs that execute live infrastructure commands
- CI or security-check bypasses, skipped security-critical steps, and fail-open behavior
- Weakening or bypassing Safety files, allow/deny lists, ignore rules, or their tests
- Regression-test weakening, including tests that assert the old bug or drop coverage
- Claims that exceed static or CI evidence (for example presenting syntax checks as live validation)

## Review stance

- Prefer concrete file evidence over assumed runtime behavior.
- Flag speculative “fixes” that are not justified by the diff.
- Keep findings concise and actionable.

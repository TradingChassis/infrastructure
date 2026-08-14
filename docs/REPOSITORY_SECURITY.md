# Repository security contract

This document is the repository-owned security CI and metadata-hygiene
runbook. It does not replace [`SECURITY.md`](../SECURITY.md) vulnerability
reporting, OCI IAM, or Vault operations.

Evidence produced by these checks is **statically validated** or
**CI validated**. It is not live validation and it does not prove that a
token is valid.

## What the Security validation job checks

Repository Validation has five major jobs:

1. Static repository checks
2. **Security validation**
3. Terraform validation
4. Ansible validation
5. GitOps validation

Security validation is a separate required-style job. It is not buried in
Terraform, Ansible, or GitOps.

It runs:

| Check | Purpose |
| --- | --- |
| Gitleaks `dir` | Credential classes in the current tree |
| Gitleaks `git` | Credential classes in the configured Git range |
| `tools/check-sensitive-metadata` | Operator/live metadata hygiene |
| `tests/unit/test_sensitive_metadata_contract.sh` | Generic scanner contract |

Gitleaks is the established credential scanner. Do not replace it with an
ad-hoc detector for known secret classes.

`check-agent-safety` remains the agent/tool execution-safety checker. It is
not a secret scanner and not a metadata-hygiene scanner.

## Scan scope

Checkout for Security validation uses `fetch-depth: 0` so Git history is
actually present for the selected Gitleaks mode. A shallow clone is not
claimed as a history scan.

| Event | Gitleaks `dir` | Gitleaks `git` |
| --- | --- | --- |
| `pull_request` | Current PR tree | Commits in `base.sha..head.sha` (newly introduced commits) |
| `push` to `main`, `workflow_dispatch` | Current tree | Reachable Git history |

Pull requests are gated on newly introduced commits plus the resulting tree
so low-risk historical metadata that is **not** a credential cannot block
every future PR.

Main still scans reachable history for **credentials**. If Gitleaks reports
a real secret in history, treat it as a **BLOCKER**. Do not allowlist it.
Do not rewrite Git history from this contract.

This checker never authenticates to OCI, GitHub, databases, or SaaS
providers with a discovered value.

## Secrets versus metadata

| Class | Owner | Examples |
| --- | --- | --- |
| Secrets / credentials | Gitleaks | API tokens, private keys, passwords, cloud keys |
| Operator / live metadata | `check-sensitive-metadata` | Concrete home paths, incidental live resource names, live-looking OCIDs, likely public host IPs |
| Declarative architecture | Allowed in Git | RFC1918 / documented CIDRs, Terraform `name_prefix`, `ansible_user: ubuntu`, synthetic OCIDs, `$HOME` paths |

Not all sensitive metadata is a secret. Severity and remediation stay
proportional.

## Synthetic fixtures

Tests must describe **classes** of forbidden data. They must not copy the
original live value into a denylist.

Acceptable:

- `$HOME/infrastructure`, `${HOME}/repo`, `~/repo`
- `/home/<user>/repo`, `/home/example/repo`, `/Users/example/repo`
- `ocid1.vault.oc1.eu-test-1..aaaaaaaaaaaaaaaa`
- documentation IPs in `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`
- password **names** such as `postgres-password` without a literal password

Unacceptable in Git:

- `/home/<actual-operator>/...`
- a regression test that lists that same operator username as a forbidden
  literal
- a real OCID, token, or private key used as a "test fixture"

Construct forbidden examples at runtime in tests when the scanner also
scans the test file.

## Personal home paths

The metadata checker flags concrete absolute user homes:

- Unix/Linux: `/home/<username>/...`
- macOS: `/Users/<username>/...`
- Windows: `C:\Users\<username>\...`

Documented safe forms: `$HOME`, `${HOME}`, `~/`, `/home/<user>/`,
`/home/example/`, `/home/test-user/`, `/home/oci/` (Cloud Shell service
account), `/home/ubuntu/` only as the declared image/Ansible contract.

There is no people-name list. Arbitrary usernames are rejected.

## OCI identifiers

Do not blanket-ban region names, resource type names, or OCID-shaped
strings. The repository needs declarative names and synthetic fixtures.

Suspicious concrete OCID-like values (mixed unique component, live length)
are flagged. Regex validators, placeholders, `example` fixtures, and
all-`a` synthetic unique components are not.

Never put a real OCID in an allowlist.

## IP addresses

RFC1918, loopback, link-local, unspecified, and RFC 5737 documentation
ranges are allowed. Designed VCN/Pod CIDRs are part of desired state.

The checker may flag likely live public IPv4 addresses in tracked files.
It does not blanket-ban every dotted-quad.

## Log safety

Gitleaks runs with `--redact`. Findings should identify rule, file, and
line without printing full secret material. Do not upload unredacted
Gitleaks JSON/SARIF artifacts.

The metadata checker redacts usernames, OCIDs, and IP addresses in its
own output.

## Allowlists

Keep allowlists minimal. Every Gitleaks allowlist entry must:

- be narrow (path or match, not `tests/**`)
- have a reason in `.gitleaks.toml`
- contain no real secret
- not disable a useful detector globally

Request a new exception in the same pull request that needs it. Do not
copy the live value into the allowlist; prefer changing the fixture to a
synthetic value.

## If a real credential is found

1. Do not merely delete it from `HEAD`.
2. Assume compromise.
3. Rotate or revoke the credential first where applicable.
4. Assess Git history and any other exposure.
5. Then clean the repository appropriately.

Do not claim rotation occurred unless an operator actually performed it.
Do not rewrite Git history unless a dedicated, explicit incident scope
authorizes it.

Historical **low-risk metadata** (operator home path, incidental resource
names) may remain in immutable normal Git history after the current tree
is cleaned. New CI prevents recurrence. History rewrite is not justified
by those Low findings.

## GitHub native secret scanning

GitHub Secret Scanning and Push Protection are **recommended** repository
settings. This repository's CI does not assume they are enabled and does
not depend on them. Operators should enable them in GitHub if the plan
allows it.

After merge, if branch protection is configured manually, add
**Security validation** to the required checks alongside the existing
Static, Terraform, Ansible, and GitOps jobs.

## Local commands

```bash
./tools/check-sensitive-metadata
./tests/unit/test_sensitive_metadata_contract.sh
./tools/check-agent-safety
./tools/validate-safe
```

Gitleaks runs in CI from the pinned official release in
`tools/gitleaks.pin`. Do not install arbitrary host packages to run it
locally unless that pin is already present.

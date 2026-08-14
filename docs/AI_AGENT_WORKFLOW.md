# AI agent workflow

This is the human-facing workflow for Cursor/AI-assisted work in this
repository. Durable machine-facing invariants live in `AGENTS.md` and
`.cursor/rules/`.

Verify first. Fix only if confirmed.

## 1. Purpose

Make one standard sequence the repository default:

implementation → staged changes → independent PRE-COMMIT review →
0 `BLOCKER` / `HIGH` / `MEDIUM` → explicitly authorized finalization task
→ commit → push / create or update PR → five required CI checks →
exact-head final CI/review gate → squash merge → remote feature branch
deletion → push-triggered main CI → live/operator validation when
applicable

The operator should not need a separate Cursor task for commit, push, CI
review, merge, and main-CI verification when one explicitly authorized
finalization task can perform them safely.

Repository guardrails steer agents. They are not a sandbox and do not
replace OS permissions, GitHub rulesets, or human review.

## 2. Responsibility split

| Role | Owns |
| --- | --- |
| Cursor implementation task | Verified, minimal change; stages when asked; does not commit, push, or merge |
| Independent PRE-COMMIT review | Read-only review of the actual staged diff |
| Explicitly authorized finalization task | After a passing PRE-COMMIT gate: commit the reviewed staged diff, push/PR, wait for required CI, exact-head gate, squash merge, delete the remote feature branch, verify main CI |
| GitHub Actions | Required static CI on the PR head and on `main` |
| Operator | Live infrastructure and any live validation |

An implementation task, a review task, or a CI-observation task does not
imply merge authorization.

Cursor does not auto-merge merely because CI turns green.

## 3. Standard workflow

1. Create or reuse a feature branch. Never work directly on `main`.
2. Verify the reported problem against the current checkout.
3. Implement the smallest confirmed fix. Add or adjust regression tests.
4. Run only permitted safe local wrappers after reviewing them when they change.
5. Review the final diff and stage only intended files.
6. Run an independent PRE-COMMIT review of the staged diff.
7. If `BLOCKER` / `HIGH` / `MEDIUM` = 0, an explicitly authorized
   finalization task may perform the remaining mechanical lifecycle on
   that exact reviewed staged diff.

## 4. Implementation phase

Follow `.cursor/rules/implementation-workflow.mdc`.

- Confirm the problem before patching.
- Reconstruct actual control flow when behavior or ownership is in doubt.
- Classify evidence. Do not speculate.
- Keep scope tight. No unrelated refactor.
- Do not use broad error suppression without justification.
- Add or adjust tests.
- Run `./tools/check-agent-safety` and `./tools/validate-safe` as applicable.
- Stage for PRE-COMMIT review when the task asks for that handoff.
- Do not commit, push, open a PR, or merge unless the current task explicitly says so.

An implementation task is not permission to commit.

## 5. Pre-commit review

Follow `.cursor/rules/review-workflow.mdc`.

- Independent and read-only.
- Inspect the actual staged diff, not the implementation report.
- The implementation agent must not approve its own work.
- Verify branch, base, and that the review target is not stale.
- Inspect root cause, failure behavior, tests, ownership, docs, and repository hygiene.

Severity: `BLOCKER`, `HIGH`, `MEDIUM`, `LOW`.

Normal gate: `BLOCKER` = 0, `HIGH` = 0, `MEDIUM` = 0.

`LOW` findings may be accepted explicitly when proportional. They are not
automatic blockers.

If `BLOCKER`, `HIGH`, or `MEDIUM` findings exist, correct the implementation
and review again before commit. Do not enter finalization.

## 6. Finalization authorization

A combined finalization task is allowed only after a successful independent
PRE-COMMIT review. It must operate on the exact reviewed staged diff.

The current task must explicitly authorize finalization. That authorization
may include merge. A new human task is not required for each mechanical
step.

Do not globally enable commit, push, or merge in Cursor permissions.

## 7. CI phase

Before merge to `main`, the active GitHub ruleset `main-protection`
currently requires these checks on the PR head:

- Static repository checks
- Security validation
- Terraform validation
- Ansible validation
- GitOps validation

That ruleset is maintained in GitHub. Repository files document the
policy; they do not themselves enforce GitHub settings.

A green CI job is `CI validated`. It is not live validation.

## 8. Exact-head final CI/review gate

Combining the mechanical lifecycle into one authorized task does **not**
eliminate the POST-CI quality gate.

Before squash merge, the finalization task must verify:

- exact current PR head SHA
- required CI belongs to that exact head
- all five required checks succeeded
- Security validation actually ran
- no unreviewed commits appeared
- final diff remains within reviewed scope
- `BLOCKER` / `HIGH` / `MEDIUM` remain zero
- merge state is clean

This is not automatic merge merely because CI turns green.

A review-only task reports merge readiness and does not merge.

## 9. Stop-on-failure

The finalization task must **STOP** without attempting implementation
repair if:

- the staged diff differs from the reviewed diff before commit
- commit or required signing fails
- push fails
- the PR head differs unexpectedly
- any required CI job fails
- Security validation fails
- the exact-head final review finds `BLOCKER`, `HIGH`, or `MEDIUM`
- merge state is not clean
- merge fails
- main CI fails

On failure it must not:

- edit implementation to repair the problem
- amend
- rebase
- force-push
- weaken tests
- weaken Security validation
- add allowlists merely to make CI pass
- merge despite failed gates

Do not self-repair. Return control to a new implementation/fix cycle.

## 10. Merge

Merge requires explicit authorization from the current task.

An explicitly authorized finalization task may include squash merge.
An ordinary implementation, review, or CI-observation task may not.

Expected merge steps:

1. Confirm the exact-head gate passed.
2. Prefer squash merge.
3. Delete the remote feature branch.
4. Verify `main` received the squash commit.
5. Verify push-triggered main CI.

Do not auto-merge after green CI.

## 11. Main CI

After squash merge and branch deletion, the same finalization task verifies
push-triggered Repository Validation on the resulting `main` commit.

Required jobs remain:

- Static repository checks
- Security validation
- Terraform validation
- Ansible validation
- GitOps validation

A green PR run does not replace this main-commit proof.

If main CI fails: report the failure and **STOP**. Do not repair `main` in
the finalization task.

Main CI still does not prove live infrastructure correctness.

## 12. Live operator validation

Live OCI, Terraform, Ansible, Kubernetes, host, firewall, and storage
operations are operator work. Agents must not perform them.

When a change needs live proof, record evidence as `live validated` only
after an operator actually ran the relevant procedure.

## 13. Security / metadata hygiene

Every implementation and review that changes repository files must
consider credentials and operator/live metadata.

Forbidden in Git:

- credentials, tokens, private keys, real secret values
- real operator usernames and personal absolute home paths
- copied shell prompts that contain identities
- live-looking OCIDs and unnecessary live environment identifiers
- likely copied public host IPs
- tests that preserve the exact real value that originally leaked

Tests must describe **classes** of forbidden data and use synthetic
fixtures. See [`REPOSITORY_SECURITY.md`](REPOSITORY_SECURITY.md).

Do not:

- build a universal human-name detector
- delete legitimate Kubernetes namespaces
- delete declarative architecture identifiers
- treat every OCI name as sensitive
- treat every private CIDR as personal metadata

Distinguish declarative desired-state, synthetic fixture, incidental
live/operator metadata, and credential.

## 14. Evidence classification

Use these labels honestly:

- `live validated`
- `CI validated`
- `statically validated`
- `statically identified`
- `not yet validated`
- `intentional behavior`
- `planned`

Do not present syntax, lint, or wrapper output as live runtime proof.

## 15. Language behavior

Language behavior is defined in `AGENTS.md` and
`.cursor/rules/safe-infrastructure-development.mdc`:

- Respond in the language explicitly requested by the current task or prompt.
- If no response language is specified, use the language of the user's current request.
- Keep repository content in English unless the task explicitly requires otherwise.

## 16. What belongs outside this repository

This repository stores only rules and documentation that agents need to
operate on **this** repository.

The following are **not** stored here:

- personal ChatGPT prompt libraries
- ChatGPT session initialization templates
- generic cross-project prompt collections

Those belong in operator-local or private tooling.

ChatGPT may generate a concrete task prompt. Cursor rules already carry
the durable repository invariants. Task prompts should therefore focus on:

- task-specific context
- target SHA and base
- root cause
- scope
- acceptance criteria
- special constraints

They should not repeat every permanent Cursor safety rule.

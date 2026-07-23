# Handoff contract

Use this format for every agent or human continuation. Do not make the recipient infer repository state, evidence scope, skipped capabilities, live resources, or the next command.

## Rules

- Never say “tests pass” without a fresh exact command, UTC time, full tested SHA, and exit code.
- Never omit explicit or automatic skips, including Docker-missing containerd skips.
- Never inherit live-resource claims without a fresh inventory.
- Never treat historical evidence as current-head evidence without an explicit reviewed scope.
- Never use a mutable test total as the sole verification contract.
- Record staged, unstaged, untracked, and deliberately excluded state separately.

## Copyable template

```markdown
# Handoff: <short objective>

## Repository state
- Repository/remote: <owner/name and URL>
- Repository path: <absolute path>
- Implementation worktree path: <absolute path>
- Branch: <branch>
- Full HEAD SHA: <40-hex SHA>
- Upstream branch/SHA: <branch> / <40-hex SHA>
- Base branch/SHA: <branch> / <40-hex SHA>
- PR: <number, URL, base, head, open/draft/closed state>
- Push permission: <allowed/not allowed and authority>
- Merge permission: <allowed/not allowed and authority>
- Rebase requirement/status: <required/not required/not checked; result>

## Working-tree state
- `git status --short --branch`: <exact output>
- Staged files: <paths or none>
- Unstaged tracked files: <paths or none>
- Untracked files/artifacts: <paths or none>
- Intentionally excluded: <paths and reason>
- `git diff --stat`: <exact summary>
- Staged diff summary: <exact summary>
- Overlapping writer ownership: <none or owner/paths>
- Safe to commit: <yes/no and why>

## Work completed
- Commits and intent: <full SHA, subject, intent>
- Production paths changed: <paths or none>
- Test paths changed: <paths or none>
- Documentation paths changed: <paths or none>
- Invariants/contracts changed: <named contracts or none>
- Named deterministic scenarios: <scenario names or none>
- Real-process boundary covered: <socket/process/filesystem/containerd/GPU/cloud or unchanged>
- Protocol compatibility impact: <none/exact change and upgrade rule>

## Verification
| UTC time | Tested full SHA | Exact command | Environment/tools | Exit | Semantic result | Seeds/RED/artifacts | Skipped/unavailable |
|---|---|---|---|---:|---|---|---|
| <time> | <SHA> | `<command>` | <OS/tool versions/capabilities> | <code> | <observable result> | <seed mode/range/count, mutation, threads, budget; RED command/output; logs/traces/corpus> | <every skip/unavailable capability> |

- Binary/image hashes: <SHA-256 values or not applicable>
- Logs/metrics/state snapshots: <paths or not applicable>
- Terraform plan digest: <digest or not applicable>
- Cleanup verification: <process/container/mount/resource inventory and result>
- Redaction scan: <command, exit, result>

## Runtime/live state
- Provider/account alias: <non-secret alias or not applicable>
- Region: <region or not applicable>
- Inventory checked at: <UTC time or not checked>
- Current state: <up/destroyed/mixed, or blocked because inventory was not checked>
- Last verified state, if useful: <up/destroyed/mixed, UTC date, source; explicitly historical>
- Owned resource identifiers/unique ownership token: <IDs/token or none>
- Unowned resources observed: <IDs or none; never adopt implicitly>
- Cleanup command: `<exact command or not authorized/not applicable>`
- Cleanup inventory: <instances, volumes, buckets, repositories, locks, units, processes, containers, mounts>
- Cost approval: <approved/not approved/not applicable>
- Destructive cleanup approval: <approved/not approved/not applicable>
- Credentials/quota status: <available/absent/not checked>
- Retained resources and reason: <none or exact list>

## Blockers and next action
- Unresolved finding/blocker: <exact issue or none>
- Exact first command: `<command>`
- Expected repository/worktree state: <state>
- Safe-to-commit state: <yes/no and condition>
- Required artifact/log paths: <paths>
- Decision/authorization required: <none or exact decision>

## Residual risks
- Product limitations: <list>
- Simulator/model limitations: <list>
- Real-process/runtime limitations: <list>
- Live-only unknowns: <list>
- Compatibility/upgrade limitations: <list>
```

## Illustrative example for PR #1, not current evidence

The values below show a complete record shape. Placeholders are intentional and must be replaced from fresh inspection. This example does not attest current HEAD or current live resources.

```markdown
# Handoff: illustrate durability-hardening continuation

## Repository state
- Repository/remote: `elijah-rou/hivemind`, `<REMOTE_URL>`
- Repository path: `<REPOSITORY_PATH>`
- Implementation worktree path: `<WORKTREE_PATH>`
- Branch: `fix/v2-durable-vrr-safety`
- Full HEAD SHA: `<FULL_HEAD_SHA>`
- Upstream branch/SHA: `origin/fix/v2-durable-vrr-safety` / `<UPSTREAM_SHA>`
- Base branch/SHA: `master` / `<BASE_SHA>`
- PR: `#1`, `<PR_URL>`, base `master`, head `fix/v2-durable-vrr-safety`, `<OPEN_STATE>`
- Push permission: not allowed unless the current task explicitly authorizes it
- Merge permission: no merge without explicit instruction
- Rebase requirement/status: not checked; inspect base and require a clean tree first

## Working-tree state
- `git status --short --branch`: `<CURRENT_STATUS_OUTPUT>`
- Staged files: none
- Unstaged tracked files: none
- Untracked files/artifacts: `.pi-subagents/`
- Intentionally excluded: `.pi-subagents/`, orchestration artifacts only
- `git diff --stat`: no tracked diff
- Staged diff summary: none
- Overlapping writer ownership: none after explicit ownership check
- Safe to commit: yes only after the actual tree and index match these fields

## Work completed
- Commits and intent: `<FULL_COMMIT_SHA> <SUBJECT_AND_INTENT>`
- Production paths changed: `<PRODUCTION_PATHS_OR_NONE>`
- Test paths changed: `<TEST_PATHS_OR_NONE>`
- Documentation paths changed: `<DOC_PATHS_OR_NONE>`
- Invariants/contracts changed: `<NAMED_CONTRACTS>`
- Named deterministic scenarios: `<SCENARIO_NAMES>`
- Real-process boundary covered: `<BOUNDARY_OR_UNCHANGED>`
- Protocol compatibility impact: `<NONE_OR_EXACT_IMPACT>`; mixed-version upgrades remain stop-the-world

## Verification
| UTC time | Tested full SHA | Exact command | Environment/tools | Exit | Semantic result | Seeds/RED/artifacts | Skipped/unavailable |
|---|---|---|---|---:|---|---|---|
| `<UTC_TIMESTAMP>` | `<FULL_HEAD_SHA>` | `cd v2 && ./tests/run-all.sh --skip-containerd` | `<OS_AND_TOOLS>` | `<EXIT>` | `<SEMANTIC_OUTPUT>` | `<RED_EVIDENCE_AND_SEEDS>`; `<ARTIFACT_PATHS>` | containerd explicitly skipped and unverified; live cloud unavailable |

- Binary/image hashes: `<HASHES_OR_NOT_APPLICABLE>`
- Logs/metrics/state snapshots: `<PATHS_OR_NOT_APPLICABLE>`
- Terraform plan digest: not applicable unless a plan was generated
- Cleanup verification: `<LOCAL_PROCESS_AND_TEMP_INVENTORY>`
- Redaction scan: `<COMMAND_EXIT_RESULT>`

## Runtime/live state
- Provider/account alias: not checked
- Region: not checked
- Inventory checked at: not checked for this illustrative record
- Current state: blocked; no fresh inventory supports `up`, `destroyed`, or `mixed`
- Last verified state, if useful: `<HISTORICAL_ENUM_DATE_SOURCE>`; historical only
- Owned resource identifiers/unique ownership token: none recorded
- Unowned resources observed: not checked
- Cleanup command: not authorized by this documentation example
- Cleanup inventory: not checked
- Cost approval: not approved
- Destructive cleanup approval: not approved
- Credentials/quota status: not checked
- Retained resources and reason: unknown until inventory is authorized and run

## Blockers and next action
- Unresolved finding/blocker: `<EXACT_FINDING_OR_NONE>`
- Exact first command: `git status --short --branch && git rev-parse HEAD`
- Expected repository/worktree state: branch above, exact SHA inspected, no unexplained tracked changes
- Safe-to-commit state: no, until placeholders are replaced and focused verification passes
- Required artifact/log paths: `<PATHS>`
- Decision/authorization required: separate approval before any live, paid, privileged, destructive, push, or merge action

## Residual risks
- Product limitations: experimental single-copy journal; bounded log lifetime; incomplete product parity
- Simulator/model limitations: no torn-write, filesystem-reordering, power-loss, kernel, GPU, or cloud proof
- Real-process/runtime limitations: local process runtime does not attest containerd; standalone failover has no worker/data plane
- Live-only unknowns: current AWS, ECR, GPU/CDI, JuiceFS, S3/SSM/systemd state and cleanup are unverified
- Compatibility/upgrade limitations: all TCP envelopes require protocol version 6; mixed-version rolling upgrades are unsupported and require a stop-the-world replacement
```

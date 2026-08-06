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

## Ten-PR thematic stack map

The local review stack is linear and each branch owns one boundary:

1. `stack/01-storage-journal`: durable journal and retained-log foundation
2. `stack/02-vrr-view-change`: bounded VRR recovery and view change
3. `stack/03-core-ingress-run`: bounded ingress and fail-closed `/run` correlation
4. `stack/04-core-vopr-dst`: VOPR oracles and durability fault model
5. `stack/05-worker-runtime-sim`: worker runtime ownership and deterministic simulation
6. `stack/06-protocol-v6-contract`: atomic protocol-v6 four-language corpus
7. `stack/07-local-durable-e2e`: owned three-replica local durability contracts
8. `stack/08-offline-ops-containerd`: offline deployment and containerd contracts
9. `stack/09-guarded-live`: guarded capability execution and evidence
10. `stack/10-evidence-docs`: aggregate evidence, governance, and navigation

The final accepted evidence run started from the exact fully merged stack and tested the cleanup-plan follow-up shown below. The later evidence documentation commit is a separately recorded descendant.

| Branch | Accepted-run tip | Tree |
|---|---|---|
| `master` after merged PRs #1 through #10 | `d21bc45792a02738b2792acc24b815c5412e3a3f` | `dfb323f2ac819a26a9a6e2519e25ce867c097f21` |
| final cleanup-plan follow-up tested parent | `7c798c99171cbc894ddf26e8f9c1e872af143401` | `671097ae849bdc7d7e4dc142353a111e70226345` |

Accepted run `20260806T063004Z-7c798c99171c` covered `25 / 25` non-live gates, exact core `0..9999`, worker `0..999`, and `28 / 28` invoked aggregate phases. Gate duration sum was `455s`; wall time was `462s`. Containerd, privileged/runtime, GPU, private-registry, provider, Terraform mutation, and live boundaries remained skipped or unexecuted. Final local cleanup and tracked/index/`v1` checks passed. Publication evidence must add the final documentation tip and preserve this tested-parent distinction.

After a lower PR is squash-merged, verify the squash tree by applying that slice's archived parent-relative patch to the new upstream parent in a temporary index. Then rebase each descendant sequentially with explicit old/new parent tips, verify every projected tree and focused gate, and update remote refs bottom-up with per-ref leases. Update the retained top PR last. Never merge descendants, use a hosted “update branch” action, or claim absolute old-tree equality after upstream has legitimately advanced.

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

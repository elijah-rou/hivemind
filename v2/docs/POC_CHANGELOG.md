# Hivemind POC Changelog

_Last updated: 2026-07-16_

Purpose: keep a running record of what changed, why it matters, how close the project is to the federated POC goal, and what should happen next.

## Progress Snapshot

- Acceptance sections complete: `6 / 8`
  - Complete: `1. Fresh AWS Redeploy`, `2. Locality Federation Proof`, `3. Real Workload Validation`, `4. Operator Workflow Proof`, `5. Failure Drill Proof`, `6. Repeatability / No-Heroics Gate`
  - Reopened: `7. Kubernetes Baseline Comparison`, `8. Final Evidence Pack`
- Execution checklist complete: `16 / 16` for warm-cache evidence pack
  - Complete: fresh redeploy, corrected smoke, origin -> locality map, Hivemind origin metadata + gossip visibility patch, local federated-origin proof surface, Thalamus POC branch locality/residency selector tests, localhost locality/failover smoke, CPU workload selection, GPU workload selection, real CPU/GPU workload validation, operator workflow proof, failure drills, repeatability / second fresh redeploy, initial EKS baseline collection, warm-cache Hivemind/EKS benchmark, final evidence pack/verdict refresh
  - Remaining for economic confidence: clean EKS rerun after GPU-node sandbox failures, cold-cache rerun after Hivemind private ECR auth fix
- Infra status: `up`: Hivemind live for reuse; EKS control plane and nodegroups left up after warm-cache rerun
- Current phase: `Final benchmark docs refreshed; benchmark/economic verdict still provisional pending clean EKS rerun`

## Current Distance To Goal

The functional/resilience POC is complete.

The basic live AWS plumbing gate is closed.

The broad Hivemind-core deterministic blocker is also closed again: fresh mutated core sweep is clean at `10000/10000` after landing regression fixes.

The local deterministic federated proof surface, localhost Thalamus/Hivemind smoke, focused fresh-AWS real workload run, operator workflow proof, live failure drills, and repeatability gate are complete.

The benchmark/economic verdict remains provisional. Latest warm-cache nginx matrix favors Hivemind with granular phase attribution, but the EKS rerun was degraded by GPU-node sandbox failures, so broad speedup/economic claims still need a clean EKS rerun.

## Next 3 Concrete Steps

1. Resolve or avoid EKS GPU-node sandbox failures and rerun the warm-cache EKS matrix.
2. Fix Hivemind private ECR auth contract so cold-cache private image benchmarks can run.
3. Decide whether to destroy or retain Hivemind/EKS after the clean EKS rerun.

## Open Unknowns

- Exact Nebius Europe region still needs confirmation for future live multi-provider work.
- Temporary EKS baseline is intentionally isolated under `infra/poc-eks/`; EKS control plane and nodegroups are currently left up for follow-up artifact refresh.
- Warm-cache Hivemind-vs-EKS reruns are collected and final benchmark docs refreshed, but benchmark/economic verdict remains provisional until clean EKS rerun.
- Old Drill A timeout was partly a test/deploy bug: `hivemind-api.service` required local `hivemind.service`, so stopping the leader also killed the public API gateway.
- Local live failover smoke is green for 3 and 5 replicas after fixing VRR frame sizing and API stale-reply handling.
- Targeted cloud Section 5 and repeatability are green for the functional/resilience POC.

## Entries

### 2026-07-16 — Ambiguous run outcomes, bounded peer handshakes, and StartPod parsing closed

What changed:
- `/run` status `5` is now the cross-language `outcome_ambiguous` result for any worker write attempt or disconnect that may follow acceptance; status `4` remains response-too-large only
- the Go gateway emits stable machine-readable `outcome_ambiguous` and pre-send `unavailable` errors; operator workflow retries only `unavailable` and `queue_full`, never ambiguous or generic failures
- peer TCP connect is nonblocking with bounded connect/identity deadlines; configured targets remain separate from validated identities, silent sockets expire, and validated bindings are never evicted
- Rust StartPod parsing requires every declared env record, validates the optional registry-auth trailer exactly, and rejects truncation, overflow, and trailing bytes

Why it matters:
- prevents automated duplicate workload execution, bounds black-hole/silent peer resource use without suppressing liveness retries, and closes fail-open StartPod env/secret parsing

Current acceptance progress: unchanged (`6 / 8` POC v1 sections; execution checklist `16 / 16` warm-cache pack)

Next steps:
1. retain application-level idempotency keys and authenticated per-peer identity as future protocol work
2. rerun independent safety review after the deterministic and local failover gates

Live infra status: unchanged (`up` from prior entries; deterministic/offline verification only)

### 2026-07-16 — `/run` ambiguous outcomes and worker response ownership hardened

What changed:
- the Go gateway never resends a `/run` request after any write attempt; read, parse, request-ID, and write failures after that boundary return `ErrRunOutcomeAmbiguous`
- worker responses resolve only when both the opaque correlation ID and sender worker index match one active entry
- malformed, oversized, foreign, and unknown worker responses disconnect only the sender through centralized worker cleanup, releasing all sender-owned correlations with deterministic client errors
- deterministic saturation coverage proves malformed-response cleanup, 1024-slot reuse, ownership isolation, unknown-ID isolation, and valid response boundaries

Why it matters:
- prevents duplicate workload execution after an accepted request loses its response and prevents one worker from resolving or leaking another worker's client correlation

Current acceptance progress: unchanged (`6 / 8` POC v1 sections; execution checklist `16 / 16` warm-cache pack)

Next steps:
1. rerun independent `/run` safety review
2. retain application-level idempotency keys as future protocol scope; ambiguous requests are not automatically replayed

Live infra status: unchanged (`up` from prior entries; deterministic/offline verification only)

### 2026-07-16 — Adversarial safety gate follow-up

What changed:
- run requests select a connected worker before dequeue; explicit send failure and post-dispatch worker disconnect atomically release all worker-owned correlations and return unavailable without unsafe automatic requeue; the 1024-entry bound and slot reuse remain deterministic
- peer startup uses one connection direction per configured pair (lower ID outbound, higher ID inbound); established bindings are immutable, and the unauthenticated initial-bind/TLS-auth limitation plus no mixed-version rolling support are explicit
- Go cluster-state parsing validates exact record sizes and bounded counts before allocation; workload benchmarks reprobe the configured replica list; GPU source archives are per-run and workspace-owned
- run requests now use gateway-unique worker correlation IDs and restore the original client/request identity on reply; a full 1024-entry table backpressures before dequeue instead of evicting unrelated work
- reciprocal peer sockets converge deterministically by replica ID and direction (lower ID outbound, higher ID inbound) only after a fully validated frame; invalid Prepare, Commit, and StartView frames leave the healthy binding intact
- worker response bodies have one 16 KiB-minus-metadata bound across Rust, Zig, and Go; overflow becomes explicit status 4 instead of successful truncation; frame writers reject oversize before allocation/write
- GPU tests use per-run Terraform workspaces and local metadata directories; a concurrent barrier fixture proves overlapping runs destroy only their own workspaces; S3/Terraform teardown failures are recorded and fail an otherwise successful run without replacing the original test status
- layout-v2 header, metadata, Command, LogEntry, and checksum inputs now use fixed-size little-endian codecs with static golden bytes
- active storage docs retain the full-cluster-stop/fresh-data boundary and no rolling migration/incarnation claim

Why it matters:
- closes cross-client response disclosure/loss, duplicate-peer eviction, concurrent infra destruction, successful response corruption, and ABI/endian-dependent journal risks found by the adversarial gate

Current acceptance progress: unchanged (`6 / 8` POC v1 sections; execution checklist `16 / 16` warm-cache pack)

Next steps:
1. rerun the independent publish/adversarial gates
2. retain the torn-write, dual-copy, migration, and snapshot work as separate production-hardening scope

Live infra status: unchanged (`up` from prior entries; deterministic/offline verification only)

### 2026-07-16 — Exact /run request-response length contract

What changed:
- Go API, Zig core/RequestQueue, and Rust worker now require exact declared run payload length with shared `MAX_PAYLOAD = 512`
- Oversized, short/long declared lengths, trailing bytes, and truncated/extra response bodies are rejected (no clamp)
- Go run responses require request-id match; gateway 9-byte errors remain valid

Why it matters:
- closes a fail-open wire contract gap on the POC `/run` path before publish

Current acceptance progress:
- publish-gate blocker on run-length clamping addressed in this worktree; remaining blockers unchanged

Next steps:
- re-run readiness/publish gate on updated HEAD

Live infra status: unchanged by this change

### 2026-07-16 — FileDisk journal layout v2 with explicit LogEntry codec

What changed:
- FileDisk journal format bumped to layout version 2
- on-disk LogEntry uses an explicit little-endian codec with checked tag-first Command decoding (never native `@sizeOf(LogEntry)` / `asBytes`)
- actual legacy layout v1 journals are rejected fail-closed as incompatible; no migration or specific error category is promised
- corrupt Command tags fail during open/decode without materializing invalid unions
- 1024-slot lifetime cap and complete-write/sync-before-publication semantics unchanged

Why it matters:
- after the nested Command wire codec change, persisting native tagged-union bytes under version 1 was an unsafe layout mismatch; v2 makes the durable format explicit and fail-closed

Acceptance progress: unchanged (`6 / 8`)

Live infra status: unchanged (`up` from prior entries; deterministic journal codec only — no new live durability evidence)

### 2026-07-16 — Fixed nested wire codec and fail-closed bench/deploy gates

What changed:
- nested `Command`/`Result` deserialize now uses a fixed tag-first wire codec (validate raw tag before union construction) with bound/boolean checks for env/rule/binding counts, probe/killswitch bools, and secret flags
- `Prepare` semantic preflight (`commit_min <= op <= LOG_SIZE_MAX`, `retention_floor <= commit_min`, `entry.op_number` match, checksum) runs before view/status/log mutation
- outer message deserialize requires exact payload size; gateway run errors route through `sendFrame`
- bench rejects truncated command/run successes and non-exact plaintext flags/version; deploy dead-process path exits nonzero; SSM wait uses a wall-clock deadline

Why it matters:
- closes the re-review release blockers for malformed peer traffic UB, benchmark false-success samples, and deploy reporting healthy clusters when processes are dead

Progress after change:
- Acceptance sections complete: `6 / 8` (unchanged)
- Execution checklist complete: `16 / 16` for warm-cache evidence pack (unchanged)
- Infra status: `up` (unchanged)

Next steps:
1. Resolve or avoid EKS GPU-node sandbox failures and rerun the warm-cache EKS matrix.
2. Fix Hivemind private ECR auth contract so cold-cache private image benchmarks can run.
3. Decide whether to destroy or retain Hivemind/EKS after the clean EKS rerun.

Blockers / unknowns:
- crash-consistent torn-write / power-loss durability remains unvalidated (experimental journal)

### 2026-07-16 — Peer-input safety and launcher fail-closed hardening

What changed:
- checked VRR deserialize (invalid tag / short payload / oversized DVC count) and peer identity/bound validation before vote and journal mutation
- secret-bearing env files and journal paths fail-closed on permissions; GPU and bench launchers no longer fail-open on test status, broad `pkill`, or caller CWD
- VOPR liveness retries recovery after clearing transient faults without wiping durable state; checker `committed_by` widened to `u16` for 11-replica topologies

Why it matters:
- peer identity/bound checks and launcher fail-closed paths reduce forged votes and false-success deploy reports
- nested Command/Result wire safety was still incomplete at this entry; do not treat panic/UB immunity as landed until the fixed nested codec lands

Progress after change:
- Acceptance sections complete: `6 / 8` (unchanged)
- Execution checklist complete: `16 / 16` for warm-cache evidence pack (unchanged)
- Infra status: `up` (unchanged)

Next steps:
1. Resolve or avoid EKS GPU-node sandbox failures and rerun the warm-cache EKS matrix.
2. Fix Hivemind private ECR auth contract so cold-cache private image benchmarks can run.
3. Decide whether to destroy or retain Hivemind/EKS after the clean EKS rerun.

Blockers / unknowns:
- nested `Command` union tags still lack a stable wire-byte layout for deserialize-time validation; handlers continue to rely on `LogEntry.valid()` and apply-time checks

### 2026-07-16 — Withdraw unvalidated crash-durability claims

What changed:
- at this entry, active docs narrowed the validated contract to write/sync success before publication, fail-stop on complete I/O errors, fail-closed 1024-op retention, and the then-current experimental layout-v1 single-copy best-effort restart recovery; the later layout-v2 entry supersedes that format version
- recorded canonical recovered-prefix (`observeRecovery`) and immutable committed-prefix validation; recorded HM-BLK-04/05 launcher repairs against maintained smoke/failover/bench paths
- explicit non-claims: no torn-write/power-loss guarantee or simulation; S3 `journal.bin` copy is not an atomic restore artifact; no production crash-durability wording
- FINDINGS adds crash-consistent versioned storage + torn-write simulation as a production blocker separate from snapshots

Why it matters:
- keeps POC safety hardenings reviewable without overclaiming production crash durability

Acceptance progress: unchanged (`6 / 8` POC v1 sections; execution checklist `16 / 16` warm-cache pack; POC v2 still the presentation gate)

Next steps:
1. option-A crash-consistent journal + torn-write simulation before any production durability claim
2. snapshot + snapshot-transfer PR to remove the 1024-op lifetime cap
3. continue POC v2 AppSpec / workload parity work

Live infra status: unchanged (`up` from prior entries; docs-only — no new live durability evidence)

### 2026-07-16 — Repair active smoke and benchmark launchers

What changed:
- stale `tests/smoke_test.sh` / `tests/multi_node_smoke_test.sh` are `exec` wrappers to `local-smoke.sh --build` / `local-failover-smoke.sh --build`
- `bench/compare.sh`, `infra/bench/{deploy.sh,main.tf}`, `infra/poc/hivemind.service`, `infra/gpu-test/run-tests.sh` use current `core/`/`worker/` roots and `--worker-port`
- bench client speaks flags-byte framing; `HIVEMIND_ONLY=1` runs offline without kind
- `tests/launcher_contract_test.sh` wired into `tests/run-all.sh`

Why it matters:
- active ops surfaces exercise current binaries instead of removed `agent/` / `--agent-port` / positional `cluster` paths

Acceptance progress: unchanged (`6 / 8`)

Live infra status: unchanged (`up` from prior entries; local launcher/bench verification only — no new live durability evidence)

### 2026-07-16 — Preserve canonical committed prefixes across recovery

What changed:
- VOPR `StateChecker.observeRecovery` rejects recovered commit regression and divergent recovered canonical prefixes
- `journalPut` / `onStartView` / `maybeStartView` reject same-op different-checksum replacement of locally committed slots; conflicting committed DVC values stay in view_change
- deterministic regressions: `checker rejects: recovered commit regression`, `checker rejects: divergent recovered canonical prefix`, `StartView rejects conflicting committed prefix`, `view change rejects conflicting committed DVC values`

Why it matters:
- recovery and view installation no longer silently mutate or escape the canonical committed prefix under adversarial deterministic tests

Acceptance progress: unchanged (`6 / 8`)

Live infra status: unchanged (`up` from prior entries; deterministic safety only — no new live durability evidence)

### 2026-07-16 — Narrow experimental journal runtime contract

What changed:
- `--data-dir` is optional again: absent logs explicit volatile POC mode; present logs an experimental single-copy journal warning that torn writes and power loss are not validated
- disk/simulation comments narrowed to whole write/sync failures and unsynced-write loss only (no torn-write claim)
- deterministic real-binary `tests/storage_mode_smoke_test.sh` covers both modes and is wired into `tests/run-all.sh`
- FileDisk remains layout version 1 with fail-closed 1024-op lifetime cap, checksums, sync-before-publication, and I/O fail-stop

Why it matters:
- avoids overclaiming production torn-write / power-loss durability while keeping the experimental journal path usable for POC
- makes storage mode operator-visible at startup without requiring live infrastructure to verify

Acceptance progress: unchanged (`6 / 8` POC v1 sections; POC v2 still the presentation gate)

Next steps:
1. keep HM-BLK-01 torn-write-safe production durability out of scope until a real design lands
2. snapshot + snapshot-transfer PR to remove the 1024-op lifetime cap
3. continue POC v2 AppSpec / workload parity work

Live infra status: unchanged (`up` from prior entries; this change is contract/docs + local smoke only)

### 2026-07-16 — Write/sync-before-publication VRR storage, fail-closed retained log, stronger VOPR checker
- Re-review hardenings: per-slot prepare identity after sync, fail-closed truncated journals, launcher `--data-dir`, journal/data-dir modes, sim write faults on metadata/clear.

What changed:
- PrepareOk, client replies, and worker effects wait for a successful journal/metadata write/sync barrier (synchronous group commit on the core loop)
- complete write/sync I/O failures fail-stop the replica (`storage_failed`) and exit nonzero in production
- recovery validates the metadata-declared committed prefix (checksum chain); corrupt/missing slots refuse to continue as a fresh replica
- retained log is fail-closed at `LOG_SIZE_MAX` (1024) with Zig `log_full`, API `ErrCodeLogFull`, and HTTP 507; no circular overwrite without snapshots
- VOPR checker compares full entry checksums, treats commit regression as a violation, and fails loudly on history capacity exhaustion
- deterministic filters: `durable storage`, `journal retention`, `group commit`, `checker rejects`
- explicit non-claims at this entry: no torn-write/power-loss model; S3 journal copy is not an atomic restore; restart recovery was limited to the then-current experimental layout-v1 single-copy journal (later superseded by layout v2)

Why it matters:
- closes previously acknowledged in-memory prepares/replies and wrap-around committed-overwrite classes under the validated write/sync and retention contract
- makes the finite-log blocker explicit to operators via metrics and HTTP 507 instead of silent overwrite

Acceptance progress: unchanged (`6 / 8` POC v1 sections; POC v2 still the presentation gate)

Next steps:
1. snapshot + snapshot-transfer PR to remove the 1024-op lifetime cap
2. keep codec/padding-free journal serialization as a separate coordinated PR
3. continue POC v2 AppSpec / workload parity work

Live infra status: unchanged (`up` from prior entries; this change is deterministic storage-safety only — no new live failure evidence)

### 2026-07-16 — Remove former platform association branding

What changed:
- scrubbed all former-platform brand strings across docs, infra comments, artifacts path strings, and Go module paths
- renamed Go modules from the old org path to `github.com/elijahrou/hivemind/v2/*`
- neutralized example hostnames to `*.hivemind.dev` and config names (`app.toml`) while keeping Hivemind architecture, routing, and POC acceptance content

Why it matters:
- Hivemind is no longer associated with that stack; docs and module identity should match the independent project
- architectural decisions (VRR, locality, AppSpec, simulation-first) stay; only brand-specific coupling was removed

Acceptance progress: unchanged (`6 / 8` POC v1 sections; POC v2 still the presentation gate)

Next steps:
1. continue POC v2 AppSpec / workload parity work without former-platform framing
2. treat remaining `*.hivemind.dev` hostnames as placeholders until real DNS is chosen

Live infra status: unchanged (`up` from prior entries; this change is docs/code identity only)

### 2026-05-04 — POC v2 acceptance spec defined

What changed:
- added `docs/POC_V2_ACCEPTANCE.md` as the pass/fail gate before presenting Hivemind as a credible current-system replacement candidate
- added `docs/design/HIVEMIND_NATIVE_PLATFORM.md` for Hivemind-native revision/routability/rollout direction
- updated `docs/FINDINGS_AND_ISSUES.md` to point next engineering passes at the POC v2 gate

Why it matters:
- the warm-cache benchmark win is not enough to convince the team by itself
- POC v2 now requires parity evidence for one real inference workload plus Hivemind-native revision/routability/rollout semantics
- the spec keeps the scope bounded: prove inference workload needs, not broad Kubernetes API compatibility

Next steps:
1. turn `AppSpec v1` into an implementation plan with simulation requirements
2. implement POC v2 in the order listed in `docs/POC_V2_ACCEPTANCE.md`
3. defer team-facing replacement pitch until POC v2 evidence pack is green


### 2026-05-03 — Containerd retry isolation and clean Hivemind rerun

What changed:
- changed containerd runtime container IDs from stable `hivemind-pod-{pod_id}` to bounded unique attempt IDs `hivemind-pod-{pod_id}-{sequence}`
- added bounded cleanup of legacy/attempt container families before create
- made `remove_pod` use kill/delete/container cleanup consistently
- fixed control-plane capacity leaks from inactive bound pods by recomputing node allocatable capacity on reconnect and refunding bound capacity when deployment delete marks pods inactive

Why it matters:
- previous degraded run was caused by hidden containerd task state where `ctr tasks start` returned `task ... already exists` even after cleanup
- unique attempt IDs avoid reusing poisoned task IDs; delete/reconnect capacity fixes keep repeated live benchmark runs from leaking scheduler capacity

Evidence:
- failed intermediate run `hmctrid-20260503013407` timed out in `50x1` at `38/50` due leaked node capacity from replayed/deleted pods
- clean full rerun `hmctrfix-20260503015744` completed with no worker `container start failed` lines in CPU worker journal window
- artifact dir: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmctrfix-20260503015744`
- run log: `artifacts/poc-final/00-runbook/hivemind-scale-matrix-hmctrfix-20260503015744.log`
- `single 0 -> 50 ready`: `7917ms`
- `50 -> 1 ready`: `488ms`
- `50x1 submit`: `10254ms`
- `50x1 all ready`: `23559ms`
- post-run cluster clean: `Deployments=0`, `Pods=0`, `Nodes=2`, `Agents=2`

Progress after change:
- Acceptance sections complete: `6 / 8`; Hivemind runtime-tail evidence improved for single-deployment burst, but economic verdict remains provisional pending clean EKS rerun
- Infra status: `up`

Next steps:
1. analyze remaining `50x1` latency, likely worker lifecycle wave/queue behavior rather than containerd start failures
2. consider persistent bounded lifecycle queues or split create/start queues if ROI justifies more Hivemind tuning
3. resolve EKS sandbox/CNI degradation and rerun EKS warm-cache matrix

Blockers / unknowns:
- EKS clean rerun still pending
- `50x1` Hivemind remains slower than desired despite no containerd start failures in latest run



### 2026-05-03 — Hivemind worker-tail benchmark rerun

What changed:
- deployed state slot reuse and cleaned replay-created active benchmark leftovers
- completed full Hivemind scale matrix run `hmtailfix3-20260503011835`

Why it matters:
- confirms the benchmark can complete after worker retry and state-slot fixes
- result is not a clean latency win: one containerd start failure still caused replacement/tail delay in the single 50-pod scenario

Evidence:
- artifact dir: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmtailfix3-20260503011835`
- run log: `artifacts/poc-final/00-runbook/hivemind-scale-matrix-hmtailfix3-20260503011835.log`
- `single 0 -> 50 ready`: `29099ms`
- `single 0 -> 50 scheduled`: observed in deep dive as `507ms` max scheduled span
- `50 -> 1 ready`: `469ms`
- `50x1 submit`: `9722ms`
- `50x1 all ready`: `21644ms`
- CPU worker logs show pod `10442886284136788347` hit repeated `ctr tasks start` `task ... already exists`, then failed after capped retries and was replaced
- post-run cluster clean: `Deployments=0`, `Pods=0`, `Nodes=2`, `Agents=2`

Progress after change:
- Acceptance sections complete: `6 / 8`; benchmark/economic verdict remains provisional
- Infra status: `up`

Next steps:
1. root-cause containerd `task ... already exists` after recreate cleanup; current cleanup did not remove enough task/container runtime state
2. rerun Hivemind after containerd cleanup fix if benchmark evidence needs non-degraded tail
3. rerun EKS only after AWS CNI/IP sandbox issue is clean

Blockers / unknowns:
- Hivemind latency tail remains degraded by containerd start failure/replacement
- EKS comparison still blocked by degraded EKS sandbox evidence



### 2026-05-03 — State slot reuse unblocks repeated benchmark runs

What changed:
- Hivemind scale rerun `hmtailfix2-20260503010614` completed the single-deployment scenario but failed during `50x1` create at deployment 12 with HTTP `503 {"error":"capacity_exceeded"}`
- root cause: state machine kept inactive deployment/pod slots after delete; repeated POC runs exhausted fixed `MAX_DEPLOYMENTS`/`MAX_PODS` arrays even with zero active deployments
- fixed create path to reuse inactive deployment and pod slots instead of treating historical deleted objects as live capacity use

Why it matters:
- repeated benchmark evidence collection must not require wiping replica state between runs
- this is control-plane behavior, so deterministic state-machine coverage and VOPR coverage were required

Evidence:
- failed run partial single result: `single 0 -> 50 ready = 5174ms`, then `50x1` failed at create 12 with capacity_exceeded
- added deterministic state-machine slot-reuse test
- `cd core && zig build test` passed
- `cd core && zig build fuzz -- sequential --seeds 10000 --mutate` passed with `failures_found=0`

Progress after change:
- Acceptance sections complete: `6 / 8`; benchmark section remains provisional until a full clean Hivemind rerun and clean EKS rerun exist
- Infra status: `up`

Next steps:
1. deploy state slot reuse
2. rerun full Hivemind scale matrix
3. record full summary/deep-dive artifacts

Blockers / unknowns:
- full corrected Hivemind run still pending after this fix
- EKS clean rerun still pending



### 2026-05-03 — Worker runtime-tail mitigation

What changed:
- improved containerd `ctr` failure diagnostics to include command, exit code, stdout, and stderr
- changed transient container start failure handling to remove stale container state, recreate the container, and retry locally before reporting pod failure to the control plane
- shortened lifecycle retry backoff so deterministic worker simulations converge after transient start failures
- fixed worker lifecycle span timestamps so `*_start`, `*_end`, and `running_status_sent` use actual wall-clock spans instead of the beginning of the worker tick
- raised pull/create/stop lifecycle concurrency to `4x` the base limit while keeping start concurrency at the bounded base limit

Why it matters:
- the `hmbatch-20260503003421` tail came from three CPU-worker `container_start` failures and replacement pods, not scheduler latency
- local recreate/retry should avoid waiting for failed-pod replacement when containerd leaves bad task/container state during burst startup
- better `ctr` errors make the next live failure actionable instead of hiding behind containerd deprecation warnings

Evidence:
- worker unit/runtime/integration tests passed
- worker deterministic fuzz `sequential --seeds 1000 --mutate` passed with `failures_found=0`

Progress after change:
- Acceptance sections complete: `6 / 8` with Sections 7-8 provisional
- Execution checklist complete: `16 / 16` for warm-cache evidence pack; worker-tail mitigation still needs live benchmark evidence
- Infra status: `up`: Hivemind and EKS retained

Next steps:
1. deploy worker-tail mitigation
2. rerun Hivemind scale matrix and compare `single 0 -> 50 ready` against `19739ms`
3. inspect new `ctr` diagnostics if any start failures remain

Blockers / unknowns:
- benchmark/economic verdict remains provisional pending clean EKS rerun
- first live rerun exposed a retry-accounting bug: create success reset `lifecycle_failures`, causing one pod to loop in scheduled/Starting instead of failing and being replaced
- fixed by preserving start retry count across recreate attempts and adding a deterministic regression test for capped repeated start failures
- live impact still pending until redeploy/rerun of the corrected fix



### 2026-05-03 — Live Hivemind batch-bind benchmark rerun

What changed:
- deployed batch-bind core/API/worker binaries to existing Hivemind infra
- reran Hivemind warm-cache scale matrix with run id `hmbatch-20260503003421`

Why it matters:
- validates the scheduler/bind fix on the live POC cluster after deterministic VOPR coverage
- isolates scheduler convergence from worker/containerd runtime tail

Evidence:
- deploy log: `artifacts/poc-final/00-runbook/deploy-batchbind-*.log`
- benchmark log: `artifacts/poc-final/00-runbook/hivemind-scale-matrix-hmbatch-20260503003421.log`
- output dir: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmbatch-20260503003421`
- `single 0 -> 50 pods_scheduled_observed`: `334ms` versus prior `778ms` baseline
- `single 0 -> 50 ready`: `19739ms`; slower than prior clean resilience run because runtime tail dominated despite fast scheduling
- `50x1 submit total`: `9703ms`
- `50x1 all ready`: `17396ms`
- `latency-deep-dive.md` and `latency-firechart.html` generated
- post-run cluster state: `Deployments=0`, `Pods=0`, `Nodes=2`, `Agents=2`, `QueueDepth=0`, `InFlight=0`

Progress after change:
- Acceptance sections complete: `6 / 8` with Sections 7-8 provisional
- Execution checklist complete: `16 / 16` for warm-cache evidence pack
- Infra status: `up`: Hivemind and EKS retained

Next steps:
1. treat scheduler/bind issue as fixed for live POC evidence
2. investigate worker/containerd runtime tail if optimizing `0 -> 50 ready` further
3. rerun EKS only after sandbox/IP failures are resolved for fair comparison

Blockers / unknowns:
- benchmark/economic verdict remains provisional pending clean EKS rerun
- Hivemind runtime tail still needs per-pod worker/API log attribution for flame-level detail


### 2026-05-02 — Scheduler batch bind implementation

What changed:
- scheduler now emits up to 64 bind actions per tick and accounts for tentative same-tick capacity before selecting nodes
- replica leader submits one `bind_pods_to_nodes` consensus command for scheduler bind batches instead of one command per pod
- state machine applies batch binds with deterministic all-or-nothing validation and aggregate capacity checks
- latency artifacts now include a reusable deep-dive Markdown report and HTML firechart generator

Why it matters:
- directly targets the observed `single 0 -> 50` scheduling convergence cost where 50 pods previously required multiple scheduler passes and many VRR bind commands
- preserves capacity safety by rejecting invalid or overcommitted batches without partial mutation

Evidence:
- deterministic unit/VOPR coverage added for 50-pod scheduler batches, batch state-machine invariants, committed batch dispatch, and 3-replica VOPR scheduling
- deep VOPR sweep initially found safety regressions at seeds `1265`, `3021`, `3482`, then after first fix found `6685`, `8531`, and an invariant regression at `5542`
- fixed follower stale-suffix commit handling by replacing conflicting uncommitted prepares and making commit heartbeats carry the leader commit checksum before followers advance commit
- replayed all discovered seeds successfully: `1265`, `3021`, `3482`, `6685`, `8531`, `5542`
- `cd core && zig build fuzz -- sequential --seeds 10000 --mutate` passed with `failures_found=0`
- live benchmark rerun pending after deploy

Progress after change:
- Acceptance sections complete: `6 / 8` with Sections 7-8 provisional
- Execution checklist complete: `16 / 16` for warm-cache evidence pack
- Infra status: `up`: Hivemind and EKS retained; batch-bind binaries not yet deployed

Next steps:
1. run full core/API verification and VOPR fuzz gate
2. deploy batch-bind Hivemind binaries when no pending benchmark workload is active
3. rerun Hivemind warm-cache matrix and compare scheduled convergence against `778ms` baseline

Blockers / unknowns:
- live scheduling latency impact not measured yet



### 2026-05-02 — Lifecycle failure resilience after parallelism rerun

What changed:
- worker `container_start` now retries transient start failures with bounded backoff before reporting a pod failed
- control plane now creates a replacement pending pod when an active deployment pod reaches `failed`
- worker simulation transition checker now accepts direct Starting -> Stopped during shutdown paths observed in deterministic fuzz

Why it matters:
- first post-parallelism Hivemind rerun reached `48/50` then stalled because two containerd starts failed and desired replicas were not replenished
- failed runtime starts no longer permanently strand deployments below desired replica count

Evidence:
- `cd core && zig build test` passed
- `cd worker && cargo test` passed: `92` lib tests plus main/integration/doc suites
- failing pre-fix live run preserved at `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmparallel-20260502225517`

Progress after change:
- Acceptance sections complete: `6 / 8` with Sections 7-8 provisional
- Execution checklist complete: `16 / 16` for warm-cache evidence pack
- Infra status: `up`: Hivemind and EKS retained; fixed binaries still need redeploy + rerun

Next steps:
1. redeploy fixed Hivemind binaries to existing infra
2. rerun Hivemind warm-cache matrix and confirm no desired-replica stall
3. rerun EKS same matrix for fresh comparison

Blockers / unknowns:
- live benchmark impact of retry/replacement fix not yet measured


### 2026-05-02 — API and worker bounded parallelism implemented

What changed:
- API consensus commands now use bounded concurrent short-lived leader connections instead of holding the gateway client mutex through send + reply wait
- worker pod lifecycle now runs pull/create/start/stop operations with bounded concurrency (`4` default, `1..32` clamp) instead of one blocking containerd operation at a time
- worker now reserves CPU, memory, and GPU on `StartPod` admission and rejects overcommit before inserting a pod
- worker simulation checker now validates CPU/memory accounting in addition to GPU accounting

Why it matters:
- directly addresses latest Hivemind latency attribution: submit path serialization and worker/containerd lifecycle queueing
- preserves node-capacity safety by counting ImagePulling/Creating/Starting pods as allocated before runtime work begins

Evidence:
- API regression test: concurrent consensus commands are both sent before either reply returns
- worker unit test: lifecycle concurrency reaches bound `2` without exceeding it
- worker unit test: CPU/memory overcommit is rejected before pod insertion
- worker simulation test: bounded lifecycle concurrency preserves resource invariants under fitted + overcommit workloads

Progress after change:
- Acceptance sections complete: `6 / 8` with Sections 7-8 provisional
- Execution checklist complete: `16 / 16` for warm-cache evidence pack
- Infra status: `up`: Hivemind and EKS left up for reuse; no live rerun after this code change yet

Next steps:
1. deploy and rerun Hivemind warm-cache scale matrix to quantify latency delta
2. tune lifecycle concurrency if containerd/snapshotter pressure appears
3. consider true background lifecycle executor if scoped bounded parallelism still blocks heartbeat/read loops too long

Blockers / unknowns:
- worker lifecycle is bounded-concurrent within a `drive_pods` wave, not a persistent async executor yet
- API now avoids the blocking gateway mutex by using per-command connections; connection pooling/request-id demux may be a future throughput optimization


### 2026-05-02 — Final benchmark docs refreshed from granular artifacts

What changed:
- refreshed final benchmark/evidence docs from the Hivemind `hmlatdetail-20260502204533` and EKS `ekslatdetail-20260502203515` latency artifacts
- updated comparison summary, raw CSV rows, final POC summary, final verdict, acceptance notes, and status report

Why it matters:
- the final evidence pack no longer says the next step is to run a warm-cache benchmark; that benchmark is now collected
- benchmark/economic verdict stays provisional for the right reason: EKS warm-cache run was degraded by GPU-node sandbox failures, not image pulls

Evidence:
- `artifacts/poc-final/06-benchmarks/results-summary.md`
- `artifacts/poc-final/06-benchmarks/hivemind-vs-eks.md`
- `artifacts/poc-final/06-benchmarks/raw-results.csv`
- `artifacts/poc-final/00-summary.md`
- `artifacts/poc-final/07-conclusion/verdict.md`
- `docs/POC_ACCEPTANCE.md`
- `docs/STATUS.md`

Progress after change:
- Acceptance sections complete: `6 / 8` with Sections 7-8 provisional
- Execution checklist complete: `16 / 16` for warm-cache evidence pack
- Infra status: `up`: Hivemind and EKS left up for reuse

Next steps:
1. rerun clean EKS warm-cache matrix after sandbox failures are resolved or avoided
2. fix Hivemind private ECR auth contract for cold-cache private-image run
3. update economic/cost readout only after clean EKS rerun

Blockers / unknowns:
- broad EKS speedup/economic claim remains blocked by EKS sandbox-failure rerun uncertainty
- cold-cache private ECR remains blocked by auth contract limits


### 2026-05-02 — Granular latency instrumentation and live reruns

What changed:
- added granular latency artifacts to the live scale-matrix evidence flow and reran warm-cache nginx matrices for Hivemind and EKS
- Hivemind warm nginx matrix passed as `hmlatdetail-20260502204533`
- EKS was warmed with a DaemonSet cache pass, then rerun as `ekslatdetail-20260502203515`

Why it matters:
- replaces coarse wall-clock-only evidence with phase-level artifacts for Hivemind API/core/worker and EKS Kubernetes/pod event paths
- gives cache-normalized comparison inputs, but not yet the final benchmark/economic verdict

Evidence:
- Hivemind summary: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmlatdetail-20260502204533/summary.md`
- Hivemind latency summary/events: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmlatdetail-20260502204533/latency-summary.md`, `latency-events-consolidated.csv`, `latency-events-consolidated.jsonl`, `latency-flamegraph.folded`
- Hivemind run log: `artifacts/poc-final/00-runbook/hivemind-scale-matrix-hmlatdetail-20260502204533.log`
- EKS summary: `artifacts/poc-final/06-benchmarks/eks-scale-matrix-ekslatdetail-20260502203515/summary.md`
- EKS latency summary/events: `artifacts/poc-final/06-benchmarks/eks-scale-matrix-ekslatdetail-20260502203515/latency-summary.md`, `latency-events.csv`, `latency-spans.csv`, `latency-spans.jsonl`, `poll-observations.jsonl`, `latency-flamegraph.folded`
- EKS run log: `artifacts/poc-final/00-runbook/eks-scale-matrix-ekslatdetail-20260502203515.log`
- key metrics: Hivemind `0 -> 50 ready 8564ms`, `50 -> 1 ready 349ms`, `50 deployments x 1 ready 13174ms`; EKS `0 -> 50 ready 133463ms`, `50 -> 1 ready 28508ms`, `50 deployments x 1 ready 238171ms`

Progress after change:
- Acceptance sections complete: `6 / 8` with Sections 7-8 provisional
- Execution checklist complete: `16 / 16` for warm-cache evidence pack
- Infra status: `up`: Hivemind live for reuse; EKS control plane and nodegroups left up

Next steps:
1. rerun clean EKS warm-cache matrix after sandbox failures are resolved or avoided
2. fix Hivemind private ECR auth contract for cold-cache private-image run
3. decide whether to destroy or retain EKS after follow-up evidence work

Blockers / unknowns:
- benchmark/economic verdict remains provisional pending clean EKS rerun
- EKS warm-cache parity used a DaemonSet prewarm and was called out in final comparison text
- EKS run hit `49` `FailedCreatePodSandBox` events, so economic verdict remains provisional


### 2026-05-02 — Sequential scale matrix blocker fixed in live Hivemind

What changed:
- added leader heartbeat-based redispatch for pods that remain `scheduled`, bounded by `WORKER_DISPATCH_RETRY_INTERVAL`
- fixed the worker stop path so `StopPod` does not block the agent event loop for the 30s grace period before it can read subsequent `StartPod` frames
- added regression tests for scheduled-pod redispatch and nonblocking worker stop behavior
- hardened `infra/poc/scale-matrix.sh` with create retries and empty-cleanup safety

Why it matters:
- live evidence showed post-churn `50x1` pods were scheduled but did not reach workers
- the root cause was worker churn backpressure: synchronous stop grace blocked reads during scale-down/delete, so later starts sat behind stop work
- full Hivemind sequential scale matrix is now green under warm-cache nginx scale conditions

Evidence:
- live pass: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmdispatchstopfix2-20260502194317/summary.md`
- run log: `artifacts/poc-final/00-runbook/hivemind-scale-matrix-hmdispatchstopfix2-20260502194317.log`
- results: `0 -> 50 ready 10978ms`, `50 -> 1 ready 369ms`, `50 deployments x 1 ready 14580ms`
- verification: `cd core && zig test src/unit_tests.zig`, `cd core && zig test src/unit_tests.zig -OReleaseFast`, `cd core && zig build test`, `cd worker && cargo test`, `cd api && go test ./...`

Progress after change:
- Acceptance sections complete: `6 / 8`
- Execution checklist complete: `14 / 16`
- Infra status: `mixed`: Hivemind live for reuse; EKS nodegroups/workers destroyed; EKS control plane remains due IAM explicit deny on `eks:DeleteCluster`

Next steps:
1. rerun the matching EKS phase scale matrix
2. generate phase attribution tables from Hivemind/EKS `latency-events.csv`
3. refresh benchmark docs and final verdict without overclaiming cache-normalized speedups

Blockers / unknowns:
- benchmark/economic verdict still provisional until EKS phase rerun and final docs are refreshed
- cold-cache Hivemind private ECR remains blocked by image-pull auth password size

### 2026-05-02 — VRR log-window hypothesis fixed in simulation but live sequential matrix still fails

What changed:
- expanded the VRR retained log / DVC bitset window from `256` to `1024` ops so the POC scale matrix no longer exhausts the circular journal during create/bind/status churn
- changed the pipeline guard to use a quorum-retained floor rather than the cluster-min retention floor, so one stale/silent replica does not unnecessarily pin a healthy leader
- added `hivemind_consensus_pipeline_guard_drops_total` to expose future guard drops directly in metrics
- resized file-backed disk bitmap layout to match the larger journal
- added deterministic VOPR coverage for healthy churn beyond the old 256-op window and for `0 -> 50 -> 1` followed by `50 deployments x 1` placement

Why it matters:
- the old 256-op window was too close to the create/bind/status volume in the POC scale matrix, and the new metric makes future drops visible
- live rerun still failed, so the VRR log-window hypothesis is insufficient as the full root cause
- benchmark/economic verdict remains provisional

Evidence:
- deterministic coverage: `core/src/vopr/test_harness.zig`
- metrics exposure: `hivemind_consensus_pipeline_guard_drops_total`
- verification: `cd core && zig test src/unit_tests.zig`, `cd core && zig test src/unit_tests.zig -OReleaseFast`, `cd core && zig build test`
- live rerun failure: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmscalevrr-20260502162739/summary.md`

Progress after change:
- Acceptance sections complete: `6 / 8`
- Execution checklist complete: `14 / 16`
- Infra status: `mixed`: Hivemind destroyed; EKS nodegroups/workers destroyed; EKS control plane remains due IAM explicit deny on `eks:DeleteCluster`

Next steps:
1. patch `infra/poc/scale-matrix.sh` to capture pods, metrics, and worker journals before teardown on timeout
2. rerun the full live Hivemind scale matrix with diagnostics
3. root-cause the remaining post-churn `50 x 1` stall before refreshing benchmark artifacts

Blockers / unknowns:
- live rerun still timed out at `0/50` after `0 -> 50 -> 1` passed
- the failed rerun did not capture metrics because the wrapper exited before the post-run scrape
- EKS control-plane cleanup is still blocked by explicit IAM deny on `eks:DeleteCluster`
- cold-cache private ECR Hivemind benchmark remains blocked by auth contract limitations


### 2026-05-02 — Hivemind scale-out receive-buffer blocker fixed; sequential matrix still has a second blocker

What changed:
- fixed Rust worker TCP receive handling so buffered complete frames are decoded before reading more bytes into the fixed 32KiB buffer
- added deterministic `RealIo` coverage for a burst larger than the read buffer
- reran live Hivemind scale evidence against AWS
- `1 deployment: 0 -> 50 -> 1` now passes after the fix
- isolated Hivemind `50 deployments x 1 replica` passes after the fix
- full sequential Hivemind matrix still fails when `50 deployments x 1 replica` runs after the prior `0 -> 50 -> 1` scenario in the same control-plane lifetime

Why it matters:
- closes the original `recv failed: frame buffer full` worker-side burst bug for single-deployment scale-out
- proves Hivemind can now complete the requested `0 -> 50 -> 1` scenario live
- keeps benchmark/economic verdict provisional because the full sequential scale matrix is not green

Evidence:
- post-fix scale table: `artifacts/poc-final/06-benchmarks/scale-matrix-postfix-20260502.md`
- Hivemind sequential matrix rerun: `artifacts/poc-final/00-runbook/hivemind-scale-matrix-hmscalefix2-20260502150317.log`
- Hivemind isolated `50 x 1` rerun: `artifacts/poc-final/06-benchmarks/hivemind-50x1-hm50x1fix-20260502151839/summary.md`
- EKS comparison matrix: `artifacts/poc-final/06-benchmarks/eks-scale-matrix-eksscalematrix-20260502004435/summary.md`

Progress after change:
- Acceptance sections complete: `6 / 8`
- Execution checklist complete: `14 / 16`
- Infra status: `mixed`: Hivemind destroyed; EKS nodegroups/workers destroyed; EKS control plane remains due IAM explicit deny on `eks:DeleteCluster`

Next steps:
1. root-cause the remaining sequential Hivemind scale blocker after high-op scale churn
2. add deterministic control-plane/scheduler coverage for `0 -> 50 -> 1` followed by `50 x 1`
3. rerun full Hivemind/EKS matrix after the sequential blocker is fixed

Blockers / unknowns:
- full sequential Hivemind scale matrix is not green
- EKS control-plane cleanup is still blocked by explicit IAM deny on `eks:DeleteCluster`
- cold-cache private ECR Hivemind benchmark remains blocked by auth contract limitations


### 2026-04-30 — Benchmark acceptance reopened for cache-normalized comparison

What changed:
- downgraded the Hivemind-vs-EKS performance verdict from final to provisional
- documented that Hivemind images were preloaded while EKS pulled from ECR on measured deploy paths
- documented that scale-to-50 also needs explicit cache-state parity proof before speedup claims are valid
- updated final summary, verdict, acceptance, status, and benchmark artifacts to require warm-cache and cold-cache reruns

Why it matters:
- prevents overclaiming Hivemind speedups from mixed-cache data
- keeps the functional/resilience POC pass intact while reopening the benchmark/economic gate
- sets the next work to a fair benchmark instead of production-hardening based on premature performance conclusions

Evidence:
- provisional benchmark summary: `artifacts/poc-final/06-benchmarks/results-summary.md`
- provisional comparison table: `artifacts/poc-final/06-benchmarks/hivemind-vs-eks.md`
- provisional final summary: `artifacts/poc-final/00-summary.md`
- provisional verdict: `artifacts/poc-final/07-conclusion/verdict.md`

Progress after change:
- Acceptance sections complete: `6 / 8`
- Execution checklist complete: `14 / 16`
- Infra status: `mixed`: Hivemind destroyed; EKS nodegroups/workers destroyed; EKS control plane remains due IAM explicit deny on `eks:DeleteCluster`

Next steps:
1. run warm-cache Hivemind/EKS comparison with same image preloaded on both systems
2. run cold-cache Hivemind/EKS comparison after clearing image cache on both systems
3. refresh final verdict after cache-normalized data lands

Blockers / unknowns:
- fair performance result is unknown until cache-normalized benchmark runs
- EKS control-plane cleanup is still blocked by explicit IAM deny on `eks:DeleteCluster`
- exact Nebius Europe region still needs confirmation for future live multi-provider work


### 2026-04-30 — Final evidence pack and verdict completed

What changed:
- wrote the final POC summary at `artifacts/poc-final/00-summary.md`
- wrote the final verdict at `artifacts/poc-final/07-conclusion/verdict.md`
- added benchmark CSV rollup at `artifacts/poc-final/06-benchmarks/raw-results.csv`
- marked Section 8 and execution checklist item 15 complete

Why it matters:
- originally closed the final POC acceptance gate, but this is now superseded by the cache-parity review above
- now serves as a provisional final evidence pack: functional/resilience POC passes, benchmark/economic verdict waits for cache-normalized rerun
- preserves the EKS cleanup issue as an infra permissions blocker, not a Hivemind viability blocker

Evidence:
- final summary: `artifacts/poc-final/00-summary.md`
- final verdict: `artifacts/poc-final/07-conclusion/verdict.md`
- benchmark rollup: `artifacts/poc-final/06-benchmarks/raw-results.csv`
- latest repeatability pass: `artifacts/poc-final/00-runbook/runbook-poc-20260428195031.log`
- latest benchmark summary: `artifacts/poc-final/06-benchmarks/results-summary.md`

Progress after change at the time:
- Acceptance sections complete: `8 / 8`
- Execution checklist complete: `15 / 15`
- Infra status: `mixed`: Hivemind destroyed; EKS nodegroups/workers destroyed; EKS control plane remains due IAM explicit deny on `eks:DeleteCluster`

Current status: superseded by the cache-parity review above; benchmark acceptance is reopened.

Next steps:
1. get elevated AWS credentials or IAM exception to delete EKS cluster `hivemind-poc-eks-baseline`
2. scope the secured one-region internal alpha
3. confirm exact Nebius Europe region before future live multi-provider federation work

Blockers / unknowns:
- EKS control-plane cleanup is blocked by explicit IAM deny on `eks:DeleteCluster`
- exact Nebius Europe region still needs confirmation for future live multi-provider work
- production readiness remains blocked by security, app spec, provider automation, compaction, readiness/routing, and observability work


### 2026-04-30 — Section 7 EKS comparison completed with corrected scale-to-50 benchmark

What changed:
- ran the isolated EKS baseline under `infra/poc-eks/` after Section 6 repeatability passed
- captured EKS CPU/GPU deploy-to-ready and cold/warm `/run` latency evidence
- investigated the initial Hivemind 50-pod `0/50` result and proved it was an invalid short-image-reference/runtime failure, not a scheduler/control-plane failure
- reran Hivemind 50-pod scheduling with fully qualified `docker.io/library/nginx:1.27-alpine`, reaching `50/50` ready
- reframed the primary burst benchmark to match the product scenario: an existing deployment on existing nodes scales from `0 -> 50` replicas after a request influx
- wrote consolidated benchmark results to `artifacts/poc-final/06-benchmarks/results-summary.md`

Why it matters:
- collected the initial Hivemind-vs-EKS comparison and corrected an invalid short-image-reference failure
- showed useful Hivemind scheduler/control-plane diagnostics: scale-to-50 created/observed 50 pods by `181ms`; the remaining latency was runtime/readiness convergence
- produced recorded mixed-cache numbers for the target scenario: Hivemind `9604ms` vs EKS `23583ms` for existing deployment scale `0 -> 50`, both `50/50` ready
- current cache-parity review supersedes the speedup interpretation: these numbers are not final benchmark proof until image cache state is normalized or explicitly recorded for both systems

Evidence:
- consolidated results: `artifacts/poc-final/06-benchmarks/results-summary.md`
- comparison table: `artifacts/poc-final/06-benchmarks/hivemind-vs-eks.md`
- EKS baseline log: `artifacts/poc-final/00-runbook/eks-baseline-eks-20260429015703.log`
- EKS scale-to-50 evidence: `artifacts/poc-final/06-benchmarks/eks-scale50-eksscale50-20260430014932.md`
- Hivemind scale-to-50 evidence: `artifacts/poc-final/06-benchmarks/hivemind-scale50-hmscale50-20260430012532.md`
- valid Hivemind 50-nginx evidence: `artifacts/poc-final/06-benchmarks/hivemind-50nginx-hm50nginx-20260430005950.md`
- invalid-image diagnostic: `artifacts/poc-final/06-benchmarks/sched-repro-sched-20260429173314/summary.md`

Progress after change at the time:
- Acceptance sections complete: `7 / 8`
- Execution checklist complete: `14 / 15`
- Infra status: `mixed`: Hivemind destroyed; EKS nodegroups/workers destroyed; EKS control plane remains due IAM explicit deny on `eks:DeleteCluster`

Current status: Section 7 acceptance is reopened for cache-normalized benchmarking.

Next steps:
1. write `artifacts/poc-final/00-summary.md`
2. write `artifacts/poc-final/07-conclusion/verdict.md`
3. get elevated AWS credentials or IAM exception to delete EKS cluster `hivemind-poc-eks-baseline`

Blockers / unknowns:
- final evidence pack/verdict remains open
- EKS control-plane cleanup is blocked by explicit IAM deny on `eks:DeleteCluster`
- exact Nebius Europe region still needs confirmation for future live multi-provider work


### 2026-04-28 — Section 6 repeatability passed after placement-asserted Drill B and CPU-node scheduling preference

What changed:
- exposed worker node IDs in the dashboard workers view so failure drills can match workers to pod placement
- tightened `infra/poc/failure-drills.sh` Drill B to create CPU-only workloads with `gpu_type: none`, `gpu_count: 0`
- added a pre-kill Drill B placement assertion comparing CPU worker node ID from `/dashboard/workers` with the running drill pod node ID from `/dashboard/pods`
- changed scheduler behavior so CPU-only pods prefer CPU-only nodes when any fit, while still falling back to GPU nodes if no CPU node has enough CPU/RAM
- reran the full runbook with `RUN_EKS=false` and teardown enabled; smoke, workloads, operator workflow, placement-asserted failure drills, log capture, and teardown all completed

Why it matters:
- closes Section 6 without relying on luck or manual host/container surgery
- prevents ambiguous worker-loss evidence where a CPU-only pod landed on the GPU worker before the CPU worker was stopped
- conserves GPU nodes for GPU workloads by default while preserving fallback behavior
- unblocks isolated EKS baseline comparison

Evidence:
- runbook log: `artifacts/poc-final/00-runbook/runbook-poc-20260428195031.log`
- Drill B placement proof: `artifacts/poc-final/05-failure-drills/worker-placement-workers.html`, `artifacts/poc-final/05-failure-drills/worker-placement-pods.html`
- worker-loss proof: `artifacts/poc-final/05-failure-drills/worker-loss.txt`
- key result: `PASS: drill pod placed on CPU worker (attempt 1)` and `Failure Drill Results: 9 passed, 0 failed`
- teardown: `terraform -chdir=infra/poc state list` count `0`

Progress after change:
- Acceptance sections complete: `6 / 8`
- Execution checklist complete: `13 / 15`
- Infra status: `destroyed`

Next steps:
1. run isolated EKS baseline comparison
2. produce Hivemind vs EKS latency/ops table
3. write final evidence pack and verdict

Blockers / unknowns:
- EKS baseline remains unrun in this evidence cycle
- final evidence pack/verdict remains open
- exact Nebius Europe region still needs confirmation for future live multi-provider work

### 2026-04-28 — Targeted repeatability pivot found stale containerd task state after interrupted start

What changed:
- stopped the full repeatability rerun after it proved too slow for debugging; pivoted to a bounded Drill B repro on the live cluster from `poc-20260428115836`
- captured CPU worker containerd state around restart in `artifacts/poc-final/05-failure-drills/target-b-20260428123213/`
- observed `ctr tasks list` empty while `ctr containers list` still had the pod container and `ctr tasks start` returned `task ... already exists`
- patched `worker/src/runtime/containerd.rs` to clean stale task/shim state and retry `tasks start` once when `already exists` is returned but no adoptable task is visible
- added deterministic unit coverage for the shim path helper and kept the existing simulated restart/adoption coverage
- destroyed the interrupted live Hivemind infra after targeted capture

Why it matters:
- narrowed Section 6 failure from broad runbook repeatability to a concrete containerd edge case: worker restart can interrupt a `ctr` subprocess and leave state that is neither a visible running task nor a cleanly startable container
- the fix no longer depends on manual `ctr` cleanup on the host
- repeatability remains open because the bounded live rerun did not complete a clean second fresh redeploy

Evidence:
- partial rerun log: `artifacts/poc-final/00-runbook/runbook-poc-20260428115836.log`
- targeted repro: `artifacts/poc-final/05-failure-drills/target-b-20260428123213/`
- key artifact: `cpu-after-restart-before-run.txt` shows empty task list, existing pod container, and `ctr: task hivemind-pod-17678023832001937445: already exists`
- verification: `cd worker && cargo fmt && cargo test` passed
- Linux worker build: `bash infra/poc/build-binaries.sh --worker-only` passed via `cargo-zigbuild`
- teardown: `DESTROY_EKS=false DESTROY_HIVEMIND=true bash scripts/poc-teardown.sh` completed; infra status destroyed

Progress after change:
- Acceptance sections complete: `5 / 8`
- Execution checklist complete: `12 / 15`
- Infra status: `destroyed`

Next steps:
1. rerun Section 6 from fresh AWS infra with the stale-task retry patch
2. keep the run bounded; do not proceed to EKS unless Section 6 passes
3. if Drill B fails again, capture `ctr tasks list`, `ctr containers list`, and worker journal before teardown

Blockers / unknowns:
- no clean second fresh redeploy has passed after the stale-task retry patch
- targeted Drill B placement is not deterministic enough when both CPU and GPU workers can serve CPU-only pods; future drill evidence should assert the pod is on the CPU worker before stopping it

### 2026-04-28 — Section 6 repeatability exposed worker restart/containerd adoption bug

What changed:
- ran Section 6 repeatability full run `poc-20260428091331` with EKS disabled and teardown enabled
- fresh smoke, real CPU/GPU workload validation, operator workflow, and leader-loss drill passed
- CPU worker restart drill failed because the restarted worker redispatched an active pod whose containerd state survived worker process stop; `ctr tasks start` returned `task ... already exists`, the worker marked the pod failed, and later `/run` requests never recovered
- patched containerd runtime to adopt existing `RUNNING`/`CREATED` tasks for the same pod ID on redispatch and to treat `already exists` from `tasks start` as success when the task is already running
- later targeted capture showed an additional stale-state form: task listing empty, container present, and `tasks start` still reporting `already exists`; the runtime now also cleans stale task/shim state and retries start once
- extended deterministic simulated runtime coverage for adopting an existing running pod after worker process restart

Why it matters:
- Section 6 correctly caught a no-heroics repeatability gap: systemd worker restart does not imply containerd task teardown
- fix makes worker re-registration compatible with durable runtime state instead of requiring manual container cleanup
- repeatability remains open until rerun on fresh AWS infra

Evidence:
- repeatability run log: `artifacts/poc-final/00-runbook/runbook-poc-20260428091331.log`
- smoke: `22 passed, 0 failed`
- Section 5 A6: `PASS: post-kill run succeeds (attempt 1)`
- Section 5 B5: `FAIL: run did not recover`
- worker log: `ctr: task hivemind-pod-12186465589309304625: already exists`
- worker-loss evidence: `artifacts/poc-final/05-failure-drills/worker-loss.txt` showed empty `recovered=`
- verification: `cd worker && cargo test` passed locally (`85` lib tests, `4` main tests, `5` integration tests)
- Linux cross-check attempted with `cargo check --target x86_64-unknown-linux-gnu`, blocked by missing `x86_64-linux-gnu-gcc` for `ring`, not code failure
- infra status after run: destroyed

Progress after change:
- Acceptance sections complete: `5 / 8`
- Execution checklist complete: `12 / 15`
- Infra status: `destroyed`

Next steps:
1. rerun Section 6 repeatability on fresh AWS infra with the containerd adoption patch
2. if repeatability passes, update Section 6 acceptance and run isolated EKS baseline
3. if repeatability fails again, capture worker/containerd task listing before teardown

Blockers / unknowns:
- live repeatability not yet rerun after the containerd adoption patch
- containerd helper unit tests are Linux-only under `worker/src/runtime/containerd.rs` and were not executed on macOS

### 2026-04-28 — Cloud Section 5 failure drills passed end-to-end

What changed:
- worker CLI now accepts a bounded comma-separated replica address list and rotates on disconnect/connect failure
- `infra/poc/deploy.sh` now writes all replica worker addresses into worker env, not just replica 0
- non-leader replicas disconnect worker sockets so workers rotate until they reach the current leader
- agent registration request IDs now include current tick so re-registration after failover bypasses VRR client-table dedup
- committed node re-registration redispatches active bound pods, allowing worker service restart to recreate lost in-memory pod tracking
- added deterministic coverage for worker reconnect/run simulation, non-leader worker disconnect, re-registration dedup, and pod redispatch
- reran targeted cloud Section 5 cycle with EKS disabled and teardown enabled

Why it matters:
- closes the Section 5 live resilience gate: leader loss, CPU worker loss/restart, and client timeout cleanup all passed against fresh AWS infra
- confirms the previous A6 failure was worker-control-plane convergence, not a workload/runtime issue
- unblocks repeatability / second fresh redeploy; EKS remains deferred until repeatability passes

Evidence:
- run log: `artifacts/poc-final/00-runbook/section5-cycle-section5-20260428032916.log`
- drill log: `artifacts/poc-final/00-runbook/section5-section5-20260428033156.log`
- A5: `PASS: api reconnects after leader loss (attempt 1)`
- A6: `PASS: post-kill run succeeds (attempt 1)`
- B5: `PASS: run recovered (attempt 1)`
- C3: `PASS: post-timeout run succeeds (attempt 1)`
- result: `Failure Drill Results: 8 passed, 0 failed`
- infra status after run: destroyed

Progress after change:
- Acceptance sections complete: `5 / 8`
- Execution checklist complete: `12 / 15`
- Infra status: `destroyed`

Next steps:
1. run repeatability / second fresh redeploy
2. if repeatability passes, run isolated EKS baseline
3. write final evidence pack and verdict

Blockers / unknowns:
- repeatability not yet rerun after Section 5 passed
- EKS baseline remains blocked until repeatability passes

### 2026-04-28 — Cloud Section 5 now proves election succeeds but worker path fails

What changed:
- added `scripts/poc-section5-cycle.sh` to run bounded apply -> CPU image push/reuse -> deploy -> CPU preload -> targeted Section 5 -> teardown
- changed `infra/poc/hivemind-api.service` so the API gateway no longer `Requires=hivemind.service`; stopping local replica should not stop the gateway because it can reconnect to another replica
- tightened `infra/poc/failure-drills.sh` cleanup with `curl --max-time 15`
- added post-failover `/run` failure diagnostics capture for A6
- reran targeted cloud Section 5 with EKS disabled

Why it matters:
- A5 no longer blocks: a new leader was elected and the API gateway stayed reachable
- current blocker moved to A6: post-failover `/run` fails because the new leader has `hivemind_connections{type="agents"} 0`
- this is worker reconnect/request-forwarding behavior, not leader election

Evidence:
- run log: `artifacts/poc-final/00-runbook/section5-cycle-section5-20260428015211.log`
- A5: `PASS: api reconnects after leader loss (attempt 1)`
- new leader: `172.31.65.128:9001`
- A6: `FAIL: post-kill run succeeds (expected field 'model', got '')`
- diagnostics: `artifacts/poc-final/05-failure-drills/diagnostics-leader-loss-recovered-1777355696-35458/`
- new leader metrics showed `hivemind_is_leader 1` and `hivemind_connections{type="agents"} 0`
- infra teardown verified afterward: `terraform -chdir=infra/poc state list` count `0`; AWS EC2 `hivemind-*` running/stopped query returned `[]`

Progress after change:
- Acceptance sections complete: `4 / 8`
- Execution checklist complete: `11 / 15`
- Infra status: `destroyed`

Next steps:
1. implement worker reconnect to the current leader or replica-side run forwarding
2. add deterministic worker simulation coverage for leader loss with post-failover `/run`
3. rerun targeted Section 5 before repeatability/EKS

Blockers / unknowns:
- post-failover worker availability path is not live-safe yet
- EKS baseline remains blocked

### 2026-04-28 — Section 5 diagnostics and safer targeted runner added

What changed:
- patched `infra/poc/failure-drills.sh` to capture per-replica diagnostics immediately when A5 leader reconnect times out
- diagnostics include local API health, consensus metrics, view-change votes, repair/connection metrics, service status, TCP sockets for 9001/9102, process list, and recent replica/API journal logs
- added `scripts/poc-section5-drill.sh`, a Section 5-only runner for already-live infra
- the new runner refuses `RUN_EKS=true`, refuses empty Terraform state, uses latest image artifact if `CPU_IMAGE` is unset, and caps the drill with `SECTION5_TIMEOUT_SECONDS` defaulting to 1200s
- checked interrupted infra state and destroyed live Hivemind POC resources with `DESTROY_EKS=false DESTROY_HIVEMIND=true bash scripts/poc-teardown.sh`

Why it matters:
- future attempts should capture why AWS leader election/reconnect fails instead of only proving it failed
- Section 5 debugging can now be split into apply/deploy, targeted drill, and teardown steps instead of one long opaque runbook
- EKS remains blocked until Section 5 passes

Evidence:
- `bash -n infra/poc/failure-drills.sh` passed
- `bash -n scripts/poc-section5-drill.sh` passed
- `scripts/poc-section5-drill.sh` correctly fails fast when `infra/poc` state is empty
- teardown completed: `terraform -chdir=infra/poc output -json` returned `{}`

Progress after change:
- Acceptance sections complete: `4 / 8`
- Execution checklist complete: `11 / 15`
- Infra status: `destroyed`

Next steps:
1. bring up/deploy Hivemind in a bounded setup step
2. run `SSH_KEY=$HOME/.ssh/id_ed25519 scripts/poc-section5-drill.sh`
3. analyze `artifacts/poc-final/05-failure-drills/diagnostics-leader-loss-timeout-*`

Blockers / unknowns:
- root cause of AWS-only leader-loss failure is still open
- no EKS baseline until Section 5 is green

### 2026-04-28 — Cloud Section 5 rerun still failed after local fix

What changed:
- reran the cloud POC with `RUN_EKS=false` after the local leader-failover fix
- smoke, Section 3, and Section 4 passed again
- Section 5 Drill A still timed out waiting for API reconnect after stopping leader `172.31.65.24:9001`
- remote logs were captured and infra was destroyed

Why it matters:
- local TCP/process recovery is not sufficient evidence for AWS
- remaining failure needs better per-replica A5 diagnostics before another full run

Evidence:
- runbook: `artifacts/poc-final/00-runbook/runbook-poc-20260427212841.log`
- remote logs: `artifacts/poc-final/00-runbook/remote-logs-poc-20260427212841/`
- failure point: `FAIL: api reconnects after leader loss (timed out)`
- teardown completed after run

Progress after change:
- Acceptance sections complete: `4 / 8`
- Execution checklist complete: `11 / 15`
- Infra status: `destroyed`

Next steps:
1. add A5 timeout diagnostics before rerunning Section 5
2. rerun only targeted Section 5 against live infra
3. root-cause from metrics/logs before repeatability/EKS

Blockers / unknowns:
- exact AWS failure mode unknown: no stable post-kill leader was observed through API

### 2026-04-27 — Local live leader failover unblocked

What changed:
- root-caused local live leader-loss stall to real TCP frame sizing: `DoViewChangeMsg` with 8 log entries is ~53 KiB, but connection receive/decrypt buffers were 16 KiB
- increased core connection frame buffers to 64 KiB and added a regression test that the largest plaintext/encrypted VRR view-change frame fits
- kept `DVC_LOG_MAX=8`; reducing it reproduced a prior VOPR safety regression, so the fix is transport sizing, not weakening view-change evidence
- hardened API command reply handling so stale replies after reconnect are skipped unless `request_id` matches the in-flight command
- reran local live failover smoke for 3 and 5 replicas successfully

Why it matters:
- closes the local reproduction of the AWS Section 5 leader-loss blocker
- proves the real TCP/process path can elect a new leader, accept a post-failover deployment, and rejoin the killed replica locally
- moves the next POC step back to cloud Section 5 with EKS still disabled

Evidence:
- `cd core && zig test src/unit_tests.zig` passed: `127/127`
- `cd core && zig test src/unit_tests.zig -OReleaseFast` passed: `127/127`
- `cd core && zig build test` passed
- `cd api && go test ./...` passed
- `REPLICA_COUNT=3 KEEP_LOGS=true tests/local-failover-smoke.sh` passed; latest log `/tmp/hivemind-failover-smoke.Fsx79P`
- `REPLICA_COUNT=5 KEEP_LOGS=true tests/local-failover-smoke.sh --build` passed; latest log `/tmp/hivemind-failover-smoke.6nQrhf`

Progress after change:
- Acceptance sections complete: `4 / 8`
- Execution checklist complete: `11 / 15`
- Infra status: `destroyed`

Next steps:
1. rerun Section 5 cloud failure drills with `RUN_EKS=false`
2. if Section 5 passes, run second fresh redeploy repeatability gate
3. only then run isolated EKS baseline comparison

Blockers / unknowns:
- cloud Section 5 has not been rerun after the local live fix
- worker-loss and abandoned-run drills still need fresh live evidence


### 2026-04-27 — Local failover VOPR coverage added; live smoke reproduces leader-loss blocker

What changed:
- added simulated process stop/start support to the VOPR test harness
- added VOPR coverage for leader stop, follower stop, node restart/rejoin, convergence, and committed-state survival
- changed post-view-change repair to wait for a quorum of status replies instead of every peer, so a stopped replica does not pin recovery
- added `tests/local-failover-smoke.sh` to start local real replica processes plus API, commit work, kill the leader, and capture diagnostics
- added API client reconnect/refresh retry paths and health refresh so stale leader sockets are not trusted
- added control-plane metrics for view-change votes, repair state, and identified peer counts

Why it matters:
- deterministic simulation now covers the leader/node kill scenarios needed before another cloud Section 5 run
- local live smoke reproduces the live failure without AWS spend
- the remaining blocker is narrowed to real TCP peer/bootstrap behavior, not the simulated VRR path

Evidence:
- VOPR: `zig test src/unit_tests.zig --test-filter 'live-style leader stop'` passed
- VOPR: `zig test src/unit_tests.zig --test-filter 'process kills'` passed
- regression: `zig test src/unit_tests.zig --test-filter '100-seed sweep'` passed
- regression: `zig test src/unit_tests.zig --test-filter 'heavy crash faults'` passed
- API: `go test ./...` passed in `api/`
- local live smoke: `REPLICA_COUNT=3 tests/local-failover-smoke.sh` failed as expected, reproducing leader-loss stall; latest diagnostic log under `/tmp/hivemind-failover-smoke.l9Ufzk`

Progress after change:
- Acceptance sections complete: `4 / 8`
- Execution checklist complete: `11 / 15`
- Infra status: `destroyed`

Next steps:
1. fix real TCP peer/bootstrap behavior so local live smoke elects a new leader after leader kill
2. rerun local failover smoke with 3 and 5 replicas
3. rerun cloud Section 5 with `RUN_EKS=false` only after local live smoke is green

Blockers / unknowns:
- local live smoke still fails after leader kill; surviving replicas report `view_change` and no stable API leader
- peer identification/duplicate TCP connection behavior appears implicated, but final root cause is not closed

### 2026-04-27 — Operator proof passed; failure drills exposed leader-loss blocker

What changed:
- ran fresh Hivemind-only POC with Sections 3-5 enabled and EKS disabled
- patched Section 3 cleanup so workload CPU/GPU deployments are deleted before Section 4, freeing the single GPU
- patched failure-drill checks to validate real model output instead of echo payloads
- patched failure-drill leader mapping from private leader address to public SSH IP
- patched failure-drill cleanup to restart `hivemind-api` with `hivemind`
- captured remote logs before teardown after leader-loss failure
- destroyed all POC infra after capture

Why it matters:
- Section 4 is now complete with real create/update/rollback/scale/scale-zero/wake/delete evidence
- Section 5 remains the next hard blocker; running EKS before fixing it would waste spend
- the failure is now evidenced instead of speculative

Evidence:
- runbook: `artifacts/poc-final/00-runbook/runbook-poc-20260427150339.log`
- operator: `artifacts/poc-final/05-operator/operator-workflow-poc-20260427150339.txt`
- failure attempt: `artifacts/poc-final/05-failure-drills/failure-drills-manual2-poc-20260427150339.txt`
- remote logs: `artifacts/poc-final/00-runbook/remote-logs-manual-section5-poc-20260427150339-160113/`

Progress after change:
- Acceptance sections complete: `4 / 8`
- Execution checklist complete: `11 / 15`
- Infra status: `destroyed`

Next steps:
1. root-cause leader-loss recovery and add deterministic coverage if simulatable
2. rerun Section 5 only after patching
3. defer repeatability and EKS until Section 5 passes

Blockers / unknowns:
- live leader-loss drill failed after stopping leader `172.31.5.249:9001`
- API did not recover a connected leader within the drill timeout
- replicas showed view-change/no stable API leader in captured logs

### 2026-04-26 — Focused fresh-AWS real workload validation passed

What changed:
- fixed worker TCP receive handling so nonblocking partial frames are preserved across reads before decoding
- removed the worker's fake echo fallback for `/run` when no running pod exists; missing pods now return explicit worker error status
- hardened POC scripts to validate dashboard readiness as exact `ready/desired`, not a loose `0/1` match
- made the smoke test delete its temporary CPU/GPU deployments so it does not consume the only GPU before Section 3
- added remote log capture/preload verification paths to the runbook for future failed or final evidence runs
- ran focused Hivemind-only fresh AWS evidence with `RUN_EKS=false`, operator/failure drills skipped, and teardown enabled

Why it matters:
- Section 3 now has real CPU and GPU workload evidence instead of echo/plumbing artifacts
- GPU capacity contention from smoke is fixed before the next operator/failure run
- future final runs will preserve remote service/containerd state before teardown

Evidence:
- runbook: `artifacts/poc-final/00-runbook/runbook-poc-20260426203208.log`
- workload artifacts: `artifacts/poc-final/04-workloads/`
- smoke: `22 passed, 0 failed`
- CPU: `poc-cpu-1777251727`, id `11693034620340510321`, cold `0.082571s`, warm `0.119884s`
- GPU: `poc-gpu-1777251727`, id `9024654201992055039`, Tesla T4/CUDA `12.4`, cold `0.632835s`, warm `0.068794s`

Progress after change:
- Acceptance sections complete: `3 / 8`
- Execution checklist complete: `10 / 15`
- Infra status: `destroyed`

Next steps:
1. run Sections 4-5 with EKS still disabled
2. if operator/failure passes, run the isolated EKS baseline comparison
3. perform repeatability run and write final evidence pack/verdict

Blockers / unknowns:
- operator workflow proof not yet rerun after Section 3 turned green
- failure drills not yet rerun after Section 3 turned green
- EKS baseline remains unexecuted in the latest evidence cycle

### 2026-04-24 — POC runbook teardown hardened before live run

What changed:
- moved the workload ECR repository into `infra/poc` Terraform with `force_delete = true`
- changed the runbook to apply `infra/poc` before image build so ECR is Terraform-owned
- added `scripts/poc-teardown.sh` for one-command cleanup of isolated Hivemind and EKS POC states
- added an exit trap so `DESTROY_HIVEMIND_AFTER=true` and `DESTROY_EKS_AFTER=true` run cleanup even after smoke/workload/drill failure
- changed the runbook to auto-detect a deployer `/32` CIDR and refuse `0.0.0.0/0` for SSH/API exposure
- added failure cleanup traps for the failure-drill and EKS workload scripts so stopped services, namespaces, port-forwards, and script-installed NVIDIA device plugin state are cleaned up

Why it matters:
- the next AWS evidence run no longer depends on a best-effort successful tail step for teardown
- ECR images are deleted by Terraform destroy instead of lingering outside state
- public SSH/API exposure is no longer the default path

Progress after change:
- Acceptance sections complete: `2 / 8`
- Execution checklist complete: `9 / 14`
- Infra status: `destroyed`

Next steps:
1. run `SSH_KEY=... ECR_REPOSITORY=hivemind-poc RUN_EKS=true DESTROY_HIVEMIND_AFTER=true DESTROY_EKS_AFTER=true bash scripts/poc-runbook.sh`
2. inspect generated evidence under `artifacts/poc-final/`
3. update sections 3-8 pass/fail based on live results

Blockers / unknowns:
- live AWS evidence run not started yet
- AWS EKS/GPU quota availability still needs confirmation at runtime

### 2026-04-24 — Session handoff docs updated for next live run

What changed:
- updated `docs/STATUS.md`, `docs/POC_ACCEPTANCE.md`, and this changelog to make the next session resumable
- documented that ECR in `us-east-1` is the chosen registry path via `ECR_REPOSITORY=hivemind-poc`
- documented the exact resume command for `scripts/poc-runbook.sh`
- recorded that temporary EKS baseline exists under isolated `infra/poc-eks/` and has not been applied yet
- recorded that no AWS infra was created or mutated during the prep/runbook scripting session

Why it matters:
- next session can start from a clean handoff without rediscovering state
- progress stays honest: scripts are ready, but live sections 3-8 are still not complete
- avoids accidentally touching existing infra by pointing to the isolated POC/EKS directories only

Progress after change:
- Acceptance sections complete: `2 / 8`
- Execution checklist complete: `9 / 14`
- Infra status: `destroyed`

Next steps:
1. run `SSH_KEY=... ECR_REPOSITORY=hivemind-poc RUN_EKS=true bash scripts/poc-runbook.sh`
2. inspect generated evidence under `artifacts/poc-final/`
3. update sections 3-8 pass/fail based on live results

Blockers / unknowns:
- live AWS evidence run not started yet
- AWS EKS/GPU quota availability still needs confirmation at runtime

### 2026-04-24 — End-to-end POC runbook script added

What changed:
- added `scripts/poc-runbook.sh` to orchestrate the remaining live POC execution
- runbook builds/pushes ECR images, applies isolated Hivemind POC infra, deploys binaries, runs fresh smoke, workload validation, operator workflow, failure drills, and optional isolated EKS baseline
- defaults are conservative: EKS is opt-in with `RUN_EKS=true`; destroys are opt-in with `DESTROY_HIVEMIND_AFTER=true` and `DESTROY_EKS_AFTER=true`
- Terraform execution is path-guarded to only `infra/poc` and `infra/poc-eks`

Why it matters:
- reduces the live smoke window to one auditable command
- keeps the temporary EKS baseline isolated from existing infrastructure
- avoids manual copy/paste errors during the evidence run

Progress after change:
- Acceptance sections complete: `2 / 8`
- Execution checklist complete: `9 / 14`
- Infra status: `destroyed`

Next steps:
1. run the script with `ECR_REPOSITORY=hivemind-poc RUN_EKS=true` when ready for AWS
2. inspect generated evidence under `artifacts/poc-final/`
3. rerun or destroy according to pass/fail state

Blockers / unknowns:
- live AWS run has not been started yet

### 2026-04-24 — CPU/GPU POC workloads selected and live-run scripts prepared

What changed:
- selected `workloads/poc/cpu` as the CPU POC workload: deterministic hash-embedding classifier on `POST /inference`
- selected `workloads/poc/gpu` as the GPU POC workload: deterministic PyTorch CUDA MLP on `POST /inference`, fails if CUDA is unavailable
- added `infra/poc/build-workload-images.sh` to build/push both images to a caller-provided registry
- added `infra/poc/workload-test.sh` to deploy CPU/GPU workloads, run cold/warm requests, sanity-check outputs, and capture section 3 evidence
- added `infra/poc/operator-workflow.sh` to exercise create/update/rollback/scale/scale-to-zero/wake/delete once AWS is live
- filled `artifacts/poc-final/04-workloads/workload-plan.md`
- exposed missing update route needed by the operator workflow: `PUT /v1/deployments/{id}`
- added core parser coverage for client command tag `10` (`update_deployment`)

Why it matters:
- closes the workload-selection unknown before recreating infra
- makes the next AWS run mostly mechanical: build/push images, deploy, smoke, run workload/operator scripts
- fixes a concrete Section 4 blocker before the smoke window

Progress after change:
- Acceptance sections complete: `2 / 8`
- Execution checklist complete: `9 / 14`
- Infra status: `destroyed`

Next steps at the time:
1. choose registry and push workload images
2. recreate fresh AWS infra
3. run smoke, then workload/operator scripts

Blockers / unknowns at the time:
- registry/repository for workload images was not selected in-repo; superseded by the later ECR/runbook decision
- scripts were prepared but not run against live AWS yet

### 2026-04-24 — Locality federation proof completed with localhost multi-origin smoke

What changed:
- added Thalamus smoke tool `scripts/hivemind_locality_smoke`
- ran four independent local Hivemind origins:
  - `aws-us-east-1` (`us-east`)
  - `crusoe-us-east-1` (`us-east`)
  - `crusoe-texas` (`us-central`)
  - `aws-eu-west-2` (`europe`)
- each origin exposed `GET /v1/internal/federation` and saw 3 fresh peer origins via gossip
- routed the actual Thalamus resolver through policy scenarios for:
  - `same-locality-best`
  - `same-locality-failover`
  - `cross-locality-fallback` to `us-central`
  - Europe fallback when policy allows
  - `residency-restricted` fail-closed behavior for strict Europe
- demonstrated stale-peer detection by killing `crusoe-texas`, waiting past the stale window, and observing `stale=true` with `last_seen_seconds=34`
- saved evidence under `artifacts/poc-final/03-locality/`

Why it matters:
- closes section 2 locally with actual Hivemind gossip endpoints and actual Thalamus resolver behavior
- proves the POC locality model without recreating AWS infra yet
- moves the critical path to real workload validation

Progress after change:
- Acceptance sections complete: `2 / 8`
- Execution checklist complete: `7 / 14`
- Infra status: `destroyed`

Next steps:
1. choose CPU/GPU real workload images and payloads
2. redeploy fresh AWS infra
3. run workload validation and capture cold/warm request evidence

Blockers / unknowns at the time:
- real workload image choice was open; superseded by the later workload-selection entry
- live multi-provider locality proof remains future work beyond this local Section 2 gate

### 2026-04-24 — Thalamus POC branch locality selector tests landed; Hivemind JSON federation endpoint added

What changed:
- created Thalamus branch `feat/hivemind-poc-locality` from `main`
- extended Thalamus locality schema/types on the branch:
  - `ClusterMetadata`: provider, region, locality, continent, active
  - `ClusterCapacity`: queue depth, health score
  - `AppRoutingPolicy`: preferred locality, allowed localities, residency mode, fallback order
- added an in-memory app routing policy store for the POC branch
- updated the real Thalamus resolver to apply locality/residency policy before final candidate scoring
- added deterministic resolver tests for:
  - `same-locality-best`
  - `same-locality-failover`
  - `cross-locality-fallback`
  - `residency-restricted`
- added Hivemind `GET /v1/internal/federation` JSON output on the replica metrics listener so Thalamus/local smoke tooling can consume origin + peer advisory state without Prometheus parsing
- reran verification:
  - `cd ../thalamus && go test ./...`
  - `cd core && zig test src/unit_tests.zig`

Why it matters:
- removes the Prometheus-text parsing decision from the critical path
- moves section 2 from Hivemind-only model proof to actual Thalamus resolver behavior on a POC branch
- leaves localhost multi-origin smoke as the next evidence gap before cloud work resumes

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `6 / 14`
- Infra status: `destroyed`

Next steps:
1. run localhost multi-origin smoke with 3-4 Hivemind origins and the Thalamus POC branch
2. save routing traces and federation JSON samples under locality evidence artifacts
3. update section 2 checklist once smoke evidence exists

Blockers / unknowns:
- localhost multi-origin smoke not run yet
- no new AWS infra was created; live infra remains destroyed
- exact Nebius Europe region still unknown

### 2026-04-23 — Repo scope trimmed; Zig control plane renamed to `core/`

What changed:
- renamed `v2/` to `core/` so the directory describes its role instead of its history
- removed stale/inactive tracked code:
  - old `v1/` implementation
  - zero-byte `hivemind/` skeleton
  - inactive `honeybee/` prototype
- removed local ignored build/deploy artifacts and caches from the working tree
- moved non-authoritative docs out of the active docs root:
  - aspirational/superseded docs to `docs/frozen/`
  - legacy Thalamus/edge-routing docs to `docs/legacy/`
- updated active docs/scripts to use `core/` paths and tightened the source-of-truth set to:
  - `docs/STATUS.md`
  - `docs/POC_ACCEPTANCE.md`
  - `docs/POC_CHANGELOG.md`
  - `docs/FINDINGS_AND_ISSUES.md`
  - `docs/ENGINEERING.md`
- reran verification:
  - `cd core && zig test src/unit_tests.zig`
  - `cd core && zig test src/unit_tests.zig -OReleaseFast`
  - `cd core && zig build test`
  - `bash tests/build_binaries_test.sh`
  - `git diff --check`

Why it matters:
- reduces confusion before production-hardening review
- removes old implementation branches from active tree
- makes `core/` + `worker/` + `api/` the clear implementation surface
- keeps historical design context without letting it compete with current truth

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `5 / 14`
- Infra status: `destroyed`

Next steps:
1. continue local-only Thalamus selector work from the cleaner repo layout
2. run localhost multi-origin smoke after selector work is wired
3. then evaluate production-hardening gaps from the reduced active tree

Blockers / unknowns:
- no POC acceptance section changes from repo hygiene alone
- `api/` source comments still contain a couple old `v2` path comments by design; source behavior was left untouched

### 2026-04-23 — Local federated selector proof landed; peer queue-depth export added

What changed:
- added consumer-facing peer `queue_depth` export to replica metrics alongside existing peer freshness/CPU/GPU/deployment signals
- extended the deterministic federated VOPR harness with a small selector model that can:
  - choose the best fresh origin within the preferred locality
  - fail over within the same locality when the preferred origin goes stale
  - fall back from `us-east` to `us-central`, then to `europe`, only when policy allows
  - fail closed for strict Europe residency when only non-European origins remain
- added deterministic proof tests for:
  - `same-locality-best`
  - `same-locality-failover`
  - `cross-locality-fallback`
  - `residency-restricted`
- reran verification:
  - `zig test src/unit_tests.zig --test-filter 'selector local proof'`
  - `zig test src/unit_tests.zig --test-filter 'metrics include origin-aware gossip labels and cpu summaries'`
  - `zig test src/unit_tests.zig`
  - `zig test src/unit_tests.zig -OReleaseFast`
  - `zig build test`

Why it matters:
- proves locally, without AWS, that Hivemind can already provide the advisory inputs needed for locality-aware selection
- closes the last obvious Hivemind-side export gap found in the advisory review
- turns the next step into actual Thalamus branch work rather than more speculative Hivemind-side plumbing

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `5 / 14`
- Infra status: `destroyed`

Next steps:
1. start Thalamus locality/residency routing work against this deterministic surface
2. choose Prometheus-text parsing vs tiny summary endpoint for the POC branch
3. then run a localhost multi-origin smoke before any new AWS proof

Blockers / unknowns:
- the local proof uses a deterministic selector model inside VOPR, not the actual Thalamus code yet
- locality federation is still not fully complete until Thalamus-side policy/routing behavior is implemented and evidenced
- real workloads, failure drills, repeatability, and K8s comparison remain open

### 2026-04-22 — Hivemind advisory surface reviewed against Thalamus POC needs

What changed:
- reviewed current Hivemind advisory surface against `docs/POC_ACCEPTANCE.md` and current replica exports
- confirmed origin-level config already exists as runtime flags/config for:
  - `origin_id`
  - `provider`
  - `region`
  - `locality`
  - `continent`
- confirmed gossip wire already carries the key soft-state signals Thalamus needs:
  - origin identity + provider/region/locality/continent
  - GPU available/total by type
  - CPU available/total summary
  - queue depth
  - active deployments
  - running pods
  - freshness via last-seen time
- confirmed metrics already expose most peer advisory fields, including:
  - identity/locality labels
  - CPU summaries
  - GPU summaries
  - deployment/pod/node counts
  - last-seen age
- identified one concrete gap before Thalamus consumption: peer `queue_depth` is present in gossip/state but not exported on the metrics surface yet

Why it matters:
- this means Hivemind does **not** need another gossip-schema redesign before Thalamus work
- the remaining Hivemind-side work is now small and tactical, not architectural
- we can move forward with Thalamus soon after exposing the missing load signal on a consumer-facing surface

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `4 / 14`
- Infra status: `destroyed`

Next steps:
1. export peer `queue_depth` alongside existing peer metrics
2. decide whether Thalamus should read Prometheus text for the POC slice or whether we should add a tiny summary endpoint
3. then start Thalamus locality/residency routing work

Blockers / unknowns:
- no new core Hivemind consensus/runtime blocker remains from this review
- the only clear Hivemind advisory gap found is consumer-facing export of peer `queue_depth`
- still need the separate multi-origin/locality proof and Thalamus-side routing policy work

### 2026-04-22 — 10k mutated core fuzz gate re-closed after fixing seeds 7957, 3250, 7393, 8146, 8820, 8896

What changed:
- added deterministic VOPR regressions for:
  - safety seed `7957`
  - liveness seeds `3250`, `7393`, `8146`, `8820`
  - safety/invariant seed `8896`
- fixed replica rejoin via higher-view `Prepare` / `Commit` so replicas drop uncommitted local suffix instead of committing stale entries under the new view
- fixed follower/leader peer commit-floor tracking so leaders resume repair when peers prove a higher committed prefix
- fixed repair intake so leaders ignore follower-only uncommitted entries above their selected suffix instead of silently keeping `highest journal op > op_number`
- reran verification:
  - `zig test src/unit_tests.zig`
  - `zig test src/unit_tests.zig -OReleaseFast`
  - `zig build test`
  - fresh `10000`-seed mutated core fuzz sweep
- result: `10000` seeds, `0` failures

Why it matters:
- closes the exact failures found in the broad sweep instead of hand-waving them away as fuzz noise
- restores confidence that Hivemind core is again a usable gate before Thalamus/locality work proceeds
- adds deterministic coverage so these recovery/view-change failures stay fixed

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `4 / 14`
- Infra status: `destroyed`

Next steps:
1. review whether the current Hivemind advisory surface is sufficient for Thalamus
2. if any origin/locality signal is still missing, add it with deterministic coverage first
3. then start Thalamus locality/residency routing work

Blockers / unknowns:
- broad mutated core gate is clean at `10000`, but this still does not replace the remaining federated-routing/workload/failure-drill proof
- selector logic still lives outside Hivemind; current proof is core-consensus/runtime correctness, not end-to-end locality routing yet

### 2026-04-22 — Federated VOPR proof harness extended for multi-origin locality scenarios

What changed:
- extended `core/src/vopr/test_harness.zig` with reusable `FederatedGossipHarness`
- added deterministic federated-origin fixtures with explicit origin metadata, capacity, and deployment shaping
- added seed-swept VOPR coverage for:
  - multi-locality advisory state visibility across origins
  - same-locality failover inputs when a preferred origin goes stale
- verified new VOPR slice in both debug and `-OReleaseFast`

Why it matters:
- moves the project past one-off gossip field assertions toward an actual federated proof surface
- gives us deterministic evidence that Hivemind can model the advisory cross-origin state Thalamus will need for locality-aware routing
- de-risks the next step by making stale-origin and same-locality-fallback behavior reproducible before live infra

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `4 / 14`
- Infra status: `destroyed`

Next steps:
1. decide whether this Hivemind advisory surface is already sufficient for the Thalamus POC branch
2. if not, add the smallest missing per-origin signal now
3. then start Thalamus locality/residency routing work against this deterministic harness

Blockers / unknowns:
- `zig build test` wrapper remains flaky even though direct debug + release test runs pass
- selector logic still lives outside Hivemind; this harness proves inputs, not end-to-end routing decisions yet

### 2026-04-22 — Build wrapper fixed; broad seed sweep exposed real Hivemind safety blockers

What changed:
- fixed `zig build test` wrapper behavior by silencing control-plane debug spam under test mode
- added quiet mode for the fuzz binary so broad seed sweeps produce usable output instead of log floods
- ran a broad sequential VOPR/fuzz sweep over `5000` seeds on the base config
- reproduced real safety violations at seeds `10`, `228`, and `362`

Why it matters:
- this closes the wrapper ambiguity: the test wrapper itself is now stable and usable as a gate
- the important result is worse than wrapper flakiness: broad deterministic fuzzing found actual consensus-safety failures in Hivemind core
- this hard-blocks any move to Thalamus; advisory gossip and locality work are irrelevant until the core is clean across broad seed sweeps

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `4 / 14`
- Infra status: `destroyed`

Next steps:
1. replay and root-cause seeds `10`, `228`, `362`
2. land failing deterministic regression tests for those seeds
3. fix core safety bug(s), then rerun broad sweeps

Blockers / unknowns:
- exact root cause of the safety divergence is still unknown
- Thalamus work is explicitly blocked until broad Hivemind sweeps are clean

### 2026-04-22 — 10k fuzz gate cleaned: seed 6239 fixed after 5k pass

What changed:
- ran a fresh `10000`-seed sequential fuzz sweep after the earlier clean `5000`-seed run
- found one additional liveness-only failure at seed `6239`
- fixed follower idle catch-up by having non-leaders poll the leader with `request_status` when normal but idle, then use leader `send_status` replies to trigger transfer/catch-up
- added explicit deterministic regression coverage for seed `6239`
- reran the targeted seed and the prior regression seeds before rerunning the broad sweep

Why it matters:
- proves the earlier `5000`-seed clean run was not enough to close the fuzz gate yet
- closes a real healed-but-idle follower catch-up hole that could leave one replica permanently behind after traffic stops
- raises confidence materially: both the original safety regressions and the deeper liveness tail are now covered explicitly

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `4 / 14`
- Infra status: `destroyed`

Next steps:
1. rerun the fresh `10000`-seed sweep to confirm no remaining failures
2. if clean, review whether the current Hivemind advisory surface is sufficient for Thalamus
3. only then begin Thalamus routing/residency work

Blockers / unknowns:
- broad fuzz gate now depends on the fresh `10000`-seed rerun after the `6239` fix

### 2026-04-22 — Broad VOPR/fuzz gate cleaned: seeds 10, 228, 362, 1317 fixed

What changed:
- fixed committed-suffix carry in `maybeStartView()` so a value is not discarded just because the new DVC quorum lacks a full matching checksum quorum
- fixed follower `StartView` handling so replicas preserve older locally-held suffix ops below the leader's bounded transmitted tail slice
- added explicit deterministic regression coverage for seeds `10`, `228`, `362`, `1317`, and `6239`
- reran verification:
  - `zig test src/unit_tests.zig`
  - `zig test src/unit_tests.zig -OReleaseFast`
  - `zig build test`
  - clean `5000`-seed sequential fuzz sweep
- result: `5000` seeds, `0` failures

Why it matters:
- clears the Hivemind-core blocker that was preventing any move toward Thalamus
- proves the test wrapper, regression tests, and broad deterministic sweep are all usable as a real gate
- restores confidence that the new federated/advisory work is not being layered on top of a known consensus bug

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `4 / 14`
- Infra status: `destroyed`

Next steps:
1. review whether the current Hivemind advisory surface is already sufficient for Thalamus
2. if not, add the smallest missing signal with deterministic coverage first
3. then, and only then, begin Thalamus work

Blockers / unknowns:
- no current broad-seed blocker remains in Hivemind core from the tested `5000`-seed sweep
- still need explicit decision on whether Hivemind's current origin/locality advisory surface is enough for the Thalamus branch

### 2026-04-22 — Hivemind origin-aware gossip landed with deterministic coverage first

What changed:
- extended `core/src/gossip.zig` with cluster-level `OriginIdentity`
- gossip snapshots now carry `origin_id`, `provider`, `region`, `locality`, `continent`
- gossip snapshots now carry CPU available/total summaries in addition to existing GPU summaries
- peer cache is now keyed by `origin_id`, not just `region`
- added `isOriginFresh()` to avoid same-region origin collisions
- extended metrics output with origin-aware labels + CPU peer metrics
- added deterministic coverage first:
  - gossip unit round-trip now asserts origin identity + CPU summaries
  - VOPR cross-origin propagation asserts identity + freshness
  - VOPR same-region distinct-origin test proves cache separation
  - metrics test asserts origin-aware labels are exposed
- added runtime flags for origin metadata in `core/src/main.zig`

Why it matters:
- this is the first real Hivemind-core slice needed for federated locality routing
- it closes the most important modeling gap: multiple origins can now share a region without collapsing into one gossip entry
- it keeps simulation-first discipline intact by landing VOPR/unit coverage before relying on the new metadata surface

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `4 / 14`
- Infra status: `destroyed`

Next steps:
1. extend the federated proof harness beyond one-off gossip assertions into locality-level scenarios
2. decide if Hivemind needs any more advisory peer state before Thalamus work starts
3. then patch Thalamus POC branch to consume this surface

Blockers / unknowns:
- still no full selector-layer proof yet
- still need decide whether Hivemind should expose any additional per-origin signals before Thalamus integration

### 2026-04-22 — Federated POC acceptance defined

What changed:
- added `docs/POC_ACCEPTANCE.md` as canonical federated pass/fail checklist
- narrowed architecture claim to region-local Hivemind clusters + gossip-backed soft global state
- defined locality buckets: `europe`, `us-east`, `us-central`
- defined strict Europe residency and US spillover routing policies
- documented required POC-branch schema changes for Thalamus and required metadata/gossip changes for Hivemind

Why it matters:
- replaces vague "multi-region" discussion with a concrete, testable federated model
- makes the next implementation sequence clear: Hivemind first, Thalamus second

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `3 / 14`
- Infra status: `destroyed`

Next steps:
1. patch Hivemind origin metadata/config
2. patch Hivemind gossip visibility + deterministic tests
3. then start Thalamus POC branch work

Blockers / unknowns:
- no multi-origin test harness yet
- exact Nebius Europe region unknown

### 2026-04-22 — Fresh AWS smoke gate closed and infra cleaned up

What changed:
- corrected fresh AWS smoke passed on live infra
- Terraform destroy completed
- verified no zombie Hivemind EC2 instances, SGs, or deployer keypair remained in checked AWS regions

Why it matters:
- clears the old plumbing gate and removes ambiguity about whether infra bugs still block the POC
- ensures next work starts from a clean AWS state

Progress after change:
- Acceptance sections complete: `1 / 8`
- Execution checklist complete: `3 / 14`
- Infra status: `destroyed`

Next steps:
1. implement Hivemind origin metadata
2. expose origin-aware gossip state
3. design minimal federated proof harness

Blockers / unknowns:
- locality federation proof still design-complete but implementation-incomplete

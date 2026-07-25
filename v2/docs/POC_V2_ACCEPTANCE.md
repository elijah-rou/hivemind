# Hivemind POC v2 acceptance

Status: **not accepted**. This is the current product gate, not a parity claim.

POC v1 and continuation-era evidence is historical. Historical evidence can inform work, but cannot set a current criterion to `passed`. No fresh criterion evidence record containing an exact source SHA and UTC timestamp was available at the documentation baseline `068c1561656dc033bd7a3a7134e73b7004c115ba`; therefore no row below is passed.

## Scope

POC v2 must prove one representative inference workload with the platform slice and Hivemind-native serving semantics below. It is not full Kubernetes compatibility, a production launch, or proof from nginx-only latency. Benchmark and economic evidence is recorded separately from functional correctness.

## Non-goals

- Full Kubernetes API, CRD/operator, or generic DaemonSet compatibility.
- Arbitrary sidecar/init-container parity unless the selected workload requires it.
- Multi-cloud production launch.
- Cold-cache economic conclusions before private-image authentication is accepted.

## Status and evidence rules

Statuses are restricted to `passed`, `failed`, `not-run`, and `blocked`. `passed` and `failed` require an exact tested source commit SHA and UTC timestamp in the criterion's current-evidence cell. `not-run` names the exact current command. `blocked` names the unavailable surface, capability, or gate and the nearest current command when one exists. An optional or automatic skip cannot satisfy a required criterion. Deterministic evidence is sufficient only where the profile says so; simulation does not attest local processes, privileged containerd, GPU/CDI, JuiceFS, private registry, or cloud behavior.

The tables use a normalized two-part mapping. Every criterion row supplies a stable ID, exact requirement, evidence profile, status, and current evidence. The referenced profile supplies the exact command/blocker, environment and required capability flags, observable pass condition, artifacts, deterministic sufficiency, required execution boundaries, and cleanup.

## Rollup

| Section | Area | Required | Current rollup |
|---:|---|---|---|
| 1 | Representative workload | Yes | blocked |
| 2 | AppSpec parity slice | Yes | blocked |
| 3 | Storage / JuiceFS | Yes | blocked |
| 4 | Secrets / private image auth | Yes | blocked |
| 5 | Logs / observability | Yes | blocked |
| 6 | Security / isolation minimum | Yes | blocked |
| 7 | Revisions / routability / rollout safety | Yes | blocked |
| 8 | Event-driven state surface | Yes | blocked |
| 9 | Queue-aware serving path | Yes | blocked |
| 10 | Autoscaling / scale-from-zero | Yes | blocked |
| 11 | GitOps / Argo bridge | Yes for demo path; not full controller parity | blocked |
| 12 | Benchmark refresh | Yes | blocked |
| 13 | Final evidence pack | Yes | blocked |

A section becomes passed only when every required criterion in it is passed. The rollup intentionally does not embed a mutable criterion count.

## Normalized evidence profiles

### `P-ABSENT`

- **Requirement class:** Unavailable: the required product surface or acceptance harness is not implemented.
- **Exact current command or blocker:** No acceptance command exists.
- **Environment and required capabilities:** N/A; implementation and a bounded harness are prerequisites.
- **Observable pass condition:** Implementation and harness expose the stated observable behavior.
- **Required artifacts:** Source diff, deterministic result, boundary logs/state.
- **Deterministic evidence sufficient:** No
- **Required execution boundary:** See the criterion row; the boundary is explicit even though its harness is unavailable.
- **Cleanup:** No resources acquired.
- **Default status:** blocked
- **Current evidence:** Blocker: required product surface or acceptance harness is absent.

### `P-MIXED`

- **Requirement class:** Current deterministic/component behavior may cover a subset, but not the complete product criterion.
- **Exact current command or blocker:** `cd v2/worker && cargo test --all-targets`; `cd v2/core && zig build test`; nearest local boundary: `cd v2 && ./tests/local-smoke.sh --build`.
- **Environment and required capabilities:** Rust/Zig/Go toolchains; local command needs loopback ports and process runtime. No capability skip may satisfy the row.
- **Observable pass condition:** All criterion-specific fields and state cross API, core, worker, and request-path boundaries with loud rejection and expected state.
- **Required artifacts:** Test output, named scenarios, API/state snapshots, process logs.
- **Deterministic evidence sufficient:** No
- **Required execution boundary:** Deterministic plus local real-process; containerd/live additionally required where the criterion names runtime/provider behavior.
- **Cleanup:** Deterministic: none. Local: trap terminates processes and removes temporary data/logs.
- **Default status:** blocked
- **Current evidence:** Blocker: current subset does not implement or prove the complete cross-component criterion.

### `P-API`

- **Requirement class:** Current Go API test/build is the nearest executable harness; it is not fresh evidence for this row.
- **Exact current command or blocker:** `cd v2/api && go test -race ./... && go build ./...`.
- **Environment and required capabilities:** Go toolchain; race detector; no optional skips.
- **Observable pass condition:** Relevant request is accepted/rejected exactly and produces no unintended mutation.
- **Required artifacts:** Command output and bounded request/response fixtures.
- **Deterministic evidence sufficient:** Yes for API-only parsing behavior
- **Required execution boundary:** No local/containerd/live boundary unless the criterion also requires system behavior.
- **Cleanup:** No external resources; remove Go build outputs if created outside normal cache.
- **Default status:** not-run
- **Current evidence:** Current command not run for acceptance at a recorded source SHA and UTC time.

### `P-LOCAL`

- **Requirement class:** Current single-replica process-runtime smoke is the nearest real-process harness.
- **Exact current command or blocker:** `cd v2 && ./tests/local-smoke.sh --build`.
- **Environment and required capabilities:** Zig, Rust, Go, curl, loopback ports, process runtime; `--skip-smoke` is forbidden for this row.
- **Observable pass condition:** Harness reaches and asserts the criterion-specific observable without process failure.
- **Required artifacts:** Harness stdout plus replica/API/worker logs and snapshots required by the criterion.
- **Deterministic evidence sufficient:** No
- **Required execution boundary:** Local real-process required; this profile does not attest containerd or live infrastructure.
- **Cleanup:** Harness trap kills tracked processes and removes temporary data/logs.
- **Default status:** not-run
- **Current evidence:** Current command not run for acceptance at a recorded source SHA and UTC time.

### `P-PRIV`

- **Requirement class:** Prepared privileged full-stack containerd boundary; execution evidence is required.
- **Exact current command or blocker:** `cd v2 && REQUIRE_CONTAINERD=1 ./tests/containerd/run-tests.sh --full-stack` or the aggregate `./tests/run-all.sh --require-containerd`.
- **Environment and required capabilities:** Docker and privileged Linux container support; real containerd/ctr. Docker absence or skip fails this required row.
- **Observable pass condition:** Criterion holds through the real worker/control-plane path and post-run runtime inventory is clean.
- **Required artifacts:** Container/task/cgroup/mount inventories, worker logs, command output.
- **Deterministic evidence sufficient:** No
- **Required execution boundary:** Privileged containerd and real Zig/Go/Rust full stack.
- **Cleanup:** Exact task/container baseline restoration plus bounded owned-process cleanup and Docker `--rm`.
- **Default status:** not-run
- **Current evidence:** Prepared only; E1 did not execute the privileged command.

### `P-LIVE`

- **Requirement class:** Provider/runtime/workload boundary requires a guarded current live run.
- **Exact current command or blocker:** `cd v2 && timeout --kill-after=30s 14400s ./tests/live/run.sh` with the mandatory environment in `tests/live/README.md`. Direct private-helper and `scripts/poc-runbook.sh` execution is rejected. The wrapper currently refuses before ownership because required JuiceFS AppSpec semantics are absent.
- **Environment and required capabilities:** Separate authorization, credentials, account/region allowlists, cost and destructive approval, unique ownership token, and criterion-specific CPU/GPU/private-registry/JuiceFS capabilities. Optional skips are forbidden.
- **Observable pass condition:** The stated behavior succeeds on the representative workload and all required capability checks and cleanup assertions pass.
- **Required artifacts:** Source SHA/time manifest, plan digest, image digest, request/response, API state/events/logs, runtime/provider inventories, cleanup proof.
- **Deterministic evidence sufficient:** No
- **Required execution boundary:** Live required; local real-process and privileged containerd are also required when named by the criterion.
- **Cleanup:** Destroy only exactly owned resources; prove deployments, tasks, mounts, instances, volumes, registry objects, workspaces, and temp secrets absent.
- **Default status:** blocked
- **Current evidence:** Prepared only; no current authorization, execution, manifest, or post-destroy inventory exists.

### `P-BENCH`

- **Requirement class:** Economic/performance evidence is separate from functional correctness and must use current feature-complete paths.
- **Exact current command or blocker:** Unavailable acceptance gate: existing `cd v2 && ./scripts/poc-runbook.sh` and `cd v2/bench && go test -race ./... && go build ./...` do not by themselves produce the required comparison.
- **Environment and required capabilities:** Functionally accepted representative workload; authorized Hivemind and comparison environments; equivalent readiness; private registry for cold-cache row; no optional capability skips.
- **Observable pass condition:** Both sides complete the exact declared scenario and emit comparable latency/resource data without degraded or omitted required capabilities.
- **Required artifacts:** Scenario manifest, source/image SHA, raw timings, readiness events, node/request shapes, cache state, provider inventory, cleanup proof.
- **Deterministic evidence sufficient:** No
- **Required execution boundary:** Live benchmark execution required; deterministic tests only validate tooling.
- **Cleanup:** Delete exactly owned workloads and infrastructure; preserve redacted immutable result bundle and prove cleanup.
- **Default status:** blocked
- **Current evidence:** Blocker: functional prerequisites and a fresh authorized benchmark manifest are absent.

### `P-DOC`

- **Requirement class:** A current curated artifact and its referenced evidence are required.
- **Exact current command or blocker:** No executable product harness; perform bounded artifact review against this acceptance spec after prerequisite evidence exists.
- **Environment and required capabilities:** Current source tree plus complete evidence bundle; reviewer must reject historical-only or skipped required evidence.
- **Observable pass condition:** Artifact contains the stated material, links exact current evidence, and contains no unsupported claim.
- **Required artifacts:** Curated Markdown/report plus linked manifests, outputs, and review record.
- **Deterministic evidence sufficient:** Only for a documentation-only criterion; never for underlying product behavior
- **Required execution boundary:** No runtime boundary for prose itself; referenced product rows retain their own required boundaries.
- **Cleanup:** No runtime resources; redact generated/curated artifacts before publication.
- **Default status:** blocked
- **Current evidence:** Blocker: current curated artifact or prerequisite current evidence is absent.

## 1. Representative workload

**Goal:** Run one realistic inference workload end to end, not nginx-only.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-01-private-image` | Workload image is private or private-auth-equivalent. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Guarded cold-pull mode is prepared but unexecuted; current private-auth evidence is absent. |
| `V2-01-env-secret` | Workload uses env vars and at least one secret ref. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Product surface remains incomplete; guarded live execution was not run. |
| `V2-01-readiness` | Workload has a readiness endpoint distinct from process start. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Readiness/routability product surface remains absent; guarded live execution was not run. |
| `V2-01-logs` | Workload writes logs retrievable through Hivemind tooling. | `P-ABSENT` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-01-juicefs` | Workload reads or writes a JuiceFS-mounted path. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | `REQUIRE_JUICEFS=1` fails before apply because required AppSpec/API mount semantics remain absent. |
| `V2-01-cpu` | Workload runs on CPU. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Guarded current-head live execution and cleanup manifest were not run. |
| `V2-01-gpu` | Workload has a GPU variant or GPU dependency smoke when the target product path needs GPU. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Process and containerd runtimes reject GPU workloads until concrete per-pod physical device reservation is implemented. |
| `V2-01-request` | Workload serves a request through the Hivemind request path. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Guarded current-head live execution and cleanup manifest were not run. |

**Required evidence set:** Live request/response; worker journals and pod logs; lifecycle/readiness/routability state dump; equivalent EKS/Kubernetes manifest.

## 2. AppSpec parity slice

**Goal:** Define and implement the smallest credible `AppSpec v1` needed for inference workloads.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-02-field-name` | `name` field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-image` | `image` field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-command` | `command`/entrypoint field, or an explicit decision to defer command override. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-port` | `port` field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-replicas` | `replicas`/`min`/`max` fields. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-resources` | CPU, memory, and GPU resource fields. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-env` | Environment-variable fields. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-secret` | Secret-reference fields. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-pull-auth` | Image-pull-auth reference fields. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-juicefs` | JuiceFS volume specification. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-liveness` | Liveness-probe field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-readiness` | Readiness-probe field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-startup` | Startup-timeout field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-grace` | Termination-grace-period field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-field-isolation` | Isolation-profile-reference field. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-api-accept` | Public API accepts `AppSpec v1`. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-core-persist` | Core state machine persists all required fields deterministically. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-worker-apply` | Worker receives and applies all required fields. | `P-ABSENT` | yes | deterministic only | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-02-reject-unsupported` | API rejects unsupported fields loudly instead of silently ignoring them. | `P-API` | yes | deterministic only | not-run | Current command not run for acceptance at a recorded source SHA and UTC time. |
| `V2-02-backward-compat` | Backward compatibility for old create-deployment payloads is documented. | `P-DOC` | yes | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |

**Required evidence set:** API tests; core state-machine tests; Zig VOPR create/update/scale coverage; worker simulation/unit spec-application coverage.

## 3. Storage / JuiceFS

**Goal:** Prove Hivemind can mount required workload storage safely and predictably.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-03-host-cli` | Hivemind host image/AMI includes the `juicefs` CLI or documented equivalent. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | No current guarded host/JuiceFS execution exists. |
| `V2-03-appspec-mount` | `AppSpec v1` exposes a required JuiceFS mount. | `P-ABSENT` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-03-mount-event` | Worker mount success is visible in events. | `P-ABSENT` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-03-mount-fail` | Required mount failure fails the pod before routing. | `P-MIXED` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-03-unmount` | Worker unmounts on stop, failure, and shutdown drain. | `P-PRIV` | no | local real-process + privileged containerd | blocked | Prepared full-stack harness was not executed; required JuiceFS AppSpec path also remains absent. |
| `V2-03-no-leak` | Repeated start/stop does not leak mountpoints. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Required mount product path remains absent and no guarded mount inventory was run. |

**Required evidence set:** Deterministic mount-failure/not-routable coverage; live mounted-path read/write; mount table before and after cleanup.

## 4. Secrets / private image auth

**Goal:** Close the cold-cache blocker and prove secrets do not leak through logs or events.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-04-registry-auth` | Registry auth supports private ECR or the selected registry without 256-byte password truncation. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Exact cold-pull/auth/digest mode is prepared but was not executed with credentials. |
| `V2-04-precedence` | Auth precedence is documented: per-deployment secret ref, then AMI/containerd hosts config, then public pull. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |
| `V2-04-env-secret` | Environment secret refs resolve through the selected secret provider. | `P-MIXED` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-04-redaction` | Secret values are redacted in API responses, events, logs, traces, and errors. | `P-MIXED` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-04-missing-secret` | A missing or invalid secret makes the pod not routable and emits a clear event. | `P-ABSENT` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: required product surface or acceptance harness is absent. |

**Required evidence set:** Redaction and missing-secret unit/simulation coverage; live private-image cold pull; live secret-backed request without value disclosure.

## 5. Logs / observability

**Goal:** Provide enough operator visibility to debug workload failures without SSH.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-05-retrieve` | Pod logs are retrievable by deployment, revision, and pod. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-05-bounded` | Logs can be tailed or fetched with bounded size and time limits. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-05-identity` | Logs are associated with revision and pod IDs. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-05-events` | State-transition events are queryable. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-05-metrics` | Component metrics remain Prometheus-scrapable. | `P-LOCAL` | no | local real-process | not-run | Current command not run for acceptance at a recorded source SHA and UTC time. |
| `V2-05-diagnose` | A failed workload can be diagnosed from API, events, and logs without host SSH. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |

**Required evidence set:** Bounded logs/events API examples; live failure diagnosis; secret redaction checks.

## 6. Security / isolation minimum

**Goal:** Reach a credible same-tenant or internal-alpha isolation baseline.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-06-api-auth` | API authentication is required for mutating endpoints. | `P-ABSENT` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-06-traffic-security` | Agent/replica traffic is authenticated and encrypted, or explicitly scoped to a PSK-encrypted internal-alpha model. | `P-MIXED` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-06-isolation` | An isolation profile applies resource limits, drops capabilities where possible, uses readonly rootfs when supported, and forbids privileged containers by default. | `P-PRIV` | no | local real-process + privileged containerd | blocked | Prepared full-stack harness was not executed, and the complete isolation-profile product surface remains absent. |
| `V2-06-gpu-device` | GPU device exposure is limited to requested devices. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Concrete per-pod physical device reservation is absent; runtimes reject GPU workloads rather than share CDI index zero. |
| `V2-06-credential-isolation` | Workloads cannot access Hivemind control-plane credentials through env, mounts, or filesystem. | `P-LIVE` | no | local real-process + privileged containerd + live | blocked | Product isolation proof remains incomplete and guarded live execution was not run. |
| `V2-06-limitations` | Security limitations state clearly what the model does and does not protect against. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |

**Required evidence set:** Isolation-model documentation; auth-failure tests; unauthenticated live mutation denial; container/device/resource inspection.

## 7. Revisions / routability / rollout safety

**Goal:** Prove Hivemind-native serving semantics, not only Kubernetes-like pod management.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-07-model-deployment` | Deployment owns immutable revisions. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-model-pod` | Pod belongs to a revision. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-model-separation` | Pod lifecycle, readiness, and routability are separate; running does not imply routable. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-model-routes` | Routes point to weighted revisions. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-new-revision` | A new deployment creates revision `N`. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-update-revision` | An update creates revision `N+1` without mutating revision `N`. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-warm-not-routable` | New-revision pods can be running and not routable until readiness gates pass. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-old-route` | The old revision remains routable until the new revision has enough routable capacity. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-failed-rollout` | A failed rollout keeps or restores old-revision routing. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-rollback` | Rollback changes routes first, then drains and cleans up. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-07-drain` | Scale-down marks pods draining before stop. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |

**Required evidence set:** Zig VOPR rollout success/failure/rollback/worker-loss scenarios; worker readiness/routability simulation; successful and failed live rollouts.

## 8. Event-driven state surface

**Goal:** Make state propagation and operator diagnosis event-driven, not log scraping or polling-only.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-08-transitions` | Every lifecycle, readiness, and routability transition emits a bounded event. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-08-placement` | Scheduling decisions emit placement reason and constraints considered. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-08-rollout` | Rollout decisions emit old/new revision capacity and route changes. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-08-query` | Events are queryable by deployment, revision, pod, node, and time range. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-08-retention` | Event retention is bounded and documented. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |

**Required evidence set:** API examples; deterministic rollout event ordering; successful and failed live event transcripts.

## 9. Queue-aware serving path

**Goal:** Prove the request path measures queue depth and concurrency near routing.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-09-instrumentation` | Hivemind has a queue-proxy/forwarder concept or equivalent instrumentation point. | `P-MIXED` | no | deterministic + local real-process | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-09-inflight` | Per-revision in-flight request count is visible. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-09-depth` | Per-revision queue depth is visible. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-09-limit` | Concurrency limit is configurable per revision or app. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-09-over-limit` | Over-limit requests queue or fail according to policy. | `P-MIXED` | no | deterministic + local real-process | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-09-scaling-input` | Metrics drive autoscaling inputs without scraping container logs. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |

**Required evidence set:** Load test for queue/in-flight metrics; deterministic overflow/backpressure coverage; metrics examples.

## 10. Autoscaling / scale-from-zero

**Goal:** Demonstrate a minimal serving autoscaler and scale-from-zero story.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-10-zero` | Deployment can scale to zero. | `P-MIXED` | no | deterministic + local real-process + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-10-activate` | A request to a zero-scale deployment triggers activation. | `P-MIXED` | no | deterministic + local real-process + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-10-request-policy` | The request is buffered or explicitly rejected according to documented policy. | `P-MIXED` | no | deterministic + local real-process + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-10-scale-up` | Queue depth or concurrency drives scale-up. | `P-MIXED` | no | deterministic + local real-process + live | blocked | Blocker: current subset does not implement or prove the complete cross-component criterion. |
| `V2-10-scale-down` | Idle cooldown drives scale-down. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-10-hysteresis` | Autoscaler avoids obvious oscillation with hysteresis or cooldown. | `P-ABSENT` | no | deterministic + local real-process + live | blocked | Blocker: required product surface or acceptance harness is absent. |

**Required evidence set:** Deterministic autoscaler coverage; live scale-to-zero/wake proof; wake-latency table.

## 11. GitOps / Argo bridge

**Goal:** Provide a credible operator path from current declarative workflows to Hivemind.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-11-apply` | A declarative workload spec can be committed and applied to Hivemind. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-11-drift` | Drift is detectable at least by a CLI/check command. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-11-machine-status` | Rollout status is machine-readable. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-11-health` | Health maps revisions and routability to `Healthy`, `Progressing`, or `Degraded`. | `P-ABSENT` | no | deterministic + local real-process | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-11-scope` | Full Argo controller parity is explicitly not required for this POC. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |

**Required evidence set:** Example YAML; apply/bridge command; CI/GitOps-suitable status output.

## 12. Benchmark refresh

**Goal:** Retain the latency-advantage claim after adding required platform features.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-12-warm-appspec` | Rerun the warm-cache benchmark with the AppSpec, revision, and routability path enabled. | `P-BENCH` | no | local real-process + privileged containerd + live | blocked | Blocker: functional prerequisites and a fresh authorized benchmark manifest are absent. |
| `V2-12-warm-workload` | Rerun the representative-workload warm-cache scale path. | `P-BENCH` | no | local real-process + privileged containerd + live | blocked | Blocker: functional prerequisites and a fresh authorized benchmark manifest are absent. |
| `V2-12-cold-private` | Rerun at least one private-image cold-cache path after the auth fix. | `P-BENCH` | no | local real-process + privileged containerd + live | blocked | Blocker: functional prerequisites and a fresh authorized benchmark manifest are absent. |
| `V2-12-equivalent-ready` | Compare against EKS using status-equivalent readiness, not benchmark wall overhead. | `P-BENCH` | no | local real-process + privileged containerd + live | blocked | Blocker: functional prerequisites and a fresh authorized benchmark manifest are absent. |
| `V2-12-shapes` | Record instance/node shapes and resource requests. | `P-BENCH` | no | local real-process + privileged containerd + live | blocked | Blocker: functional prerequisites and a fresh authorized benchmark manifest are absent. |

**Required evidence set:** Separate Hivemind and EKS artifact directories; scenario/cache-state table; explicit measurement caveats.

## 13. Final evidence pack

**Goal:** Produce a team-facing package that is hard to dismiss.

| Stable ID | Requirement | Evidence profile | Deterministic sufficient | Required boundary | Status | Current evidence |
|---|---|---|---|---|---|---|
| `V2-13-summary` | One-page executive summary. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |
| `V2-13-scenarios` | Exact benchmark scenario definitions. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |
| `V2-13-matrix` | Platform parity matrix with pass/fail evidence. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |
| `V2-13-native-demo` | Hivemind-native revision rollout, rollback, and routability demo. | `P-ABSENT` | no | deterministic + local real-process + privileged containerd + live | blocked | Blocker: required product surface or acceptance harness is absent. |
| `V2-13-security` | Security/isolation limitations and next steps. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |
| `V2-13-cost` | Cost/resource comparison. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |
| `V2-13-risks` | Known risks and explicit non-goals. | `P-DOC` | documentation only | artifact review; referenced rows retain their boundaries | blocked | Blocker: current curated artifact or prerequisite current evidence is absent. |

**Required evidence set:** One curated package linking all current functional, security, benchmark, cost, and risk evidence.

## Implementation sequence

1. `AppSpec v1` API/core/worker contract.
2. Secrets/image auth and required JuiceFS-mount semantics.
3. Readiness/routability split.
4. Revisions and route model.
5. Availability-preserving rollout/rollback.
6. Event stream.
7. Pod logs API.
8. Queue-proxy/forwarder metrics.
9. Scale-to-zero/activator path.
10. GitOps bridge.
11. Security/isolation baseline.
12. Benchmark and final evidence refresh.

## Historical evidence

Historical POC v1 AWS, benchmark, artifact, and continuation records remain labeled historical in `docs/POC_ACCEPTANCE.md`, `docs/POC_CHANGELOG.md`, `docs/STATUS.md`, and ignored artifact directories. They do not change any current status above. A docs-only descendant may reference a tested parent only after review proves the diff cannot affect the criterion; it still must record the tested source SHA, descendant SHA, UTC time, exact diff command, and rationale.

## Residual limitations

- Current worker simulation covers bounded bidirectional network/session behavior, stop/probe ownership, GPU admission, and `/run` outcome/status/accounting scenarios. These are deterministic model evidence only and do not establish AppSpec, readiness/routability, full-stack containerd, GPU/CDI, JuiceFS, private registry, or live product acceptance.
- The maintained local run, failover, and retained-storage contracts use three journal-backed replicas, the Go API, and a real Rust process-runtime worker. They cross local process/socket/filesystem boundaries only, not containerd or cloud.
- The privileged component harness remains a Rust runtime-component gate. The separate prepared full-stack containerd harness includes three Zig replicas, Go API, Rust worker/containerd, traffic, worker restart/adoption, and exact task/container baseline restoration; it has not been executed.
- The shared protocol-v6 corpus and guarded live harness are prepared; the guarded live matrix remains unexecuted and incomplete. GPU rows remain blocked on physical device reservation before live evidence can run.
- Experimental journal durability excludes torn writes and power loss and has a bounded retained-log lifetime.
- POC v2 has no parity claim. Required product surfaces and current live evidence remain incomplete.

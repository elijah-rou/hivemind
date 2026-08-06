# Hivemind v2 harness catalog

This catalog describes every maintained shell script under `v2/`. [Testing and evidence semantics](../docs/TESTING.md) define what results mean. A script is live evidence only when it actually reaches real infrastructure and records the tested commit, capabilities, exit, artifacts, and cleanup. Stubbed fixtures are deterministic evidence, not live evidence.

## Field conventions

Each catalog row records classification/topology, dependencies and boundedness, assertions/boundaries, artifacts/cleanup, and flags/exits. `run-all.sh` bounds each phase to 900 seconds with a 10-second TERM-to-KILL interval; callers still apply the published aggregate outer bound. Other scripts have no repository-wide default timeout. “Internal bounds” means the script contains explicit polling/command deadlines; “none” means no overall deadline is imposed, even if individual tools have deadlines. Unless stated otherwise, nonzero means setup or an assertion failed; zero means only that the invoked assertions completed.

## Quick commands

| Purpose | Command |
|---|---|
| Aggregate current phases | `cd v2 && timeout --foreground --kill-after=10s 3600s ./tests/run-all.sh` |
| Deterministic aggregate without containerd | `cd v2 && timeout --foreground --kill-after=10s 3600s ./tests/run-all.sh --skip-containerd` |
| Three-replica process-runtime run contract | `cd v2 && timeout --foreground --kill-after=10s 300s ./tests/local-run-contract-smoke.sh --build` |
| Three-replica data-plane failover | `cd v2 && timeout --foreground --kill-after=10s 300s ./tests/local-failover-smoke.sh --build` |
| Retained storage recovery | `cd v2 && timeout --foreground --kill-after=10s 300s ./tests/local-storage-recovery-smoke.sh --build` |
| Shared protocol-v6 wire corpus | `cd v2/tests && timeout --foreground --kill-after=10s 600s ./wire-contract-test.sh` |
| Privileged containerd component integration | `cd v2 && timeout --foreground --kill-after=10s 1800s ./tests/containerd/run-tests.sh --component` |
| Required component + full-stack containerd | `cd v2 && timeout --foreground --kill-after=10s 3600s ./tests/run-all.sh --require-containerd` |

`run-all.sh` supports `--skip-containerd`, `--require-containerd`, and `--skip-smoke`. Skip and require conflict. Required mode preflights the runner/Docker/Linux boundary before aggregate phases and makes missing/incompatible containerd, either phase failure, or cleanup residue nonzero. Optional absence is an explicit skip and remains unverified. `--skip-smoke` skips all three mandatory local failover/recovery/run contracts. Unknown flags exit 1.

## `run-all.sh` phases

The runner gives every phase a 900-second deadline, continues after a failed or timed-out invoked phase, and exits 1 if any invoked phase failed. Do not infer a fixed phase total.

| Phase | Invocation | Requirement |
|---|---|---|
| Zig unit and simulation | `core: zig build test` | Always invoked |
| Rust tests | `worker: cargo test` | Always invoked |
| Go API tests | `api: go test ./...` | Always invoked |
| Go bench tests | `bench: go test ./...` | Always invoked |
| Go builds | API and bench `go build ./...` | Always invoked |
| Worker-env fixture | `infra/poc/test-worker-env.sh` | Always invoked; offline fixture |
| Deploy-output fixture | `tests/poc_deploy_outputs_test.sh` | Always invoked; offline fixture |
| Launcher contract | `tests/launcher_contract_test.sh` | Always invoked; static fixture |
| SSM wait fixture | `tests/deploy_ssm_wait_test.sh` | Always invoked; stub AWS |
| systemd lifecycle fixture | `tests/bench_systemd_lifecycle_test.sh` | Always invoked; stubbed/offline |
| Artifact lifecycle fixture | `tests/bench_artifact_lifecycle_test.sh` | Always invoked; stubbed/offline |
| GPU cleanup fixture | `tests/gpu_test_cleanup_trap_test.sh` | Always invoked; stub Terraform/AWS |
| Strict capabilities | `tests/strict_capabilities_test.sh` | Always invoked; optional/required/evidence branches for containerd/GPU/Nydus/JuiceFS |
| GPU task evidence | `tests/gpu_evidence_test.sh` | Always invoked; stub CDI selection and in-container `nvidia-smi` decisions |
| ECR cold pull | `tests/ecr_cold_pull_test.sh` | Always invoked; stub exact-cache/auth/digest decisions |
| Live guardrails | `tests/live_guardrails_test.sh` | Always invoked; stub identity/executor/cleanup/inventory |
| Evidence manifest | `tests/evidence_manifest_test.sh` | Always invoked; bounded fields and malformed/oversized rejection |
| Docs layout | `tests/docs_layout_paths_test.sh` | Always invoked; static paths/layout |
| Shared wire contract | `tests/wire-contract-test.sh` | Always invoked; bounded schema/version validation plus Zig, Rust, Go API, and Go bench corpus consumers |
| `/run` retry fixture | `tests/run_retry_test.sh` | Always invoked; stub curl |
| HTTP helper fixture | `tests/http_helper_test.sh` | Always invoked; stub curl |
| Operator retry fixture | `tests/operator_workflow_retry_test.sh` | Always invoked; stub curl |
| Containerd component integration | `tests/containerd/run-tests.sh` | Conditional on Docker and no `--skip-containerd` |
| Local cleanup contract | `tests/local_cluster_cleanup_test.sh` | Always invoked; stopped-owned-child, shared multi-group deadline, and token-scoped residue contract |
| Local data-plane failover | `tests/local-failover-smoke.sh --build` | Conditional on no `--skip-smoke`; mandatory local phase |
| Local retained-storage recovery | `tests/local-storage-recovery-smoke.sh --build` | Conditional on no `--skip-smoke`; mandatory maintained recovery contract |
| Local run contract | `tests/local-run-contract-smoke.sh --build` | Conditional on no `--skip-smoke`; mandatory maintained run contract |

`build_binaries_test.sh` is maintained but remains absent from the runner.

## Detailed local and containerd harnesses

### `tests/local-run-contract-smoke.sh` and `tests/local-smoke.sh`

Topology: three journal-backed Zig replicas, one Rust worker using process runtime, one Go API, one Go bench, and a process workload. `local-smoke.sh` is a compatibility entry point. The shared helper chooses an isolated exact port set and temporary retained journal root. Every test invocation still requires an outer timeout.

The run contract asserts parsed connected/leader health; a successful request; response overflow status 4; forwarding failure plus lower/upper trickle deadline bounds for status 6; exact enqueue and dispatch deltas before abandoned-client cleanup returns to zero; killed-leader election and retained restart; status 9 from the exact restarted old leader after it becomes a normal follower; forwarding of that real status through the bounded relay to exercise the Go API's safe one-time reprobe; one aggregate dispatch delta and exactly-once workload execution; real bench leader probe/workload traffic; and exact zero queue/in-flight metrics. Negative process controls require explicit `--test-process-controls`, are disabled by default, use four ports disjoint from the stale-leader relay, retain one bounded last-payload execution counter slot when enabled, and do not affect containerd. Default process responses omit the test counter. `--build` is the only flag. Failure preserves the temporary root; success removes it.

### `tests/local-failover-smoke.sh`

Topology: the shared three-journal replica cluster, Go API, Rust worker using process runtime, and one process workload. It executes a successful `/run`, kills the elected leader, requires a different leader, waits separately for replacement-leader worker/pod readiness, then issues the post-failover workload once without retrying ambiguous outcomes and requires test-only `execution_count == 1`. It restarts the old replica from the same directory, requires commit/state convergence, and checks exact zero queue/in-flight metrics. It is mandatory in `run-all.sh` unless `--skip-smoke` is explicit. `--build` is the only flag.

### `tests/local-storage-recovery-smoke.sh` and `tests/storage_mode_smoke_test.sh`

Topology: the shared three-journal replica cluster plus Go API and Rust process worker. `storage_mode_smoke_test.sh` is a compatibility entry point. The contract commits named state, kills the leader, commits through the replacement, rejoins the old replica from its journal, stops the complete cluster, restarts all components from the same directories, verifies both original states and exact convergence metrics, then commits and converges a new command. `--build` is optional; failure preserves the temporary root and success removes it.

### `tests/containerd/run-tests.sh` and `tests/containerd/run.sh`

`run-tests.sh --check` performs bounded read-only Docker/Linux compatibility detection. `--component` runs the existing serial Rust integration image. `--full-stack` builds a separate image containing real Zig, Go, and Rust binaries, then starts three replicas/API/worker/containerd, exercises requests and worker restart/adoption, and requires exact task/container inventory restoration. Cleanup is installed before resource acquisition and removes only exact inventory deltas. `REQUIRE_GPU=1` adds CDI plus in-task `nvidia-smi`; `REQUIRE_NYDUS=1` proves the selected snapshotter; `REQUIRE_JUICEFS=1` requires explicit bounded mount/read/write/unmount proof. These are prepared commands, not E1 execution evidence.

### Compatibility wrappers

| Script | Contract |
|---|---|
| `tests/smoke_test.sh` | Maintained wrapper; `exec`s `local-smoke.sh --build`, forwarding arguments, signals, cleanup, and exit. |
| `tests/multi_node_smoke_test.sh` | Maintained wrapper; `exec`s `local-failover-smoke.sh --build`, forwarding arguments, signals, cleanup, and exit. |

## Deterministic fixtures and report utilities

These scripts do not contact live infrastructure when used as described. Each fixture uses temporary/stub state, asserts the named contract, cleans temporary state with traps, and returns nonzero on failure. Their internal operation is bounded where the row says so; none defines a common overall timeout.

| Script | Classification/topology | Dependencies and bounds | Assertion and non-assertion | Artifacts/cleanup; flags/exits |
|---|---|---|---|---|
| `tests/bench_artifact_lifecycle_test.sh` | Deterministic fixture around bench artifact ownership | Bash, flock, stub AWS/OpenSSL; internal command bounds | Ownership, races, ambiguous writes, keep mode, fail-closed cleanup; no AWS | Temporary logs/state removed; no flags; assertion failure nonzero |
| `tests/bench_systemd_lifecycle_test.sh` | Deterministic systemd/deploy fixture | Bash, timeout, stubs; explicit lifecycle/lock bounds | Stop/start verification, process-group kill, deploy locking; no host systemd service deployment | Temporary fixture cleaned; no flags; nonzero on failure |
| `tests/build_binaries_test.sh` | Offline build-script fixture, not in `run-all.sh` | Stub Zig/Cargo/Go/Git and temporary repo; no overall bound | Output naming/copy/build contract; no real compilation evidence | Temporary repo removed; no flags; nonzero on failure |
| `tests/deploy_ssm_wait_test.sh` | Deterministic SSM/deploy fixture | Stub AWS and fake clock; bounded waiter scenarios | Terminal status/error/deadline and captured command-ID handling; no AWS | Temporary state removed; no flags; nonzero on failure |
| `tests/docs_layout_paths_test.sh` | Stable static layout/path fixture | Bash, grep; finite file checks | Frozen `v1`/active `v2` and owned paths; no prose counts or runtime proof | Console only; no cleanup/flags; nonzero on failure |
| `tests/wire-contract-test.sh` | Shared protocol-v6 byte-corpus gate | Bash, bounded Python JSON validation, Zig, Cargo, and Go | Exact schema/version constants, complete fixture inventory, and all four consumers; no socket/cloud/runtime infrastructure | Console only; no cleanup/flags; nonzero on malformed corpus, version drift, or consumer failure |
| `tests/gpu_test_cleanup_trap_test.sh` | Deterministic GPU lifecycle fixture | Stub Terraform/AWS/archive/signals; synchronized concurrency | Pre-apply trap and per-run ownership/cleanup; no GPU or cloud | Temporary state removed; no flags; nonzero on failure |
| `tests/http_helper_test.sh` | Deterministic HTTP helper fixture | Stub curl and external timeout check | Connect/total deadlines and external deadline compatibility; no network service | Temporary state removed; no flags; nonzero on failure |
| `tests/launcher_contract_test.sh` | Static launcher/source contract | Bash, grep; finite scans | Child cleanup, launch serialization, caller-CWD safety, required failure propagation; starts nothing | Console only; no flags; nonzero on failure |
| `tests/operator_workflow_retry_test.sh` | Deterministic operator retry fixture | Stub curl; helper-defined bounded attempts | Retry/status policy; no API or workload | Temporary state removed; no flags; nonzero on failure |
| `tests/poc_deploy_outputs_test.sh` | Deterministic POC deploy-output fixture | Stub Terraform/SSH/JQ; finite scenarios | Required/bound output validation; no deploy/cloud | Temporary state removed; no flags; nonzero on failure |
| `tests/run_retry_test.sh` | Deterministic `/run` retry fixture | Stub curl; bounded retry/deadline scenarios | Retry-safe statuses, artifact handling, cleanup; no real request path | Temporary state removed; no flags; nonzero on failure |
| `infra/poc/test-worker-env.sh` | Deterministic worker-env fixture | Bash and temporary files; finite cases | Atomic update/preservation/permissions contract; no worker/cloud | Temporary state removed; no flags; nonzero on failure |
| `core/src/vopr/gen_report.sh` | Maintained report utility | Existing fuzz corpus and standard shell tools; finite input scan | Renders corpus/report information; does not run or validate seeds | Writes requested report/output; script arguments determine paths/exits |

## Maintained operational, helper, and live-capable scripts

These paths are maintained, but invoking live-capable entry points is not part of the default test gate and requires its own authorization, credentials, cost approval, evidence, and cleanup review. “No default” means the script does not impose one script-wide deadline; inspect its documented environment variables for narrower bounds.

| Script | Class and topology/services | Dependencies/bounds | Assertions and boundary | Artifacts/cleanup; flags/exits |
|---|---|---|---|---|
| `bench/compare.sh` | Benchmark comparison entry point; Hivemind and Kubernetes launchers | Built binaries, curl/system tools; internal polling, no overall default | Compares requested benchmark outputs; not evidence without a completed run | Benchmark artifacts/logs; traps tracked processes; arguments select run |
| `bench/k8s_bench.sh` | Kubernetes benchmark entry point | kubectl/cluster and bench tooling; bounded polling in script | Kubernetes comparison workload only | Benchmark output; cleans named workload resources; nonzero on failure |
| `infra/bench/artifact_lifecycle.sh` | Sourced S3 artifact ownership helper | AWS S3/SSM, OpenSSL, flock, timeout; explicit operation bounds | Account-scoped no-overwrite lease plus exact account/token/claim marker; cleanup requires fresh proofs | Caller-owned artifact paths; sourced API, not standalone evidence |
| `infra/bench/deploy.sh` | Live bench deploy entry point | Terraform, AWS/SSM, SSH/systemd helpers; bounded waits, no overall default | Deploy/readiness commands selected by caller | Logs/artifacts and remote units; cleanup is caller/runbook responsibility |
| `infra/bench/ssm_wait.sh` | Sourced SSM waiter | AWS CLI; configured wall-clock deadlines | Terminal command status or timeout | No standalone artifacts; sourced helper returns nonzero |
| `infra/bench/systemd_lifecycle.sh` | Sourced remote unit lifecycle helper | SSH/systemd/flock/timeout; configured deadlines | Verified stop/start and serialization | Caller logs; attempts verified cleanup; sourced helper |
| `infra/gpu-test/run-tests.sh` | Live GPU Terraform test entry point | Terraform, AWS S3/SSM, SSH, GPU host; command and aggregate cleanup deadlines | Provision/deploy/test steps reached; S3 deletion requires an exact lease and marker | Isolated run workspace/artifacts; bounded cleanup trap and keep mode; nonzero on failure |
| `infra/poc-eks/eks-workload-test.sh` | Live EKS workload entry point | kubectl/AWS/EKS and images; bounded waits | Workload behavior on supplied cluster | Kubernetes logs/resources; caller cleanup; env/args select target |
| `infra/poc-eks/scale-matrix.sh` | Live EKS scaling benchmark | kubectl/cluster; bounded polling | Requested scale transitions/latency | Matrix artifacts; removes named workloads; nonzero on failure |
| `infra/poc/build-binaries.sh` | Build entry point | Zig/Cargo/Go and source tree; no overall default | Required binaries produced | Output directory; `--output-dir`; nonzero on build failure |
| `infra/poc/build-workload-images.sh` | Image build/push entry point | Docker and target registry; no overall default | Requested images build/push | Local/registry images; caller owns cleanup; env-driven |
| `infra/poc/deploy.sh` | POC deploy entry point | Terraform outputs, SSH/SSM/systemd; bounded helpers | Required outputs and remote service deployment | Remote units/logs; caller/runbook cleanup; nonzero on failure |
| `infra/poc/failure-drills.sh` | Live failure-drill entry point | Existing POC, SSH/AWS/curl; bounded polling | Named failure/recovery observations | Drill logs/metrics; restores what script owns; caller verifies inventory |
| `infra/poc/http.sh` | Sourced bounded curl helper | curl and timeout; configured connect/total deadlines | HTTP command success/deadline | No standalone artifact/ports; sourced API returns curl status |
| `infra/poc/operator-workflow.sh` | API workflow entry point | Live API, curl/JQ, optional image credentials; bounded retries | CPU/GPU create/run/operator flow reached | JSON artifacts in `OUT_DIR`; deletes created deployments and temp secrets |
| `infra/poc/replica-init.sh` | Terraform-rendered cloud-init template | Linux/systemd/AWS image environment; no overall default | Bootstrap commands only when rendered/executed | Creates env/unit/data paths; provisioning owns cleanup |
| `infra/poc/run-local.sh` | Five-replica local POC entry point | Built Zig/API/worker, process/container runtime tools; no overall default | `up`, `down`, or delegated smoke behavior | `/tmp/hivemind-local` by default; `down` removes owned state |
| `infra/poc/run_retry.sh` | Sourced `/run` retry helper | curl/JQ; bounded attempts/deadlines from caller | Status-aware retry and artifact preservation | Caller temp/artifacts; sourced API, not standalone |
| `infra/poc/scale-matrix.sh` | API scale benchmark entry point | Live API/curl/JQ; bounded polling via variables | Requested scale transitions and latency events | CSV/JSONL under `OUT_DIR`; trap deletes created deployments |
| `infra/poc/smoke-test.sh` | POC API/optional GPU smoke | Live API, curl/JQ, optional SSH/GPU; bounded retries | Health, dashboard, CPU/GPU deployment/run and optional remote GPU checks | Console plus remote state; trap deletes named deployments |
| `infra/poc/update-worker-env.sh` | Worker-env mutation helper | Bash/filesystem permissions; finite operation | Atomic required env update | Replaces specified env file; arguments required; nonzero on failure |
| `infra/poc/worker-init.sh` | Terraform-rendered worker cloud-init template | EC2 metadata, Linux/systemd/containerd; no overall default | Bootstrap commands only | Creates host env/unit/config; provisioning owns cleanup |
| `infra/poc/workload-test.sh` | CPU/GPU workload entry point | Live API/images/curl/JQ; bounded retry helper | Requested CPU/GPU create and run results | JSON/summary in `OUT_DIR`; trap deletes created deployments/temp secrets |
| `scripts/poc-runbook.sh` | Guarded live executor component | Terraform/AWS/Docker/SSH and POC scripts; refuses execution unless `tests/live/run.sh` activated guardrails | Runs selected deploy/workload/drill phases after exact reviewed-plan apply | `artifacts/poc-final`; unified wrapper owns final destroy/inventory/evidence |
| `scripts/poc-section5-cycle.sh` | Bounded live Section 5 cycle | Same live dependencies; explicit apply/build/deploy/preload/overall bounds | Selected Section 5 cycle | Dated artifact log; teardown defaults documented in script; env-driven |
| `scripts/poc-section5-drill.sh` | Live drill against already-up POC | Existing Terraform outputs, SSH/API; explicit section timeout | Failure drills only; no apply/teardown | Dated drill log/artifacts; leaves existing infra intact |
| `scripts/poc-teardown.sh` | Destructive cleanup entry point | Terraform/AWS and existing states; no overall default | Destroy commands, not post-destroy proof by themselves | Terraform logs/state; environment selects POC/EKS destruction |

## Prepared opt-in live boundary

`tests/live/run.sh` is fail-closed and non-default. It requires literal live/cost/cleanup authorization, account/region allowlists, token-derived workspace/bucket/ECR names, a clean tracked tree, a digest-bound reviewed plan, `KEEP_INFRA=0` by default, zero pre-ownership inventory, and bounded hooks. Its trap is installed before execution. Immediately before Terraform destroy, cleanup rereads state and requires the exact managed address set, ownership tags, guarded names, and instance key/security-group relationships. Success requires zero owned instances, volumes, buckets, repositories, locks, units, and processes after cleanup plus a bounded redaction-clean manifest with source, binary/image/plan hashes, command exits, metrics, journals, and cleanup inventory. `HIVEMIND_LIVE_PREFLIGHT_ONLY=1` stops before ownership. See `tests/live/README.md`; E1 did not execute it live.

A smoke test is only as strong as its explicit assertions. Local process runtime is not containerd evidence, deterministic fixtures are not live evidence, prepared commands are not passes, and startup/liveness is not recovery evidence.

# Testing and evidence

This is the authoritative testing architecture and evidence-semantics document for Hivemind v2. See [the harness catalog](../tests/README.md) for script operation, [the handoff template](HANDOFF.md) for continuation records, [engineering](ENGINEERING.md) for architecture, and the [control-plane contract](design/CONTROL_PLANE_CONTRACT.md) for wire behavior.

## Testing principles

- Hivemind is simulation-first. Representable control-plane behavior belongs in named Zig VOPR scenarios; representable worker behavior belongs in named Rust simulation/runtime scenarios.
- Tests assert observable behavior and invariants, not source symbols, prose, or mutable test totals.
- Evidence names the full tested commit SHA, time, environment, exact command, exit code, and capabilities exercised.
- A skip is not a pass. An unavailable capability is not a pass.
- Historical evidence remains useful history but does not attest another commit without an explicit, reviewed scope argument.
- Deterministic simulation, local processes, privileged containerd, and live cloud cross different boundaries. Record the strongest boundary actually exercised.

Protocol version 6 gates client, worker, and replica peer envelopes. A peer body is `[2B little-endian protocol_version][1B from_id][VRR payload]`, inside the same plaintext or encrypted outer frame used by other TCP roles. Peers reject any version mismatch before sender identity binding, connection replacement/disconnect decisions, or VRR dispatch. Mixed-version rolling upgrades are unsupported: stop every replica, worker, API gateway, and bench client; replace all components; then restart the cluster.

## Fresh reviewed-stack accepted local evidence

The final non-live matrix ran from `2026-08-06T06:30:04Z` through `06:37:46Z` against evidence parent `7c798c99171cbc894ddf26e8f9c1e872af143401`, tree `671097ae849bdc7d7e4dc142353a111e70226345`. It passed `25 / 25` bounded gates with `0` failures, `455s` summed gate duration, and `462s` wall time. The final evidence/governance documentation commit is a descendant and is recorded separately from this tested parent.

Core Debug/ReleaseFast, 29 regression replays, and exact mutated seeds `0..9999` passed; the four-thread core sweep tested `10,000` seeds with `0` failures in `163.4s`. Worker formatting/all-targets, both recorded regression replays, and exact mutated seeds `0..999` passed; the four-thread worker sweep tested `1,000` seeds with `0` failures in `1.9s`. Worker all-target results were `191` library, `3` fuzz utility, `11` main, `1` CLI, `5` integration, and `0` containerd-integration tests.

Go API/bench format, race, and build; protocol-v6 schema/four-language corpus; active Bash syntax and ShellCheck with sourced-file resolution; all four offline Terraform roots; documentation layout/links; credential scanner positive/negative/redaction fixtures and branch scan; local-residue signatures; and final cleanliness passed. `./tests/run-all.sh --skip-containerd` passed all `28` invoked phases in `160s`. Final inventories found zero branch-owned processes, zero relevant listener delta, zero port-lock delta, zero generated-artifact delta, a clean tracked/index state, and no `v1` change.

Containerd component/full stack, Docker/privileged host behavior, GPU/CDI, Nydus, JuiceFS, Doppler, private registry/image pulls, AWS/ECR/EKS/S3/SSM/remote systemd, every cloud/provider operation, Terraform plan/apply/destroy, `tests/live/run.sh`, `scripts/poc-runbook.sh`, and all live/cost/destructive work remained skipped or unexecuted. Live-resource state was not inventoried and remains unknown.

## Historical accepted local evidence

The historical non-live matrix ran from `2026-07-25T01:06:39Z` through `01:14:01Z` against code commit `bc9f5f63fcf4f030177ceae321342d92b79ab613`, tree `78f4c95c28fca5233a25e57ec8179e969120779c`. It passed `25 / 25` bounded gates with `0` failures, `433s` summed gate duration, and `442s` wall time.

Core Debug/ReleaseFast and 29 regression replays passed. The mutated core sweep used `--seeds 10000 --threads 4 --mutate` and tested exact seeds `0..9999`, with `10,000` tested, `0` failures, in `164.9s`. Worker formatting/all-targets and 27 regression replays passed; all-target counts were `176` library, `3` fuzz utility, `7` main, and `5` integration tests, while the containerd-feature binary ran `0`. The mutated worker sweep used `--seeds 1000 --threads 4 --mutate` and tested exact seeds `0..999`, with `1,000` tested, `0` failures, in `6.6s`. The `--skip-containerd` aggregate passed `26 / 26` invoked phases in `139s`, including local real-process cleanup, failover, retained-storage recovery, and `/run` contracts.

Go API/bench formatting, race tests, and builds; active Bash syntax and default ShellCheck; protocol-v6 wire checks under `PYTHONOPTIMIZE=2`; docs/layout; Terraform recursive formatting; and backend-disabled lockfile-readonly init/static validation for `poc`, `poc-eks`, `bench`, and `gpu-test` passed. Credential checks passed a bounded value-redacting self-test with `12` safe, `6` unsafe, and `2` redacted-output fixtures, followed by a clean changed-line scan. Final residue was zero branch-owned processes, branch-attributable listener deltas, port locks, and lock owners.

The run explicitly skipped or did not execute containerd component/full stack, Docker, privileged namespace/cgroup behavior, GPU/CDI, Nydus, JuiceFS, Doppler, private registry/image pulls, AWS/ECR/EKS/S3/SSM/systemd, Terraform plan/apply/destroy/provider operations, `tests/live/run.sh`, `scripts/poc-runbook.sh`, and all live/cost/destructive work. Prepared E1 harnesses remain preparation, not execution evidence. Live-resource state was not inventoried and remains unknown. These results attest only historical `bc9f5f63` / tree `78f4c95c`; fresh rewritten-parent evidence is recorded separately above.

## Test layers and authoritative commands

Commands are run from the repository root unless the command changes directory. None of these commands creates current-head evidence unless its SHA, exit, environment, and skips are recorded.

| Layer | Current command | What it proves | Boundary |
|---|---|---|---|
| Zig unit and VOPR | `cd v2/core && zig build test` | The configurable Debug suite plus an explicitly configured ReleaseFast suite | Deterministic model, not real kernel/process/cloud behavior |
| Zig ReleaseFast-only configuration | `cd v2/core && zig build test -Doptimize=ReleaseFast` | Both configured suites in ReleaseFast | Does not exercise Debug |
| Zig VOPR sweep | `cd v2/core && zig build fuzz -- sequential --seeds 10000 --threads 0 --mutate` | Mutated sequential seeds `0..9999`; the fuzzer is built ReleaseFast | Simulator model only |
| Zig replay | `cd v2/core && zig build fuzz -- replay <SEED> --mutate --verbose --trace <PATH>` | Replays one named failure and can emit a trace | Requires the exact seed/configuration |
| Rust unit/simulation/runtime | `cd v2/worker && cargo fmt --check && cargo test --all-targets` | Worker units, deterministic simulation, and compiled runtime targets | Not the full Zig/Go/containerd stack |
| Rust simulation sweep | `cd v2/worker && cargo run --release --bin fuzz -- sequential --seeds 1000 --threads 0 --mutate` | Mutated sequential seeds `0..999` | Simulator model only |
| Rust replay | `cd v2/worker && cargo run --release --bin fuzz -- replay <SEED> --mutate --verbose` | Replays one worker seed | Requires the exact seed/configuration |
| Go API | `cd v2/api && go test -race ./... && go build ./...` | API/client behavior, race-enabled tests, and build | No real cluster by itself |
| Go bench | `cd v2/bench && go test -race ./... && go build ./...` | Bench client/probe behavior and build | A build is not benchmark evidence |
| Shared wire contract | `cd v2/tests && ./wire-contract-test.sh` | Bounded canonical protocol-v6 schema, exact global constants, and Zig/Rust/Go API/Go bench consumers of one byte corpus | Deterministic codec evidence; not authentication or real-network evidence |
| Aggregate | `cd v2 && ./tests/run-all.sh` | The phases actually invoked, including shared wire/capability/live-guard fixtures and optional local smoke/containerd when available | See skip semantics below |
| Local run contract | `cd v2 && ./tests/local-run-contract-smoke.sh --build` | Three journal-backed Zig replicas, Go API, Rust worker/process runtime, bench, statuses 0/4/6/9, abandonment, kill/restart reprobe, exactly-once execution, and zero accounting | Real localhost processes/sockets/filesystem; not containerd |
| Local failover | `cd v2 && ./tests/local-failover-smoke.sh --build` | Three journal-backed Zig replicas, Go API, Rust worker/process runtime, leader kill/restart, and data-plane continuity | Real localhost processes/sockets/filesystem; not containerd |
| Storage recovery | `cd v2 && ./tests/local-storage-recovery-smoke.sh --build` | Commit, leader failover/rejoin, full retained-directory restart, convergence, and a new post-recovery commit | Experimental journal/process/filesystem boundary; not torn-write or power-loss proof |
| Containerd component | `cd v2 && ./tests/containerd/run-tests.sh --component` | Privileged Docker-hosted Rust containerd integration tests | Worker runtime component only |
| Containerd full stack | `cd v2 && REQUIRE_CONTAINERD=1 ./tests/containerd/run-tests.sh --full-stack` | Three Zig replicas, Go API, Rust worker/containerd, request traffic, worker restart/adoption, and exact task/container inventory | Prepared opt-in privileged boundary; not executed for E1 |
| Terraform offline | commands below | Formatting, backend-disabled initialization, static validation | No apply or cloud proof |
| Live/cloud | `cd v2 && ./tests/live/run.sh` with the documented authorization environment and reviewed saved plan | Guarded executor, strict capabilities, evidence, destroy, and zero post-cleanup inventory | Prepared opt-in boundary; no E1 live execution or evidence |

`run-all.sh` uses plain `cargo test` and plain `go test ./...`; it does not replace the stronger Rust format/all-targets or Go race/build commands above. The aggregate runner supports `--skip-containerd`, `--require-containerd`, and `--skip-smoke`; unknown arguments fail with exit 1. It continues through invoked phases and exits 1 if any invoked phase fails. `--skip-containerd` prints an explicit component/full-stack skip. Without either containerd flag, unavailable/incompatible Docker explicitly skips both boundaries. `--require-containerd` performs a read-only compatibility preflight before aggregate phases and makes any missing runner, Docker daemon, component phase, or full-stack phase nonzero. `REQUIRE_CONTAINERD=1` is equivalent acceptance semantics. Unless `--skip-smoke` is explicit, failover, retained-storage recovery, and run-contract phases are mandatory.

Strict opt-in surfaces validate literal `REQUIRE_CONTAINERD`, `REQUIRE_GPU`, `REQUIRE_NYDUS`, and `REQUIRE_JUICEFS` values. In the aggregate, any subordinate strict runtime flag implies required full-stack containerd mode and preflights before Zig or other aggregate phases. Required absence is always a failure. `REQUIRE_GPU=1` defines the eventual evidence contract: exact deployment task, CDI selection, and in-container `nvidia-smi`. Current process and containerd runtimes reject GPU workloads because concrete physical device reservation is not implemented, so strict GPU acceptance is blocked. `REQUIRE_JUICEFS=1` fails before live ownership/apply because the current API/AppSpec cannot request the required workload mount; this preserves the product blocker rather than converting it to a skip. Deterministic fixtures exercise decision semantics without provider/runtime access.

Offline Terraform validation:

```bash
terraform fmt -check -recursive v2/infra
for root in poc poc-eks bench gpu-test; do
  terraform -chdir="v2/infra/$root" init -backend=false -lockfile=readonly
  terraform -chdir="v2/infra/$root" validate
done
```

## Coverage boundaries

VOPR models bounded replica state machines, virtual ticks, a simulated network, simulated disk operations, crashes/restarts, durable publication cut points, and safety/liveness oracles. It provides deterministic seed replay and a failure corpus. It cannot prove kernel TCP behavior, process scheduling, real filesystem ordering, torn writes, power loss, containerd namespaces/cgroups, systemd, GPU/CDI, or cloud-provider behavior.

The worker simulator models the worker state machine, fail-loud bounded I/O staging, a bounded control-plane stub, simulated runtime, deterministic scheduling, checker-visible resource/state transitions, and bounded bidirectional message delivery. Worker output traverses the simulated network in a later tick; partition, ratio drop/one-shot replay, delay, and path capacity apply in both directions. Session-tagged queues preserve FIFO order under variable delay. Delayed partitions preserve queued messages, while explicit session loss advances the epoch, discards old-session queues, and forces re-registration. Convergence requires registration observed after the most recent explicit session loss from every worker and an observed terminal status for every generated start command. Runtime fault behaviors remain scenario-specific, and evidence must name the scenario actually exercised. Named scenarios `liveness_probe_two_failures_then_success_resets_counter` and `liveness_probe_three_failures_transition_pod_to_failed` use bounded scripted simulated-runtime outcomes to check probe hysteresis and the third-failure transition. The three-failure scenario also proves that a failed stop retains the live runtime and all accounting, denies replacement GPU admission, and publishes `Failed` only after verified runtime termination and removal. Named scenario `stop_fault_retains_runtime_resources_and_denies_replacement_gpu` injects a deterministic first-stop failure and checks that the still-running runtime retains pod ownership and CPU, memory, and GPU state. Unit regression `failed_stop_retains_running_runtime_ownership_and_capacity` also uses an owned mount marker to prove failed-stop cleanup does not unmount. Named scenarios `mismatched_nonzero_gpu_type_is_rejected_without_accounting_change` and `deterministic_run_outcomes_preserve_identity_bounds_and_accounting` reject nonzero GPU requests whose type differs from the worker and exercise `/run` success, the exact response-body boundary, boundary-plus-one overflow, scripted forwarding and timeout errors, crash-tick forwarding failure, reconciled no-running-pod, and partition-healed delivery. The outbound network canonicalizes responses to their encoded wire semantics. The scenarios assert exactly one response for each ordinary request, exact request identity, statuses 0, 4, 6, and 7, bounded response bodies, and unchanged nonzero GPU, CPU, and memory accounting until the deliberate crash. Multiple matching running pods are routed deterministically to the lowest pod ID. The simulated timeout outcome checks error-to-status mapping; virtual run-deadline progression is not modeled. `Stopped` publication and resource release require terminal runtime status, verified runtime removal, and verified mount cleanup. Spontaneous crashes use the same fail-closed cleanup path, and a failed transient-start cleanup retains the runtime handle. Stop grace is capped at 30 seconds; process and containerd runtimes use TERM/grace/KILL behavior. The process runtime polls for at most two seconds after KILL and retains ownership if exit remains unobservable. Stop signals are attempted at most three times. Shutdown performs one reconciliation pass with a 20-second aggregate grace budget, then exits nonzero without publishing cleanup or refunding resources if ownership remains unverified. It cannot prove real process signals, host networking/filesystems, `ctr`/containerd behavior, GPU visibility, mounts, or cloud services.

Named deterministic socket scenario `peer envelope socketpair rejects before identity binding and VRR dispatch` covers protocol-v6 plaintext and fixed-nonce encrypted peer envelopes plus current-1, malformed, and plaintext-on-keyed-connection rejection. A well-framed version mismatch or malformed peer body is rejected without binding identity or dispatching VRR and leaves the socket connected for the bounded identity deadline. Invalid frame declarations, unknown flags, and plaintext on a keyed connection disconnect immediately, still before identity binding or VRR dispatch. Only a valid current-version-6 frame can bind identity or reach replica dispatch. AF_UNIX socketpairs cover kernel stream framing but not TCP routing, half-close behavior, process scheduling, or authenticated peer identity.

Real-process tests are required when behavior crosses sockets, process lifecycle, retained filesystem state, or OS deadlines. The local cluster harness launches each owned component in a separate process group, records PID start identity, resumes all stopped owned groups before TERM, applies one shared TERM deadline and one shared KILL deadline across all groups, inventories while its port-lock token is still held, releases only that token-owned lock, and fails cleanup if an owned process, exact listener, or attributable lock remains. Its four test-process ports are disjoint from the bounded stale-leader relay port. It never uses broad process-name killing. Privileged containerd evidence is required for namespaces, cgroups, task adoption, and the real runtime. GPU, private registry, JuiceFS, S3/SSM/systemd, Terraform apply, and provider cleanup require separately authorized live evidence.

## Pass, fail, skip, unavailable

- **Passed:** the command ran at the recorded SHA, all required capabilities were present, semantic assertions completed, and exit code was 0.
- **Failed:** the command ran and a required assertion or phase returned nonzero.
- **Skipped:** an executable path was deliberately or automatically omitted. A zero aggregate exit does not convert a skip into a pass.
- **Unavailable:** no current entry point, authorization, credentials, privilege, host capability, or prerequisite exists.

Required-capability modes fail nonzero when absent. Their deterministic fixtures prove decision semantics only; the privileged/containerd/GPU/Nydus/JuiceFS/cloud boundary remains unverified until the corresponding opt-in command actually completes.

## Fault model

| Fault | Current deterministic coverage | Observable assertion | Real-boundary gap |
|---|---|---|---|
| Network partition/session loss | Zig VOPR; worker simulation separates bounded delayed partitions from explicit queue-invalidating session loss | Isolated delayed traffic does not cross a partition; old-session messages do not survive session loss; re-registration precedes new-session traffic | Kernel TCP buffering, partial-frame loss, half-close, and process reconnect timing |
| True pause/resume | Zig VOPR | Paused replicas do not tick, sync, publish, or receive; state is retained | OS suspension and clock behavior |
| Crash/restart | Zig VOPR and worker simulation scenarios | Volatile state is lost as modeled; durable/resource invariants survive | Real process, filesystem, containerd restart |
| Delay/drop/replay/capacity | Zig simulated network; worker simulation applies each fault in both directions | Bounded delivery semantics and worker message/byte accounting | Socket buffers and kernel scheduling |
| Disk read/write/sync failure | Zig simulated disk | Fail-closed transitions and durable-prefix invariants | Torn writes, reordering, power loss |
| Durability barrier cuts | Zig VOPR around Prepare, Commit, and StartView publication | Unpublished state cannot become committed; recovery remains canonical | Real drive/cache behavior |
| Client/worker disconnect, abandonment, late/foreign response | Zig unit/deterministic connection scenarios | Queue/correlation accounting and identity remain bounded | Real socket half-close and scheduling |
| Runtime stop/probe/run failure | Rust unit and named worker simulation cover deterministic stop, scripted liveness-probe outcomes, exact and overflowing run responses, scripted forwarding/timeout errors, and crash-tick versus reconciled no-pod outcomes; process-runtime units cover queryable terminal status, graceful TERM handling, plus bounded exact HTTP status-line parsing | A stop or spontaneous crash stays `Stopping` until runtime status, runtime removal, and mount-table cleanup are verified, retaining mount/CPU/memory/GPU ownership and denying replacement GPU admission. Liveness probes execute through `Runtime`; success resets the failure count and the third consecutive failure transitions the pod to `Failed`. Process probes accept only an exact well-formed HTTP 200 status, including the required separator after the status code, with one absolute deadline across connect/write/status-line reads plus bounded status-line and request-target lengths. Run-response wire overflow is canonicalized; simulated timeout covers status mapping, not virtual deadline progression. Stop grace is capped at 30 seconds; process and containerd use TERM/grace/KILL. Stop signals use at most three attempts; shutdown uses one reconciliation pass with a 20-second aggregate grace budget and exits nonzero without releasing ownership when cleanup remains unverified. Containerd network-namespace work runs in a disposable thread so restoration failure cannot contaminate the caller thread. | Real containerd signal/error behavior and task-network-namespace probing require the privileged component gate; actual JuiceFS mount retention remains unverified |
| Torn write, kernel, GPU, cloud fault | Not modeled | None | Requires environment-specific execution |

## Evidence and artifacts

A reviewable evidence record contains:

- full tested commit SHA and UTC timestamp;
- exact command, working directory, tool/environment versions, capabilities, and exit code;
- concise semantic result rather than a mutable total;
- seed mode/range, mutation mode, thread/budget settings, replay command, failure-corpus path, and trace path;
- binary and image SHA-256 when real binaries/images ran;
- relevant logs, metrics, API/state snapshots, and Terraform plan digest;
- every explicit or automatic skip and every unavailable capability;
- process/container/mount/cloud cleanup inventory and outcome;
- redaction/secret-scan result.

Zig failures append to `v2/core/fuzz_failures.jsonl`; worker failures append to `v2/worker/fuzz_failures.jsonl`. These generated corpora are artifacts, not source changes.

## Adding a behavior

1. Name the production behavior and deterministic scenario(s).
2. Add observable deterministic coverage in Zig VOPR, worker simulation/runtime, or both.
3. Add real-process coverage when sockets, process lifecycle, filesystem, runtime, or infrastructure matter.
4. For wire changes, update Zig, Rust, Go API, Go bench, and [`tests/wire/contract-v6.json`](../tests/wire/contract-v6.json) together; run the shared gate and require byte-identical re-encoding where applicable.
5. Update this document, the harness catalog, affected contracts, and `POC_CHANGELOG.md` when POC evidence or readiness changes.

## Reviewer checklist

- Evidence names the exact tested HEAD, UTC time, command, environment, and exit.
- No explicit Docker/smoke skip or automatic Docker-missing skip is hidden.
- Assertions are semantic, not source/count checks.
- Client, worker, API, bench, and peer envelopes all use protocol version 6, and peer mismatch rejection precedes identity binding and VRR dispatch.
- Planned inventory is visibly separate from runnable commands.
- Seeds, traces, logs, hashes, metrics, and state snapshots needed for replay are present.
- Cleanup inventory is complete and current; historical live state is not inherited.
- Historical evidence is labeled and does not silently satisfy current-head acceptance.

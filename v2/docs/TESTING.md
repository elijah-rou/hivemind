# Testing and evidence

This is the authoritative testing architecture and evidence-semantics document for Hivemind v2. See [the harness catalog](../tests/README.md) for script operation, [the handoff template](HANDOFF.md) for continuation records, [engineering](ENGINEERING.md) for architecture, and the [control-plane contract](design/CONTROL_PLANE_CONTRACT.md) for wire behavior.

## Testing principles

- Hivemind is simulation-first. Representable control-plane behavior belongs in named Zig VOPR scenarios; representable worker behavior belongs in named Rust simulation/runtime scenarios.
- Tests assert observable behavior and invariants, not source symbols, prose, or mutable test totals.
- Evidence names the full tested commit SHA, time, environment, exact command, exit code, and capabilities exercised.
- A skip is not a pass. An unavailable capability is not a pass.
- Historical evidence remains useful history but does not attest another commit without an explicit, reviewed scope argument.
- Deterministic simulation, local processes, privileged containerd, and live cloud cross different boundaries. Record the strongest boundary actually exercised.

Protocol version 5 gates client and worker envelopes. Replica peer frames remain unversioned (`from_id` plus the VRR payload); protocol-v5 mismatch rejection does not protect peer frames. Mixed-version rolling upgrades are unsupported, so upgrades require stopping the full cluster.

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
| Aggregate | `cd v2 && ./tests/run-all.sh` | The phases actually invoked, including optional local smoke/containerd when available | See skip semantics below |
| Local process | `cd v2 && ./tests/local-smoke.sh --build` | One Zig replica, Go API, Rust worker, process runtime, deployment and successful `/run` | Single replica; process runtime is not containerd |
| Local failover | `cd v2 && ./tests/local-failover-smoke.sh --build` | Three Zig replicas and Go API across leader loss/restart | Standalone; no worker or data-plane `/run` |
| Storage startup | `cd v2 && ./tests/storage_mode_smoke_test.sh` | Volatile and journal mode startup, warning, listening, and liveness | Startup/liveness only; no committed-state recovery |
| Containerd component | `cd v2 && ./tests/containerd/run-tests.sh` | Privileged Docker-hosted Rust containerd integration tests | Worker runtime component only, not full stack |
| Terraform offline | commands below | Formatting, backend-disabled initialization, static validation | No apply or cloud proof |
| Live/cloud | unavailable | No unified guarded live gate exists | **Planned, not implemented** |

The aggregate runner currently supports only `--skip-containerd` and `--skip-smoke`; unknown arguments fail with exit 1. It continues through invoked phases and exits 1 if any invoked phase fails. `--skip-containerd` prints a skip and means containerd is unverified. Without that flag, missing Docker auto-skips containerd and may still produce exit 0; containerd remains unverified. `--skip-smoke` omits local real-process evidence. Local failover is not in the aggregate runner.

**Planned, not implemented:** `--require-containerd`, strict containerd/live capability flags, mandatory recovery and run-contract phases, full-stack containerd, a shared wire corpus/gate, and a unified live entry point. Do not run these as commands or cite them as evidence.

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

The worker simulator models the worker state machine, fail-loud bounded I/O staging, a bounded control-plane stub, simulated runtime, deterministic scheduling, checker-visible resource/state transitions, and bounded bidirectional message delivery. Worker output traverses the simulated network in a later tick; partition, ratio drop/one-shot replay, delay, and path capacity apply in both directions. Delayed partitions preserve queued messages, while explicit session loss discards old-session queues and forces re-registration. Convergence requires registration observed after the most recent explicit session loss from every worker and an observed terminal status for every generated start command. Runtime fault behaviors remain scenario-specific, and evidence must name the scenario actually exercised. Named scenarios `liveness_probe_two_failures_then_success_resets_counter` and `liveness_probe_three_failures_transition_pod_to_failed` use bounded scripted simulated-runtime outcomes to check probe hysteresis and the third-failure transition. The three-failure scenario also proves that a failed stop retains the live runtime and all accounting, denies replacement GPU admission, and publishes `Failed` only after verified runtime termination and removal. Named scenario `stop_fault_retains_runtime_resources_and_denies_replacement_gpu` injects a deterministic first-stop failure and checks that the still-running runtime retains pod ownership and CPU, memory, and GPU state. Unit regression `failed_stop_retains_running_runtime_ownership_and_capacity` also uses an owned mount marker to prove failed-stop cleanup does not unmount. Named scenarios `mismatched_nonzero_gpu_type_is_rejected_without_accounting_change` and `deterministic_run_outcomes_preserve_identity_bounds_and_accounting` reject nonzero GPU requests whose type differs from the worker and exercise `/run` success, the exact response-body boundary, boundary-plus-one overflow, scripted forwarding and timeout errors, crash-tick forwarding failure, reconciled no-running-pod, and partition-healed delivery. The outbound network canonicalizes responses to their encoded wire semantics. The scenarios assert exactly one response for each ordinary request, exact request identity, statuses 0, 4, 6, and 7, bounded response bodies, and unchanged nonzero GPU, CPU, and memory accounting until the deliberate crash. Multiple matching running pods are routed deterministically to the lowest pod ID. The simulated timeout outcome checks error-to-status mapping; virtual run-deadline progression is not modeled. `Stopped` publication and resource release require terminal runtime status, verified runtime removal, and verified mount cleanup. Spontaneous crashes use the same fail-closed cleanup path, and a failed transient-start cleanup retains the runtime handle. Stop grace is capped at 30 seconds; process and containerd runtimes use TERM/grace/KILL behavior. Stop signals are attempted at most three times; bounded periodic status-only reconciliation continues after exhaustion. Process shutdown performs at most 30 reconciliation attempts, then exits nonzero without publishing cleanup or refunding resources. It cannot prove real process signals, host networking/filesystems, `ctr`/containerd behavior, GPU visibility, mounts, or cloud services.

Real-process tests are required when behavior crosses sockets, process lifecycle, retained filesystem state, or OS deadlines. Privileged containerd evidence is required for namespaces, cgroups, task adoption, and the real runtime. GPU, private registry, JuiceFS, S3/SSM/systemd, Terraform apply, and provider cleanup require separately authorized live evidence.

## Pass, fail, skip, unavailable

- **Passed:** the command ran at the recorded SHA, all required capabilities were present, semantic assertions completed, and exit code was 0.
- **Failed:** the command ran and a required assertion or phase returned nonzero.
- **Skipped:** an executable path was deliberately or automatically omitted. A zero aggregate exit does not convert a skip into a pass.
- **Unavailable:** no current entry point, authorization, credentials, privilege, host capability, or prerequisite exists.

A future required-capability mode must fail nonzero when its capability is absent. Until implemented, planned strict flags are documentation only.

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
| Runtime stop/probe/run failure | Rust unit and named worker simulation cover deterministic stop, scripted liveness-probe outcomes, exact and overflowing run responses, scripted forwarding/timeout errors, and crash-tick versus reconciled no-pod outcomes; process-runtime units cover queryable terminal status, graceful TERM handling, plus bounded exact HTTP status-line parsing | A stop or spontaneous crash stays `Stopping` until runtime status, runtime removal, and mount-table cleanup are verified, retaining mount/CPU/memory/GPU ownership and denying replacement GPU admission. Liveness probes execute through `Runtime`; success resets the failure count and the third consecutive failure transitions the pod to `Failed`. Process probes accept only an exact well-formed HTTP 200 status, including the required separator after the status code, with one absolute deadline across connect/write/status-line reads plus bounded status-line and request-target lengths. Run-response wire overflow is canonicalized; simulated timeout covers status mapping, not virtual deadline progression. Stop grace is capped at 30 seconds; process and containerd use TERM/grace/KILL. Stop signals use at most three attempts, followed by bounded status-only reconciliation; process shutdown exits nonzero after 30 unsuccessful reconciliation attempts without releasing ownership. Containerd network-namespace work runs in a disposable thread so restoration failure cannot contaminate the caller thread. | Real containerd signal/error behavior and task-network-namespace probing require the privileged component gate; actual JuiceFS mount retention remains unverified |
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
4. For wire changes, update Zig, Rust, Go API, and Go bench together. Update the shared corpus when it exists; it is currently **Planned, not implemented**.
5. Update this document, the harness catalog, affected contracts, and `POC_CHANGELOG.md` when POC evidence or readiness changes.

## Reviewer checklist

- Evidence names the exact tested HEAD, UTC time, command, environment, and exit.
- No explicit Docker/smoke skip or automatic Docker-missing skip is hidden.
- Assertions are semantic, not source/count checks.
- Client/worker protocol versioning is not generalized to peer frames.
- Planned inventory is visibly separate from runnable commands.
- Seeds, traces, logs, hashes, metrics, and state snapshots needed for replay are present.
- Cleanup inventory is complete and current; historical live state is not inherited.
- Historical evidence is labeled and does not silently satisfy current-head acceptance.

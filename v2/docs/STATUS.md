# Hivemind Status Report

*Last updated: 2026-07-16*


## Current Presentation Gate (2026-05-05)

POC v1 functional/resilience evidence and warm-cache benchmark evidence exist, but the team-facing replacement pitch is now blocked on POC v2. Use `docs/POC_V2_ACCEPTANCE.md` as the pass/fail gate before claiming credible parity with the current Kubernetes/Knative system.

POC v2 requires one real inference workload shape with storage, env/secrets, logs, readiness, private image auth, security/isolation baseline, and Hivemind-native revision/routability/rollout semantics. The warm-cache nginx benchmark remains useful evidence, but it is not sufficient by itself to convince the team.

Current highest-priority engineering sequence:

1. `AppSpec v1` across API/core/worker: env, secret refs, image pull auth, JuiceFS, probes, resources, termination grace, isolation profile.
2. Private image auth fix, especially ECR/cold-cache path.
3. Required JuiceFS mount semantics: required mount failure must prevent routing.
4. Readiness/routability split: `running` must not imply `routable`.
5. First-class revisions, weighted routes, availability-preserving rollout, route-first rollback.
6. Durable event stream and pod logs API for operator diagnosis without SSH.
7. Security/isolation baseline and explicit limitations.
8. Queue-aware serving/scale-to-zero and GitOps bridge after the core workload parity path is in place.

Canonical docs:
- POC v2 gate: `docs/POC_V2_ACCEPTANCE.md`
- Hivemind-native platform model: `docs/design/HIVEMIND_NATIVE_PLATFORM.md`

## POC Status Update (2026-05-02)

Latest state after the fresh AWS redeploy, corrected smoke pass, POC acceptance rewrite, 10k local fuzz gate, local federated selector proof, Thalamus POC branch locality tests, localhost multi-origin smoke, workload prep, failure-drill/EKS prep, runbook hardening, focused fresh-AWS real workload validation, operator workflow proof, targeted cloud failure-drill proof, Section 6 repeatability pass, initial isolated EKS benchmark collection, warm-cache Hivemind/EKS latency rerun, granular span attribution, flamegraph artifacts, and refreshed final evidence pack/verdict:

- Live AWS validation reached the real POC loop: encrypted 5-replica cluster healthy, CPU worker + GPU worker registered, CPU and GPU deployments both scheduled, dashboard reflected running pods, and `/v1/deployments/{name}/run` returned successful responses on both CPU and GPU paths.
- The earlier POC blockers were fixed and pushed on `master`:
  - duplicate in-flight pod binding / duplicate `bind_pod_to_node`
  - worker `/run` forwarding hanging on HTTP keep-alive / `Content-Length`
  - recovery/view-change safety failures found by VOPR mutated fuzz
  - macOS `infra/poc/deploy.sh --build` path without Docker/`cross`
  - abandoned `/run` queue entries leaking `In-Flight` state after client timeout/disconnect
  - GPU containerd runtime selection via CDI devices (`nvidia.com/gpu=N`) with `io.containerd.runc.v2`
- Current local verification is green:
  - Zig tests: `124/124` in Debug, `124/124` in ReleaseFast, `zig build test` pass
  - core fuzz: `10000/10000` mutated seeds, `0` failures
  - worker tests: pass (`91` lib tests + main/integration suites after bounded lifecycle concurrency)
  - worker fuzz: `10000/10000` mutated seeds, `0` failures
  - local smoke: `16 passed, 0 failed`
- Fresh AWS redeploy/smoke gate is now closed. Corrected live smoke passed end-to-end on fresh infra, including remote GPU checks and CPU/GPU `/run` paths.
- POC progress is `6 / 8` acceptance sections complete with Sections 7-8 provisional, and `16 / 16` execution checklist items complete for the warm-cache evidence pack. Functional/resilience gates through Section 6 are complete; Section 7 benchmark/economic acceptance still needs a clean EKS rerun after GPU-node sandbox failures are resolved.
- Latest repeatability run `poc-20260428195031` passed smoke, real workloads, operator workflow, placement-asserted failure drills, final log capture, and teardown. Latest latency reruns left Hivemind infra and EKS nodegroups up for reuse. EKS control-plane deletion still requires elevated IAM or an exception for explicit `eks:DeleteCluster` deny.
- The POC finish line is now defined in `docs/POC_ACCEPTANCE.md`.
- Local deterministic federation modeling and localhost locality smoke have landed:
  - origin-aware gossip and metrics expose the peer advisory surface, including queue depth
  - VOPR models federated origins across localities
  - local selector-proof coverage exercises `same-locality-best`, `same-locality-failover`, `cross-locality-fallback`, and `residency-restricted`
  - localhost multi-origin smoke exercised four Hivemind origins via `/v1/internal/federation` and the actual Thalamus resolver on branch `feat/hivemind-poc-locality`
  - stale-peer detection was demonstrated by killing `crusoe-texas` and observing `stale=true` from `aws-us-east-1`
- Repo scope has been trimmed for production-hardening work:
  - At repo root, `v1/` is the frozen POC V1 snapshot and `v2/` is the active development line
  - Within `v2/`, Zig control plane path is `core/` (historical in-tree rename away from a nested `v2/` name)
  - Zero-byte `hivemind/` skeleton and inactive `honeybee/` prototype were removed from the active line
  - frozen/legacy docs are isolated under `docs/frozen/` and `docs/legacy/`
- Live execution remains scripted, not manual. `scripts/poc-runbook.sh` can build/push ECR images, apply isolated `infra/poc`, deploy Hivemind, run smoke, run real workload validation, run operator workflow proof, run failure drills, and optionally run isolated EKS baseline under `infra/poc-eks`.
- Final POC evidence and verdict are refreshed but benchmark/economic status remains provisional:
  - summary: `artifacts/poc-final/00-summary.md`
  - verdict: `artifacts/poc-final/07-conclusion/verdict.md`
  - verdict: functional/resilience POC passes; latest warm-cache matrix favors Hivemind, but broad speedup/economic claims require a clean EKS rerun after GPU-node sandbox failures
  - local live leader-loss reproduction is fixed: VRR view-change frames needed 64 KiB transport buffers, and API command replies now reject stale `request_id`s after reconnect
  - cloud Section 5 passed end-to-end after worker multi-replica reconnect, non-leader worker disconnect, re-registration dedup, and pod redispatch on worker restart
  - first Section 6 repeatability rerun `poc-20260428091331` failed at CPU worker restart recovery because the restarted worker redispatched an active pod while containerd still had stale task/container state for the same pod ID; runtime now adopts visible live tasks and cleans/retries invisible stale task state before failing on `already exists`
  - final repeatability run `poc-20260428195031` passed from clean infra with no host edits or manual container cleanup
  - Drill B now asserts CPU-worker placement before stopping the CPU worker, and scheduler now prefers CPU-only nodes for CPU-only pods
  - targeted pivot artifacts: `artifacts/poc-final/05-failure-drills/target-b-20260428123213/`
  - latest warm-cache benchmark summary is `artifacts/poc-final/06-benchmarks/results-summary.md`
  - Hivemind latency artifact: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmlatdetail-20260502204533/latency-breakdown.md`
  - EKS latency artifact: `artifacts/poc-final/06-benchmarks/eks-scale-matrix-ekslatdetail-20260502203515/latency-breakdown.md`
  - latest warm-cache 50x1 all ready: Hivemind `13174ms`, EKS `238171ms`; EKS run had `49` `FailedCreatePodSandBox` events on the GPU node
  - API consensus submit path and worker lifecycle path now have bounded parallelism; scheduler batch bind now submits one bounded batch consensus command for up to 64 pod binds; follower stale-suffix commit regressions found by 10k mutated VOPR sweep are fixed; live rerun `hmbatch-20260503003421` improved `single 0 -> 50` scheduled observation to `334ms` from `778ms`, while overall ready time remained runtime-tail dominated; worker now recreates locally after transient container start failure, preserves retry count across recreate attempts, and emits fuller `ctr` diagnostics; state machine now reuses inactive deployment/pod slots so repeated benchmark runs do not exhaust fixed arrays; latest full Hivemind rerun `hmctrfix-20260503015744` completed with no containerd start failures observed in CPU worker logs; `single 0 -> 50 ready` improved to 7917ms, while `50x1 all ready` remains high at 23559ms
  - next benchmark work: clean EKS warm-cache rerun after sandbox failures; cold-cache rerun after Hivemind private ECR auth contract fix
  - remaining infra blocker: EKS control plane `hivemind-poc-eks-baseline` still requires elevated IAM permissions or an IAM exception for `eks:DeleteCluster`

## POC Acceptance Shift (2026-04-22)

The working hypothesis is now explicitly **federated**, not “one globally synchronous cluster”:

- each Hivemind cluster remains region-local for low-latency control-plane decisions
- clusters exchange soft global state via gossip
- Thalamus remains the stateless inter-origin selector for the POC branch
- users should be able to target broader localities such as `europe`, `us-east`, and `us-central`
- strict residency policies (for example Europe-only) must be enforceable at the selector layer

This replaces the older idea that the remaining proof was only a fresh AWS smoke. That plumbing gate is done.

## POC Milestone (2026-04-17)

First real AWS deployment ran on 2026-04-17 in `us-east-1`:

- 5× `c5.xlarge` replicas on Amazon Linux 2023 (`ami-098e39bafa7e7303d`).
- 1× `c5.xlarge` + 1× `g4dn.xlarge` workers on **`hivemind-standalone`** AMI (`ami-0714f823ff4e72d73`) — forked from `ubuntu-eks-nydus` on branch `elijah-rou/hivemind-standalone`. EKS-only provisioners stripped; `scripts/bootstrap.sh` gates kubelet/sandbox startup behind `CLUSTER_NAME` so it runs standalone.
- VRR consensus elected leader, API gateway reported `{"connected":true,"leader":"…:9001"}`, workers registered + heartbeated (~50 ms) over encrypted frames, dashboard reachable from deployer IP.
- Deployments committed via consensus on real AWS infra.

Known-bad during that run:
1. **Scheduler dispatch** — pending pods never got bound to ready workers; `/run` timed out leader-side.
2. **Peer connection leak/churn** — `hivemind_connections{type="peers"}` grew past `N-1` and peers reconnected every 2 s.
3. Cosmetic: `hivemind-worker.service` passed `${VAR:-default}` literally — systemd does not expand shell defaults.

Security note: GuardDuty flagged port 8080 open to the world on the first apply. `main.tf` now scopes 8080 to `var.ssh_cidr`; only intra-SG traffic on 8080–9300 stays open via self-referenced rules.

POC infra was destroyed post-validation; the standalone worker AMI branch remains local and the AMI/keypair still exist.

## System Overview

Hivemind is a custom serverless AI/ML orchestrator replacing Kubernetes/Knative. Three languages, zero external runtime dependencies:

- **Zig 0.16.0** (`core/src/`) — VRR consensus, scheduling, networking, gossip, persistence (`core/build.zig.zon` pins `minimum_zig_version`)
- **Rust** (worker/src/) - Node worker, containerd runtime, pod lifecycle, secrets, volumes
- **Go** (api/, bench/) - HTTP API gateway, benchmarking tools

## Architecture

```
                    REST clients
                        │
                   ┌────▼────┐
                   │  Go API │  :8080
                   │ Gateway │  translates REST → binary protocol
                   └────┬────┘
                        │ TCP binary frames
         ┌──────────────▼──────────────┐
         │     Hivemind Replica (Zig)  │
         │                             │
         │  Client Listener  :9001     │  ← deployment CRUD (consensus)
         │  Agent Listener   :9000     │  ← agent registration, pod status
         │  Peer Listener    :9102+    │  ← VRR replication between replicas
         │  Metrics          :9200     │  ← Prometheus scraping
         │  Gossip (UDP)     :9300     │  ← cross-region capacity broadcast
         │                             │
         │  ┌─────────────────────┐   │
         │  │ VRR Consensus       │   │  5-node, regionally scoped
         │  │ State Machine       │   │  nodes, deployments, pods
         │  │ Scheduler           │   │  bin-packing on GPU/CPU/mem
         │  │ Request Queue       │   │  run requests (no consensus)
         │  │ Disk Journal        │   │  experimental layout v2 single-copy; not torn-write safe
         │  │ S3 Backup           │   │  forked aws s3 cp (not atomic restore)
         │  │ Gossip              │   │  UDP, 5s broadcast, 30s stale
         │  └─────────────────────┘   │
         └──────────────┬──────────────┘
                        │ TCP binary frames (versioned)
              ┌─────────▼─────────┐
              │   Agent (Rust)    │  per-node binary
              │                   │
              │  Containerd (ctr) │  pull, create, start, stop
              │  GPU allocation   │  CDI devices via `nvidia.com/gpu=*`
              │  Secret resolver  │  Doppler API, 5min cache
              │  JuiceFS mounts   │  juicefs mount subprocess
              │  Nydus snapshotter│  lazy image loading
              │  Metrics :8081    │  pods_running, gpu_free, etc.
              └───────────────────┘
```

## Wire Protocol

```
Client/Agent frames (plaintext): [4B LE len][1B flags=0x00][2B LE version][1B tag][payload...]
Client/Agent frames (encrypted): [4B LE len][1B flags=0x01][24B nonce][ciphertext][16B tag]
Peer frames (plaintext):         [4B LE len][1B flags=0x00][1B from_id][VRR payload]
Peer frames (encrypted):         [4B LE len][1B flags=0x01][24B nonce][ciphertext(from_id+VRR)][16B tag]
PROTOCOL_VERSION = 3 (2 bytes = 65535 possible versions; earlier mixed peers/workers fail closed)
```

**Client command tags:** RegisterNode(0), CreateDeployment(3), ScaleDeployment(6), UpdateDeployment(10), SetTrafficSplit(11), RollbackDeployment(12), DeleteDeployment(13), PauseDeployment(14), ResumeDeployment(15), ClientRequest(0x20), RunRequest(0x22)

**Agent tags:** register, heartbeat, pod_status, run_request, run_response

## VRR Consensus

- 5-node clusters, regionally scoped
- LOG_SIZE_MAX=1024 retained slots (fail-closed, no committed overwrite), CLIENT_TABLE_MAX=1024 so dedup spans the full retained journal
- HEARTBEAT_INTERVAL=500ms, VIEW_CHANGE_TIMEOUT=2000ms
- States: `.normal`, `.view_change`, `.recovering`
- Full view change protocol: StartViewChange → DoViewChange → StartView
- A DVC quorum selects one classic-VRR source by `(last_normal_view, op_number)`; equal-rank sources must agree on tip and overlap identities. Incomplete fixed tails remain in view change while RequestPrepare/SendPrepare fetches a source/view/tip-bound suffix from that source only.
- Log repair via RequestPrepare/SendPrepare; protocol-v3 repair messages carry optional selected-source/view/tip binding for pre-StartView suffix materialization
- Field-by-field outer serialization; nested Command/Result use a fixed tag-first wire codec (validate tags before union materialization)
- Disk persistence (experimental): optional `--data-dir` → layout-v2 `journal.bin` (`0600`) under data dir (`0700`) with explicit little-endian LogEntry codec (tag-first Command), staged writes + `fdatasync` group-commit barrier; protocol-v3 PrepareOk binds each vote to the exact durable `(view, op, entry_checksum)` identity, and client/worker publication waits for the covering barrier. Actual legacy v1 journals are rejected fail-closed as incompatible (the startup error may be a size or version rejection). For this POC change, mixed-version peer clusters and legacy-v1 journal upgrades are unsupported: stop the full cluster, then start v2 with fresh data directories or data explicitly archived/replaced out of band. There is no rolling migration or incarnation protocol claim. Absent `--data-dir` is explicit volatile POC mode. No torn-write / power-loss guarantee or simulation; no production crash-durability claim.
- Restart recovery (experimental best-effort): validate committed-prefix checksum chain; VOPR enforces canonical recovered-prefix and immutable committed-prefix contracts; corrupt/missing/truncated/wrong-sized journal fail-stop (nonzero exit); otherwise enter view_change to rejoin. Not validated under torn writes or power loss.
- Retained log: fail-closed at `LOG_SIZE_MAX` (1024) ops with `log_full` / HTTP 507 until snapshots exist; no circular overwrite of committed entries
- S3 journal backup: periodic `aws s3 cp` of mutable v2 `journal.bin` — not an atomic crash-consistent restore artifact

## State Machine Operations

| Command | Effect |
|---------|--------|
| RegisterNode | Add node to active inventory, transition to `.ready` |
| CreateDeployment | Create deployment record, trigger scheduler |
| ScaleDeployment | Update desired replicas, scheduler creates/removes pods |
| SetTrafficSplit | Update version weights for blue-green/canary |
| RollbackDeployment | Revert to previous version |
| DeleteDeployment | Mark deleted, scheduler stops all pods |
| PauseDeployment | Freeze scaling, keep pods |
| ResumeDeployment | Unfreeze |
| BindPodToNode | Scheduler assigns pod → node, dispatches to agent |
| UpdatePodStatus | Agent reports pod state change |

## Cross-Region Gossip

UDP datagrams, fixed-size advisory snapshot:
```
[4B magic "HVGP"]
[32B origin_id][32B provider][32B region][32B locality][32B continent]
[9 GPU types × (2B available + 2B total)]
[4B cpu_available_millicores][4B cpu_total_millicores]
[4B queue_depth][4B active_deployments][4B running_pods][4B node_count]
[8B timestamp]
```
- Broadcast every 5s from leader only
- Stale after 30s, max 16 peer origins
- Peer cache is keyed by `origin_id`, not just region
- Metrics expose peer advisory fields for local Thalamus selector work

## Agent Pod Lifecycle

```
ImagePulling → Creating → Starting → Running → Stopping → Stopped
                                                    ↓
                                                  Failed
```

- containerd via `ctr` CLI (no gRPC, avoids tokio deadlock)
- GPU pods: `--runtime io.containerd.runc.v2` + CDI `--device nvidia.com/gpu=<idx>`
- CPU pods: `--runtime io.containerd.runc.v2`
- 30s timeout on ctr calls, 300s for image pulls
- cgroup v2 resource limits (CPU quota, memory)
- Liveness probes every 10s, 3 failures → restart

## HTTP API Endpoints

| Endpoint | Method | Consensus | Notes |
|----------|--------|-----------|-------|
| `/v1/health` | GET | No | Returns `{connected, leader}` |
| `/v1/deployments` | POST | Yes | name, image, replicas, cpu, mem, gpu_type, gpu_count |
| `/v1/deployments/{id}/scale` | PUT | Yes | replicas |
| `/v1/deployments/{id}/pause` | PUT | Yes | |
| `/v1/deployments/{id}/resume` | PUT | Yes | |
| `/v1/deployments/{id}/rollback` | PUT | Yes | |
| `/v1/deployments/{id}/delete` | DELETE | Yes | |
| `/v1/deployments/{name}/run` | POST | No | Binary payload → pod → response |

## Benchmark Results

Current POC Hivemind-vs-EKS performance verdict is provisional. Latest warm-cache artifacts are under `artifacts/poc-final/06-benchmarks/`:

| Scenario | Metric | Hivemind | EKS | Notes |
|---|---|---:|---:|---|
| one deployment 0 -> 50 -> 1 | 0 -> 50 ready | 8564ms | 133463ms | EKS affected by GPU-node sandbox failures |
| one deployment 0 -> 50 -> 1 | 50 -> 1 ready | 349ms | 28508ms | EKS readiness convergence delayed |
| 50 deployments x 1 replica | submit total | 6000ms | 57727ms | 50 sequential submits |
| 50 deployments x 1 replica | all ready | 13174ms | 238171ms | both reached 50/50; EKS degraded by sandbox failures |

Granular attribution: Hivemind tail is worker/containerd lifecycle queueing; EKS tail is dominated by `FailedCreatePodSandBox` events on the GPU node despite warm image cache. Do not use this as a broad clean-EKS speedup claim until the EKS sandbox issue is resolved and rerun.

Legacy deploy-mode benchmark, retained for historical context only:

| Metric | Hivemind | K8s (EKS) | Ratio |
|--------|----------|-----------|-------|
| p50 | 2.2ms | 72.7ms | 33x |
| p99 | 5.1ms | 143.2ms | 28x |
| p999 | 8.3ms | 287.1ms | 35x |

*Deploy-mode (consensus path). 1000 deployments, 100 concurrent. Not the current POC verdict.*

## Dedup resource bound

The fixed client dedup table now has 1,024 entries, matching the complete retained operation window. `ClientEntry` is 64 bytes in the pinned Zig ABI, so the table is 65,536 bytes per replica. This is a 61,440-byte increase from the former 64-entry table (4,096 bytes). Compile-time assertions require `CLIENT_TABLE_MAX >= LOG_SIZE_MAX` and cap the table at 128 KiB.

## Test Coverage

**Current local verification (branch evidence; no new live durability run):**
- 262 Zig unit tests passing in Debug and ReleaseFast (`zig test src/unit_tests.zig -lc`); `zig build test` passes
- Go API tests and race tests pass; API and bench builds pass
- local smoke: `16 passed, 0 failed` (`tests/local-smoke.sh`)
- local failover smoke: PASS (`tests/local-failover-smoke.sh`)
- `tests/run-all.sh`: 15/17 phases pass; containerd-in-Docker is blocked by nested overlay mount `EINVAL`, unrelated to this diff; its SSM fixture was subsequently updated and passes standalone
- storage-mode smoke: volatile + experimental-journal startup contract (`tests/storage_mode_smoke_test.sh`)
- launcher contract: stale smoke wrappers + bench/infra paths (`tests/launcher_contract_test.sh`)
- Acceptance counts unchanged: `6 / 8` POC v1 sections; execution checklist `16 / 16` warm-cache pack; live infra status remains `up` from prior entries (no new live evidence in this docs pass)

**VOPR simulation coverage:**
- VRR consensus under faults (partitions, crashes, restarts)
- Write/sync-before-publication storage barriers, group commit, and fail-stop on whole disk I/O errors (torn writes / power loss not modeled)
- Fail-closed retained-log saturation (`log_full`) without committed-slot overwrite
- Canonical recovered-prefix validation (`observeRecovery`) and immutable committed-prefix enforcement (StartView / DVC conflict rejection)
- Checker compares full entry checksums; commit regression and history capacity are violations
- Cross-region gossip propagation
- Gossip under network partitions
- Deterministic federated locality selector proof inputs (`same-locality-best`, `same-locality-failover`, `cross-locality-fallback`, `residency-restricted`)

## Codebase Size

| Component | Language | LOC | Files |
|-----------|----------|-----|-------|
| core/src/ | Zig | ~13,658 | 27 |
| worker/src/ | Rust | ~5,919 | 26 |
| api/ | Go | ~2,978 | 13 |
| bench/ | Go | ~808 | 6 |
| infra/ | Terraform/scripts | ~1,931 | 20 |
| tests/ | Shell/Docker | ~629 | 8 |
| **Active source/tooling** | | **~25,923** | |

## What's Working

- [x] VRR 5-node consensus with view change, log repair, leader election
- [x] Experimental layout v2 journal: fixed little-endian fields, write/sync-before-publication, I/O fail-stop, fail-closed 1024-op retention, best-effort restart recovery (not torn-write / power-loss safe)
- [x] Agent registration, heartbeat, pod dispatch
- [x] Full pod lifecycle: pull → create → start → monitor → stop with bounded worker-side lifecycle concurrency
- [x] Run requests (stateless, no consensus overhead)
- [x] Abandoned run request cleanup on client disconnect/timeout
- [x] Scale-to-zero with queue-triggered wake
- [x] Cross-region gossip (UDP, leader-only broadcast)
- [x] S3 journal backup (forked, non-blocking, 60s interval; not an atomic restore artifact)
- [x] HTTP REST API (Go gateway)
- [x] Secret resolution (Doppler, 5min cache)
- [x] JuiceFS volume mounts
- [x] Nydus snapshotter support
- [x] GPU pod support (CDI devices with `io.containerd.runc.v2`)
- [x] Prometheus metrics (replica + agent)
- [x] Protocol versioning (2-byte version field)
- [x] Peer connection retry (2s interval)
- [x] VOPR simulation testing

## What's Missing (Production Gaps)

### Critical (blocks production use)

1. **TLS/mTLS** - All traffic plaintext. Need TLS for client/agent/peer/gossip.
2. **Authentication** - No auth on API or agent connections. Need API keys + agent tokens.
3. **Provider adapter** - No auto-provisioning of nodes. Manual VM setup required.
4. **App spec model** - Current CreateDeployment is basic. Need full app spec (probes, scaling policy, env config, storage).
5. **Crash-consistent versioned storage + torn-write simulation** - layout v2 single-copy journal has no torn-write/power-loss model; required before any production durability claim (separate from snapshots).
6. **Log compaction / snapshots** - Fail-closed retained log of `LOG_SIZE_MAX` (1024) ops; need snapshots before removing the cap.

### Important (blocks Knative parity)

7. **Thalamus integration** - POC branch now has locality/residency resolver tests and localhost smoke evidence against Hivemind federation JSON; production integration remains future work.
8. **Axon integration** - CLI/SDK needs to target Hivemind API instead of Knative.
9. **Image pull secrets** - No registry auth for private images.
10. **Readiness probes** - Liveness works, readiness not wired to traffic routing.
11. **Graceful agent shutdown** - SIGTERM handler, pod draining.
12. **Blue-green/canary traffic** - TrafficSplit command exists but not wired to request routing.

### Nice-to-have (polish)

13. **Rate limiting** - No request rate limits.
14. **Advanced scheduling** - Basic bin-packing; no affinity, spread, cost optimization.
15. **Observability** - Metrics exist but no tracing, no structured logging.
16. **Multi-cluster state transfer** - No mechanism to migrate state between clusters.

## Recommended Roadmap (Next Sessions)

### Phase A: Production Hardening
Priority: make one region production-ready for internal testing.

1. **Full app spec model** - Replace CreateDeployment with rich app spec in state machine. Probes, scaling config, env refs, storage.
2. **TLS everywhere** - mTLS for peer/agent, TLS for client/API. Cert rotation.
3. **API auth** - Bearer tokens or API keys. Agent auth via pre-shared key.
4. **Graceful shutdown** - Agent pod draining, replica graceful leave.
5. **Log compaction / state snapshots** - Periodic state machine snapshot to avoid unbounded log replay.

### Phase B: Integration
Connect Hivemind to existing regional infrastructure.

6. **Thalamus integration** - Router queries Hivemind gossip for capacity-aware routing.
7. **Axon integration** - CLI deploys to Hivemind API.
8. **Image pull secrets** - Support `secret:registry/token` refs for private registries.
9. **Blue-green/canary** - Wire TrafficSplit to run request routing.

### Phase C: Provider Automation
Auto-provision compute from cloud providers.

10. **Provider interface** - `ListCapacity`, `CreateNode`, `DeleteNode`, `GetPricing`.
11. **AWS EC2 adapter** - First provider. cloud-init installs agent.
12. **Crusoe adapter** - Second provider.
13. **Cost-aware scheduling** - Factor provider pricing into scheduler scoring.

### Phase D: Scale & Polish
14. **5-node production deployment** - Full regional cluster with monitoring.
15. **Chaos testing** - VOPR-informed failure scenarios on real infrastructure.
16. **Observability stack** - OpenTelemetry traces, structured logging.
17. **Multi-region production** - Two regions with gossip, overflow routing.

## Repository Hygiene

Active source of truth:
- `core/` + `worker/` + `api/` for implementation
- `docs/STATUS.md` for current state
- `docs/POC_ACCEPTANCE.md` for POC pass/fail
- `docs/POC_CHANGELOG.md` for dated POC history
- `docs/FINDINGS_AND_ISSUES.md` for production gaps/backlog

Recently trimmed/frozen:
- repo-root `v1/` is the frozen POC V1 snapshot; `v2/` is the active development line
- within `v2/`, Zig control plane lives in `core/` (historical in-tree rename from a nested `v2/` name)
- removed zero-byte `hivemind/` skeleton from the active line
- removed prototype `honeybee/` from the active line
- moved aspirational/superseded docs to `docs/frozen/`
- moved legacy Thalamus/edge-routing docs to `docs/legacy/`

## Key Files Reference

| File | Purpose |
|------|---------|
| `core/src/main.zig` | Entry point, CLI flags, main loop |
| `core/src/replica.zig` | VRR state machine, all consensus handlers |
| `core/src/connection.zig` | Protocol parsing, TCP listeners, frame I/O |
| `core/src/state_machine.zig` | Node/deployment/pod state, scheduler integration |
| `core/src/scheduler.zig` | Bin-packing pod placement |
| `core/src/message.zig` | VRR message types, field-by-field serialization |
| `core/src/gossip.zig` | Cross-region UDP gossip |
| `core/src/s3_backup.zig` | Forked S3 journal upload |
| `core/src/disk.zig` | Experimental layout v2 single-copy journal (not torn-write safe) |
| `core/src/metrics.zig` | Prometheus metrics export |
| `core/src/request_queue.zig` | Leader-local run request queue |
| `core/src/vopr/vopr.zig` | VOPR simulation scenarios |
| `core/src/vopr/simulated_io.zig` | Simulated clock (1 tick = 10ms) |
| `worker/src/worker.rs` | Pod orchestration, GPU alloc, secret/volume integration |
| `worker/src/runtime/containerd.rs` | ctr CLI wrapper for containerd |
| `worker/src/secrets.rs` | Doppler secret resolution |
| `worker/src/volumes.rs` | JuiceFS mount/unmount |
| `worker/src/metrics.rs` | Worker Prometheus endpoint |
| `worker/src/protocol.rs` | Binary protocol parsing (worker side) |
| `api/handlers.go` | REST → binary protocol translation, including deployment update route for POC operator workflow |
| `scripts/poc-runbook.sh` | End-to-end POC execution script for ECR image build/push, Hivemind deploy/smoke/workloads/operator/failure drills, optional isolated EKS baseline |
| `infra/poc/failure-drills.sh` | Section 5 live failure-drill runner |
| `infra/poc-eks/` | Isolated temporary EKS baseline Terraform and workload test; does not touch existing infra |
| `api/client.go` | TCP connection to Hivemind replica |
| `bench/main.go` | Deployment + workload benchmarking |
| `bench/k8s_bench.go` | K8s scheduling benchmark |
| `infra/bench/main.tf` | 5x c5.xlarge EC2 for benchmarking |
| `infra/gpu-test/main.tf` | g4dn.xlarge for GPU/containerd testing |

## Bugs Fixed (for context)

| Bug | Root Cause | Fix |
|-----|-----------|-----|
| Stack overflow on 5-node | ConnectionManager 3.2MB on stack | Heap alloc via initInPlace |
| View change divergence | 50ms timeout → hundreds of view changes/sec | 2000ms timeout, VOPR clock 10ms/tick |
| Struct padding UB | `std.mem.asBytes` serializes undefined padding | Field-by-field serializePayload with zeroed buffer |
| Peer connection race | EC2 SSM jitter, some nodes start before peers listen | PeerTarget retry every 2s |
| containerd gRPC deadlock | tokio block_on hangs on first tonic call | Replace gRPC with ctr CLI subprocess |
| Client table dedup | bench/API used fixed clientID, second run dropped | Timestamp-based clientIDs |
| Cross-compile fstat | std.c.fstat void on Linux x86_64 | Platform-conditional lseek |

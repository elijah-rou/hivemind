# Hivemind Final POC Acceptance

_Last updated: 2026-05-05_


> **POC v1 historical gate.** This document records the original federated POC pass/fail checklist and evidence state. It is not the current team-presentation/replacement gate. Use `docs/POC_V2_ACCEPTANCE.md` for the next acceptance bar: current-system parity plus Hivemind-native revisions/routability/rollout evidence.

## Hypothesis

Hivemind is a viable **federated alternative to Kubernetes/Knative for serverless AI/ML inference workloads** if it can:

1. Run real CPU and GPU inference services on fixed nodes
2. Provide deploy -> ready -> run -> scale -> rollback operator workflows
3. Survive expected replica/worker failures without losing basic serviceability
4. Show materially lower control-plane/runtime overhead and comparable or better cold-path behavior than equivalent EKS setup under cache-normalized benchmark conditions
5. Be redeployed and revalidated from zero without manual heroics
6. Let users target broad **localities** such as `us-east` or `europe` instead of a specific datacenter/provider cluster
7. Allow independent regional/provider Hivemind clusters to exchange **soft global state** via gossip so routing can prefer local capacity and fail over to other clusters when needed

### Scope clarification

This POC does **not** try to prove one globally synchronous consensus cluster stretched across distant regions.

That would be the wrong architecture for the latency target.

This POC instead proves a **federated model**:

- each Hivemind cluster remains region-local for fast control-plane decisions
- clusters gossip summarized capacity/state to peer clusters
- a router / selector can choose the best cluster inside a locality, then fall back to another locality if capacity or health requires it
- the shared cross-cluster state is intentionally **soft** and advisory, not strongly consistent

## Non-Goals

This POC does **not** need to prove:

- full Kubernetes feature parity
- production-ready security posture
- one global cross-region consensus cluster
- global strong consistency across all clusters
- provider automation / autoscaling across clouds
- multi-tenant isolation hardening

Those matter later. They do not block the POC hypothesis.

## POC Pass/Fail Gate

The POC is complete only if **all** sections below pass.

---

## 1. Fresh AWS Redeploy

Goal: prove Hivemind can be brought up from zero on live infra.

### Pass criteria

- [x] Custom worker AMI used, not generic DLAMI
- [x] Local ed25519 SSH key used for access
- [x] Fresh Terraform apply succeeds
- [x] 5-replica cluster elects leader
- [x] API health returns connected leader
- [x] CPU worker registers
- [x] GPU worker registers
- [x] Corrected live smoke passes on fresh infra

### Required evidence

- Terraform output with replica + worker IPs
- `/v1/health` response
- dashboard cluster/nodes/workers pages
- full `infra/poc/smoke-test.sh` output

### Current status

- [x] Fresh redeploy completed on 2026-04-22
- [x] Smoke passed: `22 passed, 0 failed`

---

## 2. Locality Federation Proof

Goal: prove users can target broader localities while independent Hivemind clusters share enough state to make sane routing/failover decisions.

### POC request path

For this POC, the request path remains:

```text
client -> Thalamus -> selected Hivemind cluster
```

Thalamus remains the stateless inter-origin selector in the POC branch.

Hivemind remains the per-origin control plane and runtime.

### Longer-term direction

Longer term, Thalamus may collapse into Hivemind itself, with the Hivemind API acting as the single proxy / selector layer.

That is **not** required for this POC. For now, use a patched Thalamus branch so the request path stays comparable to the real production pipeline.

### Model

For this POC, a **locality** is broader than one datacenter or one provider-specific region.

Use these three user-facing locality buckets:

- `europe`
- `us-east`
- `us-central`

Each origin remains its own Hivemind cluster. Clusters exchange summarized state via gossip.

### POC origin -> locality map

| origin_id | provider | region | locality | status | notes |
|---|---|---|---|---|---|
| `nebius-europe` | `nebius` | `unknown` | `europe` | planned/active | exact provider region to confirm |
| `aws-eu-west-2` | `aws` | `eu-west-2` | `europe` | planned/active | London |
| `aws-eu-north-1` | `aws` | `eu-north-1` | `europe` | planned/active | Stockholm |
| `aws-us-east-1` | `aws` | `us-east-1` | `us-east` | active | |
| `aws-us-east-2` | `aws` | `us-east-2` | `us-east` | planned/active | |
| `crusoe-us-east-1` | `crusoe` | `us-east-1` | `us-east` | planned/active | |
| `crusoe-texas` | `crusoe` | `texas` | `us-central` | planned/active | current south-central / texas bucket |

### Residency and fallback policy

Locality preference alone is not enough. The POC must also prove **residency policy**.

#### Strict residency example

Some workloads may be legally or contractually constrained to Europe.

Example policy:

```json
{
  "preferred_locality": "europe",
  "allowed_localities": ["europe"],
  "residency_mode": "strict",
  "fallback_order": ["europe"]
}
```

Effect:
- route only to `europe`
- never fail over to `us-east` or `us-central`
- if no viable European origin exists, fail closed

#### Prefer-locality with spillover example

Some US workloads should prefer `us-east`, then `us-central`, and only under extreme circumstances spill to Europe.

Example policy:

```json
{
  "preferred_locality": "us-east",
  "allowed_localities": ["us-east", "us-central", "europe"],
  "residency_mode": "prefer",
  "fallback_order": ["us-east", "us-central", "europe"]
}
```

Effect:
- route to `us-east` first
- same-country / same-continent fallback before Europe
- Europe allowed only when earlier localities have no healthy capacity

### What gossip must prove

Gossip is the mechanism for **soft global state** across federated clusters. It must demonstrate that clusters can advertise enough information for locality-aware routing:

- stable origin identity
- provider / region metadata
- freshness of advertised state
- available GPU capacity by type
- available CPU capacity summary
- queue depth / load signal
- active deployments / running pod counts
- stale-peer detection

Success here does **not** require perfect global scheduling. It requires proving that federated Hivemind clusters can exchange enough advisory state to support locality-aware placement and failover.

### Required Thalamus POC-branch changes

Current Thalamus already has resolver machinery, health checks, and cluster selection. The POC branch should extend metadata and policy, not rewrite the router.

#### Existing Thalamus types today

```go
type AppCapacity struct {
    AppID             string
    ClusterID         string
    Hardware          HardwareType
    AvailableCapacity int
    UpdatedAt         time.Time
}

type ClusterCapacity struct {
    ClusterID        string
    Hardware         HardwareType
    Cost             int
    RunningCapacity  int
    ProviderCapacity int
    UpdatedAt        time.Time
}

type ClusterMetadata struct {
    ClusterID string
    Domain    *url.URL
}
```

#### Thalamus schema changes required for POC

`ClusterMetadata` must be extended so the resolver can reason about localities and legal routing boundaries:

```go
type ClusterMetadata struct {
    ClusterID string
    Domain    *url.URL

    Provider  string
    Region    string
    Locality  string
    Continent string
    Active    bool
}
```

`ClusterCapacity` should be extended to carry the soft-state signals needed for locality-aware ranking:

```go
type ClusterCapacity struct {
    ClusterID        string
    Hardware         HardwareType
    Cost             int
    RunningCapacity  int
    ProviderCapacity int
    QueueDepth       int
    HealthScore      float64
    UpdatedAt        time.Time
}
```

`AppCapacity` can stay as-is for the POC.

A new app routing policy object/store is required:

```go
type AppRoutingPolicy struct {
    AppID             string
    PreferredLocality string
    AllowedLocalities []string
    ResidencyMode     string   // strict | prefer | global
    FallbackOrder     []string
}
```

#### Thalamus resolver behavior changes required

The POC branch resolver must:

1. fetch app routing policy before final selection
2. filter candidates by `Active`, health, freshness, hardware capability
3. enforce residency policy
4. try candidates in `FallbackOrder`
5. score candidates only within the active fallback tier
6. emit routing reasons specific to locality behavior

New routing reasons should include at least:

- `same-locality-best`
- `same-locality-failover`
- `cross-locality-fallback`
- `residency-restricted`
- `no-locality-candidates`

### Required Hivemind changes

Hivemind already carries some useful node metadata today:

- worker/node registration includes `provider`
- worker/node registration includes `region`
- cross-cluster gossip already exports peer-capacity state

But that is not quite enough for federated origin selection.

#### Hivemind metadata changes required

Each Hivemind cluster needs stable origin-level identity/config, not just node-level metadata.

Add cluster-level config fields such as:

- `origin_id`
- `provider`
- `region`
- `locality`
- `continent`

These can be flags/env/config first; they do not need a complex control-plane schema.

#### Hivemind gossip changes required

Current gossip is region-oriented. For this POC it must become safe for **origin-level** federation.

Gossip/metrics must identify peers by at least:

- `origin_id`
- `provider`
- `region`
- `locality`

And should export enough advisory capacity to support Thalamus selection:

- queue depth
- deployments
- running pods
- GPU totals / free by type
- CPU free / total summary
- last-seen freshness

If the wire snapshot is extended, add origin identity + locality metadata there.
If the wire snapshot is kept small, expose the additional fields via metrics/API derived from local config plus peer state.

#### Hivemind API changes required

None strictly required for the first POC slice.

For now, Thalamus can remain the outer selector and Hivemind can remain the selected origin's API/runtime.

Longer term, Hivemind may absorb this routing/proxy role and make Thalamus unnecessary as a separate service.

### Current local progress

Section 2 local proof is now complete. Hivemind exposes real federation JSON locally and the Thalamus POC branch consumes equivalent locality/residency state through the actual resolver path in the localhost smoke tool.

Completed locally:
- deterministic federated origins across `us-east`, `us-central`, and `europe`
- origin-aware gossip visibility with provider / region / locality / continent labels
- peer freshness / staleness modeling
- peer advisory metrics including CPU/GPU summaries, queue depth, deployments, running pods, nodes, and last-seen age
- deterministic selector-model proofs for:
  - `same-locality-best`
  - `same-locality-failover`
  - `cross-locality-fallback`
  - `residency-restricted`
- Hivemind replica metrics listener now exposes `GET /v1/internal/federation` JSON for machine-friendly origin + peer advisory state
- Thalamus branch `feat/hivemind-poc-locality` now has real resolver tests for:
  - `same-locality-best`
  - `same-locality-failover`
  - `cross-locality-fallback`
  - `residency-restricted`

Completed local smoke evidence:
- four independent localhost Hivemind origins across `us-east`, `us-central`, and `europe`
- each origin saw 3 fresh peers through gossip-fed `/v1/internal/federation`
- stale peer proof killed `crusoe-texas` and observed `stale=true` from `aws-us-east-1`
- Thalamus branch smoke emitted routing traces for same-locality best, same-locality failover, cross-locality fallback to `us-central`, Europe fallback when allowed, and strict Europe residency rejection

### Pass criteria

- [x] at least 3 independent origins defined across at least 2 localities
- [x] at least one locality contains multiple origins from different provider/datacenter buckets
- [x] origin-to-locality mapping documented
- [x] cross-cluster gossip visible for peer origins
- [x] stale-peer detection demonstrated
- [x] strict-residency app never leaves `europe`
- [x] selector/router can choose an origin within the requested locality
- [x] selector/router can fail over to another origin in the same locality without app config change
- [x] selector/router can fall back from `us-east` to `us-central`
- [x] selector/router can fall back to `europe` only when policy allows it
- [x] routing decision logs include reason (`same-locality-best`, `same-locality-failover`, `cross-locality-fallback`, etc.)

### Required evidence

- origin inventory with provider / region / locality labels
- app routing policy examples for strict residency and prefer-locality spillover
- gossip metrics or dashboard slices showing peer capacity state
- freshness / staleness proof for at least one peer
- request traces showing locality-level routing decision
- failover trace where one origin becomes unavailable and another origin in the same locality is selected
- fallback trace where request leaves preferred locality because gossip indicates no viable local capacity
- strict residency trace showing non-European candidates rejected
- schema diff / notes for Hivemind and Thalamus POC branches

---

## 3. Real Workload Validation

Goal: prove real inference value, not just echo plumbing.

### CPU workload

Run one real CPU inference app.

Selected for the next live run:
- source: `workloads/poc/cpu`
- image: built/pushed by `infra/poc/build-workload-images.sh` or the orchestrated `scripts/poc-runbook.sh`
- behavior: deterministic hash-embedding classifier exposed on `POST /inference`
- evidence runner: `infra/poc/workload-test.sh`

### GPU workload

Run one real GPU inference app.

Selected for the next live run:
- source: `workloads/poc/gpu`
- image: built/pushed by `infra/poc/build-workload-images.sh` or the orchestrated `scripts/poc-runbook.sh`
- behavior: deterministic PyTorch CUDA MLP exposed on `POST /inference`, fails if CUDA is unavailable
- evidence runner: `infra/poc/workload-test.sh`

### Minimum workload requirements

- image starts under Hivemind worker runtime
- deployment reaches ready/running
- `/run` returns valid model output
- at least one request includes realistic payload size
- logs/metrics show the pod actually served the request

### Pass criteria

- [x] CPU inference deployment create -> ready -> run passes
- [x] GPU inference deployment create -> ready -> run passes
- [x] CPU inference output sanity-checked
- [x] GPU inference output sanity-checked
- [x] cold request latency captured
- [x] warm request latency captured

### Required evidence

- deployment create responses
- dashboard deployments + pods views
- sample `/run` request/response pairs
- worker logs for request handling
- latency summary table

### Live evidence

Focused Hivemind-only run `poc-20260426203208` passed Section 3 on fresh AWS infra:

- smoke: `22 passed, 0 failed`
- CPU deployment: `poc-cpu-1777251727`, id `11693034620340510321`
- GPU deployment: `poc-gpu-1777251727`, id `9024654201992055039`
- CPU cold/warm responses include `model: poc-cpu-hash-embedder-v1`
- GPU cold/warm responses include `model: poc-gpu-torch-mlp-v1`, `device: Tesla T4`, CUDA `12.4`, and `probabilities`
- latency summary: CPU cold `0.082571s`, CPU warm `0.119884s`, GPU cold `0.632835s`, GPU warm `0.068794s`
- artifacts: `artifacts/poc-final/04-workloads/`
- runbook log: `artifacts/poc-final/00-runbook/runbook-poc-20260426203208.log`
- infra status after run: destroyed by teardown trap

### Suggested candidate workloads

- CPU: selected `workloads/poc/cpu` deterministic hash-embedding classifier
- GPU: selected `workloads/poc/gpu` deterministic PyTorch CUDA MLP

---

## 4. Operator Workflow Proof

Goal: prove Hivemind supports the workflows operators actually need.

### Pass criteria

- [x] create CPU deployment
- [x] create GPU deployment
- [x] update one deployment image/version
- [x] rollback updated deployment
- [x] scale one deployment up
- [x] scale one deployment to zero
- [x] wake scaled-zero deployment via request path
- [x] delete one deployment cleanly

### Required evidence

- API requests/responses for each operation
- dashboard before/after screenshots or saved HTML
- pod state transitions
- queue metrics around wake-from-zero

Prepared runner:
- `infra/poc/operator-workflow.sh`

### Live evidence

Run `poc-20260427150339` passed Section 4:

- create CPU: `op-cpu-1777318705`
- create GPU: `op-gpu-1777318705`
- update + rollback returned `{"ok":true}`
- scale up passed at attempt 2
- scale to zero passed at attempt 1
- wake-from-zero run returned real CPU model output at attempt 3
- CPU and GPU deletes returned `{"ok":true}`
- artifacts: `artifacts/poc-final/05-operator/`
- log: `artifacts/poc-final/05-operator/operator-workflow-poc-20260427150339.txt`

---

## 5. Failure Drill Proof

Goal: prove this is resilient enough to replace the normal K8s control loop for the target use case.

### Required drills

#### A. Leader loss during traffic
- kill current leader replica
- verify new leader election
- verify API reconnects
- verify subsequent `/run` still succeeds

#### B. CPU worker loss during traffic
- stop CPU worker service or terminate instance
- verify affected deployment stops routing there
- verify recovery after worker restart or replacement

#### C. Client disconnect / timeout cleanup
- issue `/run`, force client timeout/disconnect
- verify no permanent `in-flight` leak
- verify next request still succeeds

### Pass criteria

- [x] leader-loss drill passes
- [x] worker-loss drill passes
- [x] abandoned-run cleanup drill passes

### Required evidence

- replica journal excerpts around election/view change
- worker logs around disconnect/reconnect
- queue metrics before/after timeout cleanup
- second smoke output

Prepared runner:
- `infra/poc/failure-drills.sh`

### Latest evidence

Repeatability run `poc-20260428195031` passed Section 5 on fresh AWS infra with EKS disabled:

- leader-loss drill elected a new leader and API reconnected on attempt 1
- post-failover `/run` succeeded on attempt 1
- CPU-only Drill B pod placement was asserted on the CPU worker before stopping it
- CPU worker stop made the deployment unavailable as expected
- CPU worker restart recovered `/run` on attempt 1
- client timeout/disconnect cleanup left the next `/run` healthy
- result: `Failure Drill Results: 9 passed, 0 failed`
- run log: `artifacts/poc-final/00-runbook/runbook-poc-20260428195031.log`
- infra was destroyed after capture

---

## 6. Repeatability / No-Heroics Gate

Goal: avoid a one-off success that only works with manual surgery.

### Pass criteria

- [x] same procedure works twice from clean infra
- [x] no ad hoc host edits required during final run
- [x] no manual pod/container surgery required during final run
- [x] no hidden dependency on stale cluster state

### Notes

This gate is critical. A valid POC can tolerate known limitations. It cannot depend on luck.

### Known issue to close or scope clearly

- [x] investigate dirty-cluster CPU worker protocol corruption (`recv failed: frame too large ...`)
- [x] investigate Section 6 CPU worker restart recovery failure from `poc-20260428091331`

Fixed in the Rust worker TCP receive path by preserving partial frame buffers across nonblocking reads. Repeatability has now passed on a clean final run.

Section 6 repeatability rerun `poc-20260428091331` passed smoke, real workloads, operator workflow, and leader failover, then failed worker restart recovery because containerd retained task/container state while the restarted worker had empty in-memory pod state. The worker runtime now adopts existing `RUNNING`/`CREATED` containerd tasks for the same pod ID, treats `tasks start ... already exists` as success when the task is visible/adoptable, and cleans/retries stale invisible task/shim state when `tasks list` is empty but start still reports `already exists`. Live repeatability rerun `poc-20260428195031` passed from fresh infra with EKS disabled and teardown enabled. It completed smoke, real CPU/GPU workload validation, operator workflow, placement-asserted failure drills, and final log capture without host edits or manual container cleanup. Drill B first asserted the CPU-only pod was on the CPU worker by comparing dashboard worker/pod node IDs, then stopped/restarted that worker and recovered `/run` on attempt 1.

Final Section 6 evidence:
- runbook log: `artifacts/poc-final/00-runbook/runbook-poc-20260428195031.log`
- placement evidence: `artifacts/poc-final/05-failure-drills/worker-placement-workers.html`, `artifacts/poc-final/05-failure-drills/worker-placement-pods.html`
- worker-loss evidence: `artifacts/poc-final/05-failure-drills/worker-loss.txt`
- result: `Failure Drill Results: 9 passed, 0 failed`
- infra status after run: destroyed

Targeted pivot evidence remains in `artifacts/poc-final/05-failure-drills/target-b-20260428123213/`. That capture proved the stale invisible task/container form that the final repeatability run validated against.

---

## 7. Kubernetes Baseline Comparison

Goal: prove the economic/operational hypothesis, not just functional correctness.

Use equivalent AWS region, instance types, and workload images where possible.

### Compare against EKS on:

- deploy latency
- time to ready
- cold request latency
- warm request latency
- wake-from-zero latency
- infra footprint / moving parts
- operator steps required

### Prepared baseline path

Temporary EKS baseline is defined under `infra/poc-eks/` and is intentionally isolated from existing infrastructure:

- dedicated Terraform state/directory
- dedicated VPC CIDR `10.99.0.0/16`
- dedicated cluster name `hivemind-poc-eks-baseline`
- CPU node group: `c5.xlarge`
- GPU node group: `g4dn.xlarge`
- workload runner: `infra/poc-eks/eks-workload-test.sh`

### Pass criteria

- [x] baseline EKS environment defined
- [x] same CPU workload exercised on EKS
- [x] same GPU workload exercised on EKS
- [x] warm-cache cache-normalized latency table produced with granular attribution
- [ ] clean EKS rerun after GPU-node sandbox failures resolved
- [ ] cold-cache latency table produced
- [x] qualitative ops-complexity comparison written

### Live evidence

Initial Section 7 baseline collection is complete, and a warm-cache/cache-normalized scale matrix has now been rerun with granular latency attribution. Hivemind used warm worker cache. EKS was warmed by a DaemonSet before measurement, and `Pulled` events reported the nginx image was already present on nodes.

The latest warm-cache result favors Hivemind on the measured matrix, but Section 7 economic acceptance remains provisional because EKS hit repeated GPU-node `FailedCreatePodSandBox` events. Treat this as valid evidence for that EKS baseline state, not a broad clean-EKS speedup claim.

Key comparison evidence:
- consolidated summary: `artifacts/poc-final/06-benchmarks/results-summary.md`
- comparison table: `artifacts/poc-final/06-benchmarks/hivemind-vs-eks.md`
- Hivemind warm-cache run: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmlatdetail-20260502204533/summary.md`
- Hivemind latency breakdown: `artifacts/poc-final/06-benchmarks/hivemind-scale-matrix-hmlatdetail-20260502204533/latency-breakdown.md`
- EKS warm-cache run: `artifacts/poc-final/06-benchmarks/eks-scale-matrix-ekslatdetail-20260502203515/summary.md`
- EKS latency breakdown: `artifacts/poc-final/06-benchmarks/eks-scale-matrix-ekslatdetail-20260502203515/latency-breakdown.md`
- EKS node/cache status: `artifacts/poc-final/06-benchmarks/eks-scale-matrix-ekslatdetail-20260502203515/node-cache-status.md`

Latest warm-cache result snapshot:
- one deployment `0 -> 50` ready: Hivemind `8564ms`, EKS `133463ms`
- one deployment `50 -> 1` ready: Hivemind `349ms`, EKS `28508ms`
- 50 sequential deployments x 1 submit total: Hivemind `6000ms`, EKS `57727ms`
- 50 sequential deployments x 1 all ready: Hivemind `13174ms`, EKS `238171ms`
- 50x1 per-create submit p50: Hivemind API `7ms`, EKS `kubectl apply` server ack `1081ms`
- 50x1 scheduled -> ready: Hivemind observed tail `6926ms`; EKS p50 `7000ms`, p95 `72000ms`, max `212000ms`

Attribution:
- Hivemind tail: worker/containerd lifecycle queueing and status convergence; image pull p50 `15ms`, container create p50 `95ms`, container start p50 `55ms`
- EKS tail: `49` `FailedCreatePodSandBox` events concentrated on GPU node `ip-10-99-0-54.ec2.internal`; image was warm

Remaining reruns:
- clean warm-cache EKS rerun after sandbox failures are resolved or avoided
- cold-cache mode after Hivemind private ECR auth contract is fixed

Cleanup/status:
- Hivemind POC infra left up for reuse after latest latency run
- EKS control plane and nodegroups left up for reuse after latest latency run
- EKS control-plane deletion still requires elevated IAM or an exception for explicit `eks:DeleteCluster` deny

### Decision rule

The POC supports the benchmark/economic hypothesis only after cache-normalized data shows Hivemind is clearly better on at least one of:

- control-plane latency
- cold-path latency
- operator simplicity
- infrastructure footprint

without failing basic correctness/resilience gates above.

---

## 8. Final Evidence Pack

Create one folder or write-up containing the exact proof set.

## Recommended structure

```text
artifacts/poc-final/
  00-summary.md
  01-infra/
    terraform-outputs.txt
    smoke-fresh-run-1.txt
    smoke-fresh-run-2.txt
  02-health/
    health.json
    dashboard-cluster.html
    dashboard-nodes.html
    dashboard-workers.html
  03-locality/
    origin-inventory.md
    locality-map.md
    app-routing-policies.json
    hivemind-schema-notes.md
    thalamus-schema-notes.md
    gossip-metrics.txt
    locality-selection.txt
    same-locality-failover.txt
    cross-locality-fallback.txt
    residency-restricted-routing.txt
  04-workloads/
    cpu-create.json
    cpu-run-request.json
    cpu-run-response.json
    gpu-create.json
    gpu-run-request.json
    gpu-run-response.json
    deployments.html
    pods.html
  05-failure-drills/
    leader-failover.txt
    worker-loss.txt
    run-timeout-cleanup.txt
  06-benchmarks/
    hivemind-vs-eks.md
    raw-results.csv
  07-conclusion/
    verdict.md
```

## Required final docs

### `00-summary.md`
Short narrative:
- hypothesis
- environment
- what passed
- what failed
- recommendation: continue / narrow / stop

### `07-conclusion/verdict.md`
Must answer directly:

1. Is Hivemind viable for the target inference use case?
2. What is it already better at than K8s?
3. What would still block internal production use?
4. What is the next highest-ROI engineering step?

---

## Execution Order

1. [x] Fresh AWS redeploy
2. [x] Correct smoke on fresh infra
3. [x] Define origin -> locality map
4. [x] Patch Hivemind origin metadata + gossip visibility
5. [x] Stand up or model federated origins with gossip visibility
6. [x] Patch Thalamus POC branch for locality + residency policy
7. [x] Prove locality-aware selection + failover
8. [x] Choose CPU real workload
9. [x] Choose GPU real workload
10. [x] Run real CPU/GPU workload validation
11. [x] Run operator workflow proof
12. [x] Run failure drills
13. [x] Repeat on second fresh redeploy
14. [x] Collect initial EKS baseline
15. [x] Run warm-cache cache-normalized Hivemind/EKS benchmark
16. [x] Refresh final evidence pack + verdict after warm-cache benchmark

---

## Current Position

As of 2026-05-02, Hivemind is `6 / 8` acceptance sections complete with Sections 7-8 carrying provisional benchmark/economic status, and `16 / 16` execution checklist items complete for the warm-cache evidence pack. It has cleared the basic live-infra plumbing gate, deterministic and localhost locality federation gates, focused fresh-AWS real workload gate, operator workflow proof, targeted cloud failure-drill proof, and repeatability/no-heroics gate. A warm-cache Hivemind/EKS benchmark was collected, but the economic claim remains provisional pending a clean EKS rerun after GPU-node sandbox failures are resolved:

- fresh AWS redeploy succeeded and infra was destroyed after validation
- corrected smoke succeeded on live infra
- CPU deploy/run path works on fresh AWS with real `workloads/poc/cpu` responses
- GPU deploy/run path works on fresh AWS with real `workloads/poc/gpu` responses on Tesla T4/CUDA
- GPU runtime proof works remotely on the validated fresh cluster
- broad mutated Hivemind-core fuzz is clean at `10000/10000`
- cross-cluster gossip exists in the control plane and exports peer-capacity state
- origin-aware gossip now carries `origin_id`, `provider`, `region`, `locality`, `continent`, CPU/GPU capacity summaries, queue depth, deployment count, running pod count, and freshness
- replica metrics now expose the peer advisory fields needed for local selector work, including peer queue depth
- deterministic local VOPR coverage now models federated origins and selector outcomes for `same-locality-best`, `same-locality-failover`, `cross-locality-fallback`, and `residency-restricted`
- localhost Thalamus/Hivemind smoke proved section 2 with four local origins, fresh peer gossip, stale-peer detection, locality failover, Europe-allowed fallback, and strict Europe residency rejection

Section 8 is refreshed but provisional. Final summary is `artifacts/poc-final/00-summary.md`; verdict is `artifacts/poc-final/07-conclusion/verdict.md`. Both now state that functional/resilience POC passed, latest warm-cache matrix favors Hivemind, and benchmark/economic verdict remains provisional because EKS was degraded by GPU-node sandbox failures.

Latest repeatability pass evidence is `artifacts/poc-final/00-runbook/runbook-poc-20260428195031.log`. Latest benchmark summary is `artifacts/poc-final/06-benchmarks/results-summary.md`. Latest Hivemind/EKS latency breakdowns are under `hivemind-scale-matrix-hmlatdetail-20260502204533/` and `eks-scale-matrix-ekslatdetail-20260502203515/`.

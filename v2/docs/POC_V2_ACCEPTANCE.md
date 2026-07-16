# Hivemind POC v2 Acceptance Spec

Status: draft acceptance bar for a team-facing Hivemind pitch.

This spec defines what must be true before presenting Hivemind as more than a fast benchmark result. The goal is to prove Hivemind can run a real inference workload shape with enough platform parity and Hivemind-native serving semantics to be credible against the current Kubernetes/Knative stack.

## Scope

POC v1 proved functional/resilience basics and a warm-cache nginx serving-control-plane speedup. POC v2 must prove production-relevant capability on a representative workload.

POC v2 is not a full Kubernetes replacement gate. It is a focused proof that Hivemind can support the primitives inference workloads need while preserving its latency/control-plane advantage.

## Non-goals

- Full Kubernetes API compatibility.
- General CRD/operator ecosystem compatibility.
- Generic DaemonSet replacement.
- Arbitrary sidecar/init-container parity unless required by the selected workload.
- Multi-cloud production launch.
- Cold-cache economic verdict before private image auth is fixed.

## Acceptance summary

POC v2 passes only when all mandatory sections below are green with deterministic coverage where simulatable and live evidence where required.

| Section | Area | Required |
|---:|---|---|
| 1 | Representative workload | Yes |
| 2 | AppSpec parity slice | Yes |
| 3 | Storage / JuiceFS | Yes |
| 4 | Secrets / image auth | Yes |
| 5 | Logs / observability | Yes |
| 6 | Security / isolation minimum | Yes |
| 7 | Revisions / routability / rollout safety | Yes |
| 8 | Event-driven state surface | Yes |
| 9 | Queue-aware serving path | Yes |
| 10 | Autoscaling / scale-from-zero | Yes |
| 11 | GitOps / Argo bridge | Yes for demo path, not full controller parity |
| 12 | Benchmark refresh | Yes |
| 13 | Evidence pack | Yes |

## 1. Representative workload

### Goal

Run one real realistic inference workload end to end, not nginx-only.

### Pass criteria

- [ ] Workload image is private or private-auth-equivalent.
- [ ] Workload uses env vars and at least one secret ref.
- [ ] Workload has a readiness endpoint distinct from process start.
- [ ] Workload writes logs that can be retrieved through Hivemind tooling.
- [ ] Workload reads or writes a JuiceFS-mounted path.
- [ ] Workload runs on CPU.
- [ ] Workload has a GPU variant or GPU dependency smoke if the target product path needs GPU.
- [ ] Workload can serve a request through the Hivemind request path.

### Evidence

- Live request/response artifacts.
- Worker journals and pod logs.
- Hivemind state/event dump for lifecycle/readiness/routability.
- Equivalent EKS/K8s manifest for comparison.

## 2. AppSpec parity slice

### Goal

Define and implement the smallest credible `AppSpec v1` needed for inference workloads.

### Required fields

- [ ] name
- [ ] image
- [ ] command/entrypoint or explicit decision to defer command override
- [ ] port
- [ ] replicas/min/max
- [ ] CPU/memory/GPU resources
- [ ] env vars
- [ ] secret refs
- [ ] image pull auth refs
- [ ] JuiceFS volume spec
- [ ] liveness probe
- [ ] readiness probe
- [ ] startup timeout
- [ ] termination grace period
- [ ] isolation profile reference

### Pass criteria

- [ ] Public API accepts `AppSpec v1`.
- [ ] Core state machine persists the required fields deterministically.
- [ ] Worker receives and applies the fields.
- [ ] API rejects unsupported fields loudly instead of silently ignoring them.
- [ ] Backward compatibility is documented for old create-deployment payloads.

### Evidence

- API tests.
- Core state-machine tests.
- Zig VOPR coverage for create/update/scale with AppSpec fields.
- Worker sim/unit coverage for spec application.

## 3. Storage / JuiceFS

### Goal

Prove Hivemind can mount required workload storage safely and predictably.

### Pass criteria

- [ ] Hivemind host image/AMI includes the `juicefs` CLI or documented equivalent.
- [ ] `AppSpec v1` exposes a required JuiceFS mount.
- [ ] Worker mount success is visible in events.
- [ ] Required mount failure fails the pod before routing.
- [ ] Worker unmounts on stop, failure, and shutdown drain.
- [ ] Repeated start/stop does not leak mountpoints.

### Evidence

- Deterministic worker test for mount failure -> not routable / failed.
- Live smoke reading/writing mounted path.
- Host mount table before/after cleanup.

## 4. Secrets / private image auth

### Goal

Close the cold-cache blocker and prove secrets do not leak through logs/events.

### Pass criteria

- [ ] Registry auth supports private ECR or selected private registry without 256-byte password truncation.
- [ ] Auth precedence documented: per-deployment secret ref > AMI/containerd hosts config > public pull.
- [ ] Env secret refs resolve through the selected secret provider.
- [ ] Secret values are redacted in API responses, events, logs, traces, and errors.
- [ ] Missing/invalid secret makes pod not routable and emits a clear event.

### Evidence

- Unit tests for redaction.
- Worker sim/unit tests for missing secret.
- Live private image cold-cache pull.
- Live env secret request proof without exposing the secret value.

## 5. Logs / observability

### Goal

Provide enough operator visibility to debug workload failures without SSH.

### Pass criteria

- [ ] Pod logs retrievable by deployment/revision/pod.
- [ ] Logs can be tailed or fetched with bounded size/time limits.
- [ ] Logs are associated with revision and pod IDs.
- [ ] State transition events are queryable.
- [ ] Component metrics remain Prometheus-scrapable.
- [ ] A failed workload can be diagnosed from API/events/logs without host SSH.

### Evidence

- API examples: get logs, tail logs, get events.
- Live failure injection with diagnosis from Hivemind APIs.
- Redaction checks for env/secret values.

## 6. Security / isolation minimum

### Goal

Reach a credible same-tenant or internal-alpha isolation baseline.

### Pass criteria

- [ ] API auth required for mutating endpoints.
- [ ] Agent/replica traffic authenticated and encrypted or explicitly scoped to a PSK-encrypted internal-alpha model.
- [ ] Isolation profile applied to workload containers: resource limits, dropped capabilities where possible, readonly rootfs if supported by workload, and no privileged container by default.
- [ ] GPU device exposure limited to requested devices.
- [ ] Workload cannot access Hivemind control-plane credentials from env, mount, or filesystem.
- [ ] Security limitations documented clearly: what this does and does not protect against.

### Evidence

- Security doc section for POC v2 isolation model.
- Unit/integration tests for auth failure.
- Live smoke proving unauthenticated mutation fails.
- Live/container inspect evidence for resource/device restrictions.

## 7. Revisions / routability / rollout safety

### Goal

Prove Hivemind-native serving semantics, not just Kubernetes-like pod management.

### Required model

- Deployment owns immutable revisions.
- Pod belongs to a revision.
- Pod lifecycle, readiness, and routability are separate.
- Running does not imply routable.
- Routes point to weighted revisions.

### Pass criteria

- [ ] New deployment creates revision `N`.
- [ ] Update creates revision `N+1` without mutating revision `N`.
- [ ] New revision pods can be `running` and `not_routable` until readiness gates pass.
- [ ] Old revision remains routable until new revision has enough routable capacity.
- [ ] Failed rollout keeps or restores old revision routing.
- [ ] Rollback is route-first, then drain/cleanup.
- [ ] Scale-down marks pods draining before stop.

### Evidence

- Zig VOPR tests for rollout success, rollout failure, rollback, and worker loss mid-rollout.
- Worker simulation tests for readiness/routability transitions.
- Live rollout showing old revision serving while new revision warms.
- Live failed rollout showing old revision continues serving.

## 8. Event-driven state surface

### Goal

Make state propagation and operator diagnosis event-driven, not log scraping or polling-only.

### Pass criteria

- [ ] Every lifecycle/readiness/routability transition emits a bounded event.
- [ ] Scheduling decisions emit placement reason and constraints considered.
- [ ] Rollout decisions emit old/new revision capacity and route changes.
- [ ] Events are queryable by deployment, revision, pod, node, and time range.
- [ ] Event retention is bounded and documented.

### Evidence

- API examples.
- Deterministic event-order tests for simulated rollout.
- Live event transcript for successful and failed rollout.

## 9. Queue-aware serving path

### Goal

Prove the request path can measure queue depth/concurrency near the point of routing.

### Pass criteria

- [ ] Hivemind has a queue-proxy/forwarder concept or equivalent instrumentation point.
- [ ] Per-revision in-flight request count is visible.
- [ ] Per-revision queue depth is visible.
- [ ] Concurrency limit can be configured per revision or app.
- [ ] Over-limit requests queue or fail according to policy.
- [ ] Metrics drive autoscaling inputs without scraping container logs.

### Evidence

- Load test showing queue depth and in-flight metrics move as expected.
- Unit/sim coverage for queue overflow/backpressure policy.
- Metrics examples.

## 10. Autoscaling / scale-from-zero

### Goal

Demonstrate a minimal serving autoscaler and scale-from-zero story.

### Pass criteria

- [ ] Deployment can scale to zero.
- [ ] Request to zero-scale deployment triggers activation.
- [ ] Request is buffered or explicitly rejected according to documented policy.
- [ ] Queue depth or concurrency drives scale-up.
- [ ] Idle cooldown drives scale-down.
- [ ] Autoscaler avoids obvious oscillation with hysteresis/cooldown.

### Evidence

- Deterministic autoscaler tests.
- Live scale-to-zero/wake proof on representative workload.
- Latency table for wake path.

## 11. GitOps / Argo bridge

### Goal

Provide a credible operator path from current declarative workflows to Hivemind.

### Pass criteria

- [ ] A declarative workload spec can be committed and applied to Hivemind.
- [ ] Drift is detectable at least by a CLI/check command.
- [ ] Rollout status is machine-readable.
- [ ] Health status maps revisions/routability into a simple `Healthy/Progressing/Degraded` model.
- [ ] Full Argo controller parity is explicitly not required for this POC.

### Evidence

- Example YAML.
- CLI or bridge command applying spec.
- Status output suitable for CI/GitOps.

## 12. Benchmark refresh

### Goal

Retain the latency advantage claim after adding required platform features.

### Pass criteria

- [ ] Rerun warm-cache benchmark with AppSpec/revision/routability path enabled.
- [ ] Rerun representative workload warm-cache scale path.
- [ ] Rerun at least one private-image cold-cache path after auth fix.
- [ ] Compare against EKS using status-equivalent readiness, not benchmark wall overhead.
- [ ] Record instance/node shapes and resource requests.

### Evidence

- Hivemind and EKS artifact dirs.
- Full table with scenario names and cache state.
- Explicit caveats for what is and is not measured.

## 13. Final evidence pack

### Goal

Produce a team-facing package that is hard to dismiss.

### Pass criteria

- [ ] One-page executive summary.
- [ ] Exact benchmark scenario definitions.
- [ ] Platform parity matrix with pass/fail evidence.
- [ ] Hivemind-native feature demo: revision rollout/rollback/routability.
- [ ] Security/isolation limitations and next steps.
- [ ] Cost/resource comparison.
- [ ] Known risks and explicit non-goals.

## Implementation sequence

1. `AppSpec v1` API/core/worker contract.
2. Secrets/image auth and JuiceFS required-mount semantics.
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

## Evidence discipline

- Control-plane semantics require Zig unit/VOPR coverage.
- Worker runtime/readiness/storage/secrets semantics require Rust unit/sim/runtime coverage.
- Real infra-only glue requires nearest deterministic test plus a note explaining why simulation is not applicable.
- POC claims require live evidence and exact artifact paths.
- Generated artifacts remain ignored and must not be committed.

# Hivemind Native Platform Model

Status: design direction after POC benchmark work.

Hivemind should not become a fast Kubernetes clone. The product model should keep Kubernetes-compatible edges where useful, but own the serving-specific concepts that make Hivemind faster and simpler for inference workloads.

## Core split

Future platform work has two tracks:

1. **Kubernetes parity gaps**: storage, secrets, logging, isolation, autoscaling, Argo/GitOps, provider automation, and operator workflows users expect.
2. **Hivemind-native semantics**: revision routing, routability, richer lifecycle state, event-driven propagation, and request-aware serving primitives.

The second track is the differentiator. Do not spend engineering cycles cloning broad Kubernetes APIs unless required by real workloads.

## Native concepts

| Concept | Purpose | Priority |
|---|---|---:|
| Rich pod lifecycle states | distinguish image pull, create, start, run, stop, failure, retry, adoption | P0 |
| Readiness state | represent probe and app readiness independently from process state | P0 |
| Routability state | make `running` separate from `safe to receive traffic` | P0 |
| Revisions | immutable deployment spec instances for rollout, rollback, and traffic routing | P0 |
| Availability-preserving rollouts | keep old revision routed until new revision has enough routable capacity | P0 |
| Durable event stream | expose state transitions and decisions without polling | P0 |
| Queue-proxy equivalent | capture per-pod/revision queue depth, concurrency, backpressure, request metrics | P1 |
| Activator equivalent | buffer/trigger scale-from-zero and hide cold starts where possible | P1 |
| Ingress/router integration | Thalamus/Hivemind route model over routable revision capacity | P1 |
| Certificate provisioning | ACME/cert-manager-style integration for Hivemind-owned ingress | P1 |

## State model

Do not overload `running`. A pod should have independent lifecycle, readiness, and routing state.

### Lifecycle state

- `pending`
- `scheduled`
- `image_pulling`
- `image_ready`
- `creating`
- `created`
- `starting`
- `started`
- `running`
- `stopping`
- `stopped`
- `failed`

### Readiness state

- `unknown`
- `startup_probe_pending`
- `startup_probe_failed`
- `live`
- `readiness_probe_pending`
- `ready`
- `not_ready`

### Routability state

- `not_routable`
- `warming`
- `routable`
- `draining`
- `retired`

A pod is eligible for request routing only when:

```text
lifecycle == running
and readiness == ready
and routability == routable
and revision traffic weight > 0
and node health is acceptable
```

## Revision model

Revisions should be first-class state, not implicit deployment versions.

| Object | Key fields |
|---|---|
| Deployment | name, desired policy, active rollout, traffic policy |
| Revision | revision_id, spec hash, image, created_at, desired replicas, ready replicas, routable replicas |
| Pod | pod_id, deployment_id, revision_id, lifecycle, readiness, routability, node_id |
| Route | deployment name -> weighted revisions |
| Rollout | strategy, health gates, old-revision retention, rollback policy |

## Rollout invariants

Availability-preserving rollout is a Hivemind invariant:

- Never reduce old revision routable capacity below policy until new revision has enough routable capacity.
- New pods can be `running` but `not_routable` until startup/readiness and warmup gates pass.
- Rollback should route traffic back to the last healthy routable revision before draining the failed revision.
- Canary means weighted routing to revisions, not only replica count changes.
- Scale-down should drain routable pods before stopping containers.

These invariants belong in deterministic simulation. Control-plane changes map to Zig VOPR coverage. Worker readiness/routability changes map to Rust worker simulation coverage.

## Knative concepts to adapt

| Knative concept | Hivemind equivalent | Direction |
|---|---|---|
| Revision | immutable Hivemind `Revision` | build |
| Route | weighted deployment -> revision route | build |
| Configuration | desired `AppSpec` -> revisions | build minimal |
| Queue proxy | request-aware lightweight proxy / worker forwarder metrics | build |
| Activator | regional request buffer + scale-from-zero trigger | build after queue-proxy |
| Ingress | Thalamus/Hivemind router integration | integrate |
| Certificate provisioning | cert-manager/ACME-compatible workflow | integrate first |
| Autoscaler | queue depth + concurrency + routable capacity | build |

## Relationship to Kubernetes parity

Kubernetes parity work remains necessary for production, but should be scoped by inference workloads:

- Build: `AppSpec v1`, revision/routing model, readiness/routability, event stream, pod logs API, queue autoscaler.
- Integrate: Argo/GitOps, cert provisioning, log shipping, provider-specific identity, cloud storage backends.
- Defer: broad CRD/operator compatibility, full Service/CNI parity, generic DaemonSet clone, arbitrary sidecar/init-container parity unless a real workload requires it.

## POC v2 acceptance additions

A future real-workload POC should add deterministic and live evidence for:

1. new revision rolls out while old revision keeps serving;
2. new revision reaches `running` but stays `not_routable` until readiness passes;
3. failed rollout automatically keeps or restores old routable revision;
4. scale-from-zero path creates capacity from queued requests;
5. event stream explains every state transition and routing decision;
6. JuiceFS/env/secrets/logging/isolation work for the same workload.

# Scheduler & State Machine Expansion

## Overview

Expand the state machine to support scheduling decisions, capacity tracking, and routing - then validate it all through the VOPR under fault injection.

The scheduler reads from the local state machine copy and writes placement decisions through consensus. The VOPR simulates workload submission, node failures, and partitions to verify that scheduling decisions remain consistent across replicas.

## State Machine Expansion

### New Domain Types

**CapacityTier** (from thalamus): hot/warm/cold model
```
hot:  idle, pre-warmed capacity. Can serve immediately.
warm: running instances. Needs container spin-up.
cold: provider capacity. Needs provisioning (seconds to minutes).
```

**NodeCapacity** (derived, not stored directly): computed from node registration minus pod bindings
```
NodeCapacity {
  node_id: u64
  total_gpu: u8
  allocated_gpu: u8
  available_gpu: u8      // total - allocated
  gpu_type: GpuType
  region: [32]u8
  provider: [32]u8
  tier: CapacityTier     // derived from pod states on this node
}
```

**ScalingState** per deployment:
```
ScalingState {
  deployment_id: u64
  desired_replicas: u32   // target (set by scale command)
  current_replicas: u32   // actual running pods (derived)
  min_replicas: u32       // floor (can be 0 for scale-to-zero)
  max_replicas: u32       // ceiling
  cooldown_ticks: u64     // ticks since last scale event
}
```

**RoutingEntry** per deployment:
```
RoutingEntry {
  deployment_id: u64
  app_id: [64]u8
  backends: [MAX_BACKENDS]Backend   // pod endpoints
  backend_count: u8
}

Backend {
  pod_id: u64
  node_id: u64
  address: [64]u8    // IP:port or node address
  healthy: bool
}
```

**Killswitch**:
```
Killswitch {
  node_id: u64       // 0 = all nodes
  deployment_id: u64 // 0 = all deployments
  active: bool
}
```

### New Commands (consensus-replicated mutations)

| Command | Description | Who Submits |
|---------|-------------|-------------|
| `ScaleDeployment { deployment_id, desired }` | Set target replica count | Router (queue depth), API (manual), Scheduler (autoscale) |
| `BindPodToNode { pod_id, node_id }` | Assign pod to node | Scheduler |
| `UnbindPod { pod_id }` | Remove pod from node | Scheduler (scale-down), Agent (eviction) |
| `SetKillswitch { node_id, deployment_id, active }` | Enable/disable routing override | API (incident response) |
| `UpdateNodeCapacity { node_id, allocated_gpu }` | Adjust allocation tracking | Scheduler (after bind/unbind) |

### State Machine Query Methods (local reads, no consensus)

```zig
// Capacity queries
fn getNodesWithGpu(gpu_type: GpuType, min_available: u8) []NodeCapacity
fn getNodeCapacity(node_id: u64) ?NodeCapacity
fn getTotalAvailableGpu(gpu_type: GpuType) u32

// Routing queries
fn getBackends(app_id: []const u8) []Backend
fn isKillswitched(node_id: u64, deployment_id: u64) bool

// Scaling queries
fn getScalingState(deployment_id: u64) ?ScalingState
fn getDeploymentsNeedingScale() []ScalingState  // desired != current
```

## Scheduler Algorithm

Adapted from thalamus `candidate.go`, but operates on pods/nodes instead of clusters.

### Placement Decision

```
schedule(deployment, desired_replicas):
  current_pods = state_machine.getPodsForDeployment(deployment.id)

  if desired > current:
    // Scale up: find nodes for new pods
    for each new pod needed:
      candidates = state_machine.getNodesWithGpu(deployment.gpu_type, deployment.gpu_count)
      candidates = filterKillswitched(candidates)
      candidates = filterByRegion(candidates, deployment.preferred_regions)

      // Score candidates (thalamus-style weighted selection)
      scored = scoreCandidates(candidates, deployment)
      node = weightedSelect(scored)

      submit(BindPodToNode { pod.id, node.id })

  if desired < current:
    // Scale down: evict excess pods (prefer cold, then warm, then hot)
    excess = current - desired
    to_evict = selectForEviction(current_pods, excess)
    for each pod in to_evict:
      submit(UnbindPod { pod.id })
```

### Scoring Function (from thalamus)

```
scoreCandidates(candidates, deployment):
  for each candidate:
    base_weight = candidate.available_gpu

    // Latency modifier: sqrt(min_latency / candidate_latency)
    // Latency comes from local cache (agent heartbeat), not consensus
    latency_mod = sqrt(min_latency / max(candidate.latency, 15ms))

    // Cost modifier: penalize expensive providers when capacity is plentiful
    cost_mod = if total_available > threshold:
      min_cost / candidate.cost
    else:
      1.0  // when capacity scarce, ignore cost

    // Warm capacity modifier: penalize nodes with low warm capacity
    warm_mod = if candidate.warm_capacity < 10:
      lerp(0.1, 1.0, candidate.warm_capacity / 10)
    else:
      1.0

    candidate.weight = base_weight * latency_mod * cost_mod * warm_mod
```

## VOPR Integration

This is the critical part. The VOPR needs to validate that scheduling decisions are consistent across replicas under faults.

### New VOPR Fault Types

| Fault | Description | What It Tests |
|-------|-------------|---------------|
| `node_failure` | Remove a node (agent stops reporting) | Scheduler reschedules pods from failed node |
| `node_rejoin` | Node comes back with stale state | State machine handles re-registration |
| `scale_event` | Random ScaleDeployment command | Scheduler produces consistent bindings across replicas |
| `killswitch` | Enable/disable routing to a node | All replicas converge on same routing table |

### New StateChecker Invariants

| Invariant | Description |
|-----------|-------------|
| **Binding consistency** | If two replicas both commit BindPodToNode for the same pod, the node must be the same |
| **Capacity accounting** | Sum of allocated GPUs on a node must never exceed total GPUs |
| **No double-binding** | A pod is bound to at most one node at any time |
| **Scaling convergence** | After faults heal, desired_replicas == current_replicas on all replicas |
| **Routing convergence** | After faults heal, all replicas have the same routing table |

### VOPR Scheduling Workload

```
Phase 1 (Safety):
  - Register N nodes with various GPU types
  - Create M deployments with GPU requirements
  - Submit ScaleDeployment commands
  - Inject partitions, crashes, node failures
  - Check invariants every tick

Phase 2 (Liveness):
  - Heal all faults
  - Verify all replicas converge on:
    - Same deployment states
    - Same pod bindings
    - Same routing tables
    - Capacity accounting is consistent
```

### Example VOPR Config

```zig
const SchedulingVoprConfig = struct {
    seed: u64 = 42,
    replica_count: u8 = 3,
    safety_ticks: u64 = 1000,
    node_count: u8 = 10,           // simulated nodes
    deployment_count: u8 = 5,      // simulated deployments
    scale_event_probability: u8 = 5,
    node_failure_probability: u8 = 2,
    partition_probability: u8 = 2,
    crash_probability: u8 = 1,
    heal_probability: u8 = 5,
    liveness_ticks: u64 = 500,
};
```

## Implementation Order

### Step 1: State Machine Types + Commands
- Add CapacityTier, ScalingState, RoutingEntry, Backend, Killswitch to state_machine.zig
- Add new commands to message.zig
- Add apply() handlers for new commands
- Unit tests for each command

### Step 2: State Machine Queries
- Add getNodesWithGpu, getBackends, getScalingState, etc.
- These are pure reads on the in-memory state
- Unit tests for query correctness

### Step 3: Scheduler Module
- src/scheduler.zig: scoring algorithm, placement logic
- Reads state machine, submits consensus ops
- Unit tests for scoring, placement, scale-up, scale-down

### Step 4: VOPR Scheduling Workload
- New fault types in VOPR (node failure, scale events)
- New StateChecker invariants (binding consistency, capacity accounting)
- Scheduling-specific VOPR config
- Target: 100% pass rate across 500 seeds with scheduling faults

### Step 5: Routing Integration
- RoutingEntry built from pod bindings in state machine
- getBackends() query for Router to use
- Killswitch support
- VOPR validates routing table convergence

## Files

| File | Changes |
|------|---------|
| `src/state_machine.zig` | New types, new commands, query methods |
| `src/message.zig` | New command variants in Command union |
| New: `src/scheduler.zig` | Scoring algorithm, placement decisions |
| `src/vopr.zig` | New fault types, scheduling workload |
| `src/state_checker.zig` | New invariants (binding, capacity, routing) |
| `src/unit_tests.zig` | Tests for commands, queries, scoring |

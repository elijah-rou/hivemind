# Agent-Native Infrastructure - Future Vision

**Phase**: 6+ (Post-core Hivemind)
**Status**: Vision / Design Placeholder
**Timeline**: After 5-month core implementation
**Dependency**: Phases 1-5 stable

> "In 2026, the biggest infrastructure shock won't come from outside companies, but from within... Building for agents means re-architecting the control plane." - A16Z

---

## Context

The core Hivemind phases (1-5) optimize for human-speed workloads: request → inference → response. This is the right foundation, but agent workloads represent a fundamentally different pattern:

| Dimension | Human Workloads | Agent Workloads |
|-----------|-----------------|-----------------|
| Concurrency | 1-10 concurrent requests | 100-10,000+ parallel sub-tasks |
| Pattern | Request-response | Recursive fan-out, DAGs |
| Predictability | Relatively stable | Bursty, "looks like DDoS" |
| Latency tolerance | Seconds acceptable | Sub-100ms expected for tool calls |
| Coordination | Stateless | Shared state, locks, barriers |
| Duration | Milliseconds-minutes | Hours-days (root agent lifetime) |

---

## Design Goals

| Goal | Description |
|------|-------------|
| **Recursive scale** | Single agent goal → 5,000+ sub-tasks handled natively |
| **Coordination primitives** | Distributed locks, barriers, transactional state |
| **Agent identity** | Distinguish agent traffic, different rate limits |
| **Priority scheduling** | SLA tiers, preemption, deadline-aware |
| **Sandbox isolation** | Root agents run in isolated environments |
| **Cost controls** | Circuit breakers, budget caps, runaway prevention |

---

## Core Components (Future)

### 1. Task Graph Engine

Native support for DAG-based task submission instead of individual requests.

```
┌─────────────────────────────────────────────────────────────────┐
│                      TASK GRAPH ENGINE                           │
│                                                                 │
│   Agent submits:                                                │
│   {                                                             │
│     "goal": "refactor-auth-module",                             │
│     "tasks": [                                                  │
│       { "id": "analyze", "type": "inference", ... },            │
│       { "id": "plan", "depends_on": ["analyze"], ... },         │
│       { "id": "edit-1", "depends_on": ["plan"], ... },          │
│       { "id": "edit-2", "depends_on": ["plan"], ... },          │
│       { "id": "test", "depends_on": ["edit-1", "edit-2"], ... } │
│     ]                                                           │
│   }                                                             │
│                                                                 │
│   System handles:                                               │
│   • Dependency resolution                                       │
│   • Parallel execution where possible                           │
│   • Result aggregation                                          │
│   • Failure propagation / retry                                 │
│   • Progress reporting                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Extensibility from current design:**
- `WorkloadKind` can add `task_graph` type
- Job Controller patterns extend to DAG scheduling
- VRR can track task graph state

### 2. Coordination Service

Distributed primitives for parallel sub-task coordination.

```go
// Future API surface
type CoordinationService interface {
    // Distributed locks
    AcquireLock(ctx context.Context, resource string, opts LockOptions) (Lock, error)

    // Barriers for synchronization
    CreateBarrier(ctx context.Context, name string, parties int) (Barrier, error)

    // Shared state with conflict resolution
    GetState(ctx context.Context, key string) ([]byte, Version, error)
    CompareAndSwap(ctx context.Context, key string, expected Version, value []byte) error

    // Transactional multi-key updates
    Transaction(ctx context.Context, ops []Operation) error
}

type LockOptions struct {
    TTL         time.Duration
    WaitTimeout time.Duration
    Exclusive   bool  // vs shared/read lock
}
```

**Extensibility from current design:**
- VRR infrastructure provides distributed consensus foundation
- Could run as sidecar to Hivemind control plane
- Turso/SQLite pattern for local state with sync

### 3. Agent Identity & Rate Limiting

Distinguish agent traffic for appropriate handling.

```yaml
# Future rate limit config
rate_limits:
  # Human traffic (current)
  human:
    requests_per_minute: 1000
    burst: 100

  # Agent traffic (new)
  agent:
    requests_per_minute: 100000  # Much higher
    burst: 10000
    concurrent_task_graphs: 10
    max_fan_out_per_graph: 5000
    budget_per_hour_usd: 1000    # Circuit breaker

  # Identification
  agent_detection:
    - header: "X-Agent-ID"
    - jwt_claim: "agent_type"
    - behavior_heuristics: true  # Detect by pattern
```

**Extensibility from current design:**
- Router auth layer can add agent identity claims
- Rate limiter abstraction supports different policies
- Metrics already track per-app, can add per-agent

### 4. Priority Scheduler

SLA tiers with preemption for agent-critical tasks.

```go
type PriorityTier string

const (
    TierCritical    PriorityTier = "critical"    // Agent security remediation
    TierInteractive PriorityTier = "interactive" // Human-initiated
    TierAgent       PriorityTier = "agent"       // Standard agent tasks
    TierBatch       PriorityTier = "batch"       // Background processing
)

type SchedulerConfig struct {
    // Reserved capacity per tier
    ReservedCapacity map[PriorityTier]float32  // e.g., critical: 0.1 (10%)

    // Preemption rules
    PreemptionEnabled bool
    PreemptibleTiers  []PriorityTier  // batch can be preempted

    // Queue management
    MaxQueueDepthPerTier map[PriorityTier]int
}
```

**Extensibility from current design:**
- Scheduler scoring already pluggable (Data Locality, Queue Depth, etc.)
- Can add Priority score component
- Autoscaler can factor in priority distribution

### 5. Agent Sandbox Environment

Isolated environments for root agents to execute in.

```
┌─────────────────────────────────────────────────────────────────┐
│                     AGENT SANDBOX                                │
│                                                                 │
│   Root Agent Environment:                                       │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  • Isolated filesystem (workspace)                      │   │
│   │  • Network policies (egress whitelist)                  │   │
│   │  • Resource quotas (CPU, memory, GPU time)              │   │
│   │  • Tool access controls (which APIs callable)           │   │
│   │  • Audit logging (all actions recorded)                 │   │
│   │  • Snapshot/restore for debugging                       │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Sandbox Types:                                                │
│   • Ephemeral: Destroyed after task graph completes             │
│   • Persistent: Long-running agent with state preservation      │
│   • Nested: Sub-agents spawned with inherited restrictions      │
│                                                                 │
│   Security Model:                                               │
│   • Capability-based permissions                                │
│   • No ambient authority (explicit grants only)                 │
│   • Resource usage tracked per-agent                            │
│   • Kill switch for runaway agents                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Extensibility from current design:**
- Instance workload type provides foundation (SSH, workspace storage)
- Could be specialized instance subtype with additional constraints
- Agent module can enforce sandbox policies

### 6. Speculative Pre-warming

Predict agent behavior and pre-warm capacity.

```go
type PrewarmingStrategy struct {
    // Pattern-based
    AgentPatterns map[string]AgentPattern  // Known agent behavior profiles

    // Predictive
    EnableMLPrediction bool
    PredictionHorizon  time.Duration  // How far ahead to predict

    // Pool management
    WarmPoolSize       int            // Always-warm instances
    WarmPoolTTL        time.Duration  // How long to keep warm

    // Cost controls
    MaxPrewarmCost     Money          // Budget for speculative warming
}

type AgentPattern struct {
    Name           string
    TypicalFanOut  int              // Expected sub-task count
    BurstDuration  time.Duration    // How long bursts last
    CooldownPeriod time.Duration    // Time between bursts
}
```

**Extensibility from current design:**
- Autoscaler already has scaling signals
- Can add predictive component alongside reactive scaling
- Metrics infrastructure supports pattern detection

---

## Current Design Extensibility Checklist

Decisions to validate in Phases 1-5 to avoid painting ourselves into a corner:

### Data Model Flexibility

- [x] `WorkloadKind` enum is extensible (can add `task_graph`, `agent_sandbox`)
- [x] `WorkloadSpec` uses optional sub-specs (`JobSpec`, `InstanceSpec`) - can add `TaskGraphSpec`
- [ ] **Review**: Are IDs structured to support hierarchical task relationships?
- [ ] **Review**: Can metadata support agent identity claims?

### Scheduler Extensibility

- [x] Scoring function is weighted and pluggable
- [ ] **Ensure**: Score weights configurable at runtime (not compile-time)
- [ ] **Ensure**: Can add new score components without code changes
- [ ] **Consider**: Priority as first-class scheduling dimension

### Router Extensibility

- [x] `RoutingBackend` interface abstracts routing logic
- [x] Rate limiting is configurable
- [ ] **Ensure**: Rate limit policies selectable per-request (not just per-app)
- [ ] **Consider**: Request batching support for task graphs

### Control Plane Extensibility

- [x] Controller pattern (Autoscaler, JobController, InstanceController) is modular
- [ ] **Ensure**: Controllers can be added without modifying core
- [ ] **Consider**: Event-driven architecture for controller coordination

### Agent Extensibility

- [x] Module system allows adding capabilities
- [x] Storage module supports multiple backends
- [ ] **Ensure**: Sandbox enforcement can be added as module
- [ ] **Consider**: Agent-local coordination cache

---

## Non-Goals (for now)

These are out of scope even for Phase 6+, but noted for completeness:

1. **Multi-agent collaboration** - Agents coordinating with each other (vs sub-tasks of single agent)
2. **Agent marketplace** - Third-party agents running on platform
3. **Agent training/fine-tuning** - Learning from execution patterns
4. **Cross-customer agent sharing** - Agents that serve multiple tenants

---

## Open Questions

1. **Task graph size limits** - What's the maximum DAG size we'd support?
2. **Coordination service consistency** - Strong vs eventual consistency tradeoffs?
3. **Sandbox escape prevention** - How to handle container escapes from agent sandboxes?
4. **Billing model** - Per-task, per-graph, per-agent-hour?
5. **Observability** - How to trace through 5,000 parallel sub-tasks?
6. **Failure semantics** - Partial graph completion handling?

---

## Related Documents

- [STATUS.md](../STATUS.md) - Current core system architecture
- [HIVEMIND.md](HIVEMIND.md) - Control plane (foundation for Task Graph Engine)
- [WORKLOAD_TYPES.md](WORKLOAD_TYPES.md) - Current workload types (extensible to agents)
- [ROUTER.md](ROUTER.md) - Request routing (needs agent-aware extensions)
- [CONSENSUS.md](CONSENSUS.md) - VRR foundation for Coordination Service

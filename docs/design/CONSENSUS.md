# Consensus & State Replication in Hivemind

> Design exploration for distributed state management across routers, control planes, and pools.

---

## Overview

Hivemind is inherently distributed:
- **Multiple regions** with independent failure domains
- **Multiple routers** per region for HA and load distribution
- **Dynamic pools** of GPU nodes that come and go
- **Control planes** that make scheduling decisions

This document explores where consensus is needed, what protocols fit, and the trade-offs between correctness and latency.

---

## System State Inventory

First, let's catalog all state in the system and its characteristics:

### Router State

| State | Mutability | Readers | Writers | Durability | Notes |
|-------|------------|---------|---------|------------|-------|
| Request queue | High | Local router | Local router | Ephemeral | Requests waiting during cold start |
| App → Pool mapping | Low | All routers | Control plane | Cached | Which pools serve which apps |
| Pool health | Medium | All routers | Control plane | Cached | Which pools are healthy |
| Queue depth metrics | High | Control plane | Local router | Ephemeral | For autoscaling decisions |
| Active connections | High | Local router | Local router | Ephemeral | In-flight requests |

### Control Plane State

| State | Mutability | Readers | Writers | Durability | Notes |
|-------|------------|---------|---------|------------|-------|
| App configurations | Low | Many | API/CLI | Durable | Hardware requirements, scaling params |
| Pool definitions | Low | Many | Admin | Durable | Filter criteria, capacity limits |
| Node registry | Medium | Scheduler | Agents | Durable | Which nodes exist, their capabilities |
| Capacity allocations | High | Scheduler | Scheduler | Durable | Which apps have reserved which GPUs |
| Scheduling decisions | High | Routers, Agents | Scheduler | Durable | Pending and active placements |
| Autoscaler state | Medium | Autoscaler | Autoscaler | Durable | Scale decisions, cooldowns |

### Agent State

| State | Mutability | Readers | Writers | Durability | Notes |
|-------|------------|---------|---------|------------|-------|
| Local workloads | Medium | Agent | Agent, CP | Local | What's running on this node |
| GPU status | High | Agent, CP | Agent | Ephemeral | Utilization, memory, health |
| Container cache | Low | Agent | Agent | Local | Cached image layers |

### Cross-Region State

| State | Mutability | Readers | Writers | Durability | Notes |
|-------|------------|---------|---------|------------|-------|
| Global app registry | Low | All regions | Any region | Durable | Which apps exist system-wide |
| Region capacity summary | Medium | All regions | Each region | Eventually consistent | Rough capacity per region |
| Cross-region routing hints | Low | Routers | Control planes | Cached | Where to send overflow traffic |

---

## Consistency Requirements Analysis

### What MUST be strongly consistent?

These operations have correctness requirements that demand linearizability:

1. **Capacity allocation**
   - Risk: Double-booking GPUs leads to OOM or failed scheduling
   - Requirement: At most one app can be allocated to a GPU at a time
   - Scope: Within a pool (single region)

2. **Scheduling decisions**
   - Risk: Same request scheduled twice, or lost entirely
   - Requirement: Exactly-once semantics for schedule operations
   - Scope: Within the control plane handling that app

3. **App deployment state**
   - Risk: Conflicting configurations cause undefined behavior
   - Requirement: Single source of truth for app config
   - Scope: Could be global or per-region (design choice)

4. **Leader election** (if using leader-based consensus)
   - Risk: Split brain, conflicting decisions
   - Requirement: At most one leader at a time
   - Scope: Per consensus group

### What can be eventually consistent?

These can tolerate brief inconsistency:

1. **Queue depth metrics**
   - Staleness impact: Slightly delayed scaling decisions
   - Acceptable lag: 1-5 seconds
   - Recovery: Self-correcting (next metric push)

2. **Node health status**
   - Staleness impact: Might route to unhealthy node briefly
   - Acceptable lag: Seconds (health check interval)
   - Recovery: Request fails, retry to different node

3. **Cross-region capacity summaries**
   - Staleness impact: Suboptimal region selection
   - Acceptable lag: Seconds to minutes
   - Recovery: Overflow handling, rebalancing

4. **Routing weights/preferences**
   - Staleness impact: Slightly suboptimal routing
   - Acceptable lag: Seconds
   - Recovery: Metrics feedback loop adjusts

### What can be ephemeral?

State that can be lost on failure:

1. **In-flight request queues** (with caveats)
   - Clients will retry on timeout
   - Risk: Duplicate processing if not idempotent
   - Mitigation: Request IDs, idempotency keys

2. **Connection state**
   - Clients reconnect automatically
   - No durability needed

3. **Local caches**
   - Rebuilt from authoritative source
   - Cold cache = higher latency, not incorrectness

---

## Consensus Topology Options

### Option A: Single Global Consensus Group

```
┌─────────────────────────────────────────────────────────────────────────┐
│                     GLOBAL VRR GROUP (5 nodes)                          │
│                                                                         │
│    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
│    │ CP Node │    │ CP Node │    │ CP Node │    │ CP Node │    │ CP Node │
│    │ US-East │    │ US-West │    │ EU-West │    │ EU-East │    │ AP-South│
│    └────┬────┘    └────┬────┘    └────┬────┘    └────┬────┘    └────┬────┘
│         │              │              │              │              │
│         └──────────────┴──────────────┴──────────────┴──────────────┘
│                                   │
│                          Single replicated log
│                          All writes go through leader
└─────────────────────────────────────────────────────────────────────────┘
```

**Characteristics:**
- Single source of truth for ALL state
- All writes serialized through one leader
- Strong consistency globally

**Latency Analysis:**
- Write latency = RTT to leader + majority ack
- If leader in US-East, EU writes: ~150-200ms
- Read from local replica: ~0ms (but might be stale during view change)
- Linearizable read: requires leader round-trip

**Correctness:**
- Strongest guarantees
- No split-brain possible
- Simple mental model

**Failure Modes:**
- Leader failure: view change (~100ms-1s depending on timeout)
- Network partition: minority side cannot make progress
- Cross-region partition: potentially problematic if quorum split

**When to choose:**
- Correctness is paramount
- Write volume is manageable (< 10k ops/sec)
- Can tolerate cross-region write latency

---

### Option B: Regional Consensus Groups with Gossip

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   ┌───────────────────────┐              ┌───────────────────────┐     │
│   │    US-EAST REGION     │              │    EU-WEST REGION     │     │
│   │                       │              │                       │     │
│   │  ┌─────────────────┐  │    Gossip    │  ┌─────────────────┐  │     │
│   │  │  VRR Group (3)  │  │◄────────────►│  │  VRR Group (3)  │  │     │
│   │  │                 │  │              │  │                 │  │     │
│   │  │ CP1  CP2  CP3   │  │              │  │ CP1  CP2  CP3   │  │     │
│   │  └─────────────────┘  │              │  └─────────────────┘  │     │
│   │          │            │              │          │            │     │
│   │   Local state only    │              │   Local state only    │     │
│   │   - Regional pools    │              │   - Regional pools    │     │
│   │   - Regional capacity │              │   - Regional capacity │     │
│   │   - Apps homed here   │              │   - Apps homed here   │     │
│   │                       │              │                       │     │
│   └───────────────────────┘              └───────────────────────┘     │
│                                                                         │
│   Gossip propagates:                                                    │
│   - App existence (which apps exist globally)                          │
│   - Region summaries (rough capacity, health)                          │
│   - Routing hints (where to send overflow)                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Characteristics:**
- Each region has independent consensus
- Cross-region sync via gossip (CRDT-friendly)
- Apps have a "home" region that owns their state

**Latency Analysis:**
- Write latency = intra-region RTT (~1-5ms)
- Cross-region reads: gossip delay (configurable, 100ms-1s)
- Local operations are fast

**Correctness:**
- Strong consistency within region
- Eventual consistency across regions
- Need conflict resolution for cross-region operations

**Failure Modes:**
- Regional failure: other regions unaffected
- Cross-region partition: regions operate independently
- Gossip partition: stale cross-region data, but local ops continue

**Challenges:**
- Where does an app "live"? What happens on region failure?
- Cross-region scheduling requires coordination
- Potential for divergence if gossip fails

**When to choose:**
- Low-latency writes are critical
- Regional autonomy is acceptable
- Cross-region operations are rare

---

### Option C: Hierarchical Consensus

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         GLOBAL COORDINATOR                              │
│                         (VRR Group of 3-5)                              │
│                                                                         │
│                    Owns: App registry, region assignments               │
│                    Does NOT own: scheduling, capacity                   │
│                                                                         │
│         ┌──────────────────┼──────────────────┐                        │
│         │                  │                  │                        │
│         ▼                  ▼                  ▼                        │
│   ┌───────────┐      ┌───────────┐      ┌───────────┐                  │
│   │ US-EAST   │      │ EU-WEST   │      │ AP-SOUTH  │                  │
│   │ VRR (3)   │      │ VRR (3)   │      │ VRR (3)   │                  │
│   │           │      │           │      │           │                  │
│   │ Owns:     │      │ Owns:     │      │ Owns:     │                  │
│   │ - Local   │      │ - Local   │      │ - Local   │                  │
│   │   pools   │      │   pools   │      │   pools   │                  │
│   │ - Local   │      │ - Local   │      │ - Local   │                  │
│   │   sched   │      │   sched   │      │   sched   │                  │
│   └───────────┘      └───────────┘      └───────────┘                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Characteristics:**
- Global coordinator handles metadata (what apps exist, where they're homed)
- Regional control planes handle execution (scheduling, capacity)
- Clear separation of concerns

**Latency Analysis:**
- App creation/update: global RTT (infrequent)
- Scheduling/scaling: local RTT (frequent)
- Best of both worlds for common operations

**Correctness:**
- Global consistency for app metadata
- Regional consistency for execution
- Clear ownership boundaries

**Failure Modes:**
- Global coordinator down: can't create new apps, but existing apps run
- Regional CP down: that region's scheduling stops
- Graceful degradation

**Challenges:**
- More complex architecture
- Need to carefully define ownership boundaries
- Global coordinator is still a bottleneck for some operations

**When to choose:**
- Different operations have different latency requirements
- Clear separation between "metadata" and "execution" state
- Want to limit blast radius of failures

---

### Option D: Leaderless / Multi-Leader

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│   Every control plane node can accept writes                           │
│   Conflicts resolved via:                                               │
│     - Vector clocks + last-writer-wins                                 │
│     - CRDTs for mergeable state                                        │
│     - Application-level conflict resolution                            │
│                                                                         │
│   ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐            │
│   │   CP    │◄──►│   CP    │◄──►│   CP    │◄──►│   CP    │            │
│   │ US-East │    │ US-West │    │ EU-West │    │ AP-South│            │
│   └─────────┘    └─────────┘    └─────────┘    └─────────┘            │
│        │              │              │              │                  │
│        └──────────────┴──────────────┴──────────────┘                  │
│                         Async replication                               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

**Characteristics:**
- No designated leader
- Any node can accept writes
- Conflicts resolved after the fact

**Latency Analysis:**
- Write latency = local only (fastest possible)
- Conflict resolution: async

**Correctness:**
- Weakest guarantees
- Conflicts are possible
- Need careful data modeling (CRDTs)

**Failure Modes:**
- Node failure: other nodes continue
- Network partition: all partitions make progress (but diverge)

**Challenges:**
- Capacity allocation is HARD to do safely
  - Two nodes might allocate same GPU
  - Need reservation/claim pattern with TTLs
- Scheduling conflicts need resolution strategy

**When to choose:**
- Availability over consistency
- Can model all state as CRDTs
- Willing to accept occasional conflicts

---

## Component-Specific Analysis

### Routers

**Recommendation: Stateless + Caching**

Routers should NOT participate in consensus. They should:
1. Cache app→pool mappings from control plane
2. Queue requests locally (ephemeral, best-effort)
3. Report metrics to control plane asynchronously

```
Router Design:
┌─────────────────────────────────────────┐
│                ROUTER                    │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │      Routing Cache              │   │ ← Refreshed from CP every N seconds
│  │  app_id → [pool_endpoints]      │   │   or on cache miss
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │      Request Queue              │   │ ← Ephemeral, per-app
│  │  app_id → pending_requests      │   │   Lost on router failure (client retries)
│  └─────────────────────────────────┘   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │      Metrics Reporter           │   │ ← Async push to CP
│  │  queue_depths, latencies        │   │   Fire-and-forget
│  └─────────────────────────────────┘   │
│                                         │
└─────────────────────────────────────────┘
```

**Why no consensus for routers?**
- Request queues are transient (clients retry)
- Routing decisions are read-heavy
- Consensus overhead would kill latency
- Horizontal scaling is simpler without coordination

**Trade-off:**
- Router failure = queued requests lost
- Mitigation: Clients retry, queue sizes stay small, multiple routers per region

---

### Control Plane

**Recommendation: VRR per region (Option B or C)**

The control plane needs consensus for:
- Scheduling decisions
- Capacity allocation
- App configuration

```
Control Plane VRR Group:
┌─────────────────────────────────────────┐
│           VRR STATE MACHINE             │
│                                         │
│  Commands (writes):                     │
│  - ScheduleWorkload(app_id, requirements)
│  - AllocateCapacity(pool_id, app_id, gpus)
│  - UpdateAppConfig(app_id, config)      │
│  - RegisterNode(node_id, capabilities)  │
│  - DeregisterNode(node_id)              │
│                                         │
│  Queries (reads):                       │
│  - GetAppConfig(app_id)                 │
│  - GetPoolCapacity(pool_id)             │
│  - GetSchedulingDecision(request_id)    │
│                                         │
│  State:                                 │
│  - apps: HashMap<AppId, AppConfig>      │
│  - pools: HashMap<PoolId, PoolState>    │
│  - nodes: HashMap<NodeId, NodeInfo>     │
│  - allocations: HashMap<GpuId, AppId>   │
│  - schedules: HashMap<RequestId, Decision>
│                                         │
└─────────────────────────────────────────┘
```

**VRR group sizing:**
- 3 nodes: tolerates 1 failure, minimal overhead
- 5 nodes: tolerates 2 failures, higher latency
- Recommendation: 3 nodes per region

---

### Cross-Region Coordination

**Recommendation: Gossip + Explicit Coordination Protocol**

For cross-region operations, we need to choose based on operation type:

| Operation | Coordination Method | Rationale |
|-----------|-------------------|-----------|
| App creation | Hierarchical (Option C) or designated region | Infrequent, needs global uniqueness |
| Cross-region scheduling | Request/response to target region | Explicit, traceable |
| Capacity summaries | Gossip | Approximate is fine |
| Failover | Explicit handoff protocol | Needs coordination |

```
Cross-Region Protocol:

1. GOSSIP (background, continuous)
   - Each region broadcasts summary every N seconds
   - Content: { region_id, healthy: bool, capacity_summary, app_count }
   - Protocol: UDP multicast or TCP mesh

2. CROSS-REGION SCHEDULE REQUEST (on-demand)
   - Source region sends explicit request to target
   - Target region runs through its consensus
   - Response with accept/reject

   Sequence:
   US-East                          EU-West
      │                                │
      │──ScheduleRequest(app, reqs)───►│
      │                                │ (VRR consensus)
      │◄──ScheduleResponse(accepted)───│
      │                                │

3. FAILOVER HANDOFF (on region failure detection)
   - Healthy region claims orphaned apps
   - Uses distributed lock or consensus to prevent races
   - Loads app state from durable storage (not from failed region)
```

---

## VRR Implementation Considerations for Zig

### State Machine Interface

```zig
const StateMachine = struct {
    // The state machine must be deterministic
    // Given the same sequence of commands, produces identical state

    pub fn apply(self: *StateMachine, command: Command) Result {
        // Apply command to state
        // Must be deterministic - no randomness, no I/O, no time
    }

    pub fn snapshot(self: *StateMachine) []const u8 {
        // Serialize state for transfer to new replicas
    }

    pub fn restore(self: *StateMachine, data: []const u8) void {
        // Restore state from snapshot
    }
};
```

### VRR Core Types

```zig
const ViewNumber = u64;
const OpNumber = u64;
const RequestId = u128;  // Client-generated, for deduplication

const ReplicaId = enum(u8) {
    replica_0,
    replica_1,
    replica_2,
    // ... up to max replicas
};

const Status = enum {
    normal,
    view_change,
    recovering,
};

const LogEntry = struct {
    view_number: ViewNumber,
    op_number: OpNumber,
    command: Command,
    client_id: ClientId,
    request_id: RequestId,
};

const VRRState = struct {
    // Configuration
    replicas: []const ReplicaAddress,
    replica_id: ReplicaId,
    f: u8,  // Max failures tolerated

    // Volatile state
    status: Status,
    view_number: ViewNumber,
    op_number: OpNumber,
    commit_number: OpNumber,
    log: BoundedArray(LogEntry, MAX_LOG_SIZE),

    // For deduplication
    client_table: HashMap(ClientId, struct {
        last_request_id: RequestId,
        last_result: ?Result,
    }),

    // View change state
    view_change_votes: u8,
    do_view_change_messages: BoundedArray(DoViewChangeMsg, MAX_REPLICAS),
};
```

### Message Types

```zig
const Message = union(enum) {
    // Normal operation
    request: RequestMsg,
    prepare: PrepareMsg,
    prepare_ok: PrepareOkMsg,
    commit: CommitMsg,
    reply: ReplyMsg,

    // View change
    start_view_change: StartViewChangeMsg,
    do_view_change: DoViewChangeMsg,
    start_view: StartViewMsg,

    // Recovery
    recovery: RecoveryMsg,
    recovery_response: RecoveryResponseMsg,
};

const PrepareMsg = struct {
    view_number: ViewNumber,
    op_number: OpNumber,
    commit_number: OpNumber,
    command: Command,
    client_id: ClientId,
    request_id: RequestId,
};

const PrepareOkMsg = struct {
    view_number: ViewNumber,
    op_number: OpNumber,
    replica_id: ReplicaId,
};
```

### DST-Friendly I/O Interface

```zig
// All I/O goes through this interface
// In production: real network, real time
// In tests: simulated network, simulated time

const IO = struct {
    sendFn: *const fn (self: *IO, to: ReplicaId, msg: Message) void,
    setTimerFn: *const fn (self: *IO, delay_ms: u64, callback: TimerCallback) TimerId,
    cancelTimerFn: *const fn (self: *IO, timer_id: TimerId) void,
    nowFn: *const fn (self: *IO) Timestamp,
    randomFn: *const fn (self: *IO) u64,  // For jitter, etc.

    pub fn send(self: *IO, to: ReplicaId, msg: Message) void {
        return self.sendFn(self, to, msg);
    }

    pub fn setTimer(self: *IO, delay_ms: u64, callback: TimerCallback) TimerId {
        return self.setTimerFn(self, delay_ms, callback);
    }

    pub fn now(self: *IO) Timestamp {
        return self.nowFn(self);
    }
};

// VRR replica takes IO as parameter
const VRRReplica = struct {
    io: *IO,
    state: VRRState,
    state_machine: *StateMachine,

    pub fn init(io: *IO, config: Config) VRRReplica {
        return .{
            .io = io,
            .state = VRRState.init(config),
            .state_machine = config.state_machine,
        };
    }

    pub fn onMessage(self: *VRRReplica, from: ReplicaId, msg: Message) void {
        // Process message, potentially send responses via self.io
    }

    pub fn onTimer(self: *VRRReplica, timer_id: TimerId) void {
        // Handle timer expiry (heartbeats, view change timeouts)
    }
};
```

### Testing with DST

```zig
const SimulatedIO = struct {
    // Simulated network with controllable delays, drops, reordering
    network: SimulatedNetwork,
    // Simulated time that only advances when we say so
    current_time: Timestamp,
    // Pending timers
    timers: PriorityQueue(Timer),
    // Random seed for reproducibility
    prng: std.rand.DefaultPrng,

    // IO interface implementation
    io: IO,

    pub fn init(seed: u64) SimulatedIO {
        var self = SimulatedIO{
            .network = SimulatedNetwork.init(),
            .current_time = 0,
            .timers = PriorityQueue(Timer).init(),
            .prng = std.rand.DefaultPrng.init(seed),
            .io = undefined,
        };
        self.io = .{
            .sendFn = simulatedSend,
            .setTimerFn = simulatedSetTimer,
            .cancelTimerFn = simulatedCancelTimer,
            .nowFn = simulatedNow,
            .randomFn = simulatedRandom,
        };
        return self;
    }

    pub fn tick(self: *SimulatedIO) void {
        // Advance time, deliver messages, fire timers
        // This is where we inject failures, delays, etc.
    }

    pub fn partitionNetwork(self: *SimulatedIO, partition: []const ReplicaId) void {
        // Simulate network partition
    }

    pub fn healNetwork(self: *SimulatedIO) void {
        // Restore connectivity
    }
};

test "VRR survives leader failure" {
    var sim = SimulatedIO.init(12345);
    var replicas: [3]VRRReplica = undefined;

    // Initialize replicas
    for (&replicas, 0..) |*r, i| {
        r.* = VRRReplica.init(&sim.io, .{ .replica_id = @intCast(i) });
    }

    // Submit a request
    replicas[0].onMessage(.client, .{ .request = ... });

    // Run until committed
    while (!isCommitted()) {
        sim.tick();
    }

    // Kill the leader
    sim.partitionNetwork(&.{.replica_0});

    // Submit another request to a backup
    replicas[1].onMessage(.client, .{ .request = ... });

    // Run until view change and new commit
    while (!isCommitted()) {
        sim.tick();
    }

    // Verify correctness
    try expect(replicas[1].state.view_number > 0);
    try expect(replicas[1].state.commit_number == 2);
}
```

---

## Latency Analysis

### Single Global Group (Option A)

```
Operation: Schedule workload

Client (US-East) → Router (US-East) → CP Leader (US-East)
                                            │
                                     Prepare to all
                                            │
                          ┌─────────────────┼─────────────────┐
                          │                 │                 │
                          ▼                 ▼                 ▼
                    CP (US-West)      CP (EU-West)      CP (AP-South)
                      1-5ms            100-150ms          200-250ms
                          │                 │                 │
                          └─────────────────┼─────────────────┘
                                            │
                                     Wait for majority (f+1)
                                            │
                              Best case: US-West responds first
                              Latency: ~5ms

                              Worst case: need EU-West
                              Latency: ~150ms

If leader is NOT in client's region:
Client (AP-South) → Router (AP-South) → CP Leader (US-East)
                         200ms                  │
                                         ... same as above ...

Total latency: 200ms + 150ms = 350ms
```

### Regional Groups (Option B)

```
Operation: Schedule workload (local region)

Client (US-East) → Router (US-East) → CP Leader (US-East)
                                            │
                                     Prepare to local replicas
                                            │
                          ┌─────────────────┼─────────────────┐
                          │                 │                 │
                          ▼                 ▼                 ▼
                    CP-1 (US-East)   CP-2 (US-East)   CP-3 (US-East)
                        1ms              1ms              1ms
                          │                 │                 │
                          └─────────────────┼─────────────────┘
                                            │
                                     Commit
                                            │
Total latency: ~2-5ms (always)


Operation: Cross-region schedule

Client (US-East) → Router (US-East) → CP (US-East) → CP (EU-West)
                                            │              │
                                     "Please schedule"  VRR consensus
                                            │              │
                                            │         ~100-150ms
                                            │              │
                                     Response ◄────────────┘

Total latency: ~150-200ms (but rare operation)
```

### Hierarchical (Option C)

```
Operation: Create app (global)

Client → Global Coordinator → VRR consensus
                                   │
                            ~100-150ms (cross-region quorum)
                                   │
                            App registered globally
                                   │
                            Notify home region

Total latency: ~200-300ms (infrequent)


Operation: Schedule workload (regional)

Client → Router → Regional CP → VRR consensus
                                    │
                              ~2-5ms (local quorum)
                                    │
Total latency: ~5-10ms (frequent)
```

---

## User Requirements Context

Before evaluating options, it's important to understand what users actually care about:

| Priority | Requirement | Implication for Consensus |
|----------|-------------|--------------------------|
| 1 | Correct hardware (GPU type, count) | Pool matching must be accurate |
| 2 | Timely scheduling | Cold-start latency matters |
| 3 | Timely request routing | Routing should NOT hit consensus |
| 4 | Minimize latency | Prefer nearby compute |
| 5 | Minimize cost | Cost-aware scheduling |

**Key insight:** Most users don't care about provider or region unless:
- Specific latency requirements (user is in EU, wants EU compute)
- Jurisdiction/compliance (data must stay in EU)
- Cost optimization (specific provider is cheaper)

Apps will naturally gravitate toward certain regions/providers based on requirements, but users generally don't want to manage this explicitly.

---

## What Operations Hit Consensus?

Critical question: **Which operations are on the hot path?**

```
REQUEST FLOW - Where does consensus matter?

┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│  Client  │────►│  Router  │────►│   Pool   │────►│   GPU    │
└──────────┘     └──────────┘     └──────────┘     └──────────┘
                      │
                      │ Cache lookup (no consensus)
                      │
                 ┌────▼────┐
                 │ Routing │
                 │  Cache  │
                 └─────────┘

HOT PATH: Client → Router → Pool → GPU
- No consensus required per-request
- Router uses cached app→pool mapping
- Cache refreshed periodically OR on miss

COLD PATH (scale-up needed):
                      │
                      │ Queue builds up
                      │
                 ┌────▼────────┐
                 │  Autoscaler │ ← Observes queue depth
                 │  (async)    │
                 └──────┬──────┘
                        │
                        │ Scale decision
                        │
                 ┌──────▼──────┐
                 │  Scheduler  │ ← CONSENSUS HERE
                 │             │   (allocate capacity)
                 └──────┬──────┘
                        │
                        │ Placement
                        │
                 ┌──────▼──────┐
                 │    Agent    │
                 │  (on node)  │
                 └─────────────┘
```

**Operations that require consensus:**

| Operation | Frequency | On Hot Path? | Latency Tolerance |
|-----------|-----------|--------------|-------------------|
| App create/update | Rare | No | Seconds acceptable |
| Scale decision | Medium (per cold-start) | Yes, but async | 100-500ms acceptable |
| Capacity allocation | Medium | Yes, but async | 100-500ms acceptable |
| Node registration | Rare | No | Seconds acceptable |
| Pool membership change | Rare | No | Seconds acceptable |
| **Request routing** | **Very High** | **Yes** | **Must be <10ms** |

**Key insight:** Request routing is the hot path, but it doesn't need consensus. It uses cached data. Consensus only happens during:
1. Cold starts (scheduling new capacity)
2. Configuration changes (rare)
3. Infrastructure changes (node join/leave)

This means **Option A might be viable** if we accept that cold-start scheduling adds ~100-200ms of consensus latency. For many workloads, this is acceptable since:
- Cold starts are already slow (container pull, model load)
- An extra 100ms on a 5-30 second cold start is ~1-2%
- Warm requests don't hit consensus at all

---

## Revised Option Analysis

### Option A: Single Global Group

**Now more viable because:**
- Hot path (request routing) doesn't hit consensus
- Consensus latency only affects cold starts
- Simpler operational model

**Latency scenarios:**

```
Scenario 1: VRR nodes spread globally
- US-East, EU-West, AP-South (3 nodes)
- Write latency: ~150ms (wait for EU-West)
- Acceptable for scheduling, not for routing

Scenario 2: VRR nodes in same continent
- US-East, US-West, US-Central (3 nodes)
- Write latency: ~30-50ms
- Better, but introduces correlated failure risk

Scenario 3: VRR nodes in same region, different AZs
- US-East-1a, US-East-1b, US-East-1c
- Write latency: ~5-10ms
- Fast, but single-region failure takes out consensus
```

**Decision factor:** How much cold-start latency can we add?
- If 100-200ms is acceptable → Global group works
- If cold-start must be <50ms → Need regional groups

### Option B: Regional Groups

**Advantages clearer now:**
- Cold-start scheduling is fast (~5ms consensus)
- Regional failure is isolated
- Cross-region operations are explicit

**The "home region" question:**
- Users don't care about home region conceptually
- But internally, we might assign apps to regions based on:
  - First deployment location
  - User's account region
  - Requirements (if they specify region preference)
- This is an implementation detail, not user-facing

### Option C: Hierarchical

**Makes sense if:**
- We want global consistency for some things (app registry)
- But regional speed for others (scheduling)

**Might be over-engineering if:**
- We can make everything regional
- Cross-region coordination is rare enough to be explicit

---

## Viable Options Summary

**Ruled out:** Option D (leaderless) - consistency too weak for capacity allocation

**Still viable:**

| Option | Best When | Trade-off |
|--------|-----------|-----------|
| A: Global | Cold-start latency tolerance >100ms, operational simplicity valued | Higher scheduling latency |
| B: Regional | Cold-start latency critical, regional autonomy acceptable | More complex operations |
| C: Hierarchical | Need both global consistency AND regional speed | Most complex |

---

## Decision Criteria (for future)

When we're ready to decide, these questions will help:

1. **Cold-start latency budget**
   - What's the P99 cold-start target?
   - How much can consensus contribute?
   - Current baseline needed

2. **Cross-region operation frequency**
   - How often do apps span regions?
   - How often does failover happen?
   - This determines if B's complexity is justified

3. **Operational preference**
   - Single global brain (Option A) is simpler to reason about
   - Regional autonomy (Option B) is more resilient
   - What does the ops team prefer?

4. **Failure scenarios**
   - What's the blast radius of a region failure?
   - Option A: depends on quorum placement
   - Option B: isolated to that region

---

## Decision Points Still Open

1. **Cold-start latency target**
   - This is the key driver for A vs B/C
   - Need to measure current baseline

2. **Cross-region failover requirements**
   - Automatic vs manual?
   - How fast must failover complete?
   - This affects cross-region coordination design

3. **VRR group placement** (if Option A)
   - Same continent (fast but correlated risk)?
   - Global (slower but independent failures)?

4. **App-to-region assignment** (if Option B/C)
   - Automatic based on first request origin?
   - Explicit user choice?
   - Based on requirements matching?

---

## Component-Level Failure Analysis

This section analyzes failure scenarios for each Hivemind component under different consensus topologies.

### Component Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           HIVEMIND SYSTEM                                    │
│                                                                             │
│  EXTERNAL                                                                   │
│  ┌─────────┐                                                                │
│  │ Client  │                                                                │
│  └────┬────┘                                                                │
│       │                                                                     │
│  ─────┼─────────────────────────────────────────────────────────────────   │
│       │                                                                     │
│  EDGE LAYER                                                                 │
│  ┌────▼────┐     ┌─────────┐     ┌─────────┐                               │
│  │ Router  │     │ Router  │     │ Router  │    (N routers per region)     │
│  │   #1    │     │   #2    │     │   #N    │                               │
│  └────┬────┘     └────┬────┘     └────┬────┘                               │
│       │               │               │                                     │
│  ─────┼───────────────┼───────────────┼─────────────────────────────────   │
│       │               │               │                                     │
│  CONTROL PLANE                                                              │
│  ┌────▼───────────────▼───────────────▼────┐                               │
│  │          Hivemind Control Plane          │                               │
│  │  ┌─────────────────────────────────┐    │                               │
│  │  │         VRR Consensus           │    │                               │
│  │  │   ┌─────┐ ┌─────┐ ┌─────┐      │    │                               │
│  │  │   │ CP1 │ │ CP2 │ │ CP3 │      │    │  (3-5 nodes in VRR group)     │
│  │  │   └─────┘ └─────┘ └─────┘      │    │                               │
│  │  └─────────────────────────────────┘    │                               │
│  │                                          │                               │
│  │  Components:                             │                               │
│  │  - Scheduler (placement decisions)       │                               │
│  │  - Autoscaler (scale up/down)           │                               │
│  │  - Pool Manager (node membership)        │                               │
│  │  - App Registry (configurations)         │                               │
│  └──────────────────┬───────────────────────┘                               │
│                     │                                                       │
│  ───────────────────┼───────────────────────────────────────────────────   │
│                     │                                                       │
│  DATA PLANE                                                                 │
│  ┌──────────────────▼───────────────────┐                                  │
│  │              GPU Pools                │                                  │
│  │  ┌─────────────────────────────────┐ │                                  │
│  │  │           Pool A                 │ │                                  │
│  │  │  ┌───────┐ ┌───────┐ ┌───────┐  │ │                                  │
│  │  │  │ Node  │ │ Node  │ │ Node  │  │ │                                  │
│  │  │  │+Agent │ │+Agent │ │+Agent │  │ │  (Agent runs on every node)     │
│  │  │  └───────┘ └───────┘ └───────┘  │ │                                  │
│  │  └─────────────────────────────────┘ │                                  │
│  └──────────────────────────────────────┘                                  │
│                                                                             │
│  ───────────────────────────────────────────────────────────────────────   │
│                                                                             │
│  SUPPORTING SERVICES                                                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                         │
│  │  Honeycomb  │  │  Beekeeper  │  │   Turso     │                         │
│  │  (Registry) │  │  (Builds)   │  │  (Metadata) │                         │
│  └─────────────┘  └─────────────┘  └─────────────┘                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Failure Scenario Matrix

#### 1. Router Failures

| Scenario | Impact | Recovery | Consensus Dependency |
|----------|--------|----------|---------------------|
| Single router crash | Traffic shifts to other routers | Automatic (load balancer health check) | None |
| All routers in region | Region cannot serve traffic | DNS failover to other region | None |
| Router ↔ CP connection lost | Router serves stale cache | Fallback to last-known routing | Read-only degraded mode |

**Router failure details by consensus option:**

```
ROUTER FAILURE - All options behave similarly

Option A (Global):
┌─────────────────────────────────────────────────────────────────┐
│  Router crashes                                                  │
│       │                                                         │
│       ▼                                                         │
│  Load balancer detects (health check fails)                     │
│       │                                                         │
│       ▼                                                         │
│  Traffic routes to surviving routers                            │
│       │                                                         │
│       ▼                                                         │
│  Queued requests on crashed router: LOST                        │
│  (Clients retry, requests re-queued on healthy router)          │
│                                                                 │
│  Impact: Brief request failures during failover (~seconds)      │
│  Consensus: Not involved - routers are stateless                │
└─────────────────────────────────────────────────────────────────┘

Options B & C: Same behavior - routers don't participate in consensus
```

**Mitigation strategies:**
- Multiple routers per region (minimum 3)
- Keep request queues small (aggressive autoscaling)
- Client-side retry with idempotency keys
- Request queue replication (optional, adds complexity)

---

#### 2. Control Plane Failures

This is where consensus options diverge significantly.

**Option A: Single Global VRR Group**

```
CONTROL PLANE FAILURE - Option A

Scenario: 1 of 3 CP nodes fails
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   ┌─────┐    ┌─────┐    ┌─────┐                                │
│   │ CP1 │    │ CP2 │    │ CP3 │                                │
│   │ ███ │    │     │    │     │  ← CP1 fails                   │
│   └─────┘    └─────┘    └─────┘                                │
│                                                                 │
│   Quorum: 2 of 3 needed                                        │
│   CP2 + CP3 = quorum ✓                                         │
│                                                                 │
│   If CP1 was leader:                                           │
│   - View change triggered (~100-500ms)                         │
│   - CP2 or CP3 becomes leader                                  │
│   - Operations resume                                          │
│                                                                 │
│   If CP1 was follower:                                         │
│   - No view change needed                                      │
│   - Operations continue immediately                            │
│                                                                 │
│   Impact: Brief pause if leader fails, otherwise none          │
└─────────────────────────────────────────────────────────────────┘

Scenario: 2 of 3 CP nodes fail (no quorum)
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   ┌─────┐    ┌─────┐    ┌─────┐                                │
│   │ CP1 │    │ CP2 │    │ CP3 │                                │
│   │ ███ │    │ ███ │    │     │  ← CP1, CP2 fail               │
│   └─────┘    └─────┘    └─────┘                                │
│                                                                 │
│   Quorum: 2 of 3 needed                                        │
│   Only CP3 alive = NO quorum ✗                                 │
│                                                                 │
│   WRITES BLOCKED:                                              │
│   - Cannot schedule new workloads                              │
│   - Cannot allocate capacity                                   │
│   - Cannot update app configs                                  │
│                                                                 │
│   READS DEGRADED:                                              │
│   - Routers use stale cache                                    │
│   - Existing workloads continue running                        │
│   - No new cold starts                                         │
│                                                                 │
│   Impact: SEVERE - no scheduling until quorum restored         │
└─────────────────────────────────────────────────────────────────┘

Scenario: Network partition (CP nodes can't reach each other)
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Region A          │ PARTITION │          Region B             │
│   ┌─────┐          │           │          ┌─────┐              │
│   │ CP1 │          │     X     │          │ CP2 │              │
│   │     │◄─────────┼───────────┼─────────►│     │              │
│   └─────┘          │           │          └─────┘              │
│       ▲            │           │              ▲                │
│       │            │           │              │                │
│       │            │           │              │                │
│       ▼            │           │              ▼                │
│   ┌─────┐          │           │          (alone)              │
│   │ CP3 │          │           │                               │
│   └─────┘          │           │                               │
│                    │           │                               │
│   If CP1+CP3 in Region A:                                      │
│   - Region A has quorum, continues operating                   │
│   - Region B's CP2 isolated, read-only                        │
│   - Region B routers use stale cache                          │
│                                                                 │
│   If partition splits 1-1-1:                                   │
│   - NO quorum anywhere                                         │
│   - All regions degraded to read-only                         │
│                                                                 │
│   Impact: Depends on partition pattern                         │
└─────────────────────────────────────────────────────────────────┘
```

**Option B: Regional VRR Groups**

```
CONTROL PLANE FAILURE - Option B

Scenario: 1 CP node fails in US-East
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   US-EAST VRR                    EU-WEST VRR                   │
│   ┌─────┐ ┌─────┐ ┌─────┐       ┌─────┐ ┌─────┐ ┌─────┐       │
│   │ CP1 │ │ CP2 │ │ CP3 │       │ CP1 │ │ CP2 │ │ CP3 │       │
│   │ ███ │ │     │ │     │       │     │ │     │ │     │       │
│   └─────┘ └─────┘ └─────┘       └─────┘ └─────┘ └─────┘       │
│                                                                 │
│   US-East: CP2+CP3 = quorum ✓                                  │
│   EU-West: Unaffected                                          │
│                                                                 │
│   Impact: Minimal - US-East continues, EU-West unaware         │
└─────────────────────────────────────────────────────────────────┘

Scenario: Entire US-East region fails
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   US-EAST (FAILED)               EU-WEST (HEALTHY)             │
│   ┌─────┐ ┌─────┐ ┌─────┐       ┌─────┐ ┌─────┐ ┌─────┐       │
│   │ ███ │ │ ███ │ │ ███ │       │     │ │     │ │     │       │
│   └─────┘ └─────┘ └─────┘       └─────┘ └─────┘ └─────┘       │
│                                                                 │
│   US-East apps: UNAVAILABLE                                    │
│   - Cannot schedule in US-East                                 │
│   - Cannot access US-East pools                                │
│   - Routers return errors for US-East-only apps                │
│                                                                 │
│   EU-West apps: UNAFFECTED                                     │
│   - Full functionality                                         │
│   - No awareness of US-East failure                            │
│                                                                 │
│   Cross-region apps (if any):                                  │
│   - Can failover to EU-West                                    │
│   - Requires explicit failover protocol                        │
│                                                                 │
│   Impact: US-East isolated, EU-West continues                  │
└─────────────────────────────────────────────────────────────────┘

Scenario: Cross-region network partition
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   US-EAST            │ PARTITION │            EU-WEST          │
│   ┌─────────────┐   │           │   ┌─────────────┐            │
│   │ VRR Group   │   │     X     │   │ VRR Group   │            │
│   │ (healthy)   │◄──┼───────────┼──►│ (healthy)   │            │
│   └─────────────┘   │           │   └─────────────┘            │
│                     │           │                              │
│   Both regions have local quorum                               │
│   Both continue operating independently                        │
│   Cross-region gossip: STALE                                   │
│   Cross-region scheduling: BLOCKED                             │
│                                                                 │
│   Impact: Regions isolated but functional                      │
└─────────────────────────────────────────────────────────────────┘
```

**Option C: Hierarchical**

```
CONTROL PLANE FAILURE - Option C

Scenario: Global coordinator fails
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   GLOBAL COORDINATOR (FAILED)                                  │
│   ┌─────┐ ┌─────┐ ┌─────┐                                      │
│   │ ███ │ │ ███ │ │     │  ← 2 of 3 fail, no quorum           │
│   └─────┘ └─────┘ └─────┘                                      │
│       │       │       │                                        │
│       X       X       │                                        │
│       │       │       │                                        │
│   ┌───▼───┐ ┌─▼─────┐ │                                        │
│   │US-EAST│ │EU-WEST│ │                                        │
│   │  VRR  │ │  VRR  │ │                                        │
│   │(okay) │ │(okay) │ │                                        │
│   └───────┘ └───────┘                                          │
│                                                                 │
│   BLOCKED:                                                     │
│   - New app creation                                           │
│   - App deletion                                               │
│   - Cross-region app assignment                                │
│                                                                 │
│   CONTINUES:                                                   │
│   - Scheduling for existing apps                               │
│   - Local scaling                                              │
│   - Request routing                                            │
│                                                                 │
│   Impact: No new apps, but existing apps fully functional      │
└─────────────────────────────────────────────────────────────────┘

Scenario: Regional CP fails (US-East)
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   GLOBAL COORDINATOR (HEALTHY)                                 │
│   ┌─────┐ ┌─────┐ ┌─────┐                                      │
│   │     │ │     │ │     │                                      │
│   └─────┘ └─────┘ └─────┘                                      │
│       │       │       │                                        │
│       │       │       │                                        │
│   ┌───▼───┐ ┌─▼─────┐                                          │
│   │US-EAST│ │EU-WEST│                                          │
│   │ FAILED│ │  VRR  │                                          │
│   │███████│ │(okay) │                                          │
│   └───────┘ └───────┘                                          │
│                                                                 │
│   Global coordinator can:                                      │
│   - Detect US-East failure                                     │
│   - Reassign US-East apps to EU-West                          │
│   - Update app routing                                         │
│                                                                 │
│   Impact: US-East apps can failover to EU-West automatically   │
└─────────────────────────────────────────────────────────────────┘
```

**CP Failure Summary:**

| Scenario | Option A | Option B | Option C |
|----------|----------|----------|----------|
| 1 node fails | View change, continues | Regional view change | Depends on which layer |
| Lose quorum | **ALL scheduling stops** | Only affected region stops | Depends on which layer |
| Region fails | Depends on node placement | Other regions unaffected | Other regions + global unaffected |
| Cross-region partition | May lose quorum | Regions independent | Global may lose quorum |

---

#### 3. Agent Failures

Agents run on every GPU node. They're not in the consensus group but interact with it.

```
AGENT FAILURE

Scenario: Single agent crashes
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Pool                                                          │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐                        │
│   │  Node1  │  │  Node2  │  │  Node3  │                        │
│   │ +Agent  │  │ +Agent  │  │ +Agent  │                        │
│   │  ███    │  │         │  │         │  ← Agent on Node1 dies │
│   └─────────┘  └─────────┘  └─────────┘                        │
│                                                                 │
│   Detection:                                                    │
│   - CP stops receiving heartbeats from Node1                   │
│   - After timeout (e.g., 30s), node marked unhealthy           │
│                                                                 │
│   Impact on Node1:                                              │
│   - Existing containers: Continue running (no agent needed)    │
│   - New scheduling: Blocked (agent can't accept work)          │
│   - Metrics: Not collected                                     │
│   - Logs: Not forwarded                                        │
│                                                                 │
│   Impact on cluster:                                            │
│   - CP removes Node1 from pool                                 │
│   - New requests route to Node2/Node3                          │
│   - Existing requests to Node1: Timeout and retry              │
│                                                                 │
│   Recovery:                                                     │
│   - Agent restarts (systemd/k8s restarts it)                   │
│   - Re-registers with CP                                       │
│   - Node rejoins pool                                          │
│                                                                 │
│   Consensus dependency: None (agent is client of CP)           │
└─────────────────────────────────────────────────────────────────┘

Scenario: Agent loses connection to CP
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Agent                         Control Plane                   │
│   ┌─────────┐                   ┌─────────────┐                │
│   │         │        X          │             │                │
│   │  Node1  │◄──────────────────│     VRR     │                │
│   │         │   (network down)  │             │                │
│   └─────────┘                   └─────────────┘                │
│                                                                 │
│   Agent behavior:                                               │
│   - Continues running existing workloads                       │
│   - Cannot accept new work (CP can't reach it)                 │
│   - Buffers metrics locally (replay on reconnect)              │
│   - Retries CP connection with backoff                         │
│                                                                 │
│   CP behavior:                                                  │
│   - Marks node as unhealthy after timeout                      │
│   - Stops scheduling to this node                              │
│   - May trigger replacement node provisioning                  │
│                                                                 │
│   Impact: Graceful degradation, no data loss                   │
└─────────────────────────────────────────────────────────────────┘
```

---

#### 4. Honeycomb (Registry) Failures

Honeycomb stores container images. Critical for cold starts.

```
HONEYCOMB FAILURE SCENARIOS

Component architecture:
┌─────────────────────────────────────────────────────────────────┐
│                         HONEYCOMB                                │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    OCI API (Go)                          │   │
│   │   - Handles push/pull requests                          │   │
│   │   - Stateless, horizontally scalable                    │   │
│   └───────────────────────┬─────────────────────────────────┘   │
│                           │                                     │
│   ┌───────────────────────┼─────────────────────────────────┐   │
│   │                       │                                 │   │
│   │    ┌──────────────────▼──────────────────┐              │   │
│   │    │           Turso (Metadata)           │              │   │
│   │    │   - Blob locations                   │              │   │
│   │    │   - Manifest data                    │              │   │
│   │    │   - Globally distributed SQLite      │              │   │
│   │    └─────────────────────────────────────┘              │   │
│   │                                                         │   │
│   │    ┌─────────────────────────────────────┐              │   │
│   │    │           S3 (Layer Storage)         │              │   │
│   │    │   - Actual image layers              │              │   │
│   │    │   - Per-region buckets               │              │   │
│   │    └─────────────────────────────────────┘              │   │
│   │                                                         │   │
│   │    ┌─────────────────────────────────────┐              │   │
│   │    │           P2P Network (Zig)          │              │   │
│   │    │   - Layer distribution               │              │   │
│   │    │   - Cache sharing between nodes      │              │   │
│   │    └─────────────────────────────────────┘              │   │
│   │                                                         │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

Scenario: OCI API service down
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   OCI API: DOWN                                                 │
│                                                                 │
│   Impact:                                                       │
│   - Cannot push new images                                     │
│   - Cannot pull images (for cold starts)                       │
│   - Existing running containers: UNAFFECTED                    │
│   - Warm requests: UNAFFECTED                                  │
│                                                                 │
│   Mitigation:                                                   │
│   - Multiple OCI API replicas behind LB                        │
│   - Agents cache pulled layers locally                         │
│   - P2P can serve cached layers without API                    │
│                                                                 │
│   Recovery:                                                     │
│   - OCI API is stateless, restart/scale up                     │
│                                                                 │
│   Blast radius: Cold starts blocked, warm traffic continues    │
└─────────────────────────────────────────────────────────────────┘

Scenario: Turso metadata database unavailable
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Turso: UNAVAILABLE (all replicas)                            │
│                                                                 │
│   Impact:                                                       │
│   - Cannot resolve image tags to digests                       │
│   - Cannot find layer locations                                │
│   - All pulls fail                                             │
│                                                                 │
│   Mitigation:                                                   │
│   - Turso has built-in replication (global SQLite)             │
│   - Read replicas can serve during primary issues              │
│   - Agent-side caching of recent manifests                     │
│                                                                 │
│   Recovery:                                                     │
│   - Turso recovers (managed service)                           │
│   - Or: Restore from backup                                    │
│                                                                 │
│   Blast radius: SEVERE - no image pulls until recovered        │
└─────────────────────────────────────────────────────────────────┘

Scenario: S3 bucket unavailable
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   S3 (us-east-1): UNAVAILABLE                                  │
│                                                                 │
│   Impact:                                                       │
│   - Layers stored in us-east-1 cannot be fetched              │
│   - Other region buckets: UNAFFECTED                          │
│                                                                 │
│   Mitigation:                                                   │
│   - Cross-region replication for critical layers               │
│   - P2P can serve layers from nodes that have them cached     │
│   - Fallback to secondary bucket                               │
│                                                                 │
│   Blast radius: Region-specific, mitigated by P2P              │
└─────────────────────────────────────────────────────────────────┘

Scenario: P2P network partitioned
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   P2P Network: PARTITIONED                                     │
│                                                                 │
│   Impact:                                                       │
│   - Nodes can't share layers with each other                   │
│   - Falls back to S3 for all pulls                            │
│   - Slower pulls, higher S3 costs                              │
│                                                                 │
│   Mitigation:                                                   │
│   - P2P is optimization, not requirement                       │
│   - S3 is always available as fallback                         │
│                                                                 │
│   Blast radius: Performance degradation only                   │
└─────────────────────────────────────────────────────────────────┘
```

**Honeycomb consensus dependency:**

| Component | Needs Consensus? | Notes |
|-----------|-----------------|-------|
| OCI API | No | Stateless, metadata in Turso |
| Turso | Internal (managed) | Turso handles its own replication |
| S3 | No | AWS manages consistency |
| P2P | No | Eventually consistent by design |

Honeycomb is **not dependent on Hivemind consensus** - it has its own consistency model via Turso.

---

#### 5. Beekeeper (Build Service) Failures

```
BEEKEEPER FAILURE SCENARIOS

Component architecture:
┌─────────────────────────────────────────────────────────────────┐
│                         BEEKEEPER                                │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    API Service (Go)                      │   │
│   │   - Accepts build requests                              │   │
│   │   - Manages build queue                                 │   │
│   └───────────────────────┬─────────────────────────────────┘   │
│                           │                                     │
│   ┌───────────────────────┼─────────────────────────────────┐   │
│   │                       │                                 │   │
│   │    ┌──────────────────▼──────────────────┐              │   │
│   │    │           SQS (Build Queue)          │              │   │
│   │    └─────────────────────────────────────┘              │   │
│   │                       │                                 │   │
│   │    ┌──────────────────▼──────────────────┐              │   │
│   │    │       BuildKit Worker Pool           │              │   │
│   │    │   ┌─────┐ ┌─────┐ ┌─────┐           │              │   │
│   │    │   │ BK1 │ │ BK2 │ │ BK3 │  (spot)   │              │   │
│   │    │   └─────┘ └─────┘ └─────┘           │              │   │
│   │    └─────────────────────────────────────┘              │   │
│   │                       │                                 │   │
│   │    ┌──────────────────▼──────────────────┐              │   │
│   │    │           S3 (Build Cache)           │              │   │
│   │    └─────────────────────────────────────┘              │   │
│   │                                                         │   │
│   └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

Scenario: Beekeeper API down
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Impact:                                                       │
│   - Cannot submit new builds                                   │
│   - In-progress builds: Continue (workers poll SQS directly)   │
│   - Deployments using existing images: UNAFFECTED              │
│                                                                 │
│   Blast radius: New deployments blocked, existing continue     │
└─────────────────────────────────────────────────────────────────┘

Scenario: BuildKit workers all terminated (spot reclaim)
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Impact:                                                       │
│   - Build queue grows                                          │
│   - No builds complete                                         │
│                                                                 │
│   Recovery:                                                     │
│   - Auto-scaling provisions new workers                        │
│   - Builds resume from SQS queue                               │
│   - Cache in S3 speeds up rebuilds                             │
│                                                                 │
│   Blast radius: Build latency spike, but no data loss          │
└─────────────────────────────────────────────────────────────────┘

Scenario: S3 build cache unavailable
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Impact:                                                       │
│   - Builds still work, but slower (no cache hits)              │
│   - Higher CPU/time cost                                       │
│                                                                 │
│   Blast radius: Performance only                               │
└─────────────────────────────────────────────────────────────────┘
```

**Beekeeper consensus dependency:** None - Beekeeper is independent of Hivemind consensus.

---

#### 6. Pool/Capacity Failures

```
POOL FAILURE SCENARIOS

Scenario: GPU node dies mid-request
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Request in flight:                                           │
│   Client → Router → Pool → Node (DIES)                         │
│                                                                 │
│   Detection:                                                    │
│   - Router TCP connection breaks                               │
│   - Or: Request timeout                                        │
│                                                                 │
│   Recovery:                                                     │
│   - Router retries to different node in pool                   │
│   - Or: Returns error to client (client retries)               │
│                                                                 │
│   Consensus impact:                                             │
│   - CP eventually learns node is dead (heartbeat timeout)      │
│   - CP updates pool membership                                 │
│   - CP may trigger replacement provisioning                    │
│                                                                 │
│   Blast radius: Single request, automatic retry                │
└─────────────────────────────────────────────────────────────────┘

Scenario: Entire pool becomes unhealthy
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Pool A (H100s in us-east):                                   │
│   ┌─────┐ ┌─────┐ ┌─────┐                                      │
│   │ ███ │ │ ███ │ │ ███ │  ← All nodes fail                    │
│   └─────┘ └─────┘ └─────┘                                      │
│                                                                 │
│   Impact depends on app requirements:                          │
│                                                                 │
│   App requires: {gpu: h100, region: us-east}                   │
│   → No alternative pools, app unavailable                      │
│                                                                 │
│   App requires: {gpu: h100}  (any region)                      │
│   → Router fails over to Pool B in eu-west                     │
│                                                                 │
│   Consensus handling:                                           │
│   Option A: Global CP sees pool failure, updates routing      │
│   Option B: US-East CP reports to other regions via gossip    │
│   Option C: Global coordinator reassigns apps                  │
│                                                                 │
│   Blast radius: Apps locked to that pool                       │
└─────────────────────────────────────────────────────────────────┘

Scenario: Provider API unavailable (can't provision new capacity)
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   AWS API: UNAVAILABLE (or quota exceeded)                     │
│                                                                 │
│   Impact:                                                       │
│   - Cannot scale up in AWS                                     │
│   - Existing capacity continues working                        │
│   - Queue depth may grow if demand exceeds capacity            │
│                                                                 │
│   Mitigation:                                                   │
│   - Multi-provider: Fall back to Crusoe, Lambda Labs           │
│   - Pre-provisioned buffer capacity                            │
│                                                                 │
│   Consensus handling:                                           │
│   - CP scheduler tries alternative providers                   │
│   - Updates routing to favor providers with capacity           │
│                                                                 │
│   Blast radius: Reduced scaling ability, not immediate outage  │
└─────────────────────────────────────────────────────────────────┘
```

---

### Failure Impact Summary by Consensus Option

| Failure | Option A (Global) | Option B (Regional) | Option C (Hierarchical) |
|---------|-------------------|--------------------|-----------------------|
| **Single CP node** | View change (~100ms) | Regional view change | Depends on layer |
| **CP quorum loss** | ALL scheduling stops | Only affected region | Only affected layer |
| **Region failure** | May lose quorum | Region isolated, others OK | Region isolated, global may continue |
| **Cross-region partition** | May lose quorum | Regions independent | Global may lose quorum |
| **Router failure** | Same (stateless) | Same | Same |
| **Agent failure** | Same (not in consensus) | Same | Same |
| **Honeycomb failure** | Same (independent) | Same | Same |
| **Beekeeper failure** | Same (independent) | Same | Same |
| **Pool failure** | Global routing update | Regional + gossip | Global + regional update |

---

### Blast Radius Analysis

```
BLAST RADIUS BY CONSENSUS OPTION

Option A: Single Global VRR
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Failure: 2 of 3 CP nodes                                     │
│                                                                 │
│   ████████████████████████████████████████████████████████████ │
│   ^                                                           ^ │
│   ALL SCHEDULING STOPS GLOBALLY                                │
│                                                                 │
│   Warm traffic continues (routers use cache)                   │
│   Cold starts: BLOCKED                                         │
│   New deployments: BLOCKED                                     │
│   Config changes: BLOCKED                                      │
│                                                                 │
│   Blast radius: GLOBAL                                         │
└─────────────────────────────────────────────────────────────────┘

Option B: Regional VRR Groups
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Failure: US-East VRR loses quorum                            │
│                                                                 │
│   US-EAST                         EU-WEST                      │
│   ██████████████████              ░░░░░░░░░░░░░░░░░░           │
│   ^                ^              ^                ^           │
│   SCHEDULING STOPS                UNAFFECTED                   │
│                                                                 │
│   US-East:                        EU-West:                     │
│   - Cold starts: BLOCKED          - Fully operational          │
│   - Warm traffic: Continues       - No impact                  │
│                                                                 │
│   Blast radius: REGIONAL                                       │
└─────────────────────────────────────────────────────────────────┘

Option C: Hierarchical
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Failure: Global coordinator loses quorum                     │
│                                                                 │
│   GLOBAL:  ████████████████████ (new apps blocked)             │
│   US-EAST: ░░░░░░░░░░░░░░░░░░░░ (scheduling continues)         │
│   EU-WEST: ░░░░░░░░░░░░░░░░░░░░ (scheduling continues)         │
│                                                                 │
│   Existing apps: FULLY OPERATIONAL                             │
│   New app creation: BLOCKED                                    │
│   Cross-region changes: BLOCKED                                │
│                                                                 │
│   Blast radius: PARTIAL (metadata only)                        │
└─────────────────────────────────────────────────────────────────┘
```

---

### Recovery Time Objectives (RTO) by Scenario

| Scenario | Detection Time | Recovery Time | Notes |
|----------|---------------|---------------|-------|
| Single CP node failure | Immediate (heartbeat) | ~100-500ms (view change) | Automatic |
| CP quorum loss | Immediate | Manual (bring up nodes) | Depends on root cause |
| Router failure | ~5s (health check) | ~5s (LB reroutes) | Automatic |
| Agent failure | ~30s (heartbeat timeout) | ~60s (restart + register) | Automatic |
| Node failure | ~30s | Minutes (provision new) | May be automatic |
| Honeycomb API down | ~5s | ~5s (restart/scale) | Automatic |
| S3 unavailable | Immediate | AWS RTO | External dependency |
| Turso unavailable | Immediate | Turso RTO | External dependency |

---

## Request Lifecycle Analysis

Understanding how requests flow through the system is critical for evaluating consensus options. The request path differs significantly based on architecture choices.

### Scenario: EU User → US-Only App

Let's trace a request from a user in Europe to an app that only runs in US-East (due to requirements or data residency).

---

### Architecture Option 1: Regional Routers (No CDN)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    REGIONAL ROUTERS - NO CDN                                 │
│                                                                             │
│   User in EU                                                                │
│   ┌──────┐                                                                  │
│   │Client│                                                                  │
│   └───┬──┘                                                                  │
│       │                                                                     │
│       │ DNS resolves to nearest router (GeoDNS)                            │
│       │ → eu-west.router.hivemind.dev                                      │
│       │                                                                     │
│       ▼                                                                     │
│   ┌────────────────┐                                                        │
│   │  EU-West       │                                                        │
│   │  Router        │ ← Request arrives here first                          │
│   │                │                                                        │
│   │  1. Auth check │                                                        │
│   │  2. Lookup app │                                                        │
│   │  3. Find pools │ ← App only has pools in US-East                       │
│   │  4. ??? │                                                        │
│   └────────────────┘                                                        │
│                                                                             │
│   OPTION A: EU Router proxies to US-East pool                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EU Router ──────────────────────────────► US-East Pool            │   │
│   │              ~100ms RTT                     (GPU node)              │   │
│   │                                                                     │   │
│   │   Total latency: Client→EU Router + EU Router→US Pool + inference  │   │
│   │                   ~20ms           + ~100ms          + inference     │   │
│   │                                                                     │   │
│   │   Pros: Simple, single hop from router to compute                  │   │
│   │   Cons: EU Router holding connection for long inference            │   │
│   │         Router becomes bottleneck for cross-region traffic         │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   OPTION B: EU Router redirects client to US-East Router                   │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EU Router ──── 307 Redirect ────► Client                         │   │
│   │                                        │                           │   │
│   │                                        │ Follows redirect          │   │
│   │                                        ▼                           │   │
│   │                                    US-East Router → US-East Pool   │   │
│   │                                                                     │   │
│   │   Total latency: Client→EU Router + Client→US Router + US→Pool    │   │
│   │                   ~20ms + redirect + ~100ms         + ~local       │   │
│   │                                                                     │   │
│   │   Pros: US Router local to compute, lower router load              │   │
│   │   Cons: Extra round trip (redirect), client must follow redirect   │   │
│   │         Some clients don't handle redirects well                   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   OPTION C: EU Router returns US-East endpoint directly                    │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EU Router ──── {"endpoint": "us-east..."} ────► Client           │   │
│   │                                                      │             │   │
│   │                                                      │ Direct call │   │
│   │                                                      ▼             │   │
│   │                                                  US-East Pool      │   │
│   │                                                                     │   │
│   │   Pros: Minimal latency once endpoint known                        │   │
│   │   Cons: Client needs SDK support, bypasses router queueing         │   │
│   │         Lost observability at router level                         │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Architecture Option 2: Global Anycast Router (with CDN)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    GLOBAL ANYCAST WITH CDN                                   │
│                                                                             │
│   User in EU                                                                │
│   ┌──────┐                                                                  │
│   │Client│                                                                  │
│   └───┬──┘                                                                  │
│       │                                                                     │
│       │ DNS resolves to anycast IP                                         │
│       │ → api.hivemind.dev (anycast)                                       │
│       │                                                                     │
│       ▼                                                                     │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │                         CDN EDGE (Cloudflare/Fastly)                │    │
│   │                                                                    │    │
│   │   EU Edge PoP                                                      │    │
│   │   ┌────────────────────────────────────────────────────────────┐   │    │
│   │   │  1. TLS termination (close to user, fast handshake)        │   │    │
│   │   │  2. Auth validation (JWT verify at edge)                   │   │    │
│   │   │  3. Route to origin based on headers/path                  │   │    │
│   │   └────────────────────────────────────────────────────────────┘   │    │
│   │                           │                                        │    │
│   │                           │ CDN backbone (optimized routes)        │    │
│   │                           │                                        │    │
│   │                           ▼                                        │    │
│   │   ┌────────────────────────────────────────────────────────────┐   │    │
│   │   │                    ORIGIN SELECTION                         │   │    │
│   │   │                                                            │   │    │
│   │   │   CDN can route to nearest origin OR specific region       │   │    │
│   │   │   based on app requirements in headers/path                │   │    │
│   │   └────────────────────────────────────────────────────────────┘   │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                           │                                                 │
│                           ▼                                                 │
│   ┌────────────────────────────────────────────────────────────────────┐    │
│   │                    ORIGIN ROUTER (US-East)                          │    │
│   │                                                                    │    │
│   │   ┌────────────────────────────────────────────────────────────┐   │    │
│   │   │  1. Request already authed (CDN did it)                    │   │    │
│   │   │  2. Queue if needed (cold start)                           │   │    │
│   │   │  3. Forward to pool                                        │   │    │
│   │   └────────────────────────────────────────────────────────────┘   │    │
│   │                           │                                        │    │
│   │                           ▼                                        │    │
│   │                    US-East Pool (GPU nodes)                        │    │
│   └────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│   Latency breakdown:                                                        │
│   - Client → EU Edge: ~5-10ms (anycast, nearby PoP)                        │
│   - EU Edge → US Origin: ~80-100ms (CDN backbone, optimized)               │
│   - US Origin → US Pool: ~1-5ms (same region)                              │
│   - Total network: ~90-115ms + inference                                   │
│                                                                             │
│   Benefits:                                                                 │
│   - TLS termination at edge (faster handshake)                             │
│   - Auth at edge (reject bad requests early)                               │
│   - CDN backbone often faster than public internet                         │
│   - DDoS protection included                                               │
│   - Connection pooling from CDN to origin                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Request Lifecycle by Consensus Option

Now let's see how the consensus topology affects the request path:

#### Consensus Option A: Single Global VRR

```
REQUEST LIFECYCLE - OPTION A (GLOBAL VRR)

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   EU User → US-Only App                                                     │
│                                                                             │
│   ┌──────┐                                                                  │
│   │Client│                                                                  │
│   └───┬──┘                                                                  │
│       │                                                                     │
│       │ ①  DNS/Anycast to nearest router                                   │
│       ▼                                                                     │
│   ┌────────────────┐                                                        │
│   │  EU Router     │                                                        │
│   │                │                                                        │
│   │  ② Auth check  │ (local, fast)                                         │
│   │                │                                                        │
│   │  ③ Cache lookup│ app → pools                                           │
│   │    Cache HIT?  │──────────────────────────────────┐                    │
│   │       │        │                                  │                    │
│   │       │ NO     │                         YES      │                    │
│   │       ▼        │                                  │                    │
│   │  ④ Query CP    │                                  │                    │
│   │    (global)    │                                  │                    │
│   └───────┬────────┘                                  │                    │
│           │                                           │                    │
│           │ ~100-150ms (cross-region to CP leader)   │                    │
│           ▼                                           │                    │
│   ┌────────────────┐                                  │                    │
│   │  Global VRR    │                                  │                    │
│   │  (US-East)     │                                  │                    │
│   │                │                                  │                    │
│   │  Returns:      │                                  │                    │
│   │  - Pool list   │                                  │                    │
│   │  - Endpoints   │                                  │                    │
│   └───────┬────────┘                                  │                    │
│           │                                           │                    │
│           │ Response                                  │                    │
│           ▼                                           │                    │
│   ┌────────────────┐                                  │                    │
│   │  EU Router     │◄─────────────────────────────────┘                    │
│   │                │                                                        │
│   │  ⑤ Update cache│                                                        │
│   │                │                                                        │
│   │  ⑥ Pool has    │                                                        │
│   │    capacity?   │                                                        │
│   │       │        │                                                        │
│   │  YES  │   NO   │                                                        │
│   │       │   │    │                                                        │
│   │       │   ▼    │                                                        │
│   │       │  ⑦ Queue request                                               │
│   │       │    Signal CP for scale-up                                      │
│   │       │    (async, ~100-150ms)                                         │
│   │       │        │                                                        │
│   │       │        │ Wait for capacity...                                  │
│   │       │        │                                                        │
│   │       ▼        ▼                                                        │
│   │  ⑧ Forward to US-East Pool                                             │
│   │     ~100ms cross-region                                                │
│   └───────┬────────┘                                                        │
│           │                                                                 │
│           ▼                                                                 │
│   ┌────────────────┐                                                        │
│   │  US-East Pool  │                                                        │
│   │  (GPU Node)    │                                                        │
│   │                │                                                        │
│   │  ⑨ Run inference                                                       │
│   │                │                                                        │
│   └───────┬────────┘                                                        │
│           │                                                                 │
│           │ Response flows back same path                                  │
│           ▼                                                                 │
│   ┌──────┐                                                                  │
│   │Client│                                                                  │
│   └──────┘                                                                  │
│                                                                             │
│   LATENCY BREAKDOWN (warm, cache hit):                                     │
│   - Client → EU Router: ~20ms                                              │
│   - Auth + cache lookup: ~1ms                                              │
│   - EU Router → US Pool: ~100ms                                            │
│   - Inference: varies                                                       │
│   - Response back: ~100ms                                                  │
│   Total overhead: ~220ms + inference                                       │
│                                                                             │
│   LATENCY BREAKDOWN (cold, cache miss):                                    │
│   - Client → EU Router: ~20ms                                              │
│   - EU Router → Global CP: ~100-150ms (cache miss)                         │
│   - Queue + scale signal: ~100-150ms (async to CP)                         │
│   - Wait for scale-up: seconds to minutes                                  │
│   - EU Router → US Pool: ~100ms                                            │
│   - Inference: varies                                                       │
│   Total overhead: ~320ms + scale-up + inference                            │
│                                                                             │
│   KEY INSIGHT: Cache hit path is IDENTICAL across all options              │
│   Consensus only matters for cache miss and scaling                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Consensus Option B: Regional VRR Groups

```
REQUEST LIFECYCLE - OPTION B (REGIONAL VRR)

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   EU User → US-Only App                                                     │
│                                                                             │
│   Same flow until cache miss...                                            │
│                                                                             │
│   ┌────────────────┐                                                        │
│   │  EU Router     │                                                        │
│   │                │                                                        │
│   │  Cache MISS    │                                                        │
│   │       │        │                                                        │
│   │       ▼        │                                                        │
│   │  Query EU CP?  │ ← But app is in US-East!                              │
│   └───────┬────────┘                                                        │
│           │                                                                 │
│           │ PROBLEM: EU CP doesn't know about US-East apps                 │
│           │          (unless we have cross-region sync)                    │
│           │                                                                 │
│   SOLUTION A: All routers have app registry (gossiped)                     │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   App Registry (eventually consistent, gossiped)                   │   │
│   │   ┌─────────────────────────────────────────────────────────────┐   │   │
│   │   │  app_id: "user-app-123"                                     │   │   │
│   │   │  home_region: "us-east"                                     │   │   │
│   │   │  pools: ["us-east-h100-pool"]                               │   │   │
│   │   │  requirements: {gpu: h100, regions: [us-east]}              │   │   │
│   │   └─────────────────────────────────────────────────────────────┘   │   │
│   │                                                                     │   │
│   │   EU Router sees: "app is homed in US-East"                        │   │
│   │                                                                     │   │
│   │   Two sub-options:                                                 │   │
│   │                                                                     │   │
│   │   B1: EU Router proxies directly to US-East Pool                   │   │
│   │       (Router knows pool endpoints from gossip)                    │   │
│   │       Latency: Same as Option A                                    │   │
│   │                                                                     │   │
│   │   B2: EU Router forwards to US-East Router                         │   │
│   │       US-East Router handles queueing/scaling locally              │   │
│   │       Latency: Extra hop, but local scaling decisions              │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   SOLUTION B: Redirect to home region                                      │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EU Router returns: 307 Temporary Redirect                        │   │
│   │   Location: https://us-east.router.hivemind.dev/v1/...             │   │
│   │                                                                     │   │
│   │   Client follows redirect, hits US-East Router directly            │   │
│   │   US-East Router handles everything locally                        │   │
│   │                                                                     │   │
│   │   Latency: Extra round-trip for redirect                           │   │
│   │   Benefit: Clean separation, US-East CP handles scaling            │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   COLD START SCALING (B2 path):                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EU Router ──────► US-East Router ──────► US-East CP              │   │
│   │                                              │                     │   │
│   │                                              │ Scale decision      │   │
│   │                                              │ (local, fast)       │   │
│   │                                              │ ~5ms                │   │
│   │                                              ▼                     │   │
│   │                                          Scheduler                 │   │
│   │                                              │                     │   │
│   │                                              ▼                     │   │
│   │   EU Router ◄────── US-East Router ◄────── Pool ready             │   │
│   │                                                                     │   │
│   │   Scaling latency: ~5ms (local consensus)                          │   │
│   │   vs Option A: ~100-150ms (global consensus)                       │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Consensus Option C: Hierarchical

```
REQUEST LIFECYCLE - OPTION C (HIERARCHICAL)

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Similar to Option B, but with clearer separation:                        │
│                                                                             │
│   GLOBAL COORDINATOR owns:                                                 │
│   - App registry (which apps exist, where they're homed)                   │
│   - Region health (which regions are available)                            │
│                                                                             │
│   REGIONAL CP owns:                                                        │
│   - Pool state (nodes, capacity)                                           │
│   - Scheduling (placement decisions)                                       │
│   - Scaling (up/down decisions)                                            │
│                                                                             │
│   Request flow:                                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EU Router                                                         │   │
│   │       │                                                             │   │
│   │       │ Cache miss: "where is this app?"                           │   │
│   │       │                                                             │   │
│   │       ▼                                                             │   │
│   │   Query Global Coordinator (read-only, can use any replica)        │   │
│   │       │                                                             │   │
│   │       │ ~50-100ms (global read)                                    │   │
│   │       │                                                             │   │
│   │       ▼                                                             │   │
│   │   Response: "app homed in us-east"                                 │   │
│   │       │                                                             │   │
│   │       │ Cache this                                                 │   │
│   │       │                                                             │   │
│   │       ▼                                                             │   │
│   │   Forward to US-East Router                                        │   │
│   │       │                                                             │   │
│   │       │ ~100ms (cross-region)                                      │   │
│   │       │                                                             │   │
│   │       ▼                                                             │   │
│   │   US-East Router                                                   │   │
│   │       │                                                             │   │
│   │       │ Query local CP (fast, ~5ms)                                │   │
│   │       │                                                             │   │
│   │       ▼                                                             │   │
│   │   US-East Pool                                                     │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   Key difference from B:                                                   │
│   - Global reads from Global Coordinator (can be any replica)             │
│   - Global writes (new app creation) go through consensus                 │
│   - Regional operations don't touch global at all                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Request Path Comparison

| Aspect | Option A (Global) | Option B (Regional) | Option C (Hierarchical) |
|--------|-------------------|--------------------|-----------------------|
| **Cache hit path** | Identical | Identical | Identical |
| **Cache miss (app lookup)** | Global CP (~100-150ms) | Gossip/local cache or redirect | Global Coordinator read (~50-100ms) |
| **Scaling decision** | Global CP (~100-150ms) | Regional CP (~5ms) | Regional CP (~5ms) |
| **Cross-region request** | Router proxies directly | Router proxies or redirects | Router proxies via regional router |

---

### CDN Considerations

```
DO WE NEED A CDN?

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   BENEFITS OF CDN:                                                         │
│                                                                             │
│   1. TLS Termination at Edge                                               │
│      - TLS handshake completes at nearby PoP (~10ms vs ~100ms)            │
│      - Subsequent requests reuse connection                                │
│                                                                             │
│   2. DDoS Protection                                                       │
│      - CDN absorbs attack traffic                                          │
│      - Origin servers protected                                            │
│                                                                             │
│   3. Connection Pooling                                                    │
│      - CDN maintains persistent connections to origins                     │
│      - Reduces connection setup overhead                                   │
│                                                                             │
│   4. Geographic Distribution                                               │
│      - Anycast routing to nearest PoP                                      │
│      - Optimized backbone between PoPs                                     │
│                                                                             │
│   COSTS OF CDN:                                                            │
│                                                                             │
│   1. Extra Hop                                                             │
│      - Request goes: Client → CDN → Origin → Pool                         │
│      - But CDN backbone often faster than public internet                  │
│                                                                             │
│   2. Complexity                                                            │
│      - Another system to configure and monitor                             │
│      - Cache invalidation challenges (not relevant for us - no caching)   │
│                                                                             │
│   3. Cost                                                                  │
│      - Per-request pricing                                                 │
│      - For high-volume inference, could be significant                     │
│                                                                             │
│   RECOMMENDATION:                                                          │
│                                                                             │
│   For inference workloads, CDN is OPTIONAL:                               │
│   - Requests are not cacheable (dynamic inference)                        │
│   - Main benefit is TLS termination and DDoS protection                   │
│   - Can start without CDN, add later if needed                            │
│                                                                             │
│   If we use CDN:                                                           │
│   - Configure as pure proxy (no caching)                                  │
│   - Use Cloudflare Workers or Fastly Compute for edge auth                │
│   - Route to nearest origin that can serve the app                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Global vs Regional Router Deployment

```
ARCHITECTURE CHOICE: GLOBAL VS REGIONAL ROUTERS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OPTION 1: REGIONAL ROUTERS                                               │
│                                                                             │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                    │
│   │  US-East    │    │  EU-West    │    │  AP-South   │                    │
│   │  Routers    │    │  Routers    │    │  Routers    │                    │
│   │  (N nodes)  │    │  (N nodes)  │    │  (N nodes)  │                    │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                    │
│          │                  │                  │                           │
│   GeoDNS routes to nearest region                                          │
│                                                                             │
│   Pros:                                                                    │
│   - Routers close to both users AND compute (within region)               │
│   - Regional failures isolated                                             │
│   - Natural affinity for regional apps                                     │
│                                                                             │
│   Cons:                                                                    │
│   - Cross-region requests require router-to-router or router-to-pool hop  │
│   - More infrastructure to manage                                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OPTION 2: GLOBAL ROUTER FLEET (ANYCAST)                                  │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                    Global Router Fleet                               │   │
│   │                    (Anycast IP)                                      │   │
│   │                                                                     │   │
│   │   ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐            │   │
│   │   │ R1  │  │ R2  │  │ R3  │  │ R4  │  │ R5  │  │ R6  │            │   │
│   │   │US-E │  │US-W │  │EU-W │  │EU-E │  │AP-S │  │AP-N │            │   │
│   │   └─────┘  └─────┘  └─────┘  └─────┘  └─────┘  └─────┘            │   │
│   │                                                                     │   │
│   │   All routers identical, stateless                                 │   │
│   │   Anycast routes to nearest                                        │   │
│   │   Any router can serve any request                                 │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   Pros:                                                                    │
│   - Simple mental model (all routers are the same)                        │
│   - Automatic failover (anycast)                                          │
│   - Easy to scale (add more routers anywhere)                             │
│                                                                             │
│   Cons:                                                                    │
│   - Cross-region hop still required for distant pools                     │
│   - All routers need global view (more cache sync)                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Hot Potato Routing (Option B/C)

For regional consensus models, an elegant approach is "hot potato" routing: when a request arrives at a router that can't serve it locally, it forwards to another router, and the request becomes **that router's problem**.

```
HOT POTATO ROUTING MODEL

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   PRINCIPLE: Each router only owns requests it can serve locally.          │
│   If it can't serve locally, it forwards to someone who can.               │
│   The receiving router then owns ALL responsibility (queueing, scaling).   │
│                                                                             │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   EU User → EU Router                                               │   │
│   │                │                                                    │   │
│   │                │ "Can I serve this app locally?"                    │   │
│   │                │                                                    │   │
│   │           YES  │  NO (app is US-only)                               │   │
│   │            │   │   │                                                │   │
│   │            │   │   │ Forward to US-East Router                      │   │
│   │            │   │   │ (not my problem anymore)                       │   │
│   │            │   │   │                                                │   │
│   │            │   │   ▼                                                │   │
│   │            │   │  US-East Router                                    │   │
│   │            │   │   │                                                │   │
│   │            │   │   │ "Can I serve this locally?"                    │   │
│   │            │   │   │                                                │   │
│   │            │   │   │ YES → Queue locally, scale locally, serve      │   │
│   │            │   │   │                                                │   │
│   │            ▼   │   ▼                                                │   │
│   │        [Serve locally]                                              │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   BENEFITS:                                                                 │
│   - Each router only knows about local pools                               │
│   - Scaling decisions are always local (fast, ~5ms consensus)              │
│   - No complex cross-region scaling coordination                           │
│   - Simple mental model: "your region, your problem"                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Overflow Routing

The same principle applies when a region is at capacity:

```
OVERFLOW ROUTING

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Scenario: US-East at capacity, app allows any region                     │
│                                                                             │
│   US User → US-East Router                                                 │
│                │                                                            │
│                │ "Can I serve this?"                                        │
│                │                                                            │
│                │ Check:                                                     │
│                │ 1. Do I have pools for this app? YES                       │
│                │ 2. Do I have capacity? NO (all pools full)                │
│                │ 3. Can app be served elsewhere? YES (regions: [])         │
│                │                                                            │
│                │ Decision: Forward to another region                        │
│                │                                                            │
│                ▼                                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │   SELECT OVERFLOW TARGET                                            │   │
│   │                                                                     │   │
│   │   Candidates (from gossip):                                         │   │
│   │   - EU-West: has H100 capacity, healthy                            │   │
│   │   - AP-South: has H100 capacity, healthy                           │   │
│   │                                                                     │   │
│   │   Selection criteria:                                               │   │
│   │   - Latency to user (EU-West closer to US than AP-South)           │   │
│   │   - Available capacity                                              │   │
│   │   - Cost (if applicable)                                            │   │
│   │                                                                     │   │
│   │   Winner: EU-West                                                   │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                │                                                            │
│                │ Forward to EU-West Router                                 │
│                │ (with hop count incremented)                              │
│                │                                                            │
│                ▼                                                            │
│   EU-West Router                                                           │
│                │                                                            │
│                │ "Can I serve this?"                                        │
│                │                                                            │
│                │ YES → Queue locally, scale locally, serve                 │
│                │                                                            │
│                │ (Response goes back: EU-West → US-East → User)            │
│                │ (Or: EU-West → User directly, depends on design)          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### When to Stop: Failure Conditions

The critical question is: **when do we stop re-routing and fail the request?**

```
FAILURE CONDITIONS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. MAX HOPS EXCEEDED                                                      │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   Each forward increments: X-Hivemind-Hop-Count: N                 │   │
│   │                                                                     │   │
│   │   If hop_count >= MAX_HOPS (e.g., 3):                              │   │
│   │   → Return 503 Service Unavailable                                 │   │
│   │   → Include header: X-Hivemind-Failure: max-hops-exceeded          │   │
│   │                                                                     │   │
│   │   Rationale: Prevents infinite loops, bounded latency              │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   2. NO ELIGIBLE REGIONS                                                    │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   Router checks gossip for regions that:                           │   │
│   │   - Match app requirements                                          │   │
│   │   - Are healthy                                                     │   │
│   │   - Have not been tried (track in X-Hivemind-Tried-Regions)        │   │
│   │                                                                     │   │
│   │   If no eligible regions remain:                                   │   │
│   │   → Return 503 Service Unavailable                                 │   │
│   │   → Include header: X-Hivemind-Failure: no-capacity                │   │
│   │                                                                     │   │
│   │   Rationale: All options exhausted                                 │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   3. TTL EXPIRED                                                            │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   Track: X-Hivemind-Request-Start: <timestamp>                     │   │
│   │                                                                     │   │
│   │   If (now - request_start) > MAX_ROUTING_TIME (e.g., 30s):         │   │
│   │   → Return 504 Gateway Timeout                                     │   │
│   │   → Include header: X-Hivemind-Failure: routing-timeout            │   │
│   │                                                                     │   │
│   │   Rationale: Don't keep routing forever, give user timely failure  │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   4. QUEUE DEPTH EXCEEDED (local decision)                                  │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   When router receives request and decides to own it:              │   │
│   │                                                                     │   │
│   │   If local_queue_depth >= MAX_QUEUE_DEPTH:                         │   │
│   │   Option A: Forward to another region (overflow)                   │   │
│   │   Option B: Reject immediately (fast failure)                      │   │
│   │                                                                     │   │
│   │   Configuration per app:                                           │   │
│   │   - overflow_behavior: "route" | "reject"                          │   │
│   │   - max_queue_depth: N                                             │   │
│   │                                                                     │   │
│   │   Rationale: Prevents unbounded queuing                            │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   5. APP EXPLICITLY RESTRICTED                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   App specifies: regions: [us-east]                                │   │
│   │                                                                     │   │
│   │   US-East is at capacity, no overflow allowed:                     │   │
│   │   → Queue locally (even if deep)                                   │   │
│   │   → OR reject if queue too deep                                    │   │
│   │   → Cannot forward to other regions                                │   │
│   │                                                                     │   │
│   │   Rationale: Respect explicit constraints                          │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Request Headers for Hot Potato Routing

```
ROUTING METADATA HEADERS

Request headers (added/modified by routers):

X-Hivemind-Hop-Count: 2
  - Incremented on each forward
  - Starts at 0 from client

X-Hivemind-Request-Start: 1702569600000
  - Unix timestamp (ms) when request first hit a router
  - Used for TTL calculation

X-Hivemind-Tried-Regions: us-east,eu-west
  - Comma-separated list of regions that couldn't serve
  - Prevents loops and tracks exhaustion

X-Hivemind-Origin-Region: us-east
  - Which region first received the request
  - Useful for debugging and metrics

X-Hivemind-Forwarded-For: 10.0.1.5,10.0.2.3
  - Internal router IPs for tracing
  - Similar to X-Forwarded-For

Response headers (on failure):

X-Hivemind-Failure: max-hops-exceeded | no-capacity | routing-timeout | queue-full
  - Machine-readable failure reason

X-Hivemind-Tried-Regions: us-east,eu-west,ap-south
  - Which regions were attempted
```

#### Decision Flow for Hot Potato Router

```
HOT POTATO DECISION FLOWCHART

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   REQUEST ARRIVES AT ROUTER                                                 │
│          │                                                                  │
│          ▼                                                                  │
│   ┌──────────────┐                                                          │
│   │ Check TTL    │──── Expired ────► Return 504                            │
│   └──────┬───────┘                                                          │
│          │ OK                                                               │
│          ▼                                                                  │
│   ┌──────────────┐                                                          │
│   │ Check hops   │──── >= MAX ─────► Return 503 (max hops)                 │
│   └──────┬───────┘                                                          │
│          │ OK                                                               │
│          ▼                                                                  │
│   ┌──────────────┐                                                          │
│   │ Auth check   │──── Failed ─────► Return 401/403                        │
│   └──────┬───────┘                                                          │
│          │ OK                                                               │
│          ▼                                                                  │
│   ┌──────────────┐                                                          │
│   │ Lookup app   │──── Not found ──► Return 404                            │
│   └──────┬───────┘                                                          │
│          │ Found                                                            │
│          ▼                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │ CAN I SERVE THIS LOCALLY?                                           │   │
│   │                                                                     │   │
│   │ Check:                                                              │   │
│   │ 1. Do app requirements match my pools?                              │   │
│   │    - GPU type available locally?                                    │   │
│   │    - Region constraint satisfied?                                   │   │
│   │                                                                     │   │
│   │ 2. Do I have capacity (or can I scale)?                            │   │
│   │    - Current capacity > 0? → Serve immediately                     │   │
│   │    - Queue depth < max? → Queue and scale                          │   │
│   │    - Can overflow? → Forward                                       │   │
│   │    - Else → Reject                                                 │   │
│   │                                                                     │   │
│   └──────────────────────────┬──────────────────────────────────────────┘   │
│                              │                                              │
│          ┌───────────────────┼───────────────────┐                          │
│          │                   │                   │                          │
│          ▼                   ▼                   ▼                          │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐                   │
│   │ CAN SERVE   │     │ CAN'T SERVE │     │ AT CAPACITY │                   │
│   │ LOCALLY     │     │ (wrong      │     │ (can        │                   │
│   │             │     │  region)    │     │  overflow)  │                   │
│   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘                   │
│          │                   │                   │                          │
│          │                   │                   │                          │
│          ▼                   │                   │                          │
│   ┌─────────────┐            │                   │                          │
│   │ Queue       │            │                   │                          │
│   │ locally     │            │                   │                          │
│   │             │            │                   │                          │
│   │ Signal CP   │            │                   │                          │
│   │ for scale   │            │                   │                          │
│   │             │            │                   │                          │
│   │ Serve when  │            │                   │                          │
│   │ ready       │            │                   │                          │
│   └─────────────┘            │                   │                          │
│                              │                   │                          │
│                              ▼                   ▼                          │
│                       ┌─────────────────────────────────────────────┐       │
│                       │ SELECT FORWARD TARGET                       │       │
│                       │                                             │       │
│                       │ From gossip, find regions that:             │       │
│                       │ - Match requirements                        │       │
│                       │ - Are healthy                               │       │
│                       │ - Not in tried-regions list                 │       │
│                       │                                             │       │
│                       │ Sort by:                                    │       │
│                       │ - Has capacity (prefer)                     │       │
│                       │ - Latency to user                           │       │
│                       │ - Cost                                      │       │
│                       │                                             │       │
│                       │ If no candidates:                           │       │
│                       │ → Return 503 (no capacity)                  │       │
│                       │                                             │       │
│                       └──────────────────┬──────────────────────────┘       │
│                                          │                                  │
│                                          ▼                                  │
│                       ┌─────────────────────────────────────────────┐       │
│                       │ FORWARD REQUEST                             │       │
│                       │                                             │       │
│                       │ - Increment hop count                       │       │
│                       │ - Add self to tried-regions                 │       │
│                       │ - Forward to selected router                │       │
│                       │ - Return response to client                 │       │
│                       │   (or proxy response back)                  │       │
│                       │                                             │       │
│                       └─────────────────────────────────────────────┘       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

#### Hot Potato vs Direct Proxy Comparison

| Aspect | Hot Potato | Direct Proxy |
|--------|------------|--------------|
| **Who owns scaling?** | Receiving router (local) | Origin router (remote) |
| **Scaling latency** | Fast (~5ms local consensus) | Slow (~100-150ms remote) |
| **Queue location** | At serving region | At origin region |
| **Router complexity** | Higher (forwarding logic) | Lower (just proxy) |
| **Failure isolation** | Better (local decisions) | Worse (depends on remote) |
| **Observability** | Per-hop metrics | Single-hop metrics |

#### Recommended: Hot Potato for Options B/C

For regional consensus models, hot potato routing is preferred because:

1. **Local scaling decisions** - No cross-region consensus for scale-up
2. **Clear ownership** - Each region owns its queue and capacity
3. **Failure isolation** - Region failure doesn't block other regions' scaling
4. **Simple mental model** - "If you receive it, you own it"

The key parameters to configure:

```yaml
# Router configuration
routing:
  max_hops: 3                    # Prevent infinite loops
  max_routing_time_ms: 30000     # 30s TTL for routing phase

# Per-app configuration
app:
  overflow_behavior: "route"     # "route" | "reject"
  max_queue_depth: 1000          # When to consider overflow
  regions: []                    # Empty = any region OK
```

#### Response Path Options

When a request is forwarded (EU Router → US Router → US Pool), there are two options for the response path:

```
RESPONSE PATH OPTIONS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OPTION 1: FULL CHAIN (Symmetric)                                         │
│                                                                             │
│   Request:  Client → EU Router → US Router → US Pool                       │
│   Response: Client ← EU Router ← US Router ← US Pool                       │
│                                                                             │
│   ┌──────┐      ┌──────────┐      ┌──────────┐      ┌─────────┐            │
│   │Client│◄────►│EU Router │◄────►│US Router │◄────►│ US Pool │            │
│   └──────┘      └──────────┘      └──────────┘      └─────────┘            │
│              TCP conn 1       TCP conn 2       TCP conn 3                  │
│                                                                             │
│   How it works:                                                            │
│   - EU Router opens connection to US Router                                │
│   - US Router opens connection to US Pool                                  │
│   - Response flows back through same connections                           │
│   - Each router proxies the response                                       │
│                                                                             │
│   Pros:                                                                    │
│   - Simple, stateless forwarding                                           │
│   - Each router sees full request/response (observability)                 │
│   - No special handling needed                                             │
│   - Works with any HTTP client                                             │
│                                                                             │
│   Cons:                                                                    │
│   - Higher latency (extra hops on response)                                │
│   - EU Router holds connection for full inference duration                 │
│   - More bandwidth through intermediate routers                            │
│                                                                             │
│   Latency:                                                                 │
│   - Request: Client→EU (20ms) + EU→US (100ms) + US→Pool (5ms) = 125ms     │
│   - Response: Pool→US (5ms) + US→EU (100ms) + EU→Client (20ms) = 125ms    │
│   - Total overhead: ~250ms + inference                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OPTION 2: DIRECT RESPONSE (Asymmetric)                                   │
│                                                                             │
│   Request:  Client → EU Router → US Router → US Pool                       │
│   Response: Client ← ─ ─ ─ ─ ─ ─ US Router ← US Pool                       │
│                                                                             │
│   ┌──────┐      ┌──────────┐      ┌──────────┐      ┌─────────┐            │
│   │Client│─────►│EU Router │─────►│US Router │◄────►│ US Pool │            │
│   └──┬───┘      └──────────┘      └────┬─────┘      └─────────┘            │
│      │                                 │                                   │
│      │◄────────────────────────────────┘                                   │
│           Direct response (bypasses EU Router)                             │
│                                                                             │
│   How it works:                                                            │
│   - EU Router includes client info in forward headers                      │
│   - US Router establishes direct connection to client                      │
│   - OR: US Router sends response with redirect/new endpoint                │
│                                                                             │
│   Implementation variants:                                                  │
│                                                                             │
│   2a. Connection Handoff                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │   EU Router tells US Router: "Client is at IP:port, take over"     │   │
│   │   US Router connects directly to client for response               │   │
│   │                                                                     │   │
│   │   Requires:                                                         │   │
│   │   - Client IP visible to US Router (no NAT issues)                 │   │
│   │   - TLS session resumption or re-handshake                         │   │
│   │   - Complex connection state management                            │   │
│   │                                                                     │   │
│   │   Verdict: Complex, fragile, not recommended                       │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   2b. Redirect After Accept                                                │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │   EU Router returns quickly: "Request accepted, poll US Router"    │   │
│   │   Client polls US Router directly for result                       │   │
│   │                                                                     │   │
│   │   Response from EU Router:                                         │   │
│   │   {                                                                 │   │
│   │     "status": "accepted",                                          │   │
│   │     "request_id": "abc123",                                        │   │
│   │     "poll_endpoint": "https://us-east.router.../v1/results/abc123"│   │
│   │   }                                                                 │   │
│   │                                                                     │   │
│   │   Requires:                                                         │   │
│   │   - Client SDK support for async polling                           │   │
│   │   - Request ID tracking                                            │   │
│   │   - Changes API contract                                           │   │
│   │                                                                     │   │
│   │   Verdict: Clean but requires SDK changes                          │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   2c. WebSocket/SSE Upgrade                                                │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │   Client opens WebSocket to EU Router                              │   │
│   │   EU Router forwards to US Router                                  │   │
│   │   Response streams back through WebSocket                          │   │
│   │                                                                     │   │
│   │   Same as Option 1 for connection topology, but:                   │   │
│   │   - Better for streaming responses                                 │   │
│   │   - Connection stays open, reusable                                │   │
│   │   - Lower overhead for multiple requests                           │   │
│   │                                                                     │   │
│   │   Verdict: Good for streaming, but still symmetric path            │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   Pros (of direct response):                                               │
│   - Lower latency on response path                                         │
│   - Less load on intermediate routers                                      │
│   - EU Router can close connection quickly                                 │
│                                                                             │
│   Cons (of direct response):                                               │
│   - Complex implementation                                                 │
│   - May require client SDK changes                                         │
│   - Harder to debug/observe                                                │
│   - NAT/firewall complications                                             │
│                                                                             │
│   Latency (2b variant):                                                    │
│   - Initial: Client→EU (20ms) + EU→US (100ms) = 120ms (fast ack)          │
│   - Poll: Client→US (100ms) + inference + US→Client (100ms)               │
│   - Total overhead: ~320ms but first response is faster                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Comparison:**

| Aspect | Option 1: Full Chain | Option 2: Direct Response |
|--------|---------------------|--------------------------|
| **Implementation** | Simple | Complex |
| **Response latency** | Higher (+1 hop) | Lower |
| **Observability** | Full visibility | Partial |
| **Client changes** | None | May require SDK |
| **Connection management** | Simple | Complex |
| **Streaming support** | Via WebSocket | Native or via redirect |
| **NAT/Firewall** | No issues | Potential issues |

**Hybrid Approach:**

A pragmatic middle ground:

```
HYBRID: FULL CHAIN WITH STREAMING OPTIMIZATION

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Default: Full Chain (Option 1)                                           │
│   - Simple, works everywhere                                               │
│   - Good enough for most requests                                          │
│                                                                             │
│   Optimization for long-running inference:                                 │
│   - Client opens WebSocket/SSE to nearest router                           │
│   - Router forwards WebSocket to serving router                            │
│   - Response streams back through same path                                │
│   - Connection reused for multiple requests                                │
│                                                                             │
│   This gives us:                                                           │
│   - Simple default path                                                    │
│   - Optimized path for streaming inference                                 │
│   - No client SDK requirements for basic usage                             │
│   - Better experience for advanced clients                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Decision factors:**

| Factor | Favors Full Chain | Favors Direct Response |
|--------|-------------------|----------------------|
| Simplicity priority | ✓ | |
| Latency critical | | ✓ |
| Streaming responses | Either (WebSocket) | ✓ |
| Simple client integration | ✓ | |
| Observability priority | ✓ | |
| Bandwidth cost matters | | ✓ |

---

### Recommended Request Flow

Based on the analysis, here's a recommended flow that works with any consensus option:

```
RECOMMENDED REQUEST FLOW

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. CLIENT → NEAREST ROUTER (GeoDNS or Anycast)                           │
│      - TLS termination                                                     │
│      - Auth validation                                                     │
│      - App lookup (from cache)                                             │
│                                                                             │
│   2. ROUTER DETERMINES POOL                                                │
│      - Cache hit: Use cached pool endpoints                                │
│      - Cache miss: Query CP (global or regional depending on option)       │
│                                                                             │
│   3. IF POOL IN SAME REGION AS ROUTER:                                     │
│      - Direct forward to pool                                              │
│      - Optimal path                                                        │
│                                                                             │
│   4. IF POOL IN DIFFERENT REGION:                                          │
│      Option A: Router proxies directly to remote pool                      │
│      Option B: Router forwards to that region's router first              │
│                                                                             │
│      Recommendation: Option A (direct proxy) for simplicity               │
│      - Extra router hop adds latency without benefit                       │
│      - Regional router doesn't have more info than originating router     │
│                                                                             │
│   5. SCALING (if needed):                                                  │
│      - Router queues request                                               │
│      - Router signals CP (global or regional) for scale-up               │
│      - CP makes scaling decision                                           │
│      - Once capacity available, request proceeds                          │
│                                                                             │
│   6. RESPONSE                                                              │
│      - Pool → Router → Client                                              │
│      - Same path as request                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

KEY INSIGHT:

The main request path (cache hit, warm pool) is IDENTICAL across all options.
Consensus only affects:
- Cache miss handling (where to get app info)
- Scaling decisions (who decides to scale)

For steady-state traffic, consensus option doesn't matter for latency.
It only matters for:
- Cold starts (scaling decisions)
- New app deployments (app registry updates)
- Failure handling (what happens when CP is down)
```

---

## Additional Failure Modes & Considerations

Beyond the component-level failures analyzed above, these scenarios affect distributed architecture design:

---

### 1. Split Brain

What happens when network partitions cause multiple leaders?

```
SPLIT BRAIN SCENARIOS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OPTION A (Global VRR): Split brain prevented by quorum                   │
│                                                                             │
│   ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐    ┌─────┐                      │
│   │ CP1 │    │ CP2 │    │ CP3 │    │ CP4 │    │ CP5 │                      │
│   └──┬──┘    └──┬──┘    └──┬──┘    └──┬──┘    └──┬──┘                      │
│      │          │          │          │          │                         │
│      └──────────┴──────────┼──────────┴──────────┘                         │
│                            │                                               │
│                     PARTITION                                              │
│                            │                                               │
│   Left side: CP1, CP2 (2 nodes, no quorum)                                │
│   Right side: CP3, CP4, CP5 (3 nodes, HAS quorum)                         │
│                                                                             │
│   Result: Only right side can make progress                                │
│   VRR guarantees: At most one leader at a time                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   OPTION B (Regional VRR): Each region has independent leader              │
│                                                                             │
│   US-EAST VRR              EU-WEST VRR                                     │
│   ┌─────────────┐          ┌─────────────┐                                 │
│   │   Leader    │    X     │   Leader    │                                 │
│   │   (CP1)     │◄────────►│   (CP1)     │                                 │
│   └─────────────┘          └─────────────┘                                 │
│                                                                             │
│   Not split brain - intentionally separate leaders                         │
│   Each region authoritative for its own state                              │
│                                                                             │
│   RISK: Conflicting decisions for cross-region apps                       │
│   Mitigation: Clear ownership rules, app "home" region                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   GOSSIP SPLIT BRAIN (Options B/C)                                         │
│                                                                             │
│   If gossip partitions, regions have stale view of each other:            │
│                                                                             │
│   US-EAST thinks: "EU-WEST has 10 H100s available"                        │
│   EU-WEST reality: "We're at 100% capacity"                               │
│                                                                             │
│   Result: US-EAST forwards requests to EU-WEST, they get rejected         │
│                                                                             │
│   Mitigation:                                                              │
│   - Gossip TTL: Mark data stale after N seconds                           │
│   - Fallback to "try anyway" with fast failure                            │
│   - Hot potato: EU-WEST rejects, US-EAST tries next option                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 2. Gray Failures (Partial/Slow Failures)

Node is not dead, but degraded. Harder to detect than complete failures.

```
GRAY FAILURE SCENARIOS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. SLOW NODE                                                             │
│                                                                             │
│   CP node responding, but slowly (disk issue, GC pause, etc.)             │
│                                                                             │
│   Normal: Request → Response in 5ms                                        │
│   Degraded: Request → Response in 500ms                                    │
│                                                                             │
│   Impact:                                                                  │
│   - VRR: Slow follower delays commits (must wait for quorum)              │
│   - If slow node is leader: All operations slow                           │
│                                                                             │
│   Detection:                                                               │
│   - Latency percentile monitoring (P99 spike)                             │
│   - Heartbeat latency tracking                                            │
│                                                                             │
│   Mitigation:                                                              │
│   - Adaptive timeouts                                                      │
│   - Leader step-down on sustained high latency                            │
│   - "Probationary" state before full membership                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   2. PACKET LOSS / FLAKY NETWORK                                           │
│                                                                             │
│   Connection works, but drops 10% of packets                              │
│                                                                             │
│   Impact:                                                                  │
│   - VRR: Retransmissions, increased latency                               │
│   - Gossip: Stale data, inconsistent views                                │
│   - Hot potato: Forwarded requests sometimes fail                         │
│                                                                             │
│   Detection:                                                               │
│   - Packet loss metrics per connection                                    │
│   - Retransmission rate                                                   │
│                                                                             │
│   Mitigation:                                                              │
│   - Connection health scoring                                             │
│   - Prefer healthy paths for critical traffic                             │
│   - Circuit breaker on flaky connections                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   3. ASYMMETRIC FAILURES                                                   │
│                                                                             │
│   A can reach B, but B cannot reach A                                     │
│                                                                             │
│   ┌─────┐         ┌─────┐                                                  │
│   │  A  │────────►│  B  │                                                  │
│   │     │    X    │     │                                                  │
│   │     │◄────────│     │                                                  │
│   └─────┘         └─────┘                                                  │
│                                                                             │
│   Impact:                                                                  │
│   - A thinks B is healthy (can send)                                      │
│   - B thinks A is dead (can't receive)                                    │
│   - Confusing failure modes                                               │
│                                                                             │
│   Detection:                                                               │
│   - Bidirectional health checks                                           │
│   - Require acknowledgment for liveness                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 3. Cascading Failures

One failure triggers others, potentially bringing down the system.

```
CASCADING FAILURE SCENARIOS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. RETRY STORM                                                           │
│                                                                             │
│   Sequence:                                                                │
│   1. One pool goes unhealthy                                              │
│   2. Requests fail, clients retry                                         │
│   3. Retries overload remaining pools                                     │
│   4. More pools go unhealthy                                              │
│   5. System collapse                                                       │
│                                                                             │
│   ┌────────┐     ┌────────┐     ┌────────┐                                │
│   │ Client │────►│ Router │────►│ Pool A │ ← Dies                         │
│   │ (retry)│     │        │────►│ Pool B │ ← Overloaded                   │
│   │ (retry)│     │        │────►│ Pool C │ ← Overloaded                   │
│   │ (retry)│     │        │     │   ...  │                                │
│   └────────┘     └────────┘     └────────┘                                │
│                                                                             │
│   Mitigation:                                                              │
│   - Exponential backoff with jitter                                       │
│   - Circuit breakers                                                       │
│   - Load shedding (reject early when overloaded)                          │
│   - Retry budgets (max N retries per time window)                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   2. THUNDERING HERD (Recovery Storm)                                      │
│                                                                             │
│   Sequence:                                                                │
│   1. Region goes down                                                      │
│   2. Requests queue or failover to other regions                          │
│   3. Region comes back up                                                 │
│   4. All queued requests + new requests flood the region                  │
│   5. Region immediately goes down again                                   │
│                                                                             │
│   Mitigation:                                                              │
│   - Gradual traffic shift on recovery (1% → 10% → 50% → 100%)            │
│   - Health check warmup period before accepting full traffic              │
│   - Queue drain rate limiting                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   3. COLD START STORM                                                      │
│                                                                             │
│   Sequence:                                                                │
│   1. Many apps are scaled to zero                                         │
│   2. Burst of traffic arrives (morning, after outage, etc.)              │
│   3. Many apps need to cold start simultaneously                          │
│   4. All hit Honeycomb for images                                         │
│   5. Honeycomb/S3 overloaded                                              │
│   6. Cold starts fail or timeout                                          │
│                                                                             │
│   Mitigation:                                                              │
│   - Staggered cold start scheduling                                       │
│   - Pre-warming during low traffic periods                                │
│   - P2P layer distribution (Honeycomb)                                    │
│   - Cold start rate limiting per region                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   4. CONTROL PLANE OVERLOAD                                                │
│                                                                             │
│   Sequence:                                                                │
│   1. Burst of scaling decisions needed                                    │
│   2. CP consensus overloaded                                              │
│   3. Scaling decisions delayed                                            │
│   4. Queues grow, more scaling needed                                     │
│   5. CP falls further behind                                              │
│                                                                             │
│   Mitigation:                                                              │
│   - Batch scaling decisions                                               │
│   - Rate limit scaling requests                                           │
│   - Prioritize scale-up over scale-down                                   │
│   - Pre-scale based on predictions                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 4. Clock Skew

Distributed systems with time-dependent logic are sensitive to clock differences.

```
CLOCK SKEW IMPACT

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   Where clocks matter in Hivemind:                                         │
│                                                                             │
│   1. Request TTL (X-Hivemind-Request-Start)                               │
│      - If clocks differ, TTL calculation is wrong                         │
│      - Request might expire too early or too late                         │
│                                                                             │
│   2. VRR timeouts                                                          │
│      - Leader election timeouts                                            │
│      - Heartbeat intervals                                                 │
│      - If clocks skewed, might trigger unnecessary elections              │
│                                                                             │
│   3. Gossip TTLs                                                           │
│      - "Data is stale after N seconds"                                    │
│      - Skew causes inconsistent staleness detection                       │
│                                                                             │
│   4. Metrics timestamps                                                    │
│      - Queue depth at time T                                               │
│      - Skew causes incorrect ordering of events                           │
│                                                                             │
│   5. Log correlation                                                       │
│      - Debugging distributed requests                                      │
│      - Skew makes logs hard to correlate                                  │
│                                                                             │
│   Mitigation:                                                              │
│   - Use NTP on all nodes (typical skew < 10ms)                            │
│   - Use logical clocks where ordering matters (Lamport, vector)           │
│   - Use durations rather than absolute timestamps where possible          │
│   - Tolerate reasonable skew in calculations (add buffer)                 │
│                                                                             │
│   Example TTL calculation with skew tolerance:                             │
│                                                                             │
│   // Instead of: if (now - start) > TTL                                   │
│   // Use: if (now - start) > (TTL - MAX_CLOCK_SKEW)                       │
│   // Where MAX_CLOCK_SKEW = 100ms (conservative)                          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 5. State Recovery & Synchronization

How does a node catch up after being down?

```
STATE RECOVERY SCENARIOS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. VRR REPLICA RECOVERY                                                  │
│                                                                             │
│   CP node was down for 10 minutes, comes back up                          │
│                                                                             │
│   Recovery steps:                                                          │
│   1. Node starts in "recovering" state                                    │
│   2. Requests state from other replicas                                   │
│   3. Receives snapshot + log entries since snapshot                       │
│   4. Applies log entries to catch up                                      │
│   5. Joins as follower, can now participate in quorum                     │
│                                                                             │
│   VRR handles this natively - it's part of the protocol                   │
│                                                                             │
│   Risk: If node was down too long, log might be truncated                 │
│   Solution: Full snapshot transfer instead of log replay                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   2. ROUTER CACHE RECOVERY                                                 │
│                                                                             │
│   Router restarts, cache is empty                                         │
│                                                                             │
│   Options:                                                                 │
│   a. Cold start: All requests cause cache miss initially                  │
│      - Simple, but spike of CP queries                                    │
│                                                                             │
│   b. Pre-warm from CP: Router fetches all app→pool mappings on start      │
│      - Slower startup, but no cache miss spike                            │
│                                                                             │
│   c. Persistent cache: Router persists cache to disk                      │
│      - Fast restart with warm cache                                       │
│      - Risk: Cache might be stale after long downtime                     │
│                                                                             │
│   d. Cache sharing: New router gets cache from sibling routers            │
│      - P2P cache transfer                                                 │
│      - Requires router-to-router protocol                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   3. AGENT RECOVERY                                                        │
│                                                                             │
│   Agent restarts on a GPU node                                            │
│                                                                             │
│   Recovery steps:                                                          │
│   1. Discover running containers (query containerd/docker)                │
│   2. Re-register with control plane                                       │
│   3. Report current state (GPU utilization, running workloads)            │
│   4. Resume metrics/logs collection                                       │
│                                                                             │
│   Risk: CP might have marked node as dead and rescheduled workloads       │
│   Resolution:                                                              │
│   - Agent reports what's running                                          │
│   - CP reconciles (either adopt or terminate duplicates)                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   4. CROSS-REGION STATE SYNC (Option B/C)                                  │
│                                                                             │
│   After network partition heals, regions have diverged                    │
│                                                                             │
│   What might diverge:                                                      │
│   - App configurations (user updated in both regions?)                    │
│   - Capacity allocations (both regions allocated same resource?)          │
│   - Gossip state (stale capacity summaries)                               │
│                                                                             │
│   Resolution strategies:                                                   │
│   - App config: Last-writer-wins with vector clock                        │
│   - Capacity: Each region owns its own, no conflict                       │
│   - Gossip: Self-healing, just exchange current state                     │
│                                                                             │
│   For Option C (hierarchical):                                             │
│   - Global coordinator is source of truth for app registry                │
│   - Regional divergence limited to scheduling state                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 6. Exactly-Once Semantics & Idempotency

How do we handle retries without duplicate processing?

```
IDEMPOTENCY CONSIDERATIONS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   PROBLEM: Request might be processed multiple times                       │
│                                                                             │
│   Scenarios:                                                               │
│   1. Client retries after timeout (but request succeeded)                 │
│   2. Router retries after pool timeout (but inference ran)                │
│   3. Hot potato: Request forwarded, original router also retries          │
│                                                                             │
│   ┌──────┐         ┌────────┐         ┌──────┐                             │
│   │Client│────────►│ Router │────────►│ Pool │                             │
│   │      │         │        │    X    │      │ (timeout)                   │
│   │      │         │        │◄────────│      │                             │
│   │      │         │        │         │      │                             │
│   │      │◄────────│ retry  │────────►│      │ (duplicate!)               │
│   └──────┘         └────────┘         └──────┘                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   SOLUTION: Request IDs + Idempotency Keys                                 │
│                                                                             │
│   Client includes:                                                         │
│   X-Request-ID: <client-generated-uuid>                                   │
│   X-Idempotency-Key: <user-provided-key>  (optional)                      │
│                                                                             │
│   Router/Pool behavior:                                                    │
│   1. Check if request ID seen before                                      │
│   2. If seen: Return cached response (or "in progress")                   │
│   3. If not seen: Process and cache response                              │
│                                                                             │
│   Cache requirements:                                                      │
│   - Store: request_id → {status, response, timestamp}                     │
│   - TTL: Reasonable window (e.g., 5 minutes)                              │
│   - Distributed: All routers/pools in region need access                  │
│                                                                             │
│   Implementation options:                                                  │
│   a. Redis/Memcached cluster per region                                   │
│   b. Include in VRR state (adds consensus overhead)                       │
│   c. Pool-local dedup (limited, but simple)                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   FOR INFERENCE SPECIFICALLY:                                              │
│                                                                             │
│   Many inference requests are naturally idempotent:                        │
│   - Same input → same output (deterministic models)                       │
│   - Duplicate doesn't change state                                         │
│                                                                             │
│   Exceptions:                                                              │
│   - Non-deterministic models (sampling, random seed)                      │
│   - Requests with side effects (write to DB, send notification)           │
│   - Billing/metering (don't want to double-charge)                        │
│                                                                             │
│   Recommendation:                                                          │
│   - Implement request ID tracking for correctness                         │
│   - Critical for billing/metering                                          │
│   - Nice-to-have for general inference                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 7. Backpressure Propagation

How does overload signal propagate through the system?

```
BACKPRESSURE FLOW

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   PROBLEM: When system is overloaded, where do we push back?               │
│                                                                             │
│   Without backpressure:                                                    │
│   - Requests queue everywhere                                              │
│   - Memory exhaustion                                                      │
│   - Cascading failures                                                     │
│                                                                             │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │                                                                      │  │
│   │   Client ──► Router Queue ──► Pool Queue ──► GPU                    │  │
│   │             (growing)        (growing)       (100% busy)            │  │
│   │                                                                      │  │
│   │   Without backpressure: Queues grow unbounded, OOM                  │  │
│   │                                                                      │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   WITH BACKPRESSURE:                                                       │
│                                                                             │
│   ┌──────────────────────────────────────────────────────────────────────┐  │
│   │                                                                      │  │
│   │   Layer 1: Pool → Router                                            │  │
│   │   - Pool reports queue depth to router                              │  │
│   │   - Router stops sending when pool queue > threshold                │  │
│   │   - Or: Pool returns 503 with Retry-After header                    │  │
│   │                                                                      │  │
│   │   Layer 2: Router → Client                                          │  │
│   │   - Router queue depth > threshold                                  │  │
│   │   - Options:                                                         │  │
│   │     a. Return 503 immediately (fail fast)                           │  │
│   │     b. Return 429 with Retry-After                                  │  │
│   │     c. Hot potato to another region                                 │  │
│   │                                                                      │  │
│   │   Layer 3: Cross-region                                             │  │
│   │   - Region at capacity signals via gossip                           │  │
│   │   - Other regions stop forwarding to it                             │  │
│   │                                                                      │  │
│   └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
│   CONFIGURATION:                                                           │
│                                                                             │
│   Per app:                                                                 │
│   - max_queue_depth: 1000                                                 │
│   - backpressure_action: "reject" | "overflow" | "queue"                  │
│   - queue_timeout_ms: 30000                                               │
│                                                                             │
│   Per router:                                                              │
│   - max_total_queued: 10000                                               │
│   - memory_limit_mb: 1024                                                 │
│   - connection_limit: 10000                                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 8. Configuration Propagation Delay

How long until config changes are visible everywhere?

```
CONFIGURATION PROPAGATION

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   User updates app configuration (e.g., changes GPU requirement)           │
│                                                                             │
│   OPTION A (Global VRR):                                                   │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   User → API → Global CP (consensus) → Committed                   │   │
│   │                     │                                               │   │
│   │                     │ ~100-200ms                                    │   │
│   │                     ▼                                               │   │
│   │   All routers query same CP, see new config immediately            │   │
│   │   (on next cache refresh or cache miss)                            │   │
│   │                                                                     │   │
│   │   Propagation delay: Cache TTL (e.g., 30s) + consensus (~200ms)    │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   OPTION B (Regional VRR + Gossip):                                        │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   User → API → Home Region CP (consensus) → Committed              │   │
│   │                     │                                               │   │
│   │                     │ ~5ms (local)                                  │   │
│   │                     ▼                                               │   │
│   │   Gossip to other regions                                          │   │
│   │                     │                                               │   │
│   │                     │ ~100-1000ms (gossip interval)                 │   │
│   │                     ▼                                               │   │
│   │   Other regions see update                                         │   │
│   │                                                                     │   │
│   │   Propagation delay: Local fast, cross-region delayed              │   │
│   │                                                                     │   │
│   │   RISK: User in EU updates config, EU user sees immediately,       │   │
│   │         US user sees stale config for gossip interval              │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   OPTION C (Hierarchical):                                                 │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                                                                     │   │
│   │   User → API → Global Coordinator (consensus) → Committed          │   │
│   │                     │                                               │   │
│   │                     │ ~100-200ms (global)                           │   │
│   │                     ▼                                               │   │
│   │   Global coordinator notifies regional CPs                         │   │
│   │                     │                                               │   │
│   │                     │ Push notification (fast) or poll (slower)    │   │
│   │                     ▼                                               │   │
│   │   All regions updated                                              │   │
│   │                                                                     │   │
│   │   Propagation delay: ~200-500ms globally                           │   │
│   │                                                                     │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
│   IMPLICATIONS FOR ROUTING:                                                │
│                                                                             │
│   If user changes app from "us-east only" to "any region":                │
│   - Until propagation complete, other regions don't know they can serve  │
│   - Requests still route to us-east                                       │
│   - Harmless, just suboptimal                                             │
│                                                                             │
│   If user changes app from "any region" to "us-east only":                │
│   - Until propagation complete, other regions might serve                 │
│   - Requests might go to wrong region                                     │
│   - More problematic if compliance-related                                │
│                                                                             │
│   MITIGATION:                                                              │
│   - For restrictive changes: Wait for propagation before confirming      │
│   - Or: Accept eventual consistency, document propagation delay           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 9. Resource Exhaustion

Beyond application-level failures, system resource limits.

```
RESOURCE EXHAUSTION SCENARIOS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. FILE DESCRIPTORS                                                      │
│                                                                             │
│   Each connection uses a file descriptor                                   │
│   Router with 10,000 connections + internal connections = FD exhaustion   │
│                                                                             │
│   Symptoms:                                                                │
│   - "Too many open files" errors                                          │
│   - New connections refused                                               │
│                                                                             │
│   Mitigation:                                                              │
│   - Increase ulimit (but there's a ceiling)                               │
│   - Connection pooling                                                     │
│   - Aggressive connection timeouts                                         │
│   - Monitor FD usage, alert at 80%                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   2. MEMORY                                                                │
│                                                                             │
│   Request queues, caches, connection buffers all use memory               │
│                                                                             │
│   Symptoms:                                                                │
│   - OOM killer terminates process                                         │
│   - GC pauses (if using GC language)                                      │
│   - Swap thrashing                                                         │
│                                                                             │
│   Mitigation:                                                              │
│   - Bounded queue sizes                                                    │
│   - Request size limits                                                    │
│   - Memory-aware load shedding                                            │
│   - Zig: No hidden allocations, predictable memory                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   3. CPU                                                                   │
│                                                                             │
│   TLS handshakes, request parsing, serialization                          │
│                                                                             │
│   Symptoms:                                                                │
│   - High latency                                                           │
│   - Request timeouts                                                       │
│   - Dropped connections                                                    │
│                                                                             │
│   Mitigation:                                                              │
│   - Horizontal scaling                                                     │
│   - CPU-aware load balancing                                              │
│   - Offload TLS to hardware/CDN                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   4. NETWORK BANDWIDTH                                                     │
│                                                                             │
│   Large inference responses, image pulls                                  │
│                                                                             │
│   Symptoms:                                                                │
│   - Slow transfers                                                         │
│   - Packet drops                                                           │
│   - Increased latency for all traffic                                     │
│                                                                             │
│   Mitigation:                                                              │
│   - Response streaming (don't buffer full response)                       │
│   - Bandwidth quotas per tenant                                           │
│   - P2P distribution for images (Honeycomb)                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### 10. Deployment & Upgrade Failures

What happens during rolling updates?

```
DEPLOYMENT SCENARIOS

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   1. ROUTER ROLLING UPDATE                                                 │
│                                                                             │
│   ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐                             │
│   │ R1  │  │ R2  │  │ R3  │  │ R4  │  │ R5  │                             │
│   │ v1  │  │ v1  │  │ v1  │  │ v1  │  │ v1  │                             │
│   └─────┘  └─────┘  └─────┘  └─────┘  └─────┘                             │
│      │                                                                     │
│      ▼ Upgrade R1 to v2                                                   │
│   ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐                             │
│   │ R1  │  │ R2  │  │ R3  │  │ R4  │  │ R5  │                             │
│   │ v2  │  │ v1  │  │ v1  │  │ v1  │  │ v1  │                             │
│   └─────┘  └─────┘  └─────┘  └─────┘  └─────┘                             │
│                                                                             │
│   Risks:                                                                   │
│   - v1 and v2 have incompatible behavior                                  │
│   - Requests might get different results based on which router            │
│                                                                             │
│   Mitigation:                                                              │
│   - Backward compatible changes only                                       │
│   - Feature flags for new behavior                                        │
│   - Canary deployment (1 router first, monitor, then rest)                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   2. CONTROL PLANE ROLLING UPDATE                                          │
│                                                                             │
│   VRR consensus during upgrade:                                            │
│                                                                             │
│   ┌─────┐  ┌─────┐  ┌─────┐                                               │
│   │ CP1 │  │ CP2 │  │ CP3 │   All v1, CP1 is leader                       │
│   │ v1  │  │ v1  │  │ v1  │                                               │
│   │ LDR │  │     │  │     │                                               │
│   └─────┘  └─────┘  └─────┘                                               │
│      │                                                                     │
│      ▼ Upgrade CP1 (leader)                                               │
│                                                                             │
│   1. CP1 steps down as leader                                             │
│   2. CP2 or CP3 elected leader (v1)                                       │
│   3. CP1 restarts with v2                                                 │
│   4. CP1 rejoins as follower                                              │
│   5. Continue upgrading CP2, CP3                                          │
│                                                                             │
│   Risks:                                                                   │
│   - State machine changes incompatible between versions                   │
│   - Log format changes                                                    │
│                                                                             │
│   Mitigation:                                                              │
│   - State machine versioning                                              │
│   - Two-phase migrations (add field, then use field)                      │
│   - Never remove fields, only deprecate                                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                             │
│   3. FAILED DEPLOYMENT ROLLBACK                                            │
│                                                                             │
│   New version has bug, need to rollback                                   │
│                                                                             │
│   Scenario:                                                                │
│   1. Deploy v2 to 50% of routers                                          │
│   2. v2 has bug causing request failures                                  │
│   3. Need to rollback to v1                                               │
│                                                                             │
│   Considerations:                                                          │
│   - Can v1 handle requests started by v2?                                 │
│   - Are there state changes that v1 doesn't understand?                   │
│   - Is the cache format compatible?                                       │
│                                                                             │
│   Mitigation:                                                              │
│   - Keep previous version artifacts available                             │
│   - Automated rollback triggers (error rate threshold)                    │
│   - Blue-green deployment for zero-downtime rollback                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Summary: Additional Failure Modes

| Category | Key Scenarios | Impact on Architecture |
|----------|--------------|----------------------|
| **Split Brain** | Partition during consensus | VRR prevents; gossip needs TTLs |
| **Gray Failures** | Slow nodes, packet loss | Need latency monitoring, adaptive timeouts |
| **Cascading** | Retry storms, thundering herd | Need backpressure, rate limiting |
| **Clock Skew** | TTL calculation, ordering | Use NTP, tolerate skew in calculations |
| **State Recovery** | Node rejoin, cache warming | VRR handles; routers need strategy |
| **Idempotency** | Duplicate requests | Need request ID tracking |
| **Backpressure** | Overload propagation | Need explicit limits and signals |
| **Config Propagation** | Change visibility delay | Document delay, handle restrictive changes |
| **Resource Exhaustion** | FD, memory, CPU, bandwidth | Need limits and monitoring |
| **Deployments** | Rolling updates, rollback | Need version compatibility, canary deploys |

---

## Open Questions from Failure Analysis

1. **Quorum placement for Option A**
   - If we spread globally: resilient but slower
   - If we concentrate: faster but correlated failure risk
   - Hybrid possible? (2 in US, 1 in EU for 3-node group)

2. **Failover automation level**
   - Automatic failover vs manual intervention?
   - What failures trigger automatic response?
   - What requires human decision?

3. **External dependency resilience**
   - Turso is a hard dependency for Honeycomb
   - S3 is a hard dependency for storage
   - What's our stance on multi-cloud for these?

4. **Queue durability**
   - Router queues are ephemeral - is this acceptable?
   - Should we persist queues for at-least-once delivery?
   - Trade-off: complexity vs request loss on failure

---

## Next Steps

1. **Prototype VRR in Zig**
   - Start with single-node state machine
   - Add replication
   - Add view change
   - DST test harness

2. **Define state machine commands**
   - What operations does Hivemind CP need?
   - What's the state schema?

3. **Design cross-region protocol**
   - Gossip message format
   - Explicit coordination RPCs
   - Failure detection

4. **Benchmark latency targets**
   - What's acceptable for each operation type?
   - This drives topology decisions

---

## References

- [Viewstamped Replication Revisited](https://pmg.csail.mit.edu/papers/vr-revisited.pdf) - Liskov & Cowling
- [TigerBeetle's VRR Implementation](https://github.com/tigerbeetle/tigerbeetle/tree/main/src/vsr) - Production Zig VRR
- [Designing Data-Intensive Applications](https://dataintensive.net/) - Kleppmann, Ch. 8-9
- [Jepsen Testing](https://jepsen.io/) - Distributed systems testing methodology

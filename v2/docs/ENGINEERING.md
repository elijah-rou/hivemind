# Hivemind Engineering Principles

> Core engineering principles that must be followed when building all Hivemind components. These principles ensure testability, reliability, and maintainability regardless of implementation timeline.

---

## Overview

Hivemind uses a dual-language approach based on whether a component requires **deterministic simulation testing (DST)**:

| Requirement | Language | Components |
|-------------|----------|------------|
| DST-critical | **Zig** | `core/` control plane, consensus, scheduler, gossip |
| Runtime-critical | **Rust** | `worker/` node agent and runtime simulation |
| Orchestration/glue | **Go** | `api/` gateway and benchmark tooling |

We adopt the core engineering philosophy from the frozen long-term vision notes (`docs/frozen/VISION.md`):

1. **Deterministic Simulation Testing** - Design for testability from day one
2. **Static Allocation** - Bounded resources, predictable behavior
3. **Comprehensive Assertions** - Fail fast, fail loud

These principles are non-negotiable. Every component must be built with these in mind.

### Why This Split?

**Zig** provides the control needed for true DST:
- No hidden control flow (no GC, no runtime, no exceptions)
- First-class allocator injection for every allocation
- Zig 0.16 `Io` interface designed for exactly this swap
- Proven: TigerBeetle's VOPR simulation testing built entirely in Zig

**Go** provides rapid iteration for non-DST components:
- Team familiarity (existing Lambda API, CLI)
- Mature ecosystem (K8s clients, HTTP servers, Prometheus)
- Good enough performance for orchestration layers

See `docs/STATUS.md` for current implementation architecture and `docs/frozen/ARCHITECTURE.md` for historical rationale.

---

## POC v2 Engineering Gate

POC v2 work follows the same simulation-first discipline as core Hivemind changes. Do not implement presentation-gate features as live-only glue when their behavior is simulatable.

Required mapping:

| Feature area | Required deterministic coverage |
|---|---|
| `AppSpec v1` parsing/persistence/scheduling | Zig unit + VOPR/state-machine coverage |
| revisions, weighted routes, rollout/rollback | Zig VOPR coverage for success, failure, rollback, worker loss mid-rollout |
| lifecycle/readiness/routability state transitions | Zig control-plane tests plus Rust worker simulation where worker-observed state changes |
| required JuiceFS mount semantics | Rust worker unit/sim coverage; live smoke only after deterministic failure behavior exists |
| secrets and private image auth | Rust unit/sim coverage for resolution/failure/redaction; live private-registry smoke for provider-specific auth |
| pod logs/event stream | bounded retention/unit tests; live evidence for operator diagnosis |
| queue-aware serving/scale-to-zero | deterministic autoscaler/queue tests before live load tests |
| security/isolation baseline | unit/integration tests for auth failures and runtime spec restrictions where possible |

Acceptance evidence belongs in `docs/POC_V2_ACCEPTANCE.md` and `docs/POC_CHANGELOG.md`. Generated benchmark/run artifacts stay ignored unless explicitly promoted to curated docs.

Design rule: Hivemind should not clone broad Kubernetes APIs by default. Build primitives needed for inference workloads and Hivemind-native serving semantics; integrate external systems for GitOps, certs, logging backends, and provider identity where cloning has poor ROI.

## Stable storage and group commit

Validated POC storage contract when a journal is configured: write/sync success before publication, fail-stop on complete I/O errors, fail-closed 1024-op retention. This is an experimental POC contract only — not production crash durability under torn writes or power loss.

1. `--data-dir` is optional. Absent: explicit logged volatile POC mode (in-memory only; not durable across restart). Present: experimental v2 single-copy file journal with an explicit warning that torn writes and power loss are not validated and are not simulated. When present, the data directory is created/chmod'd to `0700`; `journal.bin` is created mode `0600` (commands may contain registry passwords or secret names). Legacy layout v1 journals are rejected at open (no migration).
2. Journal slot writes and protocol metadata are staged on the replica control loop.
3. A single synchronous durability barrier (`fdatasync`, with `fsync` fallback) covers the flush batch for that tick.
4. Prepare / PrepareOk / client replies / worker side effects are published only after the barrier that covers their current entry identity `(op, checksum)` succeeds. A monotonic op watermark alone is not sufficient after same-op replacement (view change / StartView).
5. Any whole write/metadata/sync error sets `storage_failed`, stops consensus/client/worker traffic, and causes the production process to exit nonzero. Simulation models whole write/sync failures and unsynced-write loss only — not torn/partial sector writes or power-loss bit corruption.
6. Opening an existing `journal.bin` that is not exactly the expected layout size fails closed (no silent empty re-init of truncated/partial journals). New journals are created exclusively (`O_EXCL`) and the parent directory is fsynced. FileDisk layout is version 2: fixed-size little-endian header, metadata, LogEntry, canonical tag-first Command, and checksum input codecs, with no native struct/union bytes in the durable format. Legacy v1 is rejected. This POC does not support mixed-version peer clusters or in-place legacy-v1 journal upgrades. Operators must stop the full cluster and restart v2 with fresh data directories or legacy data explicitly archived/replaced out of band. No rolling migration or incarnation protocol is implemented or claimed. Fail-closed 1024-op retained-log lifetime cap remains.
7. Restart recovery on the experimental journal is best-effort: validate the metadata-declared committed prefix checksum chain, then rejoin via view change. VOPR enforces canonical recovered-prefix and immutable committed-prefix contracts (`observeRecovery`, StartView/DVC rejection of conflicting committed entries). Corrupt/truncated/wrong-sized journals fail-stop.
8. S3 journal backup (`aws s3 cp` of the mutable v2 `journal.bin`) is **not** an atomic restore artifact and does not guarantee a crash-consistent snapshot.

Group commit keeps sync count O(1) per tick batch (typically one prepare barrier and one commit-metadata barrier), not one sync per operation. Persistence remains on the single core loop; slow disks can still stall unrelated work. Snapshots are required before removing the 1024-operation retained-log cap. Crash-consistent versioned storage plus torn-write simulation remain a production blocker (see `docs/FINDINGS_AND_ISSUES.md`).


## Principle 1: Deterministic Simulation Testing

### The Goal

Any component should be testable in a fully deterministic environment where:
- Time is controlled (not wall-clock)
- Network behavior is injectable (latency, failures, partitions)
- All randomness is seeded and reproducible
- Tests can be replayed exactly given the same seed

### Why This Matters

```
Production bug reported
        │
        ▼
┌───────────────────┐
│ Capture inputs    │  ◄── Request trace, state snapshot
│ and seed          │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Replay in         │  ◄── Same code, deterministic environment
│ simulation        │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Bug reproduces    │  ◄── 100% reproducible
│ every time        │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│ Fix and verify    │  ◄── Add regression test with same seed
└───────────────────┘
```

### Implementation Pattern: Interface-Based Abstraction (Zig)

Every I/O operation must go through an injectable interface:

```zig
// ✅ CORRECT: Injectable dependencies via interfaces

// Clock interface for time control
const Clock = struct {
    ptr: *anyopaque,
    nowFn: *const fn (*anyopaque) i64,
    sleepFn: *const fn (*anyopaque, u64) void,

    pub fn now(self: Clock) i64 {
        return self.nowFn(self.ptr);
    }

    pub fn sleep(self: Clock, nanos: u64) void {
        self.sleepFn(self.ptr, nanos);
    }
};

// Network interface for I/O control
const Network = struct {
    ptr: *anyopaque,
    sendFn: *const fn (*anyopaque, Address, []const u8) Error!usize,
    recvFn: *const fn (*anyopaque, []u8) Error!RecvResult,

    pub fn send(self: Network, addr: Address, data: []const u8) Error!usize {
        return self.sendFn(self.ptr, addr, data);
    }

    pub fn recv(self: Network, buf: []u8) Error!RecvResult {
        return self.recvFn(self.ptr, buf);
    }
};

// Seeded RNG for deterministic randomness
const Rng = struct {
    state: u64,

    pub fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    pub fn next(self: *Rng) u64 {
        // xorshift64
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        return self.state;
    }
};

// Component uses interfaces, not concrete types
const Router = struct {
    clock: Clock,
    network: Network,
    rng: Rng,
    allocator: std.mem.Allocator,
    // ...

    pub fn init(clock: Clock, network: Network, rng: Rng, allocator: std.mem.Allocator) Router {
        return .{
            .clock = clock,
            .network = network,
            .rng = rng,
            .allocator = allocator,
        };
    }
};

// ❌ WRONG: Direct system calls
const Router = struct {
    // Uses std.time.nanoTimestamp() directly
    // Uses std.net directly
    // Uses std.crypto.random directly
    // Not testable deterministically
};
```

### Production vs Simulation Implementations

```zig
// ============================================
// Production implementations
// ============================================

const SystemClock = struct {
    pub fn interface(self: *SystemClock) Clock {
        return .{
            .ptr = self,
            .nowFn = nowImpl,
            .sleepFn = sleepImpl,
        };
    }

    fn nowImpl(_: *anyopaque) i64 {
        return std.time.nanoTimestamp();
    }

    fn sleepImpl(_: *anyopaque, nanos: u64) void {
        std.time.sleep(nanos);
    }
};

// ============================================
// Simulation implementations
// ============================================

const SimulatedClock = struct {
    current_time: *i64,  // Shared with simulator

    pub fn interface(self: *SimulatedClock) Clock {
        return .{
            .ptr = self,
            .nowFn = nowImpl,
            .sleepFn = sleepImpl,
        };
    }

    fn nowImpl(ptr: *anyopaque) i64 {
        const self = @ptrCast(*SimulatedClock, @alignCast(@alignOf(SimulatedClock), ptr));
        return self.current_time.*;
    }

    fn sleepImpl(ptr: *anyopaque, nanos: u64) void {
        // Register wake-up with simulator, don't actually sleep
        const self = @ptrCast(*SimulatedClock, @alignCast(@alignOf(SimulatedClock), ptr));
        _ = self;
        _ = nanos;
        // simulator.registerTimer(self.current_time.* + nanos);
    }
};

const SimulatedNetwork = struct {
    drop_rate: f64,
    min_latency_ns: u64,
    max_latency_ns: u64,
    rng: *Rng,
    pending_packets: std.ArrayList(Packet),
    simulator_time: *i64,

    pub fn interface(self: *SimulatedNetwork) Network {
        return .{
            .ptr = self,
            .sendFn = sendImpl,
            .recvFn = recvImpl,
        };
    }

    fn sendImpl(ptr: *anyopaque, addr: Address, data: []const u8) Error!usize {
        const self = @ptrCast(*SimulatedNetwork, @alignCast(@alignOf(SimulatedNetwork), ptr));

        // Deterministic packet handling using seeded RNG
        const rand_val = @intToFloat(f64, self.rng.next()) / @intToFloat(f64, std.math.maxInt(u64));
        if (rand_val < self.drop_rate) {
            return error.NetworkTimeout;  // Simulated drop
        }

        const latency_range = self.max_latency_ns - self.min_latency_ns;
        const latency = self.min_latency_ns + (self.rng.next() % latency_range);

        try self.pending_packets.append(.{
            .data = data,
            .deliver_at = self.simulator_time.* + @intCast(i64, latency),
            .dest = addr,
        });

        return data.len;
    }

    fn recvImpl(ptr: *anyopaque, buf: []u8) Error!RecvResult {
        _ = ptr;
        _ = buf;
        // Deliver packets that have reached their delivery time
        // ...
        return error.WouldBlock;
    }
};
```

### Testing with Deterministic Simulation

```zig
const testing = std.testing;

test "router handles backend failure" {
    // Seed ensures reproducibility
    const seed: u64 = 12345;
    var sim = Simulator.init(seed, testing.allocator);
    defer sim.deinit();

    // Create simulated dependencies
    var sim_clock = sim.createClock();
    var sim_network = sim.createNetwork(.{
        .drop_rate = 0.0,
        .min_latency_ns = 1_000_000,  // 1ms
        .max_latency_ns = 5_000_000,  // 5ms
    });
    var rng = Rng.init(seed);

    // Create router with simulated dependencies
    var router = Router.init(
        sim_clock.interface(),
        sim_network.interface(),
        rng,
        testing.allocator,
    );
    defer router.deinit();

    // Add backends
    try router.addBackend("backend-1", addr1);
    try router.addBackend("backend-2", addr2);

    // Send requests
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        _ = try router.route(request);
    }

    // Advance simulated time
    sim.advance(10 * std.time.ns_per_s);

    // Inject failure - partition backend-1
    sim.partitionNetwork(addr1);

    // More requests should route to backend-2
    i = 0;
    while (i < 100) : (i += 1) {
        const result = router.route(request);
        try testing.expect(result != error.NoBackendAvailable);
    }

    sim.advance(10 * std.time.ns_per_s);

    // Verify
    try testing.expectEqual(@as(u64, 100), router.metrics().backend_1_requests);
    try testing.expectEqual(@as(u64, 100), router.metrics().backend_2_requests);
}

test "router regression issue 1234" {
    // Replay exact conditions from production bug
    const seed: u64 = 98765;  // Captured from production
    var sim = Simulator.init(seed, testing.allocator);
    defer sim.deinit();

    // ... exact replay of issue conditions

    // This test will fail until bug is fixed,
    // then serves as regression test forever
}
```

### Per-Component Requirements

| Component | Clock | Network | Storage | RNG |
|-----------|-------|---------|---------|-----|
| Router | ✓ Timeouts, health checks | ✓ Backend communication | - | ✓ Load balancing |
| Honeycomb | ✓ Cache TTL | ✓ P2P distribution | ✓ Layer storage | ✓ Peer selection |
| Beekeeper | ✓ Build timeouts | ✓ Registry push | ✓ Cache storage | - |
| Hivemind | ✓ Scaling cooldowns | ✓ Agent communication | ✓ State persistence | ✓ Scheduling tiebreakers |
| Agent | ✓ Metric intervals | ✓ Control plane comm | ✓ Local state | - |

---

## Principle 2: Static Allocation

### The Goal

All resource-consuming data structures must have:
- Compile-time or startup-time defined capacity
- No unbounded growth in steady state
- Predictable memory footprint
- Natural backpressure when limits are reached

### Why This Matters

```
Unbounded allocation:
  Request spike → Queue grows → Memory exhaustion → OOM kill → Cascading failure

Bounded allocation:
  Request spike → Queue fills → Backpressure → Controlled rejection → System stable
```

### Implementation Pattern: Bounded Collections

```zig
// ✅ CORRECT: Bounded queue with compile-time or explicit capacity
fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        len: usize = 0,

        pub fn push(self: *Self, item: T) error{QueueFull}!void {
            if (self.len >= capacity) {
                return error.QueueFull;
            }
            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % capacity;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return item;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len >= capacity;
        }
    };
}

// Usage: compile-time bounded queue
const RequestQueue = BoundedQueue(Request, 10_000);

var queue = RequestQueue{};
queue.push(request) catch {
    // Handle backpressure
    metrics.increment("requests_rejected_queue_full");
    return error.ServiceUnavailable;
};

// ❌ WRONG: Unbounded - uses allocator, can grow forever
const UnboundedQueue = struct {
    items: std.ArrayList(Request),  // Can OOM under load
};
```

For Go components (Beekeeper, CLI), use similar bounded patterns:

```go
// ✅ CORRECT: Bounded channel in Go
type BuildQueue struct {
    items chan BuildRequest  // Buffered channel = bounded
}

func NewBuildQueue(capacity int) *BuildQueue {
    return &BuildQueue{
        items: make(chan BuildRequest, capacity),
    }
}

func (q *BuildQueue) Submit(req BuildRequest) error {
    select {
    case q.items <- req:
        return nil
    default:
        return ErrQueueFull  // Non-blocking, returns immediately if full
    }
}
```

### Configuration with Explicit Limits

```zig
// All limits must be explicit - compile-time where possible
pub const RouterConfig = struct {
    // Compile-time constants for bounded data structures
    pub const max_queue_depth: usize = 10_000;
    pub const max_connections_per_backend: usize = 100;
    pub const max_backends: usize = 1_000;
    pub const max_workloads: usize = 100_000;

    // Runtime configuration
    request_timeout_ns: u64,
    health_check_interval_ns: u64,

    /// Calculate maximum memory footprint at compile time
    pub fn maxMemoryBytes() usize {
        const queue_memory = max_workloads * max_queue_depth * @sizeOf(Request);
        const connection_memory = max_workloads * max_backends *
            max_connections_per_backend * CONN_BUFFER_SIZE;
        return queue_memory + connection_memory;
    }
};

// Compile-time verification
comptime {
    const max_mem = RouterConfig.maxMemoryBytes();
    if (max_mem > 16 * 1024 * 1024 * 1024) {  // 16GB limit
        @compileError("Router memory footprint exceeds 16GB limit");
    }
}
```

For Go components, use struct tags and validation:

```go
type BeekeeperConfig struct {
    MaxConcurrentBuilds int           `yaml:"max_concurrent_builds" validate:"required,min=1,max=100"`
    MaxQueueDepth       int           `yaml:"max_queue_depth" validate:"required,min=1,max=10000"`
    BuildTimeout        time.Duration `yaml:"build_timeout" validate:"required,min=1m,max=2h"`
}

func (c *BeekeeperConfig) Validate() error {
    return validator.New().Struct(c)
}

func (c *BeekeeperConfig) MaxMemoryBytes() int64 {
    // Estimate based on limits
    return int64(c.MaxQueueDepth) * estimatedBuildRequestSize
}
```

### Pre-allocation at Startup

```zig
const Router = struct {
    const Config = RouterConfig;

    // Pre-allocated fixed-size arrays - no runtime allocation
    workloads: [Config.max_workloads]Workload = undefined,
    workload_count: usize = 0,

    // Fixed-size connection pools
    connection_pool: [Config.max_backends * Config.max_connections_per_backend]Connection = undefined,
    connection_bitmap: std.StaticBitSet(Config.max_backends * Config.max_connections_per_backend) =
        std.StaticBitSet(Config.max_backends * Config.max_connections_per_backend).initEmpty(),

    config: Config,

    pub fn init(config: Config) Router {
        std.log.info("Router initialized with bounded capacity: {} MB max", .{
            Config.maxMemoryBytes() / 1_000_000,
        });

        return Router{
            .config = config,
        };
    }

    pub fn acquireConnection(self: *Router) ?*Connection {
        // Find free slot in pre-allocated pool
        const slot = self.connection_bitmap.toggleFirstSet() orelse return null;
        return &self.connection_pool[slot];
    }

    pub fn releaseConnection(self: *Router, conn: *Connection) void {
        const index = (@ptrToInt(conn) - @ptrToInt(&self.connection_pool)) / @sizeOf(Connection);
        self.connection_bitmap.unset(index);
    }
};
```

### Backpressure Handling

```zig
const Router = struct {
    // ... fields ...

    pub fn enqueueRequest(self: *Router, workload_id: []const u8, request: Request) !void {
        const workload = self.findWorkload(workload_id) orelse {
            return error.WorkloadNotFound;
        };

        // Try to enqueue - returns error if queue full
        workload.queue.push(request) catch {
            metrics.increment("requests_rejected_queue_full");

            // Return 503 with Retry-After header
            return error.QueueFull;
        };

        metrics.increment("requests_enqueued");
    }
};

// HTTP handler that converts errors to proper responses
fn handleRequest(router: *Router, req: *HttpRequest) HttpResponse {
    router.enqueueRequest(req.workload_id, req.body) catch |err| switch (err) {
        error.QueueFull => return HttpResponse{
            .status = 503,
            .headers = &[_]Header{.{ .name = "Retry-After", .value = "1" }},
            .body = "Service temporarily unavailable",
        },
        error.WorkloadNotFound => return HttpResponse{
            .status = 404,
            .body = "Workload not found",
        },
        else => return HttpResponse{
            .status = 500,
            .body = "Internal error",
        },
    };

    return HttpResponse{ .status = 202, .body = "Accepted" };
}
```

### Per-Component Capacity Requirements

| Component | Resource | Limit | Backpressure Action |
|-----------|----------|-------|---------------------|
| **Router** | Request queue | 10K per workload | 503 + Retry-After |
| **Router** | Connections | 100 per backend | Wait or reject |
| **Honeycomb** | Layer cache | 100GB per node | LRU eviction |
| **Honeycomb** | P2P peers | 50 per swarm | Reject new peers |
| **Beekeeper** | Build queue | 1000 builds | 429 + position in queue |
| **Beekeeper** | Concurrent builds | 10 per pool | Queue |
| **Hivemind** | Pending workloads | 100K | Reject new workloads |
| **Hivemind** | Scale events | 1K per minute | Batch/throttle |
| **Agent** | Log buffer | 100MB | Drop oldest |
| **Agent** | Metric buffer | 10MB | Drop oldest |

---

## Principle 3: Comprehensive Assertions

### The Goal

Every function should validate:
- Preconditions (inputs)
- Postconditions (outputs)
- Invariants (state consistency)

Assertions should fail fast and loud in development/testing, with graceful degradation in production.

### Why This Matters

```
Without assertions:
  Invalid state → Corrupted data → Hours of debugging → Root cause unclear

With assertions:
  Invalid state → Immediate panic with context → Exact location of bug → Fast fix
```

### Implementation Pattern: Debug Assertions

**Zig** (DST components - Router, Hivemind, Agent):

```zig
const Scheduler = struct {
    nodes: [MAX_NODES]Node = undefined,
    node_count: usize = 0,
    allocations: [MAX_ALLOCATIONS]Allocation = undefined,
    allocation_count: usize = 0,

    pub fn scheduleWorkload(self: *Scheduler, workload: *const Workload) !NodeId {
        // Precondition: workload must have valid resource requirements
        std.debug.assert(workload.cpu_millicores > 0);  // Removed in release builds
        std.debug.assert(workload.memory_bytes > 0);

        // Precondition: must have available nodes
        std.debug.assert(self.node_count > 0);

        const node_id = try self.findBestNode(workload);

        // Postcondition: selected node has capacity
        const node = self.getNode(node_id).?;
        std.debug.assert(node.available_cpu >= workload.cpu_millicores);

        // Update state
        try self.allocate(node_id, workload);

        // Invariant: total allocated never exceeds capacity
        std.debug.assert(self.verifyNoOvercommit());

        return node_id;
    }

    fn verifyNoOvercommit(self: *const Scheduler) bool {
        for (self.nodes[0..self.node_count]) |node| {
            var allocated: u64 = 0;
            for (self.allocations[0..self.allocation_count]) |alloc| {
                if (alloc.node_id == node.id) {
                    allocated += alloc.cpu_millicores;
                }
            }

            if (allocated > node.capacity_cpu) {
                std.log.err("overcommit detected: node={} allocated={} capacity={}", .{
                    node.id, allocated, node.capacity_cpu,
                });
                return false;
            }
        }
        return true;
    }
};
```

**Go** (Beekeeper, CLI - non-DST components):

```go
func (s *Scheduler) ScheduleWorkload(workload *Workload) (NodeID, error) {
    // Go doesn't have debug_assert, use explicit checks that stay in production
    // but log at debug level for non-critical assertions

    if workload.CPUMillicores == 0 {
        return "", fmt.Errorf("workload %s has zero CPU request", workload.ID)
    }

    if len(s.nodes) == 0 {
        return "", fmt.Errorf("scheduler has no registered nodes")
    }

    nodeID, err := s.findBestNode(workload)
    if err != nil {
        return "", err
    }

    // Postcondition check - log warning but don't fail in production
    node := s.nodes[nodeID]
    if node.AvailableCPU < workload.CPUMillicores {
        log.Warn().
            Str("node_id", string(nodeID)).
            Uint64("available", node.AvailableCPU).
            Uint64("requested", workload.CPUMillicores).
            Msg("postcondition violated: insufficient CPU")
    }

    s.allocate(nodeID, workload)

    // Invariant check
    if !s.verifyNoOvercommit() {
        metrics.IncrementCounter("invariant_violations")
        log.Error().Msg("scheduler violated no-overcommit invariant")
    }

    return nodeID, nil
}
```

### Invariant Checking Pattern

**Zig** - use inline functions that optimize away in release:

```zig
/// Check invariant - panics in debug, logs in release
fn invariant(condition: bool, comptime message: []const u8) void {
    if (!condition) {
        if (builtin.mode == .Debug) {
            @panic(message);
        } else {
            std.log.err("invariant violated: {s}", .{message});
            metrics.increment("invariant_violations");
        }
    }
}

// Usage
const Router = struct {
    fn routeRequest(self: *Router, request: *const Request) !Response {
        invariant(
            self.backend_count > 0,
            "router has no backends",
        );

        const backend = try self.selectBackend(request);

        invariant(
            backend.isHealthy(),
            "selected unhealthy backend",
        );

        // ... route request
    }
};
```

**Go** - explicit checks with structured logging:

```go
func (r *Router) RouteRequest(req *Request) (*Response, error) {
    if len(r.backends) == 0 {
        log.Error().Str("workload_id", req.WorkloadID).Msg("invariant: no backends")
        metrics.IncrementCounter("invariant_violations")
        return nil, ErrNoBackends
    }

    backend := r.selectBackend(req)

    if !backend.IsHealthy() {
        log.Error().
            Str("backend_id", backend.ID).
            Str("workload_id", req.WorkloadID).
            Msg("invariant: selected unhealthy backend")
        metrics.IncrementCounter("invariant_violations")
    }

    // ... route request
}
```

### State Machine Assertions

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkloadState {
    Pending,
    Scheduled,
    Running,
    Ready,
    Terminating,
    Terminated,
    Failed,
}

impl WorkloadState {
    /// Valid state transitions
    fn valid_transitions(&self) -> &'static [WorkloadState] {
        match self {
            Self::Pending => &[Self::Scheduled, Self::Failed],
            Self::Scheduled => &[Self::Running, Self::Failed, Self::Terminating],
            Self::Running => &[Self::Ready, Self::Failed, Self::Terminating],
            Self::Ready => &[Self::Terminating, Self::Failed],
            Self::Terminating => &[Self::Terminated],
            Self::Terminated => &[],
            Self::Failed => &[],
        }
    }

    pub fn transition(&self, to: WorkloadState) -> Result<WorkloadState, InvalidTransition> {
        // Assert valid transition
        if !self.valid_transitions().contains(&to) {
            let err = InvalidTransition {
                from: *self,
                to,
            };

            // Always fail in debug mode
            debug_assert!(false, "invalid state transition: {:?}", err);

            // In production, log and return error
            tracing::error!(?err, "invalid workload state transition");
            return Err(err);
        }

        Ok(to)
    }
}

impl Workload {
    pub fn set_state(&mut self, new_state: WorkloadState) -> Result<(), InvalidTransition> {
        let validated_state = self.state.transition(new_state)?;

        // Postcondition: state actually changed
        debug_assert_ne!(
            self.state, validated_state,
            "state transition to same state"
        );

        self.state = validated_state;
        self.last_transition = Instant::now();

        // Invariant: terminated/failed states are final
        if matches!(self.state, WorkloadState::Terminated | WorkloadState::Failed) {
            debug_assert!(
                self.resources_released,
                "workload {} terminated without releasing resources",
                self.id
            );
        }

        Ok(())
    }
}
```

### Property-Based Testing

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn scheduler_never_overcommits(
        workloads in prop::collection::vec(arbitrary_workload(), 1..100),
        nodes in prop::collection::vec(arbitrary_node(), 1..10),
    ) {
        let mut scheduler = Scheduler::new(nodes);

        for workload in workloads {
            // Ignore failures (expected when no capacity)
            let _ = scheduler.schedule_workload(&workload);
        }

        // Invariant must hold after any sequence of operations
        assert!(
            scheduler.verify_no_overcommit(),
            "scheduler overcommitted resources"
        );
    }

    #[test]
    fn bounded_queue_never_exceeds_capacity(
        items in prop::collection::vec(any::<u64>(), 0..1000),
        capacity in 1usize..100,
    ) {
        let mut queue = BoundedQueue::new(capacity);

        for item in items {
            let _ = queue.push(item);

            // Invariant: never exceed capacity
            assert!(queue.len() <= capacity);
        }
    }

    #[test]
    fn workload_state_machine_valid(
        transitions in prop::collection::vec(arbitrary_state(), 0..20),
    ) {
        let mut workload = Workload::new();

        for target_state in transitions {
            // State machine should either succeed or return error
            // It should never panic or leave invalid state
            match workload.set_state(target_state) {
                Ok(()) => {
                    // Verify state changed
                    assert_eq!(workload.state, target_state);
                }
                Err(InvalidTransition { from, to }) => {
                    // Verify state unchanged
                    assert_eq!(workload.state, from);
                    // Verify transition was actually invalid
                    assert!(!from.valid_transitions().contains(&to));
                }
            }
        }
    }
}
```

### Assertion Checklist per Component

| Component | Preconditions | Postconditions | Invariants |
|-----------|--------------|----------------|------------|
| **Router** | Valid request, workload exists | Response or error, queue updated | Queue depth ≤ max, healthy backends exist |
| **Honeycomb** | Valid content hash, authorized | Layer stored/retrieved | Content hash matches, no orphan layers |
| **Beekeeper** | Valid build spec, authorized | Image pushed or error | Build resources released, cache consistent |
| **Hivemind** | Valid workload spec | Scheduled or error | No overcommit, state machine valid |
| **Agent** | Valid module config | Module running or error | Resource usage bounded, metrics accurate |

---

## Implementation Checklist

Before any PR is merged, verify:

### Deterministic Testing
- [ ] All I/O goes through injectable traits (Clock, Network, Storage, Rng)
- [ ] Simulation implementations exist for all traits
- [ ] At least one deterministic simulation test exists
- [ ] Tests use seeded RNG where randomness is needed

### Static Allocation
- [ ] All collections have explicit capacity limits in config
- [ ] No `Vec::new()` without `with_capacity()`
- [ ] Backpressure behavior documented for when limits are reached
- [ ] Memory footprint calculable from config

### Assertions
- [ ] Preconditions checked at function entry
- [ ] Postconditions verified before return
- [ ] State machine transitions validated
- [ ] Invariants checked after state mutations
- [ ] Property-based tests for core logic

### Code Review Questions

1. "What happens when this queue/map/buffer fills up?"
2. "How would I replay this exact scenario in a test?"
3. "What invariants should hold after this function runs?"
4. "Can this code be tested without real I/O?"

---

## Appendix: Simulator Framework

### Core Simulator Structure

```rust
pub struct Simulator {
    /// Seeded random number generator
    rng: StdRng,

    /// Virtual time (nanoseconds since epoch)
    time: u64,

    /// Pending events ordered by time
    events: BinaryHeap<ScheduledEvent>,

    /// Simulated network state
    network: SimulatedNetwork,

    /// Simulated storage state
    storage: SimulatedStorage,
}

impl Simulator {
    pub fn new(seed: u64) -> Self {
        Self {
            rng: StdRng::seed_from_u64(seed),
            time: 0,
            events: BinaryHeap::new(),
            network: SimulatedNetwork::new(),
            storage: SimulatedStorage::new(),
        }
    }

    /// Advance simulation by duration
    pub fn advance(&mut self, duration: Duration) {
        let target_time = self.time + duration.as_nanos() as u64;

        while let Some(event) = self.events.peek() {
            if event.time > target_time {
                break;
            }

            let event = self.events.pop().unwrap();
            self.time = event.time;
            (event.handler)(self);
        }

        self.time = target_time;
    }

    /// Schedule event at future time
    pub fn schedule(&mut self, delay: Duration, handler: impl FnOnce(&mut Self) + 'static) {
        self.events.push(ScheduledEvent {
            time: self.time + delay.as_nanos() as u64,
            handler: Box::new(handler),
        });
    }

    /// Inject network partition
    pub fn partition(&mut self, addr1: SocketAddr, addr2: SocketAddr) {
        self.network.add_partition(addr1, addr2);
    }

    /// Heal network partition
    pub fn heal_partition(&mut self, addr1: SocketAddr, addr2: SocketAddr) {
        self.network.remove_partition(addr1, addr2);
    }
}
```

### Running Simulation Tests

```rust
#[test]
fn test_scheduler_under_network_partition() {
    let seed = std::env::var("TEST_SEED")
        .map(|s| s.parse().unwrap())
        .unwrap_or_else(|_| rand::random());

    println!("Running with seed: {}", seed);

    let mut sim = Simulator::new(seed);

    // Setup components with simulated deps
    let hivemind = Hivemind::new(
        sim.create_clock(),
        sim.create_network(),
        sim.create_storage(),
    );

    let agent1 = Agent::new(/* ... */);
    let agent2 = Agent::new(/* ... */);

    // Run scenario
    sim.spawn(async {
        hivemind.schedule_workload(workload).await;
    });

    sim.advance(Duration::from_secs(5));

    // Inject partition between hivemind and agent1
    sim.partition(hivemind.addr(), agent1.addr());

    sim.advance(Duration::from_secs(30));

    // Verify: workload should be rescheduled to agent2
    assert_eq!(
        hivemind.get_workload_location(workload.id),
        Some(agent2.node_id())
    );
}
```

---

## Related Documents

- [STATUS.md](STATUS.md) - Current implementation architecture and verification state
- [FINDINGS_AND_ISSUES.md](FINDINGS_AND_ISSUES.md) - Active production gaps and backlog
- [design/TESTING.md](design/TESTING.md) - Testing strategy and go/no-go criteria
- [frozen/VISION.md](frozen/VISION.md) - Historical long-term vision with Zig/VOPR notes

## Run request length contract

Run request bodies are bounded by `MAX_PAYLOAD = 512` bytes (Zig `request_queue.MAX_PAYLOAD`, Go `MaxRunPayload`, Rust `MAX_RUN_PAYLOAD`).

Declared `payload_len` must equal the trailing body byte count exactly (no clamp, truncation, or trailing bytes). Oversized or mismatched lengths are rejected. Gateway `sendRunError` replies remain 9 bytes (status only); successful client run responses require an exact length prefix. Zero-length and exactly-512 bodies are valid.

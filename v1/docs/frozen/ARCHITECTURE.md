<div align="center">

# Hivemind Architecture

<img src="hivemind3.png" alt="Hivemind Logo" />

</div>

> **Practical Implementation Architecture** - This document describes the current implementation plan for Hivemind, a 6-month effort to modernize the AI platform. For the long-term aspirational vision, see [VISION.md](VISION.md).

---

## Overview

Hivemind is a unified platform for building, distributing, and running AI workloads. It replaces the current patchwork of systems (Knative, Depot, multiple DaemonSets) with purpose-built components optimized for GPU workloads.

### Workload Types

Hivemind supports three distinct workload types:

| Type | Description | Lifecycle | Access Pattern |
|------|-------------|-----------|----------------|
| **Serverless** | Request/response inference | Scale 0→N based on demand | HTTP/gRPC via Router |
| **Job** | Run-to-completion tasks | Start → Run → Complete | API submission, async results |
| **Instance** | Persistent VM-like workloads | Always-on or timed lease | SSH shell, HTTP endpoints |

See [design/WORKLOAD_TYPES.md](design/WORKLOAD_TYPES.md) for detailed design.

### Design Goals

| Goal | Description |
|------|-------------|
| **Simplicity** | Replace complex Kubernetes abstractions with focused components |
| **Performance** | Minimize cold start latency, maximize GPU utilization |
| **Cost** | Reduce infrastructure costs through better scheduling and in-house tooling |
| **Reliability** | Graceful degradation, queue-based routing, demand-driven scaling |
| **Maintainability** | Single binary agent, unified control plane, clear ownership |

---

## Engineering Principles

All components must be built following these non-negotiable principles from our [engineering standards](ENGINEERING.md):

### 1. Deterministic Simulation Testing

Every component must be testable in a fully deterministic environment:

```zig
// All I/O through injectable interfaces (Zig 0.16)
const Io = struct {
    readFn: *const fn ([]u8) Error!usize,
    writeFn: *const fn ([]const u8) Error!usize,
    // ...
};

// Components accept I/O interface, enabling simulation
const Router = struct {
    io: Io,
    clock: Clock,
    allocator: std.mem.Allocator,

    pub fn init(io: Io, clock: Clock, allocator: std.mem.Allocator) Router {
        return .{ .io = io, .clock = clock, .allocator = allocator };
    }
};
```

This enables:
- Exact bug reproduction with captured seeds
- Testing network partitions, latency, failures
- Time control for testing timeouts and cooldowns

### 2. Static Allocation

All data structures have bounded capacity:

```zig
// ✅ Bounded queue - predictable memory, natural backpressure
const RequestQueue = struct {
    items: std.BoundedArray(Request, MAX_QUEUE_SIZE),  // Compile-time capacity

    pub fn push(self: *RequestQueue, req: Request) error{QueueFull}!void {
        self.items.append(req) catch return error.QueueFull;
    }
};

// ❌ Unbounded - memory exhaustion under load
const RequestQueue = struct {
    items: std.ArrayList(Request),  // Can grow forever
};
```

### 3. Comprehensive Assertions

Every function validates preconditions, postconditions, and invariants:

```zig
pub fn scheduleWorkload(self: *Scheduler, workload: *const Workload) !NodeId {
    // Precondition
    std.debug.assert(workload.cpu > 0); // "invalid CPU request"

    const node = try self.findBestNode(workload);

    // Postcondition
    std.debug.assert(node.hasCapacityFor(workload));

    self.allocate(node, workload);

    // Invariant
    std.debug.assert(self.verifyNoOvercommit());

    return node.id;
}
```

**Full documentation**: [ENGINEERING.md](ENGINEERING.md)

---

## Language Philosophy

### The Decision Framework

Language choice is driven by a single question: **Does this component need true deterministic simulation testing (DST)?**

```
Does component need DST?
         │
         ├─── No ──► Go (team familiarity, mature ecosystem)
         │
         └─── Yes ──► Does it need consensus (VSR)?
                              │
                              ├─── No ──► Zig or Rust
                              │
                              └─── Yes ──► Zig (proven for this exact use case)
```

### Why Zig Over Rust for DST-Critical Components

Both Zig and Rust are valid choices for performance-critical systems. However, for components requiring **true deterministic simulation**, Zig has specific advantages:

| Concern | Rust | Zig |
|---------|------|-----|
| **Hidden control flow** | Panics, Drop impls, async runtime | None - what you write is what executes |
| **Async determinism** | Tokio scheduler is non-deterministic | Zig 0.16 `Io` interface designed for swapping |
| **Allocator control** | Global allocator, harder to inject per-component | First-class allocator parameter everywhere |
| **Cognitive load** | Borrow checker, lifetimes, trait bounds | C-like simplicity, all paths traceable |
| **Proven for consensus** | No equivalent to TigerBeetle's VOPR | TigerBeetle built VSR + VOPR in Zig |

**The core issue**: For DST, you must control ALL sources of non-determinism. Rust's async runtime and implicit behaviors (Drop, panics) make this harder. Zig's "no hidden control flow" philosophy makes it achievable.

### Why Go for Non-DST Components

For components where deterministic simulation isn't critical:

- **Team familiarity**: Hivemind already uses Go for Lambda API and CLI
- **Faster iteration**: Less ceremony than Rust/Zig for CRUD-style code
- **Mature ecosystem**: HTTP servers, Kubernetes clients, observability tooling
- **Good enough performance**: GC pauses acceptable for non-latency-critical paths

### When Rust Could Be Reconsidered

Rust remains a valid choice if:

1. Team already has deep Rust expertise and wants to maintain one systems language
2. Component needs performance but "interface-mocked testing" (not true DST) is sufficient
3. Mature crate ecosystem provides significant value (e.g., async HTTP, gRPC)

However, for Hivemind's goals—particularly scheduler determinism and potential VSR consensus—Zig's simplicity and TigerBeetle's proof point make it the better choice.

---

## Language Decisions by Component

| Component | Language | DST Required | Consensus | Rationale |
|-----------|----------|--------------|-----------|-----------|
| **Router** | Zig | ✓ Yes | Possibly | Routing decisions, queue behavior, failure handling must be testable under all conditions. May need VSR for consistent routing across instances. |
| **Honeycomb** (core) | Zig | ✓ Yes | Possibly | P2P protocols, cache eviction, regional sync require deterministic testing. Regional coordination may need consensus. |
| **Honeycomb** (OCI API) | Go | No | No | Standard HTTP API layer. Team familiarity, mature OCI libraries. |
| **Beekeeper** | Go | No | No | Orchestration around BuildKit. Builds are independent operations. No consensus needed—queue ordering via SQS. |
| **Hivemind Control Plane** | Zig | ✓ Yes | ✓ Yes | Scheduling decisions must be deterministic. Multi-cluster coordination likely needs VSR for consistency. |
| **Agent** | Zig | ✓ Yes | No | Binary size and memory efficiency critical (runs on every node). GPU allocation and storage mounting need DST. |
| **CLI** | Go | No | No | Team familiarity. User-facing tool where iteration speed matters more than DST. |
| **Observability Exporters** | Go | No | No | Standard Prometheus/metrics integrations. Well-supported Go ecosystem. |

### Zig 0.16 I/O interface

Zig 0.16’s `Io` interface enables exactly the abstraction pattern we need:

```zig
// Production: real system calls
const io = std.io.getStdIo();

// Testing: simulated I/O with controlled behavior
const io = SimulatedIo.init(seed);
```

This is a language-level feature designed for our exact use case—swapping real I/O for simulated I/O to enable deterministic replay.

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        HIVEMIND PLATFORM                             │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                      CONTROL PLANE                            │  │
│   │                                                               │  │
│   │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐        │  │
│   │   │   Router    │   │  Scheduler  │   │  Autoscaler │        │  │
│   │   │             │   │             │   │             │        │  │
│   │   │ Queue-based │   │Cross-cluster│   │ Queue-depth │        │  │
│   │   │  routing    │   │ placement   │   │   driven    │        │  │
│   │   └──────┬──────┘   └──────┬──────┘   └──────┬──────┘        │  │
│   │          │                 │                 │                │  │
│   │          └─────────────────┼─────────────────┘                │  │
│   │                            │                                  │  │
│   │                     ┌──────▼──────┐                           │  │
│   │                     │  Hivemind   │                           │  │
│   │                     │   Control   │                           │  │
│   │                     │   Plane     │                           │  │
│   │                     └─────────────┘                           │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
│   ┌──────────────────────────────────────────────────────────────┐  │
│   │                      DATA PLANE                               │  │
│   │                                                               │  │
│   │   ┌─────────────┐   ┌─────────────┐   ┌─────────────┐        │  │
│   │   │  Honeycomb  │   │  Beekeeper  │   │    Agent    │        │  │
│   │   │             │   │             │   │             │        │  │
│   │   │ OCI Registry│   │   Build     │   │ Single node │        │  │
│   │   │ + P2P Cache │   │   System    │   │   binary    │        │  │
│   │   └─────────────┘   └─────────────┘   └─────────────┘        │  │
│   │                                                               │  │
│   └──────────────────────────────────────────────────────────────┘  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### Phase 1: Router

**Purpose**: Queue-based request routing with graceful scaling integration.

**Key Features**:
- In-process Rust router (replaces Axum server)
- Request queuing during scale-up (no immediate 503s)
- Queue depth metrics for autoscaler
- Graceful connection draining
- Bidirectional communication with Hivemind control plane

**Architecture**:
```
                    ┌─────────────────────────┐
                    │         Router          │
                    │                         │
   Request ───────► │  ┌─────────────────┐   │
                    │  │  Request Queue  │   │ ◄──── Queue Depth
                    │  │   (per workload)│   │       Metrics
                    │  └────────┬────────┘   │
                    │           │            │
                    │           ▼            │
                    │  ┌─────────────────┐   │
                    │  │ Backend Selector│   │
                    │  │  (health-aware) │   │
                    │  └────────┬────────┘   │
                    │           │            │
                    └───────────┼────────────┘
                                │
                                ▼
                    ┌─────────────────────────┐
                    │    Workload Instances   │
                    └─────────────────────────┘
```

**Technology**: Zig (requires DST for routing decisions, queue behavior, failure handling)

**Documentation**: [design/ROUTER.md](design/ROUTER.md)

---

### Phase 2: Honeycomb

**Purpose**: Container registry and content distribution system optimized for large AI images.

**Key Features**:
- OCI-compatible registry API
- Content-addressable layer storage (S3 + Turso metadata)
- P2P layer distribution between nodes
- Regional caching hierarchy
- Optional Nydus lazy loading

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                         HONEYCOMB                                │
│                                                                  │
│   ┌────────────────┐                    ┌────────────────┐      │
│   │  Registry API  │                    │  Layer Storage │      │
│   │                │                    │                │      │
│   │  OCI v2 Spec   │                    │  S3 + Turso    │      │
│   │  Manifest ops  │                    │  Deduplication │      │
│   └───────┬────────┘                    └───────┬────────┘      │
│           │                                     │               │
│           └──────────────┬──────────────────────┘               │
│                          │                                      │
│                          ▼                                      │
│           ┌──────────────────────────────┐                      │
│           │      P2P Distribution        │                      │
│           │                              │                      │
│           │  BitTorrent-style chunking   │                      │
│           │  Regional supernodes         │                      │
│           │  Peer discovery              │                      │
│           └──────────────────────────────┘                      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Technology**: Zig (core P2P/distribution) + Go (OCI API layer)

**Documentation**: [design/HONEYCOMB.md](design/HONEYCOMB.md)

---

### Phase 3: Beekeeper

**Purpose**: Container image build system replacing Depot.

**Key Features**:
- BuildKit-based builder pool
- SQS-based build queue
- Distributed S3 cache
- Automatic Dockerfile generation from app.toml
- Integration with Honeycomb registry

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                         BEEKEEPER                                │
│                                                                  │
│   ┌────────────────┐    ┌────────────────┐    ┌──────────────┐  │
│   │   Build API    │    │   Build Queue  │    │ Builder Pool │  │
│   │                │    │                │    │              │  │
│   │  Submit builds │───►│   SQS-based    │───►│  BuildKit    │  │
│   │  Check status  │    │   ordering     │    │  executors   │  │
│   └────────────────┘    └────────────────┘    └──────┬───────┘  │
│                                                       │         │
│                                                       ▼         │
│   ┌────────────────────────────────────────────────────────┐    │
│   │                    Build Cache (S3)                     │    │
│   │                                                         │    │
│   │  Layer caching   │   Dependency caching   │   Artifacts │    │
│   └────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Technology**: Go + BuildKit (orchestration layer, no DST/consensus requirements)

**Documentation**: [design/BEEKEEPER.md](design/BEEKEEPER.md)

---

### Phase 4: Hivemind Control Plane

**Purpose**: Unified workload management, scheduling, and autoscaling for all workload types.

**Key Features**:
- Unified WorkloadSpec API with kind (serverless, job, cronjob, instance)
- Cross-cluster scheduler with data locality scoring
- Type-specific controllers:
  - **Autoscaler**: Queue-depth-driven scaling for serverless workloads
  - **Job Controller**: Run-to-completion semantics, cron scheduling
  - **Instance Controller**: Persistent workloads, SSH access, timed leases
- Direct pod management (bypassing Knative)
- SSH Gateway for instance shell access

**Workload Controllers**:
```
┌───────────────────────────────────────────────────────────────┐
│                    HIVEMIND CONTROL PLANE                      │
│                                                                │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────────────┐  │
│  │  Autoscaler │   │ Job         │   │ Instance            │  │
│  │  (Serverless)│   │ Controller  │   │ Controller          │  │
│  │             │   │             │   │                     │  │
│  │ Scale 0→N   │   │ Completions │   │ SSH Gateway         │  │
│  │ Queue-driven│   │ Cron jobs   │   │ Timed leases        │  │
│  │ Concurrency │   │ Backoff     │   │ Workspace storage   │  │
│  └─────────────┘   └─────────────┘   └─────────────────────┘  │
│                                                                │
│               ┌─────────────────────────┐                     │
│               │      Scheduler          │                     │
│               │  Cross-cluster scoring  │                     │
│               └─────────────────────────┘                     │
└───────────────────────────────────────────────────────────────┘
```

**Scheduler Scoring**:
```
Score = Data Locality (40) + Queue Depth (25) + Capacity (20) + Bin Packing (15)
```

**Workload State Machine** (serverless):
```
┌─────────┐     ┌───────────┐     ┌─────────┐     ┌───────┐
│ Pending │────►│ Scheduled │────►│ Running │────►│ Ready │
└────┬────┘     └─────┬─────┘     └────┬────┘     └───┬───┘
     │                │                │              │
     ▼                ▼                ▼              ▼
┌─────────┐     ┌───────────┐     ┌─────────┐     ┌───────────┐
│ Failed  │     │  Failed   │     │ Failed  │     │Terminating│
└─────────┘     └───────────┘     └─────────┘     └───────────┘
```

**Technology**: Zig (requires DST for scheduling, likely needs VSR for multi-cluster consensus)

**Documentation**: [design/HIVEMIND.md](design/HIVEMIND.md), [design/WORKLOAD_TYPES.md](design/WORKLOAD_TYPES.md)

---

### Phase 5: Agent

**Purpose**: Single node binary replacing 6+ DaemonSets.

**Replaces**:
| Current DaemonSet | Agent Module |
|-------------------|--------------|
| node_exporter | Metrics module |
| DCGM exporter | Metrics module (GPU) |
| Fluent Bit | Logs module |
| Dragonfly | P2P module |
| JuiceFS CSI | Storage module |
| NVIDIA device plugin | GPU module |

**Architecture**:
```
┌─────────────────────────────────────────────────────────────────┐
│                           AGENT                                  │
│                      (Single Binary)                             │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    Core Runtime                          │   │
│   │  Config │ Health │ Feature Flags │ Control Plane Comm   │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│   ┌───────────┐ ┌───────────┐ ┌───────────┐ ┌───────────┐      │
│   │  Metrics  │ │   Logs    │ │    P2P    │ │  Storage  │      │
│   │           │ │           │ │           │ │           │      │
│   │ CPU/Mem/  │ │ Container │ │ Honeycomb │ │ JuiceFS   │      │
│   │ GPU/Disk  │ │ stdout/   │ │ layer     │ │ mount/    │      │
│   │ Network   │ │ stderr    │ │ sharing   │ │ unmount   │      │
│   └───────────┘ └───────────┘ └───────────┘ └───────────┘      │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    GPU Module                            │   │
│   │  Device Discovery │ NVML Metrics │ Device Plugin API    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Technology**: Zig (binary size + memory efficiency critical, DST for GPU allocation/storage)

**Documentation**: [design/AGENT.md](design/AGENT.md)

---

## Cross-Cutting Concerns

### Provider Abstraction

Hivemind operates across multiple compute providers:

| Provider Type | Examples | Use Case |
|---------------|----------|----------|
| **VM/Instance** | AWS EC2, Crusoe, Lambda Labs | Primary compute |
| **Kubernetes** | EKS, GKE, on-prem | Existing infrastructure |
| **Bare Metal** | Equinix, dedicated | Maximum performance |

**Why multi-provider?**
- **Regional coverage**: Different providers have different geographic presence
- **Scarce compute**: H100/H200/B200 availability varies by provider
- **Cost optimization**: Take advantage of pricing differences
- **Resilience**: No single provider dependency

**The unifying principle**: Once the Hivemind Agent runs on any compute, it becomes a standard Hivemind node. Provider complexity is contained at provisioning.

**Documentation**: [design/PROVIDERS.md](design/PROVIDERS.md)

### Security

Comprehensive security model covering:
- Multi-tenant isolation
- mTLS between all components
- RBAC for workload management
- Compliance frameworks (SOC 2, GDPR, HIPAA, PCI DSS)
- Audit logging

**Documentation**: [design/SECURITY.md](design/SECURITY.md)

### Testing

Systematic testing strategy:
- Unit tests (75%), Integration tests (20%), E2E tests (5%)
- Load testing with k6
- Chaos engineering with Chaos Mesh
- Go/no-go criteria per phase

**Documentation**: [design/TESTING.md](design/TESTING.md)

---

## Technology Stack

| Layer | Technology | Rationale |
|-------|------------|-----------|
| **Language (DST-critical)** | Zig | DST support, no hidden control flow, allocator control, proven for consensus |
| **Language (orchestration)** | Go | Team familiarity, mature ecosystem, good enough performance |
| **Database** | Turso (SQLite) | Edge-compatible, low latency |
| **Object Storage** | S3 | Layer storage, build cache |
| **Queue** | SQS | Build queue, reliable ordering |
| **Container Runtime** | containerd | Industry standard |
| **Build System** | BuildKit | Layer caching, multi-platform |

---

## Implementation Timeline

### 6-Month Roadmap

```
Month 1: Router
├── In-process Rust router
├── Queue-based routing
├── Graceful scaling integration
└── Migration: Shadow mode → Canary → Full

Month 2: Honeycomb
├── OCI registry implementation
├── S3 layer storage + Turso metadata
├── P2P distribution (simplified)
└── Migration: Parallel registry → Switch pulls

Month 3: Beekeeper
├── BuildKit pool setup
├── SQS queue integration
├── Dockerfile generation
└── Migration: Canary builds → Full replacement of Depot

Month 4: Hivemind Control Plane
├── Unified WorkloadSpec API
├── Single-cluster scheduler
├── Queue-depth autoscaler
└── Migration: API wrapper → Direct pod management

Month 5: Agent
├── Metrics + Logs modules
├── P2P + Storage modules
├── Systemd integration
└── Migration: Module-by-module replacement

Month 6: Advanced Features
├── Cross-cluster scheduling
├── GPU module (if deferred)
├── Nydus lazy loading (if deferred)
└── Performance optimization
```

**Documentation**: [PROJECT_PLAN.md](PROJECT_PLAN.md), [MIGRATION.md](MIGRATION.md)

---

## Migration Strategy

### Principles

1. **Zero downtime**: All migrations use canary/shadow patterns
2. **Reversible**: Every phase has documented rollback procedures
3. **Observable**: Metrics parity before, during, and after migration
4. **Incremental**: Small changes, frequent validation

### Phase Dependencies

```
Router ──► Honeycomb ──► Beekeeper ──► Hivemind ──► Agent
  │            │            │            │           │
  └────────────┴────────────┴────────────┴───────────┘
                All depend on Router stability
```

**Documentation**: [MIGRATION.md](MIGRATION.md)

---

## Open Questions

Key decisions to be made before implementation:

1. **Cold-start latency target?** - Drives Nydus priority
2. **Concurrent build capacity?** - Drives Beekeeper pool size
3. **Cross-cluster latency budget?** - Affects scheduler design
4. **Rollback SLA?** - Drives automation requirements
5. **Multi-tenant isolation level?** - Affects security design

**Full list**: [REVIEW.md](REVIEW.md#open-questions)

---

## Document Index

| Document | Purpose |
|----------|---------|
| [PLATFORM.md](PLATFORM.md) | High-level platform concepts |
| [ARCHITECTURE.md](ARCHITECTURE.md) | This document - practical implementation |
| [ENGINEERING.md](ENGINEERING.md) | **Core engineering principles (must read)** |
| [VISION.md](VISION.md) | Long-term aspirational vision |
| [PROJECT_PLAN.md](PROJECT_PLAN.md) | Timeline and milestones |
| [MIGRATION.md](MIGRATION.md) | Migration strategy |
| [REVIEW.md](REVIEW.md) | Gaps, compromises, open questions |
| [design/ROUTER.md](design/ROUTER.md) | Phase 1 detailed design |
| [design/HONEYCOMB.md](design/HONEYCOMB.md) | Phase 2 detailed design |
| [design/BEEKEEPER.md](design/BEEKEEPER.md) | Phase 3 detailed design |
| [design/HIVEMIND.md](design/HIVEMIND.md) | Phase 4 detailed design |
| [design/AGENT.md](design/AGENT.md) | Phase 5 detailed design |
| [design/WORKLOAD_TYPES.md](design/WORKLOAD_TYPES.md) | **Jobs, CronJobs, and Instances design** |
| [design/AGENT_NATIVE.md](design/AGENT_NATIVE.md) | **Future: Agent-native infrastructure (Phase 6+)** |
| [design/SECURITY.md](design/SECURITY.md) | Security and compliance model |
| [design/TESTING.md](design/TESTING.md) | Testing strategy |
| [design/PROVIDERS.md](design/PROVIDERS.md) | **Multi-provider abstraction layer** |

---

## Getting Started

### For Developers

1. Read [PLATFORM.md](PLATFORM.md) for high-level concepts
2. Read this document for implementation overview
3. Read the relevant phase design doc for your component
4. Check [REVIEW.md](REVIEW.md) for known gaps and open questions

### For Operators

1. Read [MIGRATION.md](MIGRATION.md) for migration procedures
2. Read [design/TESTING.md](design/TESTING.md) for go/no-go criteria
3. Read [design/SECURITY.md](design/SECURITY.md) for compliance requirements

### For Leadership

1. Read [PROJECT_PLAN.md](PROJECT_PLAN.md) for timeline
2. Read [REVIEW.md](REVIEW.md) for risks and compromises
3. Review open questions that need business input

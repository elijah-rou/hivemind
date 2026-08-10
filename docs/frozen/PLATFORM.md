> **NOTE**: This describes the aspirational platform architecture. For current implementation state, see [`docs/STATUS.md`](STATUS.md).

# Hivemind Platform Architecture

## Overview

The Hivemind platform consists of three interconnected systems that together provide serverless infrastructure for building, deploying, and scaling applications.

```
┌─────────────────────────────────────────────────────────────────┐
│                     HIVEMIND PLATFORM                           │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐         │
│  │  BEEKEEPER  │    │  HONEYCOMB  │    │   HIVEMIND  │         │
│  │             │    │             │    │             │         │
│  │   Build     │───►│ Distribute  │◄──►│ Distribute  │         │
│  │   Apps      │    │    Data     │    │  Workloads  │         │
│  └─────────────┘    └─────────────┘    └─────────────┘         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

| System | Purpose | Balances |
|--------|---------|----------|
| **Hivemind** | Distribute workloads | Cost, latency, hard requirements |
| **Honeycomb** | Distribute data | Latency, cost, throughput |
| **Beekeeper** | Build applications | Optimization, reproducibility |

---

## Hivemind - Workload Distribution

Hivemind is a workload orchestration system. It decides **where** and **when** to run applications across heterogeneous infrastructure.

### Core Responsibilities

1. **Cluster Selection**: Choose which infrastructure source to use (cloud regions, on-prem, GPU pools)
2. **Scheduling**: Place workloads on specific nodes within a cluster, optimizing for resources
3. **Provisioning**: Scale infrastructure up/down based on demand
4. **Routing**: Direct requests to running instances based on user and business criteria

### Distributed Router Architecture

The Hivemind router is not a single point - it's distributed globally via CDN-style deployment:

```
┌─────────────────────────────────────────────────────────────────┐
│                   DISTRIBUTED ROUTER MESH                        │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                     Global DNS / Anycast                 │   │
│   │                                                         │   │
│   │   User request → Nearest router (by latency/geography)  │   │
│   └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│          ┌───────────────────┼───────────────────┐              │
│          │                   │                   │              │
│          ▼                   ▼                   ▼              │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐      │
│   │  Router     │     │  Router     │     │  Router     │      │
│   │  US-EAST    │     │  EU-WEST    │     │  APAC       │      │
│   │             │     │             │     │             │      │
│   │ Primary:    │     │ Primary:    │     │ Primary:    │      │
│   │ US compute  │     │ EU compute  │     │ APAC compute│      │
│   │             │     │             │     │             │      │
│   │ Fallback:   │     │ Fallback:   │     │ Fallback:   │      │
│   │ Any region  │     │ Any region  │     │ Any region  │      │
│   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘      │
│          │                   │                   │              │
│          │ Routes to local compute first,        │              │
│          │ but can route cross-region if needed  │              │
│          │                   │                   │              │
│          ▼                   ▼                   ▼              │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐      │
│   │ US Compute  │     │ EU Compute  │     │APAC Compute │      │
│   │ Cluster     │     │ Cluster     │     │ Cluster     │      │
│   └─────────────┘     └─────────────┘     └─────────────┘      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Key properties:**

| Property | Description |
|----------|-------------|
| **Geographic distribution** | Routers deployed on edge infrastructure (CDN PoPs, regional clouds) |
| **Local affinity** | Each router primarily serves compute in its region |
| **Cross-region capability** | Can route to any region if local capacity exhausted or user requires it |
| **Shared state** | Routers share view of global capacity via gossip or control plane sync |
| **Independent operation** | Each router can function during network partitions |

**Router placement strategy:**

```
Router lives close to users (edge):
├── Minimize request latency to first hop
├── TLS termination at edge
└── Quick routing decisions

Router talks to compute (backend):
├── Persistent connections to node agents
├── Health monitoring
└── Load information
```

### The Routing ↔ Orchestration Loop

Each regional router communicates bidirectionally with the orchestration control plane:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   Regional Router ◄────────────────────► Control Plane          │
│                                                                 │
│   Router → Control Plane:                                       │
│   • "Queue depth for app X is growing, scale up"                │
│   • "Latency SLA breached, need more capacity"                  │
│   • "Cold start request waiting, no warm instance"              │
│   • "Request patterns suggest demand spike coming"              │
│                                                                 │
│   Control Plane → Router:                                       │
│   • "Instance ready at address Y, send traffic"                 │
│   • "Region Z has no capacity, route elsewhere"                 │
│   • "Instance draining, stop sending new requests"              │
│   • "New region available, update routing table"                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Routing Decisions

The router considers multiple factors when directing requests:

| Factor | Example |
|--------|---------|
| **User preferences** | "Run in EU only" (data residency) |
| **Latency requirements** | Route to nearest region with capacity |
| **Cost optimization** | Prefer spot instances when latency allows |
| **Warm instance availability** | Avoid cold starts when possible |
| **Load balancing** | Distribute across healthy instances |
| **Hard requirements** | GPU type, memory, specific hardware |

### Scheduling Decisions

Once a region/cluster is selected, the scheduler places workloads:

| Consideration | Description |
|---------------|-------------|
| **Resource fit** | CPU, memory, GPU availability |
| **Bin packing** | Minimize wasted resources |
| **Data locality** | Co-locate with cached images/models (via Honeycomb) |
| **Priority/preemption** | Higher priority workloads can evict lower |
| **Topology** | Respect zone/rack anti-affinity for HA |

---

## Battery-Included Node Runtime

A core design principle: **no daemonset hell**.

Kubernetes clusters often require deploying dozens of system components as DaemonSets:
- CNI plugins (Calico, Cilium, etc.)
- CSI drivers
- GPU device plugins
- Log collectors
- Metrics agents
- Service mesh sidecars
- Node problem detectors
- ...

This creates operational complexity, version skew, and debugging nightmares.

**Hivemind takes a different approach**: the node agent is a single, unified binary that includes everything needed to run workloads.

### Node Agent Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    HIVEMIND NODE AGENT                           │
│                                                                 │
│   Single binary, all batteries included                         │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    Core Runtime                          │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │ Container   │  │  Workload   │  │   Health    │     │    │
│  │  │ Lifecycle   │  │  Manager    │  │   Monitor   │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  │                                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   GPU Runtime                            │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │   NVIDIA    │  │    AMD      │  │   Intel     │     │    │
│  │  │   Driver    │  │   ROCm      │  │   oneAPI    │     │    │
│  │  │   + CUDA    │  │   Driver    │  │   Driver    │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐                      │    │
│  │  │  GPU Time   │  │    MIG      │   Fractional GPU     │    │
│  │  │  Slicing    │  │  Manager    │   allocation         │    │
│  │  └─────────────┘  └─────────────┘                      │    │
│  │                                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  Storage Runtime                         │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │  Honeycomb  │  │   Volume    │  │   Image     │     │    │
│  │  │   Client    │  │   Manager   │  │   Cache     │     │    │
│  │  │             │  │             │  │             │     │    │
│  │  │  P2P agent  │  │  Mount/     │  │  Layer      │     │    │
│  │  │  Chunk xfer │  │  Unmount    │  │  storage    │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  │                                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                 Networking Runtime                       │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │   Network   │  │    Mesh     │  │   Service   │     │    │
│  │  │   Plugin    │  │  Connector  │  │   Proxy     │     │    │
│  │  │             │  │             │  │             │     │    │
│  │  │  Pod IPs    │  │  WireGuard  │  │  L4/L7      │     │    │
│  │  │  NAT/SNAT   │  │  mTLS       │  │  routing    │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  │                                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │               Observability Runtime                      │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │   Metrics   │  │    Logs     │  │   Traces    │     │    │
│  │  │  Collector  │  │  Collector  │  │  Collector  │     │    │
│  │  │             │  │             │  │             │     │    │
│  │  │ Prometheus  │  │  Structured │  │  OpenTel    │     │    │
│  │  │ compatible  │  │  stdout/err │  │  compatible │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  │                                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  Security Runtime                        │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │    Auth     │  │   Secret    │  │  Workload   │     │    │
│  │  │   Agent     │  │   Manager   │  │  Identity   │     │    │
│  │  │             │  │             │  │             │     │    │
│  │  │  mTLS certs │  │  Inject     │  │  SPIFFE     │     │    │
│  │  │  rotation   │  │  at runtime │  │  SVIDs      │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  │                                                         │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐     │    │
│  │  │  Container  │  │   gVisor    │  │    Kata     │     │    │
│  │  │  Sandbox    │  │   (runsc)   │  │ Containers  │     │    │
│  │  │  Manager    │  │             │  │             │     │    │
│  │  │             │  │  User-space │  │  MicroVM    │     │    │
│  │  │  Policy     │  │  kernel     │  │  isolation  │     │    │
│  │  │  selection  │  │  isolation  │  │             │     │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘     │    │
│  │                                                         │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Container Sandboxing

Multi-tenant serverless requires strong isolation. The node agent includes multiple sandboxing runtimes:

| Runtime | Isolation Level | Overhead | GPU Support | Use Case |
|---------|-----------------|----------|-------------|----------|
| **runc** | Linux namespaces/cgroups | Lowest | Full | Trusted workloads, single-tenant |
| **gVisor (runsc)** | User-space kernel | Low-medium | Partial | Multi-tenant, untrusted code |
| **Kata Containers** | MicroVM | Medium | Via VFIO | Strongest isolation, compliance |

**Policy-based selection:**

```
Workload spec:
  isolation: auto | runc | gvisor | kata

auto (default):
  - Multi-tenant: gVisor
  - GPU required + multi-tenant: Kata with VFIO passthrough
  - Single-tenant/trusted: runc

Platform can enforce minimum isolation level per tenant tier.
```

**Why bundle all three:**
- Different workloads have different requirements
- GPU workloads may need Kata for VFIO passthrough
- Compliance requirements may mandate VM-level isolation
- No operator decision needed - policy-driven selection

### What "Battery-Included" Means

| Component | Kubernetes Approach | Hivemind Approach |
|-----------|--------------------|--------------------|
| **GPU support** | Install NVIDIA device plugin DaemonSet, configure container runtime | Built into agent, auto-detects GPUs |
| **Storage** | Install CSI driver DaemonSet per storage type | Honeycomb client built into agent |
| **Networking** | Install CNI plugin, possibly service mesh sidecar | Network plugin built into agent |
| **Metrics** | Deploy Prometheus node exporter DaemonSet | Metrics exporter built into agent |
| **Logs** | Deploy Fluentd/Fluent Bit DaemonSet | Log collector built into agent |
| **Auth/certs** | Deploy cert-manager, SPIRE DaemonSet | Auth agent built into agent |
| **Sandboxing** | Configure containerd + install gVisor/Kata separately | All runtimes bundled, policy-selected |

**Result:**
- One binary to deploy per node
- One thing to upgrade
- One thing to debug
- Consistent versions across all capabilities
- Faster node bootstrap (no waiting for DaemonSet pods)

### Node Bootstrap Sequence

```
1. Node starts
   │
   └─► Hivemind agent binary starts (single process)

2. Agent self-configures
   │
   ├─► Detects hardware (CPU, memory, GPUs, network)
   ├─► Initializes GPU runtime (NVIDIA/AMD/Intel)
   ├─► Connects to Honeycomb (P2P agent ready)
   ├─► Establishes mesh connectivity (WireGuard/mTLS)
   ├─► Starts metrics/log collectors
   └─► Obtains identity (SPIFFE SVID)

3. Agent registers with control plane
   │
   └─► "Node X ready, capacity: 8 CPU, 64GB RAM, 2x A100"

4. Node ready to receive workloads
   │
   └─► Total time: seconds, not minutes
```

### Compile-Time Configuration

The agent binary can be built with different feature sets:

```
hivemind-agent:
  --features=nvidia,amd          # GPU support
  --features=honeycomb           # Storage client
  --features=wireguard           # Mesh networking
  --features=prometheus          # Metrics
  --features=opentelemetry       # Tracing

Default build: all features
Minimal build: core only (for constrained environments)
```

---

## Resource Model

Hivemind uses a simplified resource model:

```
Workload:
  id: uuid
  tenant: string

  # What to run
  image: content_hash          # Reference to Honeycomb
  resources:
    cpu: millicores
    memory: bytes
    gpu: {type, count, fraction}

  # How to run
  type: serving | job | dev
  replicas: int
  scaling:
    min: int
    max: int
    policy: resource | request | predictive

  # Constraints
  regions: [allowed regions]
  requirements: [hardware requirements]

  # Status (computed)
  ready_replicas: int
  endpoints: [{node, address}]
```

### Multi-Cluster Architecture

Hivemind manages multiple infrastructure sources:

```
┌─────────────────────────────────────────────────────────────────┐
│                    HIVEMIND CONTROL PLANE                        │
│                                                                 │
│    Global view of all clusters, routing, scaling decisions      │
│                                                                 │
└─────────────────────────┬───────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          │               │               │
          ▼               ▼               ▼
    ┌───────────┐   ┌───────────┐   ┌───────────┐
    │  AWS      │   │  GCP      │   │  On-Prem  │
    │  us-east  │   │  europe   │   │  colo-1   │
    │           │   │           │   │           │
    │  Nodes    │   │  Nodes    │   │  Nodes    │
    │  (agents) │   │  (agents) │   │  (agents) │
    └───────────┘   └───────────┘   └───────────┘
```

### Canary Releases

Hivemind supports progressive rollout of system components and workloads:

```
Release Channels:
├── base     → Stable, runs on majority of nodes
├── canary   → New version, runs on labeled subset
└── test     → Experimental, isolated test nodes

Node Labels:
  hivemind.io/release: base | canary | test

Rollout Flow:
  1. Deploy to test nodes (internal validation)
  2. Promote to canary (subset of production traffic)
  3. Monitor metrics, compare against base
  4. Promote to base (full rollout) or rollback
```

**What can be canaried:**
| Component | Canary Strategy |
|-----------|-----------------|
| **Node agent** | Different agent versions on canary nodes |
| **GPU drivers** | Test new CUDA/driver versions |
| **Container runtime** | Validate runtime changes |
| **User workloads** | Route percentage of traffic to new version |

### Disruption Schedules

Controlled maintenance windows for node operations:

```
Disruption Budget:
  schedule:
    - window: "0 2 * * 1-5"    # Weekdays 2-6 AM
      action: allow
    - window: "0 0 * * 6-0"    # Weekends
      action: deny              # No disruptions on weekends
    - window: "*"
      action: deny              # Default deny

  constraints:
    max_unavailable: 10%        # Never disrupt more than 10%
    consolidation_delay: 30m    # Wait before consolidating
    drain_timeout: 300s         # Time to drain workloads
```

**Disruption types:**
| Type | Trigger | Behavior |
|------|---------|----------|
| **Consolidation** | Underutilized nodes | Drain and terminate |
| **Upgrade** | New AMI/agent version | Rolling replacement |
| **Spot interruption** | Cloud reclaim | Immediate drain |
| **Maintenance** | Scheduled window | Graceful drain |

### Priority and Overprovisioning

Workload priority determines scheduling and preemption:

```
Priority Classes:
┌─────────────────────────────────────────────────────────────────┐
│  Priority      │ Value  │ Purpose                               │
├─────────────────────────────────────────────────────────────────┤
│  system        │ 10000  │ Hivemind agents, critical infra       │
│  user-gpu      │ 1000   │ User GPU workloads                    │
│  user-cpu      │ 100    │ User CPU workloads                    │
│  overprovisioning │ -5  │ Warm capacity (preemptible)           │
│  reserved      │ -9     │ Capacity reservations (preemptible)   │
└─────────────────────────────────────────────────────────────────┘

Preemption:
  Higher priority workloads evict lower priority
  overprovisioning pods exist solely to be evicted
```

**Overprovisioning strategy:**

```
┌─────────────────────────────────────────────────────────────────┐
│                    OVERPROVISIONING                              │
│                                                                 │
│   Purpose: Maintain warm capacity for instant scaling           │
│                                                                 │
│   How it works:                                                 │
│   1. Deploy low-priority "placeholder" pods                     │
│   2. Pods consume resources, triggering node provisioning       │
│   3. When real workload arrives, placeholder is evicted         │
│   4. Real workload starts instantly (node already warm)         │
│                                                                 │
│   Configuration per compute type:                               │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  compute_type: gpu-a100                                 │   │
│   │  replicas: 4           # Maintain 4 warm A100 nodes     │   │
│   │  resources:                                             │   │
│   │    gpu: 1                                               │   │
│   │    memory: 80Gi                                         │   │
│   │                                                         │   │
│   │  downtime:             # Cost optimization              │   │
│   │    enabled: true                                        │   │
│   │    schedule: "0 22 * * *"  # Scale down at 10 PM        │   │
│   │    resume: "0 6 * * *"     # Scale up at 6 AM           │   │
│   │    weekend_scale: 0        # Zero on weekends           │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Affinity rules:**
- Overprovisioning pods prefer nodes with existing user workloads
- CPU overprovisioning spreads across nodes (anti-affinity)
- GPU overprovisioning packs onto nodes (consume all GPUs before new node)

### Key Design Principles

Current implementation principles:

- **Queue-based routing**: Requests queue during scale-up, no immediate failures
- **Demand-driven scaling**: Autoscaling based on queue depth, not just resource utilization
- **Data locality**: Scheduler prefers nodes with cached images/data
- **Single binary agent**: All node capabilities in one deployable unit
- **Incremental migration**: Canary-based rollout with easy rollback

Long-term principles (see [VISION.md](./VISION.md)):

- **Deterministic simulation**: Test distributed scenarios with VOPR
- **Actor model**: Isolated components with message passing
- **Supervision trees**: Fault tolerance via "let it crash" philosophy

---

## Honeycomb - Data Distribution

Honeycomb distributes data to where it's needed. This includes container images, model weights, datasets, and persistent volumes.

### Core Responsibilities

1. **Store**: Content-addressable storage for all distributable data
2. **Distribute**: Get data to nodes efficiently (P2P, caching, pre-positioning)
3. **Cache**: Manage node-local and regional caches
4. **Serve**: Provide data access for running workloads

### Distribution Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│                   HONEYCOMB DISTRIBUTION                         │
│                                                                 │
│   Origin Store                                                  │
│   └── Source of truth, durable, replicated                      │
│                                                                 │
│         │                                                       │
│         │ replicate                                             │
│         ▼                                                       │
│                                                                 │
│   Regional Cache (+ Supernode)                                  │
│   └── Per-region cache, coordinates P2P within region           │
│                                                                 │
│         │                                                       │
│         │ P2P distribute                                        │
│         ▼                                                       │
│                                                                 │
│   Node-Local Cache (+ Agent)                                    │
│   └── On each compute node, fastest access                      │
│       (Agent is part of Hivemind node agent - battery included) │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### P2P Distribution

When multiple nodes need the same data, they share chunks directly:

```
Scenario: 10 nodes need a 50GB model

Without P2P:
  Each node pulls 50GB from origin = 500GB egress from origin

With P2P:
  Origin seeds to first few nodes
  Nodes share chunks with each other
  Total origin egress ≈ 50-100GB (10x reduction)

Implementation:
  - Content split into chunks (e.g., 4MB each)
  - Supernode tracks chunk availability per node
  - Nodes pull chunks from multiple peers in parallel
  - Each node seeds chunks it has received
```

### Content Types

| Type | Characteristics | P2P Benefit |
|------|-----------------|-------------|
| **Container images** | OCI layers, 1-20GB, shared base layers | High (layer dedup) |
| **Model weights** | Large files, 1-200GB+, model-specific | Very high |
| **Datasets** | Variable size, often read-only | High |
| **Persistent volumes** | Mutable, workload-specific | Not P2P (attached storage) |

### Content Addressing

All distributable data is content-addressed:

```
content_id = sha256(content)

Benefits:
├── Deduplication (identical content stored once)
├── Integrity verification (hash = address)
├── Immutable (safe to cache forever)
└── P2P friendly (chunks self-describing)
```

### Honeycomb ↔ Hivemind Integration

Hivemind directs distribution strategy; Honeycomb executes:

```
Hivemind → Honeycomb:
  PrePosition(content_id, regions[])     # Proactive caching
  Evict(content_id, nodes[])             # Free space
  SetPriority(content_id, level)         # Prevent eviction

Honeycomb → Hivemind:
  GetLocations(content_id) → nodes[]     # Where is this cached?
  EstimatePullTime(content_id, node)     # How long to fetch?
  GetCapacity(node) → bytes              # Cache space available

Honeycomb events → Hivemind:
  ContentAvailable(content_id, node)     # Ready for use
  ContentEvicted(content_id, node)       # No longer cached
```

### Warmup and Pre-positioning

Proactive caching to eliminate cold starts before they happen:

```
┌─────────────────────────────────────────────────────────────────┐
│                      WARMUP SYSTEM                               │
│                                                                 │
│   Triggers for warmup:                                          │
│   ├── Deployment: New app deployed → warm likely regions        │
│   ├── Scheduled: Cron-based warming before peak hours           │
│   ├── Predictive: ML model predicts demand spike                │
│   └── Manual: Operator triggers warmup for specific content     │
│                                                                 │
│   Warmup Job:                                                   │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  content_id: sha256:abc123...                           │   │
│   │  targets:                                               │   │
│   │    - region: us-east-1                                  │   │
│   │      nodes: 5           # Warm on 5 nodes               │   │
│   │      priority: high                                     │   │
│   │    - region: eu-west-1                                  │   │
│   │      nodes: 3                                           │   │
│   │      priority: normal                                   │   │
│   │  strategy: parallel | sequential                        │   │
│   │  timeout: 30m                                           │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Warmup Flow:                                                  │
│   1. Honeycomb receives warmup request                          │
│   2. Checks current cache state (what's already warm?)          │
│   3. Calculates delta (what needs pulling?)                     │
│   4. Schedules pulls across target nodes                        │
│   5. Uses P2P if content exists in region                       │
│   6. Reports completion to Hivemind                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Warmup strategies:**

| Strategy | Description | Use Case |
|----------|-------------|----------|
| **Eager** | Pull full content immediately | Small images, critical apps |
| **Lazy** | Pull metadata only, content on-demand | Large models, lazy-loading compatible |
| **Tiered** | Pull base layers eager, app layers lazy | Balanced approach |

**Cache retention policy:**

```
Retention Rules:
  - Warmup content: pinned until explicitly released
  - Recently used: LRU with configurable TTL
  - Overprovisioning images: always pinned (for instant start)

Eviction Priority:
  1. Unpinned, unused content
  2. Old versions of updated content
  3. Content from scaled-down apps
  Never evict: pinned, actively-used, or overprovisioning images
```

### Registry Interface

Honeycomb provides an OCI-compatible registry interface for container images:

```
┌─────────────────────────────────────────────────────────────────┐
│                   HONEYCOMB REGISTRY                             │
│                                                                 │
│   OCI Distribution Spec compliant                               │
│   ├── Push images (from Beekeeper or external builds)           │
│   ├── Pull images (for node agents)                             │
│   └── Manifest/blob operations                                  │
│                                                                 │
│   Architecture:                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                                                         │   │
│   │   Registry API (per region)                             │   │
│   │   ├── Stateless HTTP service                            │   │
│   │   ├── Authenticates via Hivemind identity               │   │
│   │   └── Routes to storage backend                         │   │
│   │                                                         │   │
│   │         │                                               │   │
│   │         ▼                                               │   │
│   │                                                         │   │
│   │   Storage Backend                                       │   │
│   │   ├── Content-addressable blob store                    │   │
│   │   ├── Backed by distributed filesystem                  │   │
│   │   └── Automatic layer deduplication                     │   │
│   │                                                         │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Registry URL pattern:                                         │
│     registry.{region}.honeycomb.internal/                       │
│     registry.{region}.hivemind.dev/ (external)                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Registry features:**

| Feature | Description |
|---------|-------------|
| **Layer deduplication** | Identical layers stored once, referenced by hash |
| **Cross-tenant sharing** | Base images (python, cuda) shared across tenants |
| **Regional affinity** | Pull from nearest registry replica |
| **Garbage collection** | Remove unreferenced blobs after retention period |
| **Metrics export** | Pull latency, bandwidth, cache hit rate |

**Integration with P2P:**

```
Pull Flow:
  1. Node requests image from regional registry
  2. Registry checks: is content in local cache?
     ├── Yes → Serve directly
     └── No → Check P2P availability
         ├── Peers have it → Coordinate P2P pull
         └── No peers → Pull from origin, seed to P2P

Push Flow (from Beekeeper):
  1. Beekeeper pushes to origin registry
  2. Origin notifies regional registries
  3. Regions pull based on warmup policy
  4. P2P seeds across nodes in each region
```

### Cold Start Optimization

The interplay between Hivemind and Honeycomb determines cold start latency:

```
Best case (pre-positioned):
  Hivemind predicted demand → Honeycomb pre-cached
  Request arrives → Image on node → Start → ~1-2s

Good case (P2P available):
  Image not on node, but peers in region have it
  P2P pull (parallel chunks) → Start → ~5-15s

Worst case (cold region):
  No peers, pull from origin
  Full transfer → Start → ~30-120s
  (This node now seeds for next request)
```

### Storage Classes

For persistent volumes (non-P2P):

| Class | Durability | Performance | Use Case |
|-------|------------|-------------|----------|
| **Ephemeral** | None (dies with workload) | Fastest (local NVMe) | Scratch space |
| **Regional** | Replicated in region | Fast | Databases, state |
| **Global** | Cross-region replication | Variable | Shared datasets |

---

## Beekeeper - Application Building

Beekeeper transforms user code into runnable container images, then stores them in Honeycomb.

### Core Responsibilities

1. **Build**: Execute builds (Dockerfile or buildpack-style inference)
2. **Optimize**: Apply optimizations for faster cold starts
3. **Store**: Push built images to Honeycomb origin

### Build Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        BEEKEEPER                                 │
│                                                                 │
│   User Code                                                     │
│   ├── Python files                                              │
│   ├── requirements.txt                                          │
│   ├── app.toml (or Dockerfile)                            │
│   │                                                             │
│   ▼                                                             │
│                                                                 │
│   Build Execution                                               │
│   ├── Resolve dependencies                                      │
│   ├── Install packages                                          │
│   ├── Copy application code                                     │
│   ├── Apply optimizations                                       │
│   │                                                             │
│   ▼                                                             │
│                                                                 │
│   OCI Image                                                     │
│   ├── Layers (content-addressed)                                │
│   ├── Metadata (entrypoint, env, labels)                        │
│   │                                                             │
│   ▼                                                             │
│                                                                 │
│   Push to Honeycomb Origin                                      │
│   └── content_id = sha256(image_manifest)                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Build Modes

| Mode | Input | Best For |
|------|-------|----------|
| **Dockerfile** | User-provided Dockerfile | Full control |
| **Inference** | Code + app.toml | Simplicity, optimization |

### Optimizations

Beekeeper can apply optimizations for serverless:

| Optimization | Description |
|--------------|-------------|
| **Layer ordering** | Frequently changing layers last (better caching) |
| **Dependency dedup** | Share common packages across users |
| **Multi-stage builds** | Smaller final images |
| **Pre-compilation** | AOT compile Python, pre-download models |
| **Filesystem snapshots** | For instant container start (future) |

### Relationship to Honeycomb

Beekeeper's output is Honeycomb's input:

```
Beekeeper                    Honeycomb
─────────                    ─────────
Build image          ───►    Store at origin
Generate content_id  ───►    Index for distribution
Report layers        ───►    Enable deduplication

Beekeeper does NOT:
- Decide where to cache images (Hivemind decides)
- Distribute images (Honeycomb handles)
- Know about runtime scheduling
```

---

## System Integration

### Request Lifecycle

Complete flow from user request to response:

```
1. BUILD (one-time)
   User deploys code
   └─► Beekeeper builds image
       └─► Pushes to Honeycomb origin
           └─► Hivemind notified: "new app available"
               └─► Hivemind tells Honeycomb: "pre-position in likely regions"

2. FIRST REQUEST (cold start)
   User request arrives at nearest router (CDN-distributed)
   └─► Router checks: warm instance available?
       └─► No → queues request, signals control plane
           └─► Autoscaler decides to scale up
               └─► Scheduler checks Honeycomb: "where is image cached?"
                   └─► Places workload on node with cached image
                       └─► Node agent starts container (batteries included)
                           └─► Container ready, registers with router
                               └─► Router drains queue to new instance
                                   └─► Response returned

3. SUBSEQUENT REQUESTS (warm)
   User request arrives at nearest router
   └─► Router finds warm instance
       └─► Routes directly
           └─► Response returned

4. SCALE DOWN (idle)
   No requests for cooldown period
   └─► Autoscaler scales to zero
       └─► Instance terminated
           └─► (Image remains cached on node for next cold start)
```

### Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│    USER                                                         │
│      │                                                          │
│      │ deploy code                                              │
│      ▼                                                          │
│  ┌─────────┐     build      ┌───────────┐                      │
│  │BEEKEEPER│───────────────►│ HONEYCOMB │                      │
│  └─────────┘   push image   │  (origin) │                      │
│                             └─────┬─────┘                      │
│                                   │                             │
│                                   │ distribute                  │
│                                   ▼                             │
│                             ┌───────────┐                      │
│                             │ HONEYCOMB │                      │
│    USER                     │ (regional)│                      │
│      │                      └─────┬─────┘                      │
│      │ request                    │                             │
│      ▼                            │ P2P                         │
│  ┌─────────┐    route       ┌─────┴─────┐                      │
│  │HIVEMIND │───────────────►│ HONEYCOMB │                      │
│  │ Router  │  (distributed) │  (node)   │                      │
│  └────┬────┘                └─────┬─────┘                      │
│       │                           │                             │
│       │ schedule                  │ provide image               │
│       ▼                           ▼                             │
│  ┌─────────┐              ┌─────────────┐                      │
│  │HIVEMIND │──────────────│  WORKLOAD   │                      │
│  │Scheduler│   place      │  (running)  │                      │
│  └─────────┘              └─────────────┘                      │
│                                   │                             │
│                                   │ response                    │
│                                   ▼                             │
│                                 USER                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### API Boundaries

```
┌─────────────────────────────────────────────────────────────────┐
│                      EXTERNAL APIs                               │
│                                                                 │
│  User-facing:                                                   │
│  ├── Beekeeper API: deploy(code) → app_id                       │
│  ├── Hivemind API: invoke(app_id, request) → response           │
│  └── Honeycomb API: upload(data) → content_id (for datasets)    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     INTERNAL APIs                                │
│                                                                 │
│  Beekeeper → Honeycomb:                                         │
│  └── PushImage(layers[]) → content_id                           │
│                                                                 │
│  Hivemind → Honeycomb:                                          │
│  ├── PrePosition(content_id, regions[])                         │
│  ├── GetLocations(content_id) → nodes[]                         │
│  ├── EstimatePullTime(content_id, node) → duration              │
│  └── AttachVolume(volume_id, workload) → mount                  │
│                                                                 │
│  Honeycomb → Hivemind:                                          │
│  ├── ContentAvailable(content_id, node)                         │
│  └── ContentEvicted(content_id, node)                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Design Principles

### Separation of Concerns

Each system has one job:

| System | Knows About | Doesn't Know About |
|--------|-------------|-------------------|
| **Hivemind** | Workload placement, routing, scaling | How images are built, storage internals |
| **Honeycomb** | Data storage, caching, distribution | Workload scheduling, request routing |
| **Beekeeper** | Code → Image transformation | Where images run, how they're distributed |

### Battery-Included Philosophy

Don't make operators assemble systems from parts:

| Principle | Description |
|-----------|-------------|
| **Single binary** | Node agent includes all runtime capabilities |
| **Auto-detection** | Discovers hardware, configures drivers |
| **No DaemonSets** | No separate deployments for GPU, networking, monitoring |
| **Consistent versions** | All components versioned together |
| **Fast bootstrap** | Node ready in seconds, not minutes |

### Distributed by Default

No single points of failure:

| Component | Distribution Strategy |
|-----------|----------------------|
| **Router** | CDN-style, global anycast, regional instances |
| **Control plane** | VSR-replicated state machine |
| **Honeycomb** | Origin + regional caches + P2P |
| **Compute** | Multi-region, multi-cloud, on-prem |

### Content Addressing

All distributable data identified by hash:

```
image:    sha256:abc123...
model:    sha256:def456...
dataset:  sha256:ghi789...
```

Benefits: deduplication, integrity, immutability, cache-friendliness.

### Optimize for Cold Start

Every design decision considers cold start latency:

- Pre-positioning before demand
- P2P to accelerate pulls
- Scheduler prefers nodes with cached data
- Router queues during scale-up (doesn't fail)
- Battery-included agent = fast container start

---

## Glossary

| Term | Definition |
|------|------------|
| **Workload** | A deployable unit (serving, job, or dev environment) |
| **Content ID** | SHA256 hash identifying content-addressed data |
| **Supernode** | Regional Honeycomb coordinator for P2P distribution |
| **Pre-positioning** | Proactively caching data before it's requested |
| **Cold start** | Time from request to response when no warm instance exists |
| **Warm instance** | Running workload ready to serve requests |
| **Battery-included** | Node agent with all capabilities built in |
| **Router mesh** | Distributed routers deployed globally via CDN |

---

## Related Documents

- [ARCHITECTURE.md](./ARCHITECTURE.md) - Current practical architecture and implementation plan
- [VISION.md](./VISION.md) - Long-term aspirational vision (Zig, VSR, deterministic simulation)

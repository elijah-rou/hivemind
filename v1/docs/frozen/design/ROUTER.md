> **DESIGN STAGE**: Describes a future distributed edge router. Current requests route through the Go API gateway (`api/`) + Zig replica. See [`docs/STATUS.md`](../STATUS.md).

# Hivemind Router - Technical Design

## Overview

The Hivemind Router is the entry point for all user traffic. It receives requests and routes them to the appropriate **pool** based on application requirements and real-time capacity.

**Key responsibilities:**
1. Route requests to the correct pool (determined by hardware, region, provider constraints)
2. Load balance across healthy instances within a pool
3. Queue requests during cold starts (don't fail)
4. Signal demand to the control plane for autoscaling
5. Provide unified metrics across all pools

> **Note**: The Router uses a dynamic pool model rather than hardcoded clusters. See [PROVIDERS.md](PROVIDERS.md#topology--pool-model) for the full topology design.

---

## Workload Type Handling

The Router handles different workload types differently. See [WORKLOAD_TYPES.md](WORKLOAD_TYPES.md) for full design.

| Workload Type | Router Involvement | Access Pattern |
|---------------|-------------------|----------------|
| **Serverless** | Primary path - pool selection, queue management, autoscaling signals | All requests via Router |
| **Job** | **Bypassed** - Jobs are submitted directly to control plane API | API submission only, no Router involvement |
| **Instance** | Minimal - Instance HTTP endpoints can optionally route through Router | SSH via Gateway, HTTP via Router or direct |

### Why Jobs Bypass the Router

Jobs are **run-to-completion** workloads, not request/response:
- No queue depth signals needed (job queue managed by Job Controller)
- No pool selection needed (scheduler picks cluster at submission time)
- No load balancing (each job runs independently to completion)
- Results retrieved via API or webhooks, not synchronous response

```
┌─────────────────────────────────────────────────────────────────┐
│                    WORKLOAD TYPE FLOWS                           │
│                                                                 │
│   Serverless:                                                   │
│   Client → Router → Pool Selection → Instance → Response        │
│            ↓                                                    │
│         Queue if cold start                                     │
│                                                                 │
│   Job:                                                          │
│   Client → Hivemind API → Job Controller → K8s Job              │
│                                (no Router)                      │
│                                                                 │
│   Instance:                                                     │
│   SSH:  Client → SSH Gateway → Instance Pod                     │
│   HTTP: Client → Router (optional) → Instance Pod               │
│         OR Client → Direct endpoint → Instance Pod              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Instance HTTP Routing

Instances may expose HTTP endpoints. These can be accessed:

1. **Via Router** (optional): Instance HTTP endpoints registered with Router for load balancing and metrics
2. **Direct**: Instance has dedicated endpoint (e.g., `{instance-id}.instances.hivemind.dev`)

Instance HTTP routing through Router uses simpler logic than serverless:
- No queue management (instance is always running)
- No pool selection (already placed)
- Simple proxy to fixed endpoint

---

## Design Goals

| Goal | Description |
|------|-------------|
| **Low latency** | Add minimal overhead to request path (<10ms P99) |
| **High availability** | No single point of failure, survive region outages |
| **Stateless** | Router instances share nothing, scale horizontally |
| **Graceful degradation** | Route around failures, queue during cold starts |
| **Observable** | Rich metrics for debugging and optimization |

### Non-Goals (Phase 1)

- Custom autoscaling (control plane responsibility, Phase 4)
- Request transformation (pass-through proxy)
- Authentication (handled by backend services)
- Rate limiting (can be added later)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     ROUTER ARCHITECTURE                          │
│                                                                 │
│   Internet                                                      │
│       │                                                         │
│       ▼                                                         │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    Global DNS                            │   │
│   │                                                         │   │
│   │   api.hivemind.dev → Anycast / GeoDNS                   │   │
│   │   Routes to nearest router deployment                    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│          ┌───────────────────┼───────────────────┐              │
│          ▼                   ▼                   ▼              │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐      │
│   │   Router    │     │   Router    │     │   Router    │      │
│   │   US-EAST   │     │   EU-WEST   │     │   APAC      │      │
│   │             │     │             │     │             │      │
│   │ Pool State  │     │ Pool State  │     │ Pool State  │      │
│   │ + Queues    │     │ + Queues    │     │ + Queues    │      │
│   └──────┬──────┘     └──────┬──────┘     └──────┬──────┘      │
│          │                   │                   │              │
│          │      ┌────────────┴────────────┐      │              │
│          │      │    Control Plane        │      │              │
│          │      │    (Pool Registry)      │      │              │
│          │      └────────────┬────────────┘      │              │
│          │                   │                   │              │
│          └───────────────────┼───────────────────┘              │
│                              │                                  │
│   ┌──────────────────────────┴──────────────────────────────┐   │
│   │                    DYNAMIC POOLS                         │   │
│   │                                                         │   │
│   │   Pools are formed by constraints, not hardcoded:       │   │
│   │                                                         │   │
│   │   ┌─────────────────┐  ┌─────────────────┐              │   │
│   │   │ Pool: H100-8x   │  │ Pool: A100-4x   │              │   │
│   │   │ us-east:aws     │  │ eu-west:*       │              │   │
│   │   │ (3 nodes)       │  │ (5 nodes)       │              │   │
│   │   └─────────────────┘  └─────────────────┘              │   │
│   │                                                         │   │
│   │   ┌─────────────────┐  ┌─────────────────┐              │   │
│   │   │ Pool: H100-8x   │  │ Pool: H200-8x   │              │   │
│   │   │ *:crusoe        │  │ *:*             │              │   │
│   │   │ (2 nodes)       │  │ (4 nodes)       │              │   │
│   │   └─────────────────┘  └─────────────────┘              │   │
│   │                                                         │   │
│   │   Nodes join/leave pools based on their attributes      │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

> **Pool Model**: Pools are defined by filter criteria (hardware type, region, provider) rather than static cluster membership. A single node may match multiple pools. See [PROVIDERS.md](PROVIDERS.md#topology--pool-model).

---

## Incremental Migration: Static Clusters → Dynamic Pools

Since the Router is Phase 1 and dynamic pools come with Hivemind (Phase 4), we need a bridge that allows incremental development.

### Phase 1: Static Cluster Mode

Initially, the Router works with statically configured clusters (existing Knative + Kourier setup):

```yaml
# Static cluster config (Phase 1)
clusters:
  - id: "aws-us-east-1"
    provider: aws
    region: us-east-1
    endpoint: "https://kourier.us-east-1.internal.hivemind.dev"
    gpu_types: [a100, h100]  # Available GPUs in this cluster
    status: healthy

  - id: "crusoe-us-central"
    provider: crusoe
    region: us-central
    endpoint: "https://kourier.crusoe.internal.hivemind.dev"
    gpu_types: [h100]
    status: healthy
```

### The Abstraction: RoutingBackend Interface

The Router uses an abstraction that can be backed by either static clusters or dynamic pools:

```zig
const RoutingBackend = struct {
    // Function pointers for polymorphism
    getEndpointsForAppFn: *const fn (*RoutingBackend, AppId) Error![]Endpoint,
    getCapacityFn: *const fn (*RoutingBackend, []const Endpoint) Error![]Capacity,
    reportQueueDepthFn: *const fn (*RoutingBackend, AppId, u32) Error!void,

    pub fn getEndpointsForApp(self: *RoutingBackend, app_id: AppId) Error![]Endpoint {
        return self.getEndpointsForAppFn(self, app_id);
    }
};

const Endpoint = struct {
    id: []const u8,           // Cluster ID or Pool ID
    url: []const u8,          // Where to send requests
    region: RegionId,
    provider: ProviderId,
    gpu_types: []const GpuType,
    capacity: Capacity,
};
```

### Phase 1 Implementation: StaticClusterBackend

```zig
const StaticClusterBackend = struct {
    clusters: []Cluster,
    app_deployments: std.StringHashMap([]ClusterId),

    pub fn getEndpointsForApp(self: *StaticClusterBackend, app_id: AppId) ![]Endpoint {
        const cluster_ids = self.app_deployments.get(app_id) orelse return &[_]Endpoint{};

        var endpoints = std.ArrayList(Endpoint).init(allocator);
        for (cluster_ids) |cluster_id| {
            const cluster = self.clusters.get(cluster_id) orelse continue;
            if (cluster.status == .healthy) {
                try endpoints.append(.{
                    .id = cluster.id,
                    .url = cluster.endpoint,
                    .region = cluster.region,
                    .provider = cluster.provider,
                    .gpu_types = cluster.gpu_types,
                    .capacity = cluster.capacity,
                });
            }
        }
        return endpoints.toOwnedSlice();
    }
};
```

### Phase 4+ Implementation: DynamicPoolBackend

```zig
const DynamicPoolBackend = struct {
    control_plane: *ControlPlaneClient,
    pool_cache: std.StringHashMap(PoolState),

    pub fn getEndpointsForApp(self: *DynamicPoolBackend, app_id: AppId) ![]Endpoint {
        // Get app requirements
        const app = try self.control_plane.getApp(app_id);

        // Resolve requirements to matching pools
        const pools = try self.control_plane.resolvePoolsForRequirements(app.requirements);

        var endpoints = std.ArrayList(Endpoint).init(allocator);
        for (pools) |pool| {
            if (pool.status == .healthy) {
                try endpoints.append(.{
                    .id = pool.id,
                    .url = pool.endpoint,  // Pool has a load-balanced endpoint
                    .region = pool.region,
                    .provider = pool.provider,
                    .gpu_types = &[_]GpuType{pool.gpu_type},
                    .capacity = pool.capacity,
                });
            }
        }
        return endpoints.toOwnedSlice();
    }
};
```

### Migration Path

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      ROUTER MIGRATION PATH                               │
│                                                                         │
│   Phase 1a-1d: Static Clusters                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Router uses StaticClusterBackend                               │   │
│   │  • Clusters defined in config file                              │   │
│   │  • App → Cluster mapping from Lambda API                        │   │
│   │  • Works with existing Kourier endpoints                        │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                      │                                  │
│                                      ▼                                  │
│   Phase 4a: Dual Mode                                                   │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Router supports BOTH backends                                  │   │
│   │  • Feature flag per app: use_dynamic_pools                      │   │
│   │  • Canary apps use DynamicPoolBackend                           │   │
│   │  • Most apps still use StaticClusterBackend                     │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                      │                                  │
│                                      ▼                                  │
│   Phase 4b+: Full Dynamic Pools                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Router uses DynamicPoolBackend exclusively                     │   │
│   │  • Pools resolved from app requirements                         │   │
│   │  • Cross-pool failover                                          │   │
│   │  • Cost-aware routing                                           │   │
│   │  • StaticClusterBackend removed                                 │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Why This Approach?

| Benefit | Description |
|---------|-------------|
| **Ship early** | Phase 1 Router works with current infrastructure |
| **No big bang** | Gradual migration from static to dynamic |
| **Testable** | Each backend can be tested independently |
| **Rollback safe** | Can switch back to static if dynamic has issues |
| **DST compatible** | Both backends can be simulated for testing |

---

## Components

### 1. Router Service

The core routing logic. Stateless, horizontally scalable.

```
┌─────────────────────────────────────────────────────────────────┐
│                      ROUTER SERVICE                              │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    Request Handler                       │   │
│   │                                                         │   │
│   │  1. Parse request (extract app ID, headers)             │   │
│   │  2. Lookup app config (which clusters, preferences)     │   │
│   │  3. Select target cluster (routing rules)               │   │
│   │  4. Check instance availability                         │   │
│   │  5. Route or queue                                      │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐            │
│   │   Config    │  │  Connection │  │   Request   │            │
│   │   Cache     │  │    Pool     │  │    Queue    │            │
│   │             │  │             │  │             │            │
│   │ App configs │  │ Per-cluster │  │ Per-app     │            │
│   │ Cluster map │  │ HTTP/2      │  │ cold start  │            │
│   │ TTL: 30s    │  │ keep-alive  │  │ queue       │            │
│   └─────────────┘  └─────────────┘  └─────────────┘            │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                   Health Checker                         │   │
│   │                                                         │   │
│   │  • Periodic health checks to all clusters               │   │
│   │  • Marks clusters healthy/unhealthy                     │   │
│   │  • Feeds into routing decisions                         │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                   Metrics Exporter                       │   │
│   │                                                         │   │
│   │  • Request count, latency by app/cluster                │   │
│   │  • Queue depth, wait time                               │   │
│   │  • Routing decisions (why chose this cluster)           │   │
│   │  • Backend health status                                │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2. Config Store

Stores cluster and application configuration. Shared across all router instances.

**Options:**
| Option | Pros | Cons |
|--------|------|------|
| **Redis/Valkey** | Fast, simple, pub/sub for updates | Another dependency |
| **DynamoDB** | Managed, multi-region | Higher latency |
| **Embedded + Gossip** | No external dependency | Complex consistency |
| **Control plane API** | Single source of truth | Latency, availability |

**Recommendation**: Start with **DynamoDB** (or existing database) with aggressive caching in router. Config changes are infrequent, so cache invalidation is manageable.

### 3. Request Queue

Queues requests during cold starts instead of failing.

```
┌─────────────────────────────────────────────────────────────────┐
│                       REQUEST QUEUE                              │
│                                                                 │
│   When no warm instance available:                              │
│                                                                 │
│   1. Add request to per-app queue                               │
│   2. Signal control plane: "app X needs instance"               │
│   3. Hold connection (long-poll or WebSocket)                   │
│   4. When instance ready, drain queue                           │
│   5. If timeout, return 503 with retry-after                    │
│                                                                 │
│   Queue Properties:                                             │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  max_queue_size: 1000      # per app                    │   │
│   │  max_wait_time: 60s        # before 503                 │   │
│   │  queue_storage: memory     # local to router instance   │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Note: Queue is per-router-instance (not shared)               │
│   If router dies, queued requests are lost (acceptable)         │
│   Client should retry on 503                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Model

### Pool State (Router-local)

The Router maintains local pool state, updated by the Control Plane:

```zig
const PoolState = struct {
    pool_id: PoolId,           // e.g., "h100_sxm_8x:us-east:aws"

    // Filter that defines this pool
    filter: PoolFilter,

    // Capacity
    total_nodes: u32,
    healthy_nodes: u32,
    available_gpus: u32,

    // Load
    queue_depth: u32,
    active_workloads: u32,

    // Cost (normalized $/GPU-hour)
    cost_per_gpu_hour: Money,

    // Health
    last_health_check: i64,
    status: PoolStatus,
};

const PoolFilter = struct {
    gpu_type: GpuType,
    gpu_count: u8,
    regions: ?[]const RegionId,     // null = any
    providers: ?[]const ProviderId, // null = any
};
```

> **Full pool model**: See [PROVIDERS.md](PROVIDERS.md#topology--pool-model) for complete topology design.

### Application Config

Applications specify **requirements**, not specific clusters. The Router resolves requirements to matching pools.

```yaml
applications:
  - id: "app-abc123"
    project_id: "proj-xyz"
    name: "my-model"

    # Hardware and topology requirements
    requirements:
      hardware:
        gpu_type: h100_sxm
        gpu_count: 8
        nvlink_required: true
      # Optional: region constraints (empty = any region)
      regions: []
      # Optional: provider constraints (empty = any provider)
      providers: []

    # Capacity bounds
    capacity:
      min_replicas: 0
      max_replicas: 10
      spot_allowed: false

    # Cold start behavior
    cold_start:
      queue_enabled: true
      max_queue_depth: 100
      max_wait_seconds: 30

    # Failover strategy
    failover: nearest_first  # any_matching | nearest_first | cheapest_first | reject
```

**Example configurations:**

```yaml
# Minimal: just hardware (runs anywhere with H100s)
requirements:
  hardware:
    gpu_type: h100_sxm
    gpu_count: 8

# Region-constrained: EU data residency
requirements:
  hardware:
    gpu_type: a100_80gb
    gpu_count: 4
  regions: [eu-west, eu-central]

# Provider-constrained: cost optimization
requirements:
  hardware:
    gpu_type: h100_sxm
    gpu_count: 8
  providers: [crusoe, lambda]  # cheaper providers
capacity:
  spot_allowed: true

# Fully constrained: enterprise
requirements:
  hardware:
    gpu_type: h100_sxm
    gpu_count: 8
  regions: [us-east]
  providers: [aws]
capacity:
  min_replicas: 4
  spot_allowed: false
```

### Pool Resolution

The Router resolves app requirements to matching pools:

```zig
fn getPoolsForApp(app: *const Application) []const PoolId {
    // Generate pool filter from app requirements
    const filter = PoolFilter{
        .gpu_type = app.requirements.hardware.gpu_type,
        .gpu_count = app.requirements.hardware.gpu_count,
        .regions = if (app.requirements.regions.len > 0)
            app.requirements.regions
        else
            null,  // any region
        .providers = if (app.requirements.providers.len > 0)
            app.requirements.providers
        else
            null,  // any provider
    };

    // Find all pools matching this filter
    return pool_registry.findMatchingPools(filter);
}
```

---

## Request Flow

### Happy Path (Warm Instance)

```
┌─────────────────────────────────────────────────────────────────┐
│                    WARM INSTANCE FLOW                            │
│                                                                 │
│   1. Request arrives at router                                  │
│      POST /v4/p-abc123/predict                                  │
│      Host: api.hivemind.dev                                     │
│                                                                 │
│   2. Router parses request                                      │
│      app_id = "p-abc123"                                        │
│      project = lookup(app_id)                                   │
│                                                                 │
│   3. Router looks up app config (cached)                        │
│      deployments = [us-east-1 (2 replicas), eu-west-1 (0)]     │
│      routing.strategy = "latency"                               │
│                                                                 │
│   4. Router selects cluster                                     │
│      client_region = geo_lookup(client_ip) → "us-east"          │
│      nearest_with_capacity = "aws-us-east-1"                    │
│                                                                 │
│   5. Router forwards request                                    │
│      → https://kourier.us-east-1.../p-abc123/predict            │
│      (uses connection pool, HTTP/2)                             │
│                                                                 │
│   6. Response returned to client                                │
│      Total added latency: ~5ms                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Cold Start (Queue)

```
┌─────────────────────────────────────────────────────────────────┐
│                    COLD START FLOW                               │
│                                                                 │
│   1. Request arrives at router                                  │
│      POST /v4/p-def456/predict                                  │
│                                                                 │
│   2. Router looks up app config                                 │
│      deployments = [us-east-1 (0 replicas)]  ← scaled to zero  │
│                                                                 │
│   3. Router checks: any warm instances?                         │
│      No warm instances available                                │
│                                                                 │
│   4. Router queues request                                      │
│      queue.add(request, app_id="p-def456")                      │
│      queue_depth = 1                                            │
│                                                                 │
│   5. Router signals control plane                               │
│      POST /internal/scale-signal                                │
│      { app_id: "p-def456", queue_depth: 1, cluster: "us-east" } │
│                                                                 │
│   6. Control plane triggers scale-up                            │
│      (Knative activator or custom autoscaler)                   │
│                                                                 │
│   7. Instance becomes ready                                     │
│      Router receives notification (webhook or poll)             │
│                                                                 │
│   8. Router drains queue                                        │
│      Forwards queued request to new instance                    │
│      Returns response to client                                 │
│                                                                 │
│   Total time: ~5-30s (depending on cold start)                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Failover

```
┌─────────────────────────────────────────────────────────────────┐
│                      FAILOVER FLOW                               │
│                                                                 │
│   1. Request arrives, routed to us-east-1                       │
│                                                                 │
│   2. us-east-1 returns 503 or times out                         │
│                                                                 │
│   3. Router checks: is this retryable?                          │
│      • 503 Service Unavailable → yes                            │
│      • 504 Gateway Timeout → yes                                │
│      • Connection refused → yes                                 │
│      • 400/401/404 → no (client error)                          │
│                                                                 │
│   4. Router selects next cluster                                │
│      next_cluster = select_cluster(exclude=["us-east-1"])       │
│      → "eu-west-1"                                              │
│                                                                 │
│   5. Router forwards to eu-west-1                               │
│                                                                 │
│   6. If eu-west-1 also fails → return error to client           │
│      503 with Retry-After header                                │
│                                                                 │
│   Note: Retry budget = 2 attempts max (configurable)            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Routing Strategies

Pool selection considers multiple factors and uses a scoring algorithm. The app's `failover` strategy determines how alternatives are selected when the primary pool is unavailable.

### Pool Selection Algorithm

```zig
pub fn selectPool(
    self: *RouterPoolState,
    app_id: AppId,
    client_region: ?RegionId,
) !PoolId {
    const pools = self.getPoolsForApp(app_id);

    var best_pool: ?PoolId = null;
    var best_score: f32 = 0;

    for (pools) |pool_id| {
        const pool = self.pools.get(pool_id) orelse continue;
        if (pool.status != .healthy) continue;

        var score: f32 = 0;

        // Capacity score (0-30): prefer pools with available capacity
        score += capacityScore(pool);

        // Latency score (0-30): prefer pools near client
        if (client_region) |region| {
            score += latencyScore(pool, region);
        }

        // Queue depth score (0-20): prefer pools with shorter queues
        score += queueScore(pool);

        // Cost score (0-20): prefer cheaper pools
        score += costScore(pool);

        if (score > best_score) {
            best_score = score;
            best_pool = pool_id;
        }
    }

    return best_pool orelse error.NoPoolAvailable;
}

fn capacityScore(pool: *const PoolState) f32 {
    if (pool.available_gpus == 0) return 0;
    // More available capacity = higher score (up to 30)
    return @min(30, @intToFloat(f32, pool.available_gpus) * 3);
}

fn latencyScore(pool: *const PoolState, client_region: RegionId) f32 {
    const latency_ms = estimateLatency(pool.filter.regions, client_region);
    // Lower latency = higher score
    // 0ms = 30 points, 100ms = 20 points, 200ms = 10 points, 300ms+ = 0
    return @max(0, 30 - @intToFloat(f32, latency_ms) / 10);
}

fn queueScore(pool: *const PoolState) f32 {
    // Lower queue depth = higher score
    // 0 queued = 20 points, 10 queued = 10 points, 20+ = 0
    return @max(0, 20 - @intToFloat(f32, pool.queue_depth));
}

fn costScore(pool: *const PoolState) f32 {
    // Normalized against cheapest option
    // Cheapest = 20 points, 2x price = 10 points, 4x = 5 points
    const ratio = pool.cost_per_gpu_hour / cheapest_cost;
    return 20.0 / ratio;
}
```

### Failover Strategies

When the primary pool is unhealthy or full:

```zig
const FailoverStrategy = enum {
    /// Fail to any pool matching requirements
    any_matching,

    /// Fail to pools in order of latency (default)
    nearest_first,

    /// Fail to pools in order of cost
    cheapest_first,

    /// Don't fail over (reject if primary unavailable)
    reject,
};

fn selectPoolWithFailover(
    app: *const Application,
    primary_pool: PoolId,
) !PoolId {
    const primary = pools.get(primary_pool);

    // Try primary first
    if (primary.status == .healthy and primary.available_gpus > 0) {
        return primary_pool;
    }

    // Get all pools matching app requirements
    const alternatives = getPoolsForApp(app);

    return switch (app.failover) {
        .any_matching => selectFirstHealthy(alternatives),
        .nearest_first => selectByLatency(alternatives, client_region),
        .cheapest_first => selectByCost(alternatives),
        .reject => error.PrimaryPoolUnavailable,
    };
}
```

### Constraint Enforcement

Region and provider constraints are enforced at pool resolution time, not during selection:

```zig
// App with region constraint: regions: [eu-west, eu-central]
// Only pools in eu-west or eu-central are ever considered
// Failover CANNOT route outside these regions

// App with provider constraint: providers: [aws]
// Only pools with AWS nodes are considered
// Even if Crusoe has capacity, it won't be used

// App with no constraints
// All pools matching hardware requirements are considered
// Can route anywhere with available capacity
```

---

## Integration Points

### With Existing Infrastructure

```
┌─────────────────────────────────────────────────────────────────┐
│                   INTEGRATION (PHASE 1)                          │
│                                                                 │
│   Router integrates with existing systems:                      │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Lambda API                                             │   │
│   │  • Provides app config (deployments, routing rules)     │   │
│   │  • Router polls or receives webhooks on changes         │   │
│   │  • No changes to Lambda API required                    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Kourier (per cluster)                                  │   │
│   │  • Router forwards to Kourier endpoint                  │   │
│   │  • Kourier handles per-cluster load balancing           │   │
│   │  • No changes to Kourier required                       │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Knative Autoscaler                                     │   │
│   │  • Still handles scale-to-zero and scale-up             │   │
│   │  • Router signals demand (optional enhancement)         │   │
│   │  • Can work without any Knative changes                 │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Config Sync

```
┌─────────────────────────────────────────────────────────────────┐
│                      CONFIG SYNC                                 │
│                                                                 │
│   Option A: Pull-based (simpler, Phase 1)                       │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Router polls Lambda API every 30s                      │   │
│   │  GET /internal/router-config                            │   │
│   │  → Returns all apps, clusters, routing rules            │   │
│   │  Router caches locally, serves from cache               │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Option B: Push-based (lower latency, more complex)            │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Lambda API pushes changes to config store              │   │
│   │  Router subscribes to changes (Redis pub/sub, etc.)     │   │
│   │  Config updates propagate in ~1s                        │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Recommendation: Start with Option A, move to B if needed      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Deployment Options

### Option A: Edge Workers (Cloudflare Workers / Fly.io)

```
Pros:
  + Lowest latency (runs at edge)
  + No infrastructure to manage
  + Automatic global distribution
  + Built-in DDoS protection

Cons:
  - Limited runtime (CPU, memory, execution time)
  - Vendor lock-in
  - Complex debugging
  - May not support all routing logic

Best for: Simple routing, latency-critical
```

### Option B: Regional Deployments (EKS/K8s)

```
Pros:
  + Full control over runtime
  + Can run complex logic
  + Easier debugging
  + No vendor lock-in

Cons:
  - More infrastructure to manage
  - Higher latency than edge
  - Need to deploy in multiple regions

Best for: Complex routing, queue management
```

### Option C: Hybrid

```
Edge (Cloudflare Workers):
  • TLS termination
  • Simple routing (healthy cluster selection)
  • DDoS protection

Regional (EKS):
  • Queue management
  • Complex routing logic
  • Metrics aggregation

This is the recommended approach for production.
```

### Recommended Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                   HYBRID DEPLOYMENT                              │
│                                                                 │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │              Cloudflare (Edge Layer)                    │   │
│   │                                                         │   │
│   │  • DNS: api.hivemind.dev                                │   │
│   │  • TLS termination                                      │   │
│   │  • DDoS protection                                      │   │
│   │  • Simple routing: forward to nearest regional router   │   │
│   └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│          ┌───────────────────┼───────────────────┐              │
│          ▼                   ▼                   ▼              │
│   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐      │
│   │  Regional   │     │  Regional   │     │  Regional   │      │
│   │  Router     │     │  Router     │     │  Router     │      │
│   │  US-EAST    │     │  EU-WEST    │     │  APAC       │      │
│   │             │     │             │     │             │      │
│   │  • Queue    │     │  • Queue    │     │  • Queue    │      │
│   │  • Routing  │     │  • Routing  │     │  • Routing  │      │
│   │  • Metrics  │     │  • Metrics  │     │  • Metrics  │      │
│   └─────────────┘     └─────────────┘     └─────────────┘      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## API Design

### External API (User-Facing)

No changes to existing API. Router is transparent proxy.

```
# Existing API continues to work
POST https://api.hivemind.dev/v4/{app_id}/predict
Authorization: Bearer {token}
Content-Type: application/json

{"input": "..."}
```

### Internal API (Router ↔ Control Plane)

```yaml
# Get router configuration
GET /internal/router/config
Response:
  clusters: [...]
  applications: [...]
  routing_rules: [...]

# Report scale signal (router → control plane)
POST /internal/router/scale-signal
Body:
  app_id: "p-abc123"
  cluster_id: "aws-us-east-1"
  queue_depth: 5
  oldest_request_age_ms: 2500

# Instance ready notification (control plane → router)
POST /internal/router/instance-ready
Body:
  app_id: "p-abc123"
  cluster_id: "aws-us-east-1"
  endpoint: "http://10.0.1.5:8080"
  replicas: 1
```

### Health Check API

```yaml
# Router health (for load balancer)
GET /health
Response: 200 OK

# Detailed status
GET /internal/status
Response:
  status: "healthy"
  clusters:
    - id: "aws-us-east-1"
      status: "healthy"
      last_check: "2024-01-15T10:30:00Z"
    - id: "aws-eu-west-1"
      status: "degraded"
      last_check: "2024-01-15T10:30:00Z"
      error: "high latency"
  queues:
    - app_id: "p-abc123"
      depth: 3
      oldest_ms: 1500
```

---

## Metrics

### Request Metrics

```
# Request count by app, cluster, status
router_requests_total{app_id, cluster_id, status_code}

# Request latency (histogram)
router_request_duration_seconds{app_id, cluster_id, quantile}

# Routing decisions
router_routing_decisions_total{app_id, from_region, to_cluster, reason}
# reason: "latency", "geo_constraint", "failover", "weighted"
```

### Queue Metrics

```
# Current queue depth by app
router_queue_depth{app_id}

# Queue wait time (histogram)
router_queue_wait_seconds{app_id, quantile}

# Requests that timed out in queue
router_queue_timeouts_total{app_id}
```

### Backend Health Metrics

```
# Cluster health status
router_cluster_healthy{cluster_id}  # 1 = healthy, 0 = unhealthy

# Backend latency
router_backend_latency_seconds{cluster_id, quantile}

# Backend errors
router_backend_errors_total{cluster_id, error_type}
```

---

## Implementation Plan

### Phase 1a: Minimal Router (2 weeks)

```
Deliverables:
  [ ] Router service skeleton (Go or Rust)
  [ ] Config loading from Lambda API
  [ ] Simple routing (app → single cluster)
  [ ] Health check endpoint
  [ ] Prometheus metrics
  [ ] Deploy to one region (us-east-1)

Not included:
  - Multi-cluster routing
  - Queue management
  - Failover
```

### Phase 1b: Multi-Cluster Routing (2 weeks)

```
Deliverables:
  [ ] Cluster registry data model
  [ ] Latency-based routing
  [ ] Geo-constrained routing
  [ ] Health checking for clusters
  [ ] Failover on backend errors
  [ ] Deploy to all regions
```

### Phase 1c: Queue Management (2 weeks)

```
Deliverables:
  [ ] Per-app request queue
  [ ] Scale signal to control plane
  [ ] Instance ready notification handling
  [ ] Queue metrics
  [ ] Timeout handling (503 with Retry-After)
```

### Phase 1d: Production Hardening (2 weeks)

```
Deliverables:
  [ ] Connection pooling optimization
  [ ] Circuit breaker for unhealthy clusters
  [ ] Rate limiting (optional)
  [ ] Detailed logging and tracing
  [ ] Runbook and alerting
  [ ] Load testing (target: 10k RPS)
```

---

## Technology Choice

### Language: Zig

**Decision**: Zig

The Router is a DST-critical component. Routing decisions, queue behavior, and failure handling must be testable under all conditions through deterministic simulation.

#### Why Zig?

| Factor | Zig Advantage |
|--------|---------------|
| **Deterministic Simulation** | No GC, no runtime - complete control over all non-determinism |
| **Queue testing** | Can simulate exact request timing, backpressure scenarios |
| **Failure injection** | Simulate network partitions, backend failures at precise moments |
| **Performance** | No GC pauses, predictable latency (important for <10ms P99 goal) |
| **Binary size** | Smaller deployment footprint |
| **Zig 0.16 I/O** | Native support for swapping real I/O with simulated I/O |

#### Why Not Go?

| Factor | Go Consideration |
|--------|------------------|
| **Team familiarity** | Team knows Go well (Lambda API, CLI). Zig requires learning. |
| **Faster iteration** | Go compiles fast, mature tooling, easy debugging |
| **HTTP ecosystem** | net/http, fasthttp are battle-tested. Zig HTTP is less mature. |
| **GC pauses** | Modern Go GC pauses are typically <1ms - likely acceptable for routing |

#### Why Not Rust?

| Factor | Rust Consideration |
|--------|-------------------|
| **Mature async** | Tokio is well-tested, but its scheduler is non-deterministic |
| **Safety** | Borrow checker provides memory safety, but adds complexity |
| **DST difficulty** | Async runtime makes true deterministic simulation harder |

#### Decision Rationale

The Router's correctness is critical - routing bugs affect all traffic. The ability to:
1. Replay exact failure scenarios from production
2. Test all queue state transitions deterministically
3. Simulate network partitions between router and backends
4. Verify timeout handling under controlled time

...justifies the investment in Zig despite the learning curve. The team can use Go for non-DST components (Beekeeper, CLI) where iteration speed matters more.

### Key Libraries (Zig)

```
HTTP Server:     std.http.Server or custom (for DST compatibility)
Networking:      Abstract via interface (see ENGINEERING.md)
Metrics:         Custom prometheus exporter
Config:          YAML/JSON parsing with std.json
Logging:         std.log with structured output
```

### Infrastructure

```
Deployment:      Kubernetes (EKS) in each region
Load Balancer:   AWS NLB or Cloudflare
Config Store:    DynamoDB (or Lambda API direct)
Metrics:         Prometheus → Grafana Cloud
```

---

## WebSocket and Streaming Support

The router must support WebSocket connections and streaming responses (SSE, chunked transfer).

### WebSocket Handling

```
┌─────────────────────────────────────────────────────────────────┐
│                    WEBSOCKET FLOW                                │
│                                                                 │
│   1. Client initiates WebSocket upgrade                         │
│      GET /v4/p-abc123/ws                                        │
│      Upgrade: websocket                                         │
│      Connection: Upgrade                                        │
│                                                                 │
│   2. Router handles upgrade                                     │
│      • Auth validation (same as HTTP)                           │
│      • Select target cluster                                    │
│      • Establish upstream WebSocket                             │
│                                                                 │
│   3. Bidirectional proxy                                        │
│      Client ◄──────► Router ◄──────► Backend                   │
│              ws              ws                                 │
│                                                                 │
│   4. Connection lifetime                                        │
│      • Router maintains both connections                        │
│      • Forwards frames bidirectionally                          │
│      • Handles ping/pong keepalives                             │
│      • Closes both on either side disconnect                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Sticky sessions**: WebSocket connections are inherently sticky (single long-lived connection). No special handling needed beyond maintaining the connection pair.

**Failover**: WebSocket connections cannot fail over mid-stream. If backend dies, connection closes. Client must reconnect (may hit different cluster).

### Streaming Response Handling

```
┌─────────────────────────────────────────────────────────────────┐
│                   STREAMING FLOW                                 │
│                                                                 │
│   SSE (Server-Sent Events):                                     │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Content-Type: text/event-stream                        │   │
│   │  Transfer-Encoding: chunked                             │   │
│   │                                                         │   │
│   │  Router behavior:                                       │   │
│   │  • Do NOT buffer response body                          │   │
│   │  • Stream chunks as received from backend               │   │
│   │  • Flush after each chunk                               │   │
│   │  • Maintain connection until backend closes             │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Chunked Transfer (e.g., model streaming):                     │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  Transfer-Encoding: chunked                             │   │
│   │                                                         │   │
│   │  Router behavior:                                       │   │
│   │  • Stream chunks transparently                          │   │
│   │  • Track bytes for metrics                              │   │
│   │  • Timeout on chunk gaps (configurable, default 30s)    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Request body handling**: Stream request body to backend (don't buffer entirely). Allows large payloads without memory pressure.

### Connection Management

```go
type ConnectionConfig struct {
    // HTTP connections
    MaxIdleConnsPerHost     int           // 100
    IdleConnTimeout         time.Duration // 90s
    ResponseHeaderTimeout   time.Duration // 30s

    // Streaming
    StreamingChunkTimeout   time.Duration // 30s between chunks
    MaxStreamDuration       time.Duration // 1h max stream

    // WebSocket
    WebSocketReadLimit      int64         // 1MB per message
    WebSocketPingInterval   time.Duration // 30s
    WebSocketPongTimeout    time.Duration // 10s
}
```

---

## Authentication at Router

Auth happens at the router to reject invalid requests early, before routing to backend clusters. This follows the axon pattern.

### Three-Layer Auth

```
┌─────────────────────────────────────────────────────────────────┐
│                   AUTHENTICATION LAYERS                          │
│                                                                 │
│   Layer 1: Metadata Validation (Turso)                          │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  • Project exists?                                      │   │
│   │  • Project payment status active?                       │   │
│   │  • App exists and not deleted?                          │   │
│   │  • Auth disabled for this app?                          │   │
│   │  • App available in requested region?                   │   │
│   │                                                         │   │
│   │  Early exit: 402, 403, 404 before crypto overhead       │   │
│   └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│   Layer 2: JWT Signature Validation                             │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  • Extract Bearer token                                 │   │
│   │  • Check token not in blacklist (Turso)                 │   │
│   │  • Select public key (dev/prod based on project prefix) │   │
│   │  • Validate RS256 signature                             │   │
│   │                                                         │   │
│   │  Exit: 401 Unauthorized                                 │   │
│   └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│   Layer 3: Claims Validation                                    │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  • Verify projectId claim matches URL projectId         │   │
│   │  • Verify token not expired                             │   │
│   │  • (Future: scope validation)                           │   │
│   │                                                         │   │
│   │  Exit: 401 Unauthorized                                 │   │
│   └─────────────────────────────────────────────────────────┘   │
│                              │                                  │
│                              ▼                                  │
│                     Route to backend                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Turso Integration

```
┌─────────────────────────────────────────────────────────────────┐
│                   TURSO FOR AUTH DATA                            │
│                                                                 │
│   Turso Embedded Replica:                                       │
│   • SQLite database synced from Turso cloud                     │
│   • Sync interval: 10 seconds                                   │
│   • Queries hit local SQLite (microseconds, not network)        │
│   • Perfect for read-heavy auth checks                          │
│                                                                 │
│   Tables:                                                       │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  projects                                               │   │
│   │  ├── id: string (project ID)                            │   │
│   │  └── payment_status: "active" | "unpaid" | "trialing"   │   │
│   │                                                         │   │
│   │  models (apps)                                          │   │
│   │  ├── id: "{projectId}-{appName}"                        │   │
│   │  ├── project_id: string                                 │   │
│   │  ├── status: null | "deleted"                           │   │
│   │  ├── disable_auth: bool                                 │   │
│   │  └── regions: string (comma-separated)                  │   │
│   │                                                         │   │
│   │  invalidated_keys                                       │   │
│   │  ├── jwt_token: string                                  │   │
│   │  ├── public_key: string                                 │   │
│   │  └── project_id: string                                 │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Sync architecture:                                            │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                                                         │   │
│   │   Turso Cloud ──────────────────────────────────────    │   │
│   │        │              │              │                  │   │
│   │        │ sync         │ sync         │ sync             │   │
│   │        ▼              ▼              ▼                  │   │
│   │   ┌────────┐    ┌────────┐    ┌────────┐               │   │
│   │   │Router 1│    │Router 2│    │Router 3│               │   │
│   │   │(local) │    │(local) │    │(local) │               │   │
│   │   │SQLite  │    │SQLite  │    │SQLite  │               │   │
│   │   └────────┘    └────────┘    └────────┘               │   │
│   │                                                         │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Note: 10s sync means token invalidation takes up to 10s       │
│   to propagate. Acceptable for most cases.                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### JWT Key Management

```go
// Keys per environment (from axon pattern)
// In production, load from secrets manager
var publicKeys = map[string]*rsa.PublicKey{
    "dev":  loadKey(os.Getenv("JWT_PUBLIC_KEY_DEV")),
    "prod": loadKey(os.Getenv("JWT_PUBLIC_KEY_PROD")),
}

func getKeyForProject(projectId string) *rsa.PublicKey {
    if strings.HasPrefix(projectId, "dev-") {
        return publicKeys["dev"]
    }
    return publicKeys["prod"]
}
```

### Auth Bypass Cases

```go
// Skip auth for:
// 1. CORS preflight requests
if r.Method == "OPTIONS" &&
   r.Header.Get("Origin") != "" &&
   r.Header.Get("Access-Control-Request-Method") != "" {
    return next(r)  // Skip auth
}

// 2. Apps with auth disabled
if app.DisableAuth {
    return next(r)  // Skip auth
}

// 3. Health check endpoints
if r.URL.Path == "/health" {
    return next(r)  // Skip auth
}
```

---

## Rate Limiting and DDoS Protection

### Rate Limiting Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                   RATE LIMITING LAYERS                           │
│                                                                 │
│   Layer 1: DDoS Protection (Router / Edge)                      │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  • Connection rate limiting per IP                      │   │
│   │  • Request rate limiting per IP                         │   │
│   │  • Payload size limits                                  │   │
│   │  • Slowloris protection (connection timeouts)           │   │
│   │  • Geographic blocking (if needed)                      │   │
│   │                                                         │   │
│   │  Implementation: Cloudflare (edge) or router middleware │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Layer 2: API Rate Limiting (Router)                           │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  • Per-project request rate                             │   │
│   │  • Per-project concurrent connections                   │   │
│   │  • Per-app request rate                                 │   │
│   │                                                         │   │
│   │  Implementation: Token bucket in router                 │   │
│   │  Storage: Redis (shared across router instances)        │   │
│   │  Or: Approximate local counting (simpler, less precise) │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│   Layer 3: Resource Rate Limiting (Backend/Control Plane)       │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │  • GPU-seconds per billing period                       │   │
│   │  • Concurrent GPU instances                             │   │
│   │  • Storage usage                                        │   │
│   │                                                         │   │
│   │  Implementation: Control plane / billing system         │   │
│   │  Not at router layer                                    │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Router Rate Limit Config

```yaml
rate_limits:
  # DDoS protection (per IP)
  ddos:
    requests_per_second: 100
    burst: 200
    block_duration: 60s

  # API rate limits (per project)
  api:
    requests_per_minute: 1000     # Adjustable per tier
    concurrent_connections: 100
    max_request_size: 100MB

  # Bypass for internal traffic
  bypass:
    - cidr: "10.0.0.0/8"          # Internal VPC
    - header: "X-Internal-Token"   # Service-to-service
```

### Rate Limit Response

```http
HTTP/1.1 429 Too Many Requests
Retry-After: 30
X-RateLimit-Limit: 1000
X-RateLimit-Remaining: 0
X-RateLimit-Reset: 1705312800

{
  "error": "rate_limit_exceeded",
  "message": "Too many requests. Please retry after 30 seconds.",
  "retry_after": 30
}
```

---

## Open Questions

1. **Request body buffering**: Buffer entire request before forwarding, or stream?
   - **Decision**: Stream by default for large payloads, buffer only for retry logic

2. **Turso sync interval**: 10 seconds acceptable for token invalidation?
   - **Decision**: Yes, acceptable. Critical invalidations can use Redis cache overlay if needed.

3. **Multi-region Turso**: One Turso DB or per-region replicas?
   - **Decision**: Single Turso DB with embedded replicas in each router region (built-in to Turso)

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Added latency (P50) | < 5ms |
| Added latency (P99) | < 15ms |
| Availability | 99.9% |
| Throughput | 10,000 RPS per region |
| Queue wait time (P50) | < 5s |
| Config propagation | < 30s |

---

## Related Documents

- [ARCHITECTURE.md](../ARCHITECTURE.md) - Overall system architecture
- [PLATFORM.md](../PLATFORM.md) - Current platform state
- [PROVIDERS.md](PROVIDERS.md) - Multi-provider abstraction and pool model
- [HIVEMIND.md](HIVEMIND.md) - Control plane (provides pool state to Router)
- [WORKLOAD_TYPES.md](WORKLOAD_TYPES.md) - Jobs, CronJobs, and Instances (bypass Router)
- [MIGRATION.md](../MIGRATION.md) - Migration strategy

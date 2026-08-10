# Thalamus: Inter-Cluster Router

> **LEGACY — not Hivemind `core/` in-repo:** Inter-cluster / edge-router design and delivery planning. It extends [Edge Routing.md](Edge%20Routing.md). For the **Hivemind `core/` Zig control plane** and agents in this repo, see **`docs/STATUS.md`** and **`docs/FINDINGS_AND_ISSUES.md`**. Listed in **`docs/legacy/README.md`**.

> **Foundation**: This document extends the original Thalamus design from [Edge Routing.md](Edge%20Routing.md), adding implementation details, capacity signals, and a 10-week delivery timeline.

---

## Background

Thalamus was originally proposed as Hivemind's inter-cluster router - a Cloudflare Workers-based system that routes requests across multiple origins based on configurable strategies. The original design established:

- **Strategy pattern** for pluggable routing logic
- **Push-based state model** where origins push signals to the edge
- **Axon load shedding** for cluster-to-cluster failover via `X-Thalamus-Metadata`
- **Separation of concerns** between intra-cluster (Cortex/Axon) and inter-cluster (Thalamus) routing

This document extends that foundation with:

1. **Concrete capacity signals** - GPU allocation, queue depth, scalability metrics
2. **Data locality scoring** - Route considering where images are cached
3. **Turso as the state store** - Edge-replicated SQLite instead of KV/Durable Objects
4. **Implementation options** - Cloudflare Workers OR Go service
5. **10-week delivery timeline** - Phased implementation plan

### Extensions from Accelerated Planning

| Original Thalamus Concept | Extension |
|--------------------------|-----------|
| Origin capabilities (GPU types) | + Scalability signals (can we get MORE nodes?) |
| Push state to edge storage | Turso with edge replication (replaces KV/admin worker) |
| Strategy pattern | + Concrete strategies: CapacityWeighted, CostOptimized, DataLocality |
| Axon load shedding | Unchanged - critical for real-time failover |
| App manifest push at build | + Sync from DynamoDB (existing config store) |
| — | + Data locality scoring for cold start optimization |
| — | + Two-tier failover (router-level + Axon load shed) |

---

## Current Infrastructure

| Component | Current State |
|-----------|---------------|
| **Clusters** | 5 K8s clusters: 3 AWS EKS (us-east-1, eu-west-2, ap-southeast-1), 2 Crusoe (us-east, us-southwest) |
| **Ingress** | Each cluster has its own Kourier ingress, directly reachable |
| **Load Balancing** | Cloudflare ratio-based splitting between Crusoe US-East and AWS US-East only |
| **Storage** | JuiceFS on AWS S3 (us-east-1, eu-west-2); Crusoe uses AWS JuiceFS cross-provider |
| **Registry** | Per-cluster registries backed by JuiceFS |
| **Autoscaling** | Karpenter (EKS), custom autoscaler (Crusoe) |
| **Observability** | Prometheus + DCGM + Kourier metrics in each cluster |
| **App Config** | DynamoDB |

---

## The Problem

**Current State**:
- 5 independent K8s clusters (3 AWS EKS, 2 Crusoe)
- Each cluster has its own ingress and DNS
- Cloudflare does ratio-based splitting between 2 clusters only
- Running out of capacity in existing clusters
- Need to add more clusters but can't route to them intelligently

**What We Need**:
1. Single DNS entry point (`api.hivemind.dev`)
2. Route requests to appropriate cluster based on app requirements (GPU type, region, provider)
3. Route away from clusters that are at capacity
4. Fail over when clusters are unhealthy or can't scale
5. Cost-optimize by preferring cheaper providers when possible
6. Factor data locality into routing decisions

**What We're NOT Doing** (in 10 weeks):
- Replacing Knative (keep it in each cluster)
- New container registry (keep existing)
- New build system (keep Depot)
- New control plane (just routing)
- New node agent (keep DaemonSets)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│                          api.hivemind.dev                                    │
│                               │                                              │
│                               ▼                                              │
│   ┌───────────────────────────────────────────────────────────────────────┐  │
│   │                         THALAMUS ROUTER                               │  │
│   │                                                                       │  │
│   │   1. Extract app_id from request path                                 │  │
│   │   2. Lookup app config → get requirements (GPU type, region, etc.)    │  │
│   │   3. Get cluster state → filter to clusters that can serve            │  │
│   │   4. Execute routing strategies → pick best cluster                   │  │
│   │   5. Proxy request with X-Thalamus-Metadata header                    │  │
│   │   6. On 503/timeout → failover to next best cluster                   │  │
│   │                                                                       │  │
│   └───────────────────────────────────────────────────────────────────────┘  │
│                               │                                              │
│       ┌───────────────────────┼───────────────────────┐                      │
│       │                       │                       │                      │
│       ▼                       ▼                       ▼                      │
│  ┌─────────────┐        ┌─────────────┐        ┌─────────────┐              │
│  │ AWS US-East │        │ AWS EU-West │        │ Crusoe US   │   + more     │
│  │             │        │             │        │             │              │
│  │  Kourier    │        │  Kourier    │        │  Kourier    │              │
│  │  Axon ◄─────┼────────┼── Axon ◄────┼────────┼── Axon      │              │
│  │  (load shed)│        │  (load shed)│        │  (load shed)│              │
│  └─────────────┘        └─────────────┘        └─────────────┘              │
│         │                      │                      │                      │
│         └──────────────────────┴──────────────────────┘                      │
│                               │                                              │
│                    Axon can shed load to other clusters                      │
│                    using X-Thalamus-Metadata for eligible origins            │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Core Concepts

### Terminology (from original Thalamus design)

- **Origin**: A single cluster, usually denoted by a domain name
- **Cluster**: Interchangeable with origin; the suite of services running in a single origin
- **Thalamus**: The inter-cluster router (named after the brain's relay center)
- **Axon**: Intra-cluster proxy layer (already exists in clusters) - handles load shedding
- **Strategy**: A pluggable routing algorithm implementing the `RoutingStrategy` interface
- **State**: Dynamic data used as input to routing decisions (pushed by origins)

### App Manifest

Apps define their requirements, not specific clusters:

```go
type AppManifest struct {
    AppID    string       `json:"app_id"`
    Revision int          `json:"revision"`
    Requirements struct {
        GPU     []string `json:"gpu"`      // ["h100", "a100"]
        Regions []string `json:"regions"`  // [] = any
        Providers []string `json:"providers"` // [] = any
    } `json:"requirements"`
}
```

### Origin State

Each origin reports its capabilities and current state:

```go
type Origin struct {
    Name   string `json:"name"`   // aws-us-east-1, crusoe-us-east, etc
    Region string `json:"region"`
    Domain string `json:"domain"`

    // Capabilities (static)
    Capabilities struct {
        GPUTypes []string `json:"gpu_types"`
        TotalGPUs int     `json:"total_gpus"`
    } `json:"capabilities"`

    // State (dynamic, pushed to Turso by cluster)
    State struct {
        AvailableGPUs  int       `json:"available_gpus"`
        QueueDepth     float64   `json:"queue_depth"`
        PendingGPUPods int       `json:"pending_gpu_pods"`
        HealthScore    float64   `json:"health_score"`
        Scalability    ScalabilityState `json:"scalability"`
    } `json:"state"`

    // Cost
    CostTier int `json:"cost_tier"` // 1=cheapest, 3=expensive
}
```

---

## Routing Engine

### Strategy Pattern (from original design)

The original Thalamus design defined a `RoutingStrategy` interface where implementations encode specific load balancing logic. We extend this with concrete implementations:

```go
type RoutingStrategy interface {
    Name() string
    Evaluate(ctx RoutingContext) *RoutingDecision
}

type RoutingContext struct {
    Request        *http.Request
    App            AppManifest
    AllowedOrigins []Origin
    UserRegion     string // From CF headers if available
}

type RoutingDecision struct {
    Origin Origin
    Score  float64 // 0.0 - 1.0, used as tiebreaker
    Reason string  // For logging/debugging
}
```

### Built-in Strategies (new implementations)

The original design mentioned `LeastConcurrentStrat` as an example. We extend with these concrete strategies for our use case:

#### 1. Capacity-Weighted Strategy

Prefers clusters with more available capacity:

```go
type CapacityWeightedStrategy struct{}

func (s CapacityWeightedStrategy) Name() string { return "capacity-weighted" }

func (s CapacityWeightedStrategy) Evaluate(ctx RoutingContext) *RoutingDecision {
    var best *Origin
    var bestScore float64 = -1

    for _, orig := range ctx.AllowedOrigins {
        // Score based on available capacity
        capacityRatio := float64(orig.State.AvailableGPUs) / float64(orig.Capabilities.TotalGPUs)

        // Penalize queue depth
        queuePenalty := math.Min(orig.State.QueueDepth * 0.02, 0.3)

        // Factor in scalability
        scalePenalty := 0.0
        if !orig.State.Scalability.CanScale {
            scalePenalty = 0.3
        } else if orig.State.Scalability.FailureRate > 0.3 {
            scalePenalty = 0.15
        }

        score := capacityRatio - queuePenalty - scalePenalty

        if score > bestScore {
            bestScore = score
            best = &orig
        }
    }

    if best == nil {
        return nil
    }
    return &RoutingDecision{Origin: *best, Score: bestScore, Reason: "capacity-weighted"}
}
```

#### 2. Least Concurrent Strategy

Prefers the origin with fewest active requests:

```go
type LeastConcurrentStrategy struct{}

func (s LeastConcurrentStrategy) Name() string { return "least-concurrent" }

func (s LeastConcurrentStrategy) Evaluate(ctx RoutingContext) *RoutingDecision {
    var best *Origin
    lowestQueue := math.MaxFloat64

    for _, orig := range ctx.AllowedOrigins {
        if orig.State.QueueDepth < lowestQueue {
            lowestQueue = orig.State.QueueDepth
            best = &orig
        }
    }

    if best == nil {
        return nil
    }

    // Normalize score (lower queue = higher score)
    score := 1.0 / (1.0 + lowestQueue)
    return &RoutingDecision{Origin: *best, Score: score, Reason: "least-concurrent"}
}
```

#### 3. Cost-Optimized Strategy

Prefers cheaper providers when capacity is available:

```go
type CostOptimizedStrategy struct{}

func (s CostOptimizedStrategy) Name() string { return "cost-optimized" }

func (s CostOptimizedStrategy) Evaluate(ctx RoutingContext) *RoutingDecision {
    // Sort by cost tier (lowest first)
    sorted := make([]Origin, len(ctx.AllowedOrigins))
    copy(sorted, ctx.AllowedOrigins)
    sort.Slice(sorted, func(i, j int) bool {
        return sorted[i].CostTier < sorted[j].CostTier
    })

    // Return cheapest with capacity
    for _, orig := range sorted {
        if orig.State.AvailableGPUs >= ctx.App.Requirements.GPUCount {
            score := float64(4-orig.CostTier) / 3.0 // tier 1 = 1.0, tier 3 = 0.33
            return &RoutingDecision{Origin: orig, Score: score, Reason: "cost-optimized"}
        }
    }

    return nil
}
```

#### 4. Geo-Proximity Strategy

Prefers clusters near the user:

```go
type GeoProximityStrategy struct{}

func (s GeoProximityStrategy) Name() string { return "geo-proximity" }

func (s GeoProximityStrategy) Evaluate(ctx RoutingContext) *RoutingDecision {
    if ctx.UserRegion == "" {
        return nil // Can't determine user location
    }

    // Find origin in same region
    for _, orig := range ctx.AllowedOrigins {
        if orig.Region == ctx.UserRegion {
            return &RoutingDecision{Origin: orig, Score: 1.0, Reason: "geo-proximity-exact"}
        }
    }

    // Find origin in same continent
    userContinent := regionToContinent(ctx.UserRegion)
    for _, orig := range ctx.AllowedOrigins {
        if regionToContinent(orig.Region) == userContinent {
            return &RoutingDecision{Origin: orig, Score: 0.7, Reason: "geo-proximity-continent"}
        }
    }

    return nil
}
```

#### 5. Data Locality Strategy

Prefers clusters where app data is cached:

```go
type DataLocalityStrategy struct {
    imageCache ImageCacheTracker
}

func (s DataLocalityStrategy) Name() string { return "data-locality" }

func (s DataLocalityStrategy) Evaluate(ctx RoutingContext) *RoutingDecision {
    var best *Origin
    var bestScore float64 = 0

    for _, orig := range ctx.AllowedOrigins {
        score := 0.0

        // Image already pulled = fast cold start
        if s.imageCache.HasImage(orig.Name, ctx.App.ImageRef) {
            score = 1.0
        } else if orig.Region == ctx.App.PrimaryDataRegion {
            score = 0.7 // Same region as primary storage
        } else if orig.Provider == ctx.App.StorageProvider {
            score = 0.4 // Same provider = better peering
        }

        if score > bestScore {
            bestScore = score
            best = &orig
        }
    }

    if best == nil || bestScore == 0 {
        return nil
    }
    return &RoutingDecision{Origin: *best, Score: bestScore, Reason: "data-locality"}
}
```

### Strategy Orchestration

The router combines multiple strategies:

```go
type Router struct {
    strategies []RoutingStrategy
    store      StateStore
}

func (r *Router) SelectOrigin(ctx RoutingContext) (*Origin, error) {
    // Step 1: Filter origins by requirements
    allowed := r.filterByRequirements(ctx.App, r.store.GetOrigins())
    if len(allowed) == 0 {
        return nil, ErrNoEligibleOrigins
    }
    ctx.AllowedOrigins = allowed

    // Step 2: Run all strategies
    var decisions []RoutingDecision
    for _, strat := range r.strategies {
        if decision := strat.Evaluate(ctx); decision != nil {
            decisions = append(decisions, *decision)
        }
    }

    if len(decisions) == 0 {
        // Fallback: return first available
        return &allowed[0], nil
    }

    // Step 3: Combine scores (weighted average or pick highest)
    // Simple approach: pick highest score
    sort.Slice(decisions, func(i, j int) bool {
        return decisions[i].Score > decisions[j].Score
    })

    return &decisions[0].Origin, nil
}

func (r *Router) filterByRequirements(app AppManifest, origins []Origin) []Origin {
    var allowed []Origin
    for _, orig := range origins {
        if !r.satisfiesRequirements(app, orig) {
            continue
        }
        allowed = append(allowed, orig)
    }
    return allowed
}

func (r *Router) satisfiesRequirements(app AppManifest, orig Origin) bool {
    // GPU type must match
    if !containsAny(orig.Capabilities.GPUTypes, app.Requirements.GPU) {
        return false
    }

    // Region constraint (if specified)
    if len(app.Requirements.Regions) > 0 && !contains(app.Requirements.Regions, orig.Region) {
        return false
    }

    // Provider constraint (if specified)
    if len(app.Requirements.Providers) > 0 && !contains(app.Requirements.Providers, orig.Provider) {
        return false
    }

    // Must have capacity
    if orig.State.AvailableGPUs < app.Requirements.GPUCount {
        return false
    }

    return true
}
```

---

## Capacity Signals (Extension)

The original Thalamus design described origins pushing "capabilities" and "constraints" to the edge. This section defines the **concrete signals** we'll use for routing decisions.

### Signal 1: GPU Allocation (from DCGM)

```promql
# Available GPUs = Total - Allocated
sum(kube_node_status_allocatable{resource="nvidia.com/gpu"})
  - sum(kube_pod_container_resource_requests{resource="nvidia.com/gpu"})
```

### Signal 2: Queue Depth (from Kourier)

```promql
# Queue depth per revision
activator_request_count{state="queued"}
```

### Signal 3: Pending Pods (from kube-state-metrics)

```promql
# Pods waiting for GPU resources
sum(kube_pod_status_phase{phase="Pending"}
    * on(pod,namespace) kube_pod_container_resource_requests{resource="nvidia.com/gpu"})
```

### Signal 4: Scalability

Can the cluster scale up when needed?

#### EKS Clusters (Karpenter)

```promql
karpenter_nodeclaims_state{state="pending"}
karpenter_nodes_state{state="not_ready"}
increase(karpenter_disruption_actions_performed_total[10m])
```

#### Crusoe Clusters (Custom Autoscaler)

Required metrics to add:

```prometheus
hivemind_autoscaler_pending_requests{gpu_type="h100"} 3
hivemind_autoscaler_provisioning_failures_total
```

### Scalability State Model

```go
type ScalabilityState struct {
    CanScale          bool    // Can this cluster scale up?
    ScaleConfidence   float64 // 0.0 - 1.0
    PendingNodeClaims int     // Nodes waiting to provision
    RecentFailures    int     // Scale failures in last 10 min
    FailureRate       float64 // Failures / attempts
    Reason            string  // "karpenter_stuck", "provider_sold_out", etc
}
```

---

## Axon Load Shedding (from original design)

This section implements the load shedding mechanism described in the original Thalamus document.

### The Problem Router-Level Failover Can't Solve

The router makes decisions based on state that's up to 30 seconds stale. A cluster might:
- Become overloaded between polling cycles
- Hit capacity limits the router doesn't know about
- Experience internal issues (OOM, network partition)

### Solution: X-Thalamus-Metadata Header

When routing a request, include all eligible origins in a header:

```go
func (r *Router) proxyRequest(req *http.Request, primary Origin, alternatives []Origin) (*http.Response, error) {
    // Build metadata for Axon
    metadata := ThalamusMetadata{
        RequestID:    uuid.New().String(),
        Primary:      primary.Name,
        Alternatives: make([]string, len(alternatives)),
        MaxHops:      3,
        CurrentHop:   0,
    }
    for i, alt := range alternatives {
        metadata.Alternatives[i] = alt.Domain
    }

    // Serialize and attach
    metaJSON, _ := json.Marshal(metadata)
    req.Header.Set("X-Thalamus-Metadata", string(metaJSON))

    return r.proxy.Do(req, primary.Domain)
}

type ThalamusMetadata struct {
    RequestID    string   `json:"request_id"`
    Primary      string   `json:"primary"`
    Alternatives []string `json:"alternatives"`
    MaxHops      int      `json:"max_hops"`
    CurrentHop   int      `json:"current_hop"`
}
```

### Axon Behavior

When Axon receives a request with `X-Thalamus-Metadata`:

```go
func (a *Axon) HandleRequest(req *http.Request) (*http.Response, error) {
    metadata := parseThalamusMetadata(req.Header.Get("X-Thalamus-Metadata"))

    // Try to process locally
    if a.canProcess(req) {
        return a.processLocally(req)
    }

    // Load shedding: can't process, try alternatives
    if metadata != nil && metadata.CurrentHop < metadata.MaxHops {
        return a.shedToAlternative(req, metadata)
    }

    // No alternatives or max hops reached
    return nil, ErrServiceUnavailable
}

func (a *Axon) shedToAlternative(req *http.Request, metadata *ThalamusMetadata) (*http.Response, error) {
    // Remove self from alternatives
    remaining := removeOrigin(metadata.Alternatives, a.selfDomain)

    if len(remaining) == 0 {
        return nil, ErrNoAlternatives
    }

    // Update metadata
    metadata.CurrentHop++
    metadata.Alternatives = remaining
    metaJSON, _ := json.Marshal(metadata)
    req.Header.Set("X-Thalamus-Metadata", string(metaJSON))

    // Forward to next alternative
    return http.DefaultClient.Do(req.WithURL(remaining[0] + req.URL.Path))
}
```

### Benefits

1. **Real-time decisions**: Axon knows its actual state, not 30-second-old metrics
2. **Graceful degradation**: Request finds a cluster that can serve it
3. **No circular routing**: Each hop removes the current origin from alternatives
4. **Bounded hops**: MaxHops prevents infinite forwarding
5. **Observability**: RequestID enables tracing across hops

---

## State Management

### Push Model with Turso (evolved from original design)

The original Thalamus design proposed an "admin worker" that origins would push state to, with storage in Cloudflare KV or Durable Objects. We evolve this to use **Turso** (distributed SQLite) which provides:

- Automatic edge replication (no need for manual KV sync)
- SQL queries (more flexible than KV get/put)
- Embedded replicas (sub-ms reads in Go service)

Clusters push state to Turso. The router reads from the nearest edge replica.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PUSH MODEL WITH TURSO                              │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         TURSO (Primary)                              │   │
│   │                    Distributed SQLite with edge replicas             │   │
│   │                                                                      │   │
│   │   Tables:                                                            │   │
│   │   • origins (capabilities, state, scalability)                       │   │
│   │   • apps (manifests, requirements)                                   │   │
│   │   • image_cache (origin, image_ref, pulled_at)                       │   │
│   │                                                                      │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                    ▲                              │                          │
│                    │ PUSH                         │ REPLICATE                │
│                    │                              ▼                          │
│   ┌────────────────┴────────────────┐    ┌─────────────────────────────┐   │
│   │         CLUSTER PUSHERS          │    │      EDGE REPLICAS          │   │
│   │                                  │    │                             │   │
│   │  ┌──────────┐  ┌──────────┐     │    │  ┌─────────┐  ┌─────────┐  │   │
│   │  │AWS US-E  │  │Crusoe US │     │    │  │ US Edge │  │ EU Edge │  │   │
│   │  │StateSync │  │StateSync │     │    │  │ Replica │  │ Replica │  │   │
│   │  └──────────┘  └──────────┘     │    │  └────┬────┘  └────┬────┘  │   │
│   │                                  │    │       │            │       │   │
│   │  Reads from local Prometheus     │    │       ▼            ▼       │   │
│   │  Pushes to Turso every 10-30s    │    │  ┌─────────┐  ┌─────────┐ │   │
│   │                                  │    │  │Router US│  │Router EU│ │   │
│   └──────────────────────────────────┘    │  └─────────┘  └─────────┘ │   │
│                                           │                           │   │
│                                           │  Reads from local replica │   │
│                                           │  (sub-ms latency)         │   │
│                                           └───────────────────────────┘   │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Why Turso?

| Feature | Benefit |
|---------|---------|
| **Edge replication** | Automatic sync to 30+ locations; router reads locally |
| **SQLite compatibility** | Simple schema, familiar tooling, easy migrations |
| **Embedded replicas** | Can embed read replica in router process |
| **libSQL** | Open source, no vendor lock-in risk |
| **Low latency reads** | Sub-ms from edge replica vs 50-200ms cross-region |

### Schema

```sql
-- Origin capabilities and state
CREATE TABLE origins (
    name TEXT PRIMARY KEY,           -- 'aws-us-east-1', 'crusoe-us-east'
    region TEXT NOT NULL,
    domain TEXT NOT NULL,
    provider TEXT NOT NULL,
    cost_tier INTEGER NOT NULL,      -- 1=cheapest, 3=expensive

    -- Capabilities (static, set on cluster registration)
    gpu_types TEXT NOT NULL,         -- JSON array: ["h100", "a100"]
    total_gpus INTEGER NOT NULL,

    -- State (updated by cluster pusher)
    available_gpus INTEGER NOT NULL DEFAULT 0,
    queue_depth REAL NOT NULL DEFAULT 0,
    pending_gpu_pods INTEGER NOT NULL DEFAULT 0,
    health_score REAL NOT NULL DEFAULT 100,
    status TEXT NOT NULL DEFAULT 'unknown',  -- healthy, degraded, down

    -- Scalability
    can_scale BOOLEAN NOT NULL DEFAULT true,
    scale_confidence REAL NOT NULL DEFAULT 1.0,
    pending_node_claims INTEGER NOT NULL DEFAULT 0,
    recent_scale_failures INTEGER NOT NULL DEFAULT 0,
    scale_failure_rate REAL NOT NULL DEFAULT 0,

    -- Metadata
    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

-- App manifests
CREATE TABLE apps (
    app_id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,

    -- Requirements
    gpu_types TEXT NOT NULL,          -- JSON array: ["h100"]
    gpu_count INTEGER NOT NULL DEFAULT 1,
    regions TEXT,                     -- JSON array or NULL for any
    providers TEXT,                   -- JSON array or NULL for any

    -- Data locality hints
    image_ref TEXT,
    primary_data_region TEXT,
    storage_provider TEXT,

    updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

-- Image cache tracking (which origins have pulled which images)
CREATE TABLE image_cache (
    origin TEXT NOT NULL,
    image_ref TEXT NOT NULL,
    pulled_at INTEGER NOT NULL DEFAULT (unixepoch()),
    PRIMARY KEY (origin, image_ref)
);

-- Indexes for common queries
CREATE INDEX idx_origins_status ON origins(status);
CREATE INDEX idx_origins_updated ON origins(updated_at);
CREATE INDEX idx_apps_project ON apps(project_id);
CREATE INDEX idx_image_cache_origin ON image_cache(origin);
```

### Cluster State Pusher

Each cluster runs a state pusher that reads from local Prometheus and pushes to Turso:

```go
type StatePusher struct {
    clusterName string
    prometheus  promapi.API
    turso       *sql.DB
    interval    time.Duration  // 10-30s
}

func (p *StatePusher) Run(ctx context.Context) {
    ticker := time.NewTicker(p.interval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            if err := p.pushState(ctx); err != nil {
                log.Error("failed to push state", "cluster", p.clusterName, "err", err)
            }
        }
    }
}

func (p *StatePusher) pushState(ctx context.Context) error {
    // 1. Query local Prometheus for all metrics
    state, err := p.collectState(ctx)
    if err != nil {
        return fmt.Errorf("collect state: %w", err)
    }

    // 2. Push to Turso (upsert)
    _, err = p.turso.ExecContext(ctx, `
        UPDATE origins SET
            available_gpus = ?,
            queue_depth = ?,
            pending_gpu_pods = ?,
            health_score = ?,
            status = ?,
            can_scale = ?,
            scale_confidence = ?,
            pending_node_claims = ?,
            recent_scale_failures = ?,
            scale_failure_rate = ?,
            updated_at = unixepoch()
        WHERE name = ?
    `,
        state.AvailableGPUs,
        state.QueueDepth,
        state.PendingGPUPods,
        state.HealthScore,
        state.Status,
        state.CanScale,
        state.ScaleConfidence,
        state.PendingNodeClaims,
        state.RecentScaleFailures,
        state.ScaleFailureRate,
        p.clusterName,
    )
    return err
}

func (p *StatePusher) collectState(ctx context.Context) (*OriginState, error) {
    // Query Prometheus for metrics (same queries as before)
    availableGPUs, _ := p.queryAvailableGPUs(ctx)
    queueDepth, _ := p.queryQueueDepth(ctx)
    pendingPods, _ := p.queryPendingGPUPods(ctx)
    scalability, _ := p.queryScalability(ctx)

    healthScore := computeHealthScore(availableGPUs, queueDepth, pendingPods, scalability)

    return &OriginState{
        AvailableGPUs:       availableGPUs,
        QueueDepth:          queueDepth,
        PendingGPUPods:      pendingPods,
        HealthScore:         healthScore,
        Status:              "healthy",
        CanScale:            scalability.CanScale,
        ScaleConfidence:     scalability.Confidence,
        PendingNodeClaims:   scalability.PendingNodeClaims,
        RecentScaleFailures: scalability.RecentFailures,
        ScaleFailureRate:    scalability.FailureRate,
    }, nil
}
```

### Router State Reader

The router reads from its local Turso embedded replica:

```go
type TursoStateStore struct {
    db *sql.DB  // Embedded replica, syncs automatically
}

func NewTursoStateStore(tursoURL, authToken string) (*TursoStateStore, error) {
    // Connect with embedded replica for local reads
    connector, err := libsql.NewEmbeddedReplicaConnector(
        "local.db",           // Local replica path
        tursoURL,             // Remote primary
        libsql.WithAuthToken(authToken),
        libsql.WithSyncInterval(time.Second * 5),  // Sync every 5s
    )
    if err != nil {
        return nil, err
    }

    db := sql.OpenDB(connector)
    return &TursoStateStore{db: db}, nil
}

func (s *TursoStateStore) GetOrigins() ([]Origin, error) {
    rows, err := s.db.Query(`
        SELECT name, region, domain, provider, cost_tier,
               gpu_types, total_gpus,
               available_gpus, queue_depth, pending_gpu_pods, health_score, status,
               can_scale, scale_confidence, pending_node_claims,
               recent_scale_failures, scale_failure_rate,
               updated_at
        FROM origins
        WHERE status != 'down'
    `)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var origins []Origin
    for rows.Next() {
        var o Origin
        var gpuTypesJSON string
        var updatedAt int64

        err := rows.Scan(
            &o.Name, &o.Region, &o.Domain, &o.Provider, &o.CostTier,
            &gpuTypesJSON, &o.Capabilities.TotalGPUs,
            &o.State.AvailableGPUs, &o.State.QueueDepth, &o.State.PendingGPUPods,
            &o.State.HealthScore, &o.State.Status,
            &o.State.Scalability.CanScale, &o.State.Scalability.ScaleConfidence,
            &o.State.Scalability.PendingNodeClaims,
            &o.State.Scalability.RecentFailures, &o.State.Scalability.FailureRate,
            &updatedAt,
        )
        if err != nil {
            return nil, err
        }

        json.Unmarshal([]byte(gpuTypesJSON), &o.Capabilities.GPUTypes)
        o.State.UpdatedAt = time.Unix(updatedAt, 0)
        origins = append(origins, o)
    }
    return origins, nil
}

func (s *TursoStateStore) GetApp(appID string) (*AppManifest, error) {
    var app AppManifest
    var gpuTypesJSON, regionsJSON, providersJSON string

    err := s.db.QueryRow(`
        SELECT app_id, project_id, revision,
               gpu_types, gpu_count, regions, providers,
               image_ref, primary_data_region, storage_provider
        FROM apps WHERE app_id = ?
    `, appID).Scan(
        &app.AppID, &app.ProjectID, &app.Revision,
        &gpuTypesJSON, &app.Requirements.GPUCount, &regionsJSON, &providersJSON,
        &app.ImageRef, &app.PrimaryDataRegion, &app.StorageProvider,
    )
    if err != nil {
        return nil, err
    }

    json.Unmarshal([]byte(gpuTypesJSON), &app.Requirements.GPU)
    json.Unmarshal([]byte(regionsJSON), &app.Requirements.Regions)
    json.Unmarshal([]byte(providersJSON), &app.Requirements.Providers)

    return &app, nil
}

func (s *TursoStateStore) HasCachedImage(origin, imageRef string) bool {
    var count int
    s.db.QueryRow(`
        SELECT COUNT(*) FROM image_cache
        WHERE origin = ? AND image_ref = ?
    `, origin, imageRef).Scan(&count)
    return count > 0
}
```

### Staleness Detection

Even with push model, state can become stale if a cluster stops pushing:

```go
func (s *TursoStateStore) GetOriginsWithStaleness() ([]Origin, error) {
    origins, err := s.GetOrigins()
    if err != nil {
        return nil, err
    }

    now := time.Now()
    for i := range origins {
        staleness := now.Sub(origins[i].State.UpdatedAt)

        // Mark as degraded if no update in 60s
        if staleness > 60*time.Second {
            origins[i].State.Status = "degraded"
            origins[i].State.HealthScore *= 0.5  // Halve health score
        }

        // Mark as down if no update in 5 minutes
        if staleness > 5*time.Minute {
            origins[i].State.Status = "down"
            origins[i].State.HealthScore = 0
        }
    }

    return origins, nil
}
```

### Benefits Over Pull Model

| Aspect | Pull (Prometheus) | Push (Turso) |
|--------|-------------------|--------------|
| **Networking** | Router must reach every Prometheus | Clusters push outbound only |
| **Latency** | 50-200ms per cluster query | Sub-ms local read |
| **Freshness** | Fixed 30s intervals | Push on change possible |
| **Scaling** | O(clusters) queries per interval | O(1) local read |
| **Failure mode** | Router can't reach cluster = no data | Cluster can't push = stale data (detectable) |

---

## Router Implementation Options

The original Thalamus design proposed Cloudflare Workers (with TypeScript). We present this alongside a Go service option - both are viable.

### Option A: Cloudflare Workers (original proposal)

```
┌─────────────────────────────────────────────────────────────────┐
│  CLOUDFLARE                                                      │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Worker (per request)                                        │ │
│  │                                                              │ │
│  │  1. Query Turso (HTTP API or Hyperdrive)                     │ │
│  │  2. Run routing strategies                                   │ │
│  │  3. Proxy with X-Thalamus-Metadata                          │ │
│  │                                                              │ │
│  │  Note: Turso has native Cloudflare integration via          │ │
│  │        Hyperdrive for connection pooling                     │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

| Pros | Cons |
|------|------|
| Already using Cloudflare | 50ms CPU limit per request |
| Edge deployment globally | Debugging harder |
| No infrastructure to manage | Turso query adds ~5-10ms latency |
| Built-in DDoS/TLS | Vendor lock-in (Cloudflare) |
| WebSocket support | |
| Turso Hyperdrive integration | |

### Option B: Go Service (alternative)

```
┌─────────────────────────────────────────────────────────────────┐
│                        CLOUDFLARE                                │
│   DNS: api.hivemind.dev                                          │
│   TLS termination, DDoS protection                               │
│   Geo-routes to nearest router                                   │
└───────────────────────────────┬─────────────────────────────────┘
                                │
        ┌───────────────────────┼───────────────────────┐
        ▼                       ▼                       ▼
┌───────────────┐       ┌───────────────┐       ┌───────────────┐
│ Router (US)   │       │ Router (EU)   │       │ Router (APAC) │
│               │       │               │       │               │
│ - Turso embed │       │ - Turso embed │       │ - Turso embed │
│   replica     │       │   replica     │       │   replica     │
│ - Strategies  │       │ - Strategies  │       │ - Strategies  │
│ - Proxy       │       │ - Proxy       │       │ - Proxy       │
└───────────────┘       └───────────────┘       └───────────────┘

  Each router embeds a Turso replica that auto-syncs.
  State reads are sub-ms from local SQLite file.
```

| Pros | Cons |
|------|------|
| Full control | More infrastructure |
| Sub-ms state reads (embedded replica) | Need to manage replica sync |
| Standard debugging | Need TLS/DDoS separately |
| No CPU limits | Deployment complexity |
| Evolves to full Hivemind | |

### Go Deployment Options

| Model | Description | Pros | Cons |
|-------|-------------|------|------|
| **Fly.io** | Deploy to Fly.io Machines | Global (30+ regions), simple deploys, built-in anycast | Another vendor, egress costs |
| **Bunny.net Magic Containers** | Deploy to Bunny's edge container platform | 100+ PoPs, integrated with Bunny CDN, simple pricing | New platform (launched 2024), less mature |
| **In-cluster (K8s)** | Router Deployment in each existing cluster | Uses existing infra, no new vendors | Router health tied to cluster health, chicken-egg problem |
| **Dedicated VMs** | Standalone VMs (EC2, GCE, Hetzner) per region | Full isolation, predictable costs | More infra to manage, manual scaling |
| **Single region + CF** | Router in one region, Cloudflare geo-routes | Simplest, fewer moving parts | Single point of failure, added latency |

#### Option Details

**Fly.io** (Recommended for speed)
```
┌─────────────────────────────────────────────────────────────┐
│  Cloudflare (DNS + DDoS)                                     │
│       │                                                      │
│       ▼                                                      │
│  Fly.io Anycast (automatic geo-routing)                      │
│       │                                                      │
│  ┌────┴────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
│  │ iad     │  │ lhr     │  │ sin     │  │ + more  │        │
│  │ (US-E)  │  │ (EU)    │  │ (APAC)  │  │         │        │
│  └─────────┘  └─────────┘  └─────────┘  └─────────┘        │
└─────────────────────────────────────────────────────────────┘

fly launch --image hivemind/thalamus:latest
fly scale count 2 --region iad,lhr,sin
```
- Turso embedded replica works natively (both are Fly ecosystem)
- Auto-restart, health checks, rolling deploys built-in
- ~$5-10/month per region for small instances

**Bunny.net Magic Containers**
```
┌─────────────────────────────────────────────────────────────┐
│  Bunny CDN (100+ PoPs)                                       │
│       │                                                      │
│       ▼                                                      │
│  Magic Containers (edge compute)                             │
│       │                                                      │
│  Runs container at nearest PoP to user                       │
│  Auto-scales based on traffic                                │
└─────────────────────────────────────────────────────────────┘
```
- Integrated with Bunny CDN (potential future benefit)
- Pay-per-request pricing model
- Less mature than Fly.io but growing fast

**In-Cluster (K8s Deployment)**
```yaml
# Deploy router as Deployment in each cluster
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thalamus-router
  namespace: thalamus
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: router
        image: hivemind/thalamus:latest
        env:
        - name: TURSO_URL
          valueFrom:
            secretKeyRef:
              name: turso-credentials
              key: url
```
- **Chicken-egg problem**: If cluster is unhealthy, router in that cluster may also be unhealthy
- Mitigation: Deploy to subset of clusters, use Cloudflare failover between regions
- Benefit: No new vendors, uses existing K8s expertise

**Dedicated VMs**
```
┌─────────────────────────────────────────────────────────────┐
│  Cloudflare (DNS + geo-routing + DDoS)                       │
│       │                                                      │
│  ┌────┴────┐  ┌─────────┐  ┌─────────┐                      │
│  │ EC2     │  │ EC2     │  │ EC2     │                      │
│  │ us-east │  │ eu-west │  │ ap-se   │                      │
│  │ t3.small│  │ t3.small│  │ t3.small│                      │
│  └─────────┘  └─────────┘  └─────────┘                      │
└─────────────────────────────────────────────────────────────┘
```
- Full control, no platform constraints
- Use systemd + Docker for deployment
- Consider Hetzner for cost-effective EU presence

#### Deployment Recommendation

| Priority | Recommendation | Reason |
|----------|----------------|--------|
| **Speed** | Fly.io | Fastest to deploy, Turso integration native |
| **Cost** | In-cluster | No new vendors, uses existing infra |
| **Isolation** | Dedicated VMs | Router independent of cluster health |
| **Scale** | Bunny.net | 100+ PoPs if we need massive edge presence |

---

## Data Distribution (Extension)

The original Thalamus design focused on request routing but didn't address data locality. This is critical: routing is useless if the app can't access its data where it's routed.

### Current Problem

| Component | State | Issue |
|-----------|-------|-------|
| JuiceFS (us-east-1) | AWS S3 | Crusoe access cross-provider |
| JuiceFS (eu-west-2) | AWS S3 | Only serves EU |
| APAC | No local storage | Must pull from US/EU |

### Target: Tigris

```
┌─────────────────────────────────────────────────────────────────┐
│                           TIGRIS                                 │
│                    (Global Object Storage)                       │
│                                                                  │
│   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐        │
│   │ US Edge │   │ EU Edge │   │APAC Edge│   │ + more  │        │
│   └────┬────┘   └────┬────┘   └────┬────┘   └────┬────┘        │
│        └─────────────┴──────┬──────┴─────────────┘              │
│                             │                                    │
│                    ┌────────┴────────┐                          │
│                    │  JuiceFS Layer  │                          │
│                    └─────────────────┘                          │
└─────────────────────────────────────────────────────────────────┘
```

**Why Tigris over R2**:
- Full S3 API compatibility (R2 ListObjects breaks JuiceFS `gc`, `fsck`, `sync`)
- 3-30x faster reads globally (see benchmarks below)
- Zero egress

### Benchmark Data

JuiceFS backing store comparison across regions:

```
S3 + Redis (current)
┌────────────────┬─────────────────────────┬──────────────────┬────────────────────┬─────────────┐
│     Region     │ Small Write (200 files) │    Small Read    │ Large Write (10MB) │ Large Read  │
├────────────────┼─────────────────────────┼──────────────────┼────────────────────┼─────────────┤
│ us-east-1      │ 7.73s (26 IOPS)         │ 6.60s (30 IOPS)  │ 56.97 MB/s         │ 112.03 MB/s │
│ eu-west-2      │ 21.61s (9 IOPS)         │ 22.29s (9 IOPS)  │ 10.18 MB/s         │ 11.40 MB/s  │
│ ap-southeast-1 │ 50.70s (4 IOPS)         │ 51.13s (4 IOPS)  │ 3.62 MB/s          │ 3.81 MB/s   │
│ us-west-2      │ 17.88s (11 IOPS)        │ 18.33s (11 IOPS) │ 10.61 MB/s         │ 15.84 MB/s  │
└────────────────┴─────────────────────────┴──────────────────┴────────────────────┴─────────────┘

Tigris + Redis
┌────────────────┬─────────────────────────┬──────────────────┬────────────────────┬────────────┐
│     Region     │ Small Write (200 files) │    Small Read    │ Large Write (10MB) │ Large Read │
├────────────────┼─────────────────────────┼──────────────────┼────────────────────┼────────────┤
│ us-east-1      │ 88.81s (2 IOPS)         │ 2.33s (86 IOPS)  │ 7.09 MB/s          │ 50.70 MB/s │
│ eu-west-2      │ 13.17s (15 IOPS)        │ 4.67s (43 IOPS)  │ 21.92 MB/s         │ 55.93 MB/s │
│ ap-southeast-1 │ 94.96s (2 IOPS)         │ 1.69s (118 IOPS) │ 2.27 MB/s          │ 72.35 MB/s │
│ us-west-2      │ 13.61s (15 IOPS)        │ 6.13s (33 IOPS)  │ 22.77 MB/s         │ 30.61 MB/s │
└────────────────┴─────────────────────────┴──────────────────┴────────────────────┴────────────┘

Bunny + Redis
┌────────────────┬─────────────────────────┬─────────────────┬────────────────────┬────────────┐
│     Region     │ Small Write (200 files) │   Small Read    │ Large Write (10MB) │ Large Read │
├────────────────┼─────────────────────────┼─────────────────┼────────────────────┼────────────┤
│ us-east-1      │ 29.72s (7 IOPS)         │ 21.72s (9 IOPS) │ 9.88 MB/s          │ 7.21 MB/s  │
│ eu-west-2      │ 11.14s (18 IOPS)        │ 5.97s (34 IOPS) │ 48.70 MB/s         │ 36.92 MB/s │
│ ap-southeast-1 │ 39.40s (5 IOPS)         │ 36.95s (5 IOPS) │ 5.55 MB/s          │ 3.33 MB/s  │
│ us-west-2      │ 40.58s (5 IOPS)         │ 37.44s (5 IOPS) │ 5.59 MB/s          │ 2.92 MB/s  │
└────────────────┴─────────────────────────┴─────────────────┴────────────────────┴────────────┘
```

**Key Insight**: Read performance is what matters for cold starts. We write once, read many times.

| Region | S3 Small Read | Tigris Small Read | Improvement |
|--------|---------------|-------------------|-------------|
| us-east-1 | 30 IOPS | 86 IOPS | **2.9x faster** |
| eu-west-2 | 9 IOPS | 43 IOPS | **4.8x faster** |
| ap-southeast-1 | 4 IOPS | 118 IOPS | **29.5x faster** |
| us-west-2 | 11 IOPS | 33 IOPS | **3x faster** |

Tigris wins on reads globally because of edge replication. Writes are slower (replication cost), but that's acceptable for our write-once-read-many workload.

### Data Locality in Routing

```go
func (s DataLocalityStrategy) Evaluate(ctx RoutingContext) *RoutingDecision {
    for _, orig := range ctx.AllowedOrigins {
        score := 0.0

        if s.imageCache.HasImage(orig.Name, ctx.App.ImageRef) {
            score = 1.0  // Image cached = fast cold start
        } else if orig.Region == ctx.App.PrimaryDataRegion {
            score = 0.7  // Same region as storage
        } else if orig.Provider == ctx.App.StorageProvider {
            score = 0.4  // Same provider = better peering
        }

        if score > 0 {
            return &RoutingDecision{Origin: orig, Score: score, Reason: "data-locality"}
        }
    }
    return nil
}
```

---

## 10-Week Implementation Timeline

This timeline implements the Thalamus design with the extensions described above.

### Weeks 1-2: Foundation

- [ ] Set up project structure (Go or Workers)
- [ ] Set up Turso database with schema
- [ ] Implement basic HTTP proxy
- [ ] Implement WebSocket proxy
- [ ] Static origin config loading (seed Turso)
- [ ] Basic health check endpoint
- [ ] Deploy to one region, test proxying

**Exit criteria**: HTTP and WebSocket requests reach a single cluster.

### Weeks 3-4: State Push Infrastructure

- [ ] Build state pusher service (runs in each cluster)
- [ ] Query local Prometheus: GPU availability (DCGM)
- [ ] Query local Prometheus: queue depth (Kourier)
- [ ] Query local Prometheus: scalability (Karpenter, custom autoscaler)
- [ ] Push state to Turso every 10-30s
- [ ] Deploy state pusher to all 5 clusters
- [ ] Implement router state reader (Turso embedded replica or HTTP)
- [ ] Implement staleness detection

**Exit criteria**: All 5 clusters pushing state; router reads from Turso.

### Weeks 5-6: Routing Engine

- [ ] Implement strategy pattern
- [ ] Implement CapacityWeightedStrategy
- [ ] Implement CostOptimizedStrategy
- [ ] Implement DataLocalityStrategy
- [ ] Implement X-Thalamus-Metadata header
- [ ] Migrate app configs to Turso (or sync from DynamoDB)
- [ ] Implement router-level failover

**Exit criteria**: Requests route based on requirements + capacity + cost + locality.

### Weeks 7-8: Axon Integration + Hardening

- [ ] Implement Axon load shedding (read X-Thalamus-Metadata)
- [ ] Streaming response support (SSE)
- [ ] Connection pooling
- [ ] Circuit breaker for unhealthy origins
- [ ] Prometheus metrics for router
- [ ] Load testing

**Exit criteria**: End-to-end failover works (router → Axon → alternative).

### Weeks 9-10: Migration

- [ ] Deploy to all regions
- [ ] Shadow mode (duplicate traffic, compare)
- [ ] Canary: 1% → 10% → 50% → 100%
- [ ] Update DNS
- [ ] Runbooks and alerting
- [ ] Deprecate Cloudflare ratio splitting

**Exit criteria**: 100% traffic through Thalamus, stable 48 hours.

---

## Metrics & Observability

### Router Metrics

```prometheus
# Routing decisions
thalamus_routing_decisions_total{app_id, origin, strategy}
thalamus_request_duration_seconds{app_id, origin}
thalamus_failovers_total{app_id, from_origin, to_origin, level}  # level: router or axon

# Origin state
thalamus_origin_health_score{origin}
thalamus_origin_available_gpus{origin}
thalamus_origin_queue_depth{origin}
thalamus_origin_scalability_score{origin}

# Errors
thalamus_errors_total{type}  # no_capacity, all_origins_down, etc
```

### Alerts

```yaml
alerts:
  - name: ThalamusHighErrorRate
    expr: rate(thalamus_errors_total[5m]) > 0.01
    severity: critical

  - name: OriginCapacityLow
    expr: thalamus_origin_available_gpus < 4
    for: 5m
    severity: warning

  - name: AllOriginsUnhealthy
    expr: sum(thalamus_origin_health_score > 20) == 0
    severity: critical

  - name: HighAxonLoadShedding
    expr: rate(thalamus_failovers_total{level="axon"}[5m]) > 0.1
    severity: warning
```

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Added latency (P50) | < 10ms |
| Added latency (P99) | < 50ms |
| Availability | 99.9% |
| Failover time | < 2s |
| State staleness | < 60s |
| Routing accuracy | > 95% |

---

## Future Evolution

```
Week 10          →    Month 4           →    Month 6+
─────────────────────────────────────────────────────────
Thalamus Router       + Queue mgmt           Full Hivemind
(strategy routing)    (hold during cold)     (control plane)
+ Axon load shed      + Tigris migration     + Honeycomb
                                             + Beekeeper
                                             + Agent
```

---

## Open Questions

1. **Turso replication latency**: What's the actual sync latency between primary and edge replicas? Need to validate <5s in practice.
2. **DynamoDB → Turso migration**: Strategy for migrating app configs? Shadow writes during transition?
3. **Axon changes**: Scope of changes needed for X-Thalamus-Metadata handling?
4. **Turso pricing**: Validate cost at expected write volume (~5 clusters × 1 write/10s = 0.5 writes/sec).

## Action Items

1. Add metrics to Crusoe autoscaler (`hivemind_autoscaler_pending_requests`, `hivemind_autoscaler_failures_total`)
2. Set up Turso database and test replication latency
3. Build state pusher PoC for one cluster
4. Choose implementation: Workers vs Go
5. Scope Axon changes for load shedding
6. Plan DynamoDB → Turso app config migration

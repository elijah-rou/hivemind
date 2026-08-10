> **LEGACY**: This is a historical planning document from before the current `core/` implementation. For current state and roadmap, see [`docs/STATUS.md`](../STATUS.md) and [`docs/FINDINGS_AND_ISSUES.md`](../FINDINGS_AND_ISSUES.md).

# Accelerated Hivemind: 10-Week Plan

> **Context**: Timeline cut from 5 months to 10 weeks. This document defines a minimal viable architecture that solves the core routing problem.

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
4. Fail over when clusters are unhealthy
5. Cost-optimize by preferring cheaper providers when possible

**What We're NOT Doing** (in 10 weeks):
- Replacing Knative (keep it in each cluster)
- New container registry (keep existing)
- New build system (keep Depot)
- New control plane (just routing)
- New node agent (keep DaemonSets)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                                                                              │
│                          api.hivemind.dev                                    │
│                               │                                              │
│                               ▼                                              │
│   ┌───────────────────────────────────────────────────────────────────────┐  │
│   │                        SMART ROUTER                                    │  │
│   │                                                                        │  │
│   │   1. Extract app_id from request path                                  │  │
│   │   2. Lookup app config → get requirements (GPU type, region, etc.)     │  │
│   │   3. Get cluster capacities → filter to clusters that can serve        │  │
│   │   4. Score clusters → pick best (capacity + cost + latency)            │  │
│   │   5. Proxy request to cluster's Kourier                                │  │
│   │   6. On 503/timeout → failover to next best cluster                    │  │
│   │                                                                        │  │
│   └───────────────────────────────────────────────────────────────────────┘  │
│                               │                                              │
│       ┌───────────────────────┼───────────────────────┐                      │
│       │                       │                       │                      │
│       ▼                       ▼                       ▼                      │
│  ┌─────────────┐        ┌─────────────┐        ┌─────────────┐              │
│  │ AWS US-East │        │ AWS EU-West │        │ Crusoe US   │   + more     │
│  │             │        │             │        │             │              │
│  │  Kourier ◄──┼────────┼── Kourier ◄─┼────────┼── Kourier   │              │
│  │  Knative    │        │  Knative    │        │  Knative    │              │
│  │  DCGM ──────┼────┐   │  DCGM ──────┼────┐   │  DCGM ──────┼────┐         │
│  │  Prometheus │    │   │  Prometheus │    │   │  Prometheus │    │         │
│  └─────────────┘    │   └─────────────┘    │   └─────────────┘    │         │
│                     │                      │                      │         │
│                     └──────────────────────┴──────────────────────┘         │
│                                        │                                     │
│                                        ▼                                     │
│                     ┌─────────────────────────────────────┐                  │
│                     │         CAPACITY AGGREGATOR          │                  │
│                     │                                      │                  │
│                     │  Polls each cluster's Prometheus     │                  │
│                     │  Aggregates: GPU util, queue depth   │                  │
│                     │  Writes to shared store (30s cycle)  │                  │
│                     └─────────────────────────────────────┘                  │
│                                        │                                     │
│                                        ▼                                     │
│                     ┌─────────────────────────────────────┐                  │
│                     │           SHARED STATE               │                  │
│                     │                                      │                  │
│                     │  • Cluster capacities (from agg)     │                  │
│                     │  • App configs (from DynamoDB sync)  │                  │
│                     │  • Cluster registry (static config)  │                  │
│                     │                                      │                  │
│                     │  Options: Cloudflare KV, Redis,      │                  │
│                     │           DynamoDB, or in-memory     │                  │
│                     └─────────────────────────────────────┘                  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Capacity Signals

You have the full observability stack, so we can use multiple signals:

### Signal 1: GPU Allocation (from DCGM)

```promql
# Available GPUs = Total - Allocated
sum(DCGM_FI_DEV_COUNT) - sum(DCGM_FI_DEV_GPU_UTIL > 0)

# Or more accurately, from device plugin:
sum(kube_node_status_allocatable{resource="nvidia.com/gpu"})
  - sum(kube_pod_container_resource_requests{resource="nvidia.com/gpu"})
```

**Interpretation**:
- `available_gpus >= app.gpu_count` → cluster can potentially serve
- `available_gpus < app.gpu_count` → definitely can't serve this app

### Signal 2: Queue Depth (from Kourier)

```promql
# Queue depth per revision
activator_request_count{state="queued"}

# Or from Kourier directly
kourier_upstream_rq_pending
```

**Interpretation**:
- `queue_depth > 0` → cluster is under pressure
- `queue_depth > 10` → cluster is struggling, prefer others
- `queue_depth > 50` → cluster is saturated, avoid if possible

### Signal 3: Pending Pods (from kube-state-metrics)

```promql
# Pods waiting for GPU resources
sum(kube_pod_status_phase{phase="Pending"}
    * on(pod,namespace) kube_pod_container_resource_requests{resource="nvidia.com/gpu"})
```

**Interpretation**:
- `pending_gpu_pods > 0` → K8s scheduler can't place workloads
- This is a lagging indicator but important for detecting true exhaustion

### Signal 4: Scalability - Can We Get More Nodes?

Current capacity is not enough - we also need to know if a cluster **can scale up** when needed. This is critical because:
- AWS might be out of H100s in a region
- Crusoe might be sold out
- Karpenter/autoscaler might be failing to provision

#### EKS Clusters (Karpenter Metrics)

```promql
# Pending NodeClaims (Karpenter wants nodes but can't get them)
karpenter_nodeclaims_state{state="pending"}

# Nodes not ready (provisioning stuck)
karpenter_nodes_state{state="not_ready"}

# Disruption events (nodes being terminated)
increase(karpenter_disruption_actions_performed_total[10m])
```

#### Crusoe Clusters (Custom Autoscaler)

Since Crusoe uses a custom autoscaler (our code), it needs to expose metrics for the router to consume.

**Required metrics to add:**

```prometheus
# Pending node requests - nodes requested but not yet provisioned
hivemind_autoscaler_pending_requests{gpu_type="h100"} 3

# Provisioning failures - recent failures to provision nodes
hivemind_autoscaler_provisioning_failures_total
# Router uses: increase(hivemind_autoscaler_provisioning_failures_total[10m])

# Provisioning latency (optional but useful)
hivemind_autoscaler_provisioning_duration_seconds{quantile="0.9"} 120

# Provider capacity signal (if Crusoe communicates this)
hivemind_autoscaler_provider_status{gpu_type="h100"} 1  # 1=available, 0=unavailable
```

**Minimum viable (if tight on time):**

```prometheus
# Just these two are enough for routing decisions:
hivemind_autoscaler_pending_requests 5
hivemind_autoscaler_failures_total
```

The router uses these signals:
- `pending_requests > 0` for extended time → scaling is slow/stuck
- `increase(failures_total[10m]) > 0` → provider likely out of capacity

#### Provider Capacity APIs

| Provider | Capacity API | Status |
|----------|-------------|--------|
| AWS | No direct API; infer from Karpenter failures + Service Quotas | Available |
| Crusoe | No public API found | Need to confirm with Crusoe |
| Lambda Labs | Has capacity API | Available if we expand there |

Since Crusoe doesn't have a public capacity API, we must **track failures internally**.

#### Router-Level Failure Tracking

Track scale-up outcomes at the router:

```go
type ScaleHistory struct {
    ClusterID    string
    Window       time.Duration  // 10 minutes
    Attempts     []ScaleAttempt
    FailureRate  float64        // Computed: failures / total
}

type ScaleAttempt struct {
    Timestamp   time.Time
    Succeeded   bool
    FailReason  string  // "timeout", "503_after_cold_start", "provider_unavailable"
}

// Track when we route to a cluster and it fails with cold-start 503
func (r *Router) recordScaleAttempt(clusterID string, succeeded bool, reason string) {
    r.scaleHistory.Record(clusterID, ScaleAttempt{
        Timestamp:  time.Now(),
        Succeeded:  succeeded,
        FailReason: reason,
    })
}
```

**Logic**: If a cluster has >50% failure rate for cold starts in the last 10 minutes, it likely can't scale. Heavily penalize it.

### Scalability State Model

```go
type ScalabilityState struct {
    CanScale          bool      // Overall: can this cluster scale up?
    ScaleConfidence   float64   // 0.0 - 1.0

    // Per-provider signals
    PendingNodeClaims int       // Karpenter: nodes waiting to provision
    RecentFailures    int       // Scale failures in last 10 min
    FailureRate       float64   // Failures / attempts

    // Provider-level (if available)
    ProviderAvailable bool      // From provider API (if exists)

    Reason            string    // "karpenter_stuck", "high_failure_rate", "provider_sold_out"
}
```

### Composite Capacity Score (with Scalability)

```python
def compute_cluster_health(cluster_id: str) -> float:
    """
    Returns 0-100 score. Higher = more capacity available.
    """
    metrics = fetch_cluster_metrics(cluster_id)
    scalability = fetch_scalability_state(cluster_id)

    # === CURRENT CAPACITY (40 points) ===
    gpu_available_ratio = metrics.available_gpus / metrics.total_gpus
    score_current = gpu_available_ratio * 40

    # === QUEUE PRESSURE (20 points) ===
    queue_penalty = min(metrics.avg_queue_depth * 2, 20)
    score_queue = 20 - queue_penalty

    # === SCALABILITY (30 points) ===
    score_scale = compute_scalability_score(scalability)

    # === COST (10 points) ===
    score_cost = (4 - metrics.cost_tier) * 3.33

    return score_current + score_queue + score_scale + score_cost


def compute_scalability_score(s: ScalabilityState) -> float:
    """30 points max for scalability."""
    if not s.can_scale:
        return 0  # Cluster cannot scale - massive penalty

    score = 30.0

    # Pending node claims = trying to scale but slow/stuck
    if s.pending_node_claims > 0:
        score -= min(s.pending_node_claims * 5, 15)

    # Recent failures = actively having trouble
    if s.recent_failures > 0:
        score -= min(s.recent_failures * 10, 20)

    # High failure rate = unreliable scaling
    if s.failure_rate > 0.3:
        score -= 15
    elif s.failure_rate > 0.1:
        score -= 5

    return max(score, 0)
```

---

## Cluster Selection Algorithm

```python
def select_cluster(
    app: AppConfig,
    clusters: List[ClusterState],
    exclude: List[str] = []
) -> Optional[Cluster]:
    """
    Select best cluster for this app's requirements.
    Returns None if no cluster can serve.
    """

    # Step 1: Filter to clusters that match requirements
    candidates = []
    for cluster in clusters:
        if cluster.id in exclude:
            continue
        if cluster.status != "healthy":
            continue
        if not matches_requirements(cluster, app.requirements):
            continue
        if cluster.available_gpus < app.requirements.gpu_count:
            continue  # Can't fit this workload
        candidates.append(cluster)

    if not candidates:
        return None

    # Step 2: Score remaining candidates
    scored = []
    for cluster in candidates:
        score = compute_selection_score(cluster, app)
        scored.append((cluster, score))

    # Step 3: Return highest score
    scored.sort(key=lambda x: x[1], reverse=True)
    return scored[0][0]


def matches_requirements(cluster: Cluster, req: Requirements) -> bool:
    """Check if cluster can serve this app's requirements."""

    # GPU type must match
    if req.gpu_type not in cluster.gpu_types:
        return False

    # Region constraint (if specified)
    if req.regions and cluster.region not in req.regions:
        return False

    # Provider constraint (if specified)
    if req.providers and cluster.provider not in req.providers:
        return False

    return True


def compute_selection_score(cluster: Cluster, app: AppConfig) -> float:
    """
    Score a cluster for selection. Higher = better.

    Weights (tunable):
    - Capacity: 40% - prefer clusters with more headroom
    - Queue:    30% - prefer clusters with shorter queues
    - Cost:     20% - prefer cheaper providers
    - Latency:  10% - prefer clusters near user (if known)
    """
    score = 0.0

    # Capacity score (0-40)
    capacity_ratio = cluster.available_gpus / cluster.total_gpus
    score += capacity_ratio * 40

    # Queue score (0-30)
    # Lower queue = higher score
    queue_penalty = min(cluster.queue_depth * 1.5, 30)
    score += 30 - queue_penalty

    # Cost score (0-20)
    # cost_tier: 1=cheapest, 3=expensive
    cost_score = (4 - cluster.cost_tier) * 6.67  # tier 1 = 20, tier 3 = 6.67
    score += cost_score

    # Latency score (0-10) - optional, if we know user region
    # For now, skip or use static regional affinity
    score += 5  # neutral

    return score
```

---

## Router Implementation

Two viable options - choose based on team familiarity and constraints.

### Option A: Cloudflare Workers

```
┌─────────────────────────────────────────────────────────────┐
│  CLOUDFLARE                                                  │
│                                                              │
│  ┌─────────────────────┐    ┌─────────────────────────────┐ │
│  │  Cron Trigger        │───▶│  KV Store                   │ │
│  │  (every 30s)         │    │  - cluster capacities       │ │
│  │  Polls Prometheus    │    │  - app configs              │ │
│  └─────────────────────┘    └──────────────▲──────────────┘ │
│                                             │                │
│  ┌─────────────────────────────────────────┼──────────────┐ │
│  │  Worker (per request)                    │              │ │
│  │  1. Read capacity from KV ◄──────────────┘              │ │
│  │  2. Select cluster                                      │ │
│  │  3. Proxy to Kourier                                    │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

| Pros | Cons |
|------|------|
| Already using Cloudflare | 50ms CPU limit per request |
| Edge deployment globally | Debugging harder (Logpush, no traditional logs) |
| No infrastructure to manage | State limited to KV/D1/Durable Objects |
| Fast to deploy | Cron Trigger must reach Prometheus (networking) |
| Built-in DDoS/TLS | Vendor lock-in |
| WebSocket support via WebSocket API | Long-lived connection behavior at scale untested |

**Potential blockers to validate:**
- Can Cron Trigger reach Prometheus endpoints? (private networking)
- WebSocket proxy performance at scale
- Streaming (SSE) behavior

### Option B: Go Service

| Pros | Cons |
|------|------|
| Full control over implementation | More infrastructure to manage |
| Standard debugging/logging | Need to handle TLS, DDoS separately |
| No CPU/memory limits | Deployment complexity |
| Evolves naturally to full Hivemind | Slightly slower to initial deploy |
| WebSocket/streaming fully supported | |

**Deployment options for Go service:**

| Deployment Model | Description | Pros | Cons |
|-----------------|-------------|------|------|
| **Fly.io edge** | Deploy to Fly.io's edge network | Global distribution, simple deploys, built-in load balancing | Another vendor, egress costs |
| **Per-region in existing clusters** | Router pods in each EKS/Crusoe cluster | Uses existing infra, no new vendors | Router health tied to cluster health |
| **Dedicated regional VMs** | Standalone VMs (EC2, etc.) in each region | Full isolation, independent of clusters | More infra to manage |
| **Single region + Cloudflare** | Router in one region, Cloudflare for global distribution | Simplest, fewer moving parts | Single point of failure, added latency for distant regions |

**Recommended Go architecture (if chosen):**

```
┌─────────────────────────────────────────────────────────────┐
│                        CLOUDFLARE                            │
│   DNS: api.hivemind.dev                                      │
│   TLS termination, DDoS protection                           │
│   Routes to nearest regional router                          │
└─────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  Router (US)    │  │  Router (EU)    │  │  Router (APAC)  │
│  Fly.io / EKS   │  │  Fly.io / EKS   │  │  Fly.io / EKS   │
│                 │  │                 │  │                 │
│  - Aggregator   │  │  - Aggregator   │  │  - Aggregator   │
│  - Proxy        │  │  - Proxy        │  │  - Proxy        │
│  - Config sync  │  │  - Config sync  │  │  - Config sync  │
└─────────────────┘  └─────────────────┘  └─────────────────┘
```

### Comparison Summary

| Factor | Workers | Go Service |
|--------|---------|------------|
| Time to first deploy | ~1 week | ~2 weeks |
| WebSocket support | Yes (WebSocket API) | Yes (full control) |
| Streaming (SSE) | Yes | Yes |
| CPU limits | 50ms/request | None |
| Debugging | Logpush, Tail Workers | Standard logging |
| State | KV (updated by Cron) | In-memory + sync |
| Long-term evolution | May need rewrite | Evolves to Hivemind |
| Vendor dependency | Cloudflare | Choice of platform |

---

## Authentication

Two options for handling authentication at the router:

### Option A: Passthrough (Simpler)

Router forwards JWT as-is to clusters. Clusters validate.

```go
func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
    // Just forward all headers including Authorization
    cluster := r.selectCluster(appID)
    resp, err := r.proxy.Forward(req, cluster.Endpoint)
    // ...
}
```

**Pros**:
- Simplest implementation
- No key management at router
- Clusters already validate JWTs

**Cons**:
- Invalid requests still hit clusters (wasted resources)
- Latency: bad requests travel to cluster before rejection

### Option B: Validate at Router (Recommended)

Router validates JWT before routing. Rejects early.

```go
func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
    // 1. Validate JWT first
    token, err := r.auth.ValidateJWT(req.Header.Get("Authorization"))
    if err != nil {
        http.Error(w, "Unauthorized", 401)
        return
    }

    // 2. Check project matches app
    if token.ProjectID != app.ProjectID {
        http.Error(w, "Forbidden", 403)
        return
    }

    // 3. Route to cluster
    cluster := r.selectCluster(app)
    resp, err := r.proxy.Forward(req, cluster.Endpoint)
    // ...
}
```

**Pros**:
- Invalid requests rejected early (saves cluster resources)
- Can enforce project-level rate limits
- Consistent auth errors across all clusters

**Cons**:
- Need to sync JWT public keys to router
- Slightly more complex implementation

**Recommendation**: Start with **Option A** (passthrough) for weeks 1-6. Add router-level validation in weeks 7-8 as part of hardening.

---

## WebSocket Support

WebSocket support is required on day 1. The router must handle WebSocket upgrade requests.

### WebSocket Proxy Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    WEBSOCKET FLOW                                │
│                                                                 │
│   1. Client initiates WebSocket upgrade                         │
│      GET /v4/app-abc123/ws                                      │
│      Upgrade: websocket                                         │
│      Connection: Upgrade                                        │
│                                                                 │
│   2. Router detects upgrade request                             │
│      → Select cluster (same algorithm as HTTP)                  │
│      → Establish upstream WebSocket to cluster                  │
│                                                                 │
│   3. Bidirectional proxy                                        │
│      Client ◄──────► Router ◄──────► Cluster                   │
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

### Implementation

```go
import "github.com/gorilla/websocket"

var upgrader = websocket.Upgrader{
    CheckOrigin: func(r *http.Request) bool { return true },
}

func (r *Router) handleWebSocket(w http.ResponseWriter, req *http.Request) {
    // 1. Select cluster
    appID := extractAppID(req.URL.Path)
    app, _ := r.store.GetApp(appID)
    cluster := r.selector.Select(app, r.store.GetClusters(), nil)

    // 2. Connect to upstream
    upstreamURL := cluster.Endpoint + req.URL.Path
    upstreamConn, _, err := websocket.DefaultDialer.Dial(upstreamURL, nil)
    if err != nil {
        http.Error(w, "upstream connection failed", 502)
        return
    }
    defer upstreamConn.Close()

    // 3. Upgrade client connection
    clientConn, err := upgrader.Upgrade(w, req, nil)
    if err != nil {
        return
    }
    defer clientConn.Close()

    // 4. Bidirectional proxy
    errc := make(chan error, 2)
    go proxyWS(clientConn, upstreamConn, errc)  // client → upstream
    go proxyWS(upstreamConn, clientConn, errc)  // upstream → client

    <-errc  // Wait for either direction to close
}

func proxyWS(dst, src *websocket.Conn, errc chan error) {
    for {
        messageType, data, err := src.ReadMessage()
        if err != nil {
            errc <- err
            return
        }
        if err := dst.WriteMessage(messageType, data); err != nil {
            errc <- err
            return
        }
    }
}
```

### WebSocket Failover

WebSocket connections **cannot fail over mid-stream**. If the cluster goes down:
- Connection closes
- Client must reconnect
- New connection may hit different cluster

This is acceptable behavior for WebSocket.

---

### Router Structure

```
router/
├── cmd/
│   └── router/
│       └── main.go           # Entry point
├── internal/
│   ├── config/
│   │   └── config.go         # Load cluster registry, app configs
│   ├── routing/
│   │   ├── selector.go       # Cluster selection algorithm
│   │   ├── scorer.go         # Scoring functions
│   │   └── failover.go       # Failover logic
│   ├── capacity/
│   │   ├── aggregator.go     # Polls Prometheus, updates state
│   │   └── metrics.go        # Prometheus query helpers
│   ├── proxy/
│   │   └── proxy.go          # HTTP/WebSocket proxy to clusters
│   └── store/
│       └── store.go          # Shared state (in-memory + sync)
├── pkg/
│   └── types/
│       └── types.go          # Cluster, App, Requirements types
└── go.mod
```

### Request Flow

```go
func (r *Router) ServeHTTP(w http.ResponseWriter, req *http.Request) {
    // 1. Parse request
    appID, err := extractAppID(req.URL.Path)
    if err != nil {
        http.Error(w, "invalid path", 400)
        return
    }

    // 2. Get app config
    app, err := r.store.GetApp(appID)
    if err != nil {
        http.Error(w, "app not found", 404)
        return
    }

    // 3. Get cluster capacities
    clusters := r.store.GetClusters()

    // 4. Select best cluster
    cluster := r.selector.Select(app, clusters, nil)
    if cluster == nil {
        http.Error(w, "no capacity available", 503)
        return
    }

    // 5. Proxy request
    resp, err := r.proxy.Forward(req, cluster.Endpoint)
    if err != nil || resp.StatusCode == 503 {
        // 6. Failover
        fallback := r.selector.Select(app, clusters, []string{cluster.ID})
        if fallback != nil {
            resp, err = r.proxy.Forward(req, fallback.Endpoint)
        }
    }

    // 7. Return response
    copyResponse(w, resp)
}
```

---

## Capacity Aggregator

Runs as a goroutine inside the router (or separate service):

```go
type CapacityAggregator struct {
    clusters []ClusterConfig
    store    *Store
    interval time.Duration  // 30s
}

func (a *CapacityAggregator) Run(ctx context.Context) {
    ticker := time.NewTicker(a.interval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            a.updateAll()
        }
    }
}

func (a *CapacityAggregator) updateAll() {
    for _, cluster := range a.clusters {
        capacity, err := a.fetchCapacity(cluster)
        if err != nil {
            log.Error("failed to fetch capacity", "cluster", cluster.ID, "err", err)
            // Mark cluster as unknown/degraded
            a.store.SetClusterStatus(cluster.ID, "degraded")
            continue
        }
        a.store.UpdateCapacity(cluster.ID, capacity)
    }
}

func (a *CapacityAggregator) fetchCapacity(cluster ClusterConfig) (*Capacity, error) {
    // Query Prometheus
    client := promapi.NewClient(promapi.Config{Address: cluster.PrometheusURL})
    v1api := promv1.NewAPI(client)

    // Query 1: Available GPUs
    availableGPUs, err := a.queryAvailableGPUs(v1api)
    if err != nil {
        return nil, err
    }

    // Query 2: Queue depth
    queueDepth, err := a.queryQueueDepth(v1api)
    if err != nil {
        return nil, err
    }

    // Query 3: Pending pods
    pendingPods, err := a.queryPendingGPUPods(v1api)
    if err != nil {
        return nil, err
    }

    return &Capacity{
        TotalGPUs:      cluster.TotalGPUs,  // Static config
        AvailableGPUs:  availableGPUs,
        QueueDepth:     queueDepth,
        PendingGPUPods: pendingPods,
        LastUpdated:    time.Now(),
    }, nil
}
```

---

## Data Model

### Cluster Registry (Static Config)

```yaml
# clusters.yaml - deployed with router
clusters:
  - id: "aws-us-east-1"
    provider: aws
    region: us-east-1
    endpoint: "https://kourier.us-east-1.internal.hivemind.dev"
    prometheus_url: "http://prometheus.us-east-1.internal:9090"
    gpu_types: [a100, h100]
    total_gpus: 64
    cost_tier: 2  # 1=cheapest, 3=expensive

  - id: "aws-eu-west-2"
    provider: aws
    region: eu-west-2
    endpoint: "https://kourier.eu-west-2.internal.hivemind.dev"
    prometheus_url: "http://prometheus.eu-west-2.internal:9090"
    gpu_types: [a100]
    total_gpus: 32
    cost_tier: 2

  - id: "crusoe-us-east"
    provider: crusoe
    region: us-east
    endpoint: "https://kourier.crusoe-east.internal.hivemind.dev"
    prometheus_url: "http://prometheus.crusoe-east.internal:9090"
    gpu_types: [h100]
    total_gpus: 48
    cost_tier: 1  # Cheaper

  # ... more clusters
```

### App Config (from DynamoDB)

```go
type AppConfig struct {
    ID           string       `json:"id"`            // "app-abc123"
    ProjectID    string       `json:"project_id"`    // "proj-xyz"
    Requirements Requirements `json:"requirements"`
    Failover     string       `json:"failover"`      // "nearest_first", "cheapest_first", "reject"
}

type Requirements struct {
    GPUType   string   `json:"gpu_type"`    // "h100", "a100"
    GPUCount  int      `json:"gpu_count"`   // 1, 2, 4, 8
    Regions   []string `json:"regions"`     // [] = any
    Providers []string `json:"providers"`   // [] = any
}
```

### Runtime Capacity (Updated by Aggregator)

```go
type ClusterCapacity struct {
    ClusterID      string    `json:"cluster_id"`
    TotalGPUs      int       `json:"total_gpus"`
    AvailableGPUs  int       `json:"available_gpus"`
    QueueDepth     float64   `json:"queue_depth"`      // Avg across revisions
    PendingGPUPods int       `json:"pending_gpu_pods"`
    Status         string    `json:"status"`           // "healthy", "degraded", "down"
    HealthScore    float64   `json:"health_score"`     // 0-100
    LastUpdated    time.Time `json:"last_updated"`
}
```

---

## App Config Sync

Sync from DynamoDB to router's in-memory store:

```go
type AppConfigSyncer struct {
    dynamodb *dynamodb.Client
    table    string
    store    *Store
    interval time.Duration  // 60s
}

func (s *AppConfigSyncer) Run(ctx context.Context) {
    // Initial load
    s.syncAll()

    ticker := time.NewTicker(s.interval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            s.syncAll()
        }
    }
}

func (s *AppConfigSyncer) syncAll() {
    // Scan DynamoDB table for all apps
    // This assumes ~10k apps, scan is fine
    // For larger scale, use DynamoDB Streams

    paginator := dynamodb.NewScanPaginator(s.dynamodb, &dynamodb.ScanInput{
        TableName: aws.String(s.table),
    })

    apps := make(map[string]*AppConfig)
    for paginator.HasMorePages() {
        page, err := paginator.NextPage(ctx)
        if err != nil {
            log.Error("failed to scan apps", "err", err)
            return
        }
        for _, item := range page.Items {
            app := parseAppConfig(item)
            apps[app.ID] = app
        }
    }

    s.store.ReplaceApps(apps)
    log.Info("synced apps", "count", len(apps))
}
```

---

## 10-Week Timeline

### Weeks 1-2: Foundation

```
[ ] Set up Go project structure
[ ] Implement basic HTTP proxy (no routing logic)
[ ] Implement WebSocket proxy (required day 1)
[ ] Static cluster config loading
[ ] Deploy to one region, test proxying to one cluster
[ ] Basic health check endpoint
```

**Exit criteria**: HTTP and WebSocket requests to router reach a single cluster.

### Weeks 3-4: Capacity Aggregation

```
[ ] Implement Prometheus client for each cluster
[ ] Query GPU availability metrics (DCGM)
[ ] Query queue depth metrics (Kourier)
[ ] Query pending pod metrics (kube-state-metrics)
[ ] Query Karpenter metrics (EKS scalability)
[ ] Implement health score calculation
[ ] Implement scalability score (pending nodes, failure tracking)
[ ] Store capacity in memory, log updates
[ ] Test with real cluster metrics
```

**Exit criteria**: Router logs capacity + scalability for all 5 clusters every 30s.

### Weeks 5-6: Smart Routing

```
[ ] Implement requirements matching (GPU type, region, provider)
[ ] Implement cluster scoring algorithm (capacity + scalability + cost)
[ ] Implement cluster selection
[ ] Add app config sync from DynamoDB
[ ] Implement failover on 503/timeout
[ ] Implement router-level failure tracking (for scalability signal)
[ ] Add routing decision logging/metrics
```

**Exit criteria**: Requests route based on requirements + capacity + scalability.

### Weeks 7-8: Production Hardening

```
[ ] Streaming response support (SSE, chunked transfer)
[ ] Connection pooling to clusters
[ ] Circuit breaker for unhealthy clusters
[ ] Router-level JWT validation (optional, reduces cluster load)
[ ] Prometheus metrics for router itself
[ ] Structured logging with request tracing
[ ] Load testing (target: current RPS + 50%)
```

**Exit criteria**: Router handles production-like load.

### Weeks 9-10: Migration

```
[ ] Deploy to all regions
[ ] Shadow mode: duplicate traffic, compare responses
[ ] Canary: 1% → 10% → 25% → 50% → 100%
[ ] Update DNS to point to new router
[ ] Runbooks and alerting
[ ] Deprecate Cloudflare ratio-based splitting
```

**Exit criteria**: 100% traffic through router, stable 48 hours.

---

## Deployment Architecture

### Option A: Cloudflare Workers Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CLOUDFLARE EDGE                                    │
│                                                                              │
│   DNS: api.hivemind.dev                                                      │
│   TLS termination + DDoS protection (built-in)                               │
│                                                                              │
│   ┌───────────────────────────────────────────────────────────────────────┐ │
│   │                         CLOUDFLARE KV                                  │ │
│   │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐        │ │
│   │  │ Cluster         │  │ App Configs     │  │ Cached Images   │        │ │
│   │  │ Capacities      │  │ (from DynamoDB) │  │ (per cluster)   │        │ │
│   │  └────────▲────────┘  └────────▲────────┘  └────────▲────────┘        │ │
│   └───────────┼────────────────────┼────────────────────┼─────────────────┘ │
│               │                    │                    │                    │
│   ┌───────────┴────────────────────┴────────────────────┴─────────────────┐ │
│   │                      CRON TRIGGER (every 30s)                          │ │
│   │                                                                        │ │
│   │  • Polls Prometheus in each cluster                                    │ │
│   │  • Syncs app configs from DynamoDB                                     │ │
│   │  • Updates KV with fresh data                                          │ │
│   │  • Queries registry for cached images                                  │ │
│   │                                                                        │ │
│   │  ⚠️  Requires: Network path from Cloudflare to Prometheus              │ │
│   └────────────────────────────────────────────────────────────────────────┘ │
│                                                                              │
│   ┌────────────────────────────────────────────────────────────────────────┐ │
│   │                    WORKER (runs at edge, per request)                   │ │
│   │                                                                         │ │
│   │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐               │ │
│   │   │ US Edge     │    │ EU Edge     │    │ APAC Edge   │   + 200 more  │ │
│   │   │ Worker      │    │ Worker      │    │ Worker      │               │ │
│   │   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘               │ │
│   │          │                  │                  │                       │ │
│   │          │    1. Read capacity from KV         │                       │ │
│   │          │    2. Select best cluster           │                       │ │
│   │          │    3. Proxy HTTP/WebSocket          │                       │ │
│   │          │    4. Failover on 503               │                       │ │
│   │          │                  │                  │                       │ │
│   └──────────┴──────────────────┴──────────────────┴───────────────────────┘ │
│                                 │                                            │
└─────────────────────────────────┼────────────────────────────────────────────┘
                                  │
          ┌───────────────────────┼───────────────────────┐
          ▼                       ▼                       ▼
   ┌─────────────┐         ┌─────────────┐         ┌─────────────┐
   │ AWS US-East │         │ AWS EU-West │         │ Crusoe US   │
   │ Kourier     │         │ Kourier     │         │ Kourier     │
   └─────────────┘         └─────────────┘         └─────────────┘
```

### Option B: Go Service Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              CLOUDFLARE                                      │
│                                                                              │
│   DNS: api.hivemind.dev                                                      │
│   TLS termination + DDoS protection                                          │
│   Geo-routing to nearest router region                                       │
│                                                                              │
└──────────────────────────────────┬──────────────────────────────────────────┘
                                   │
           ┌───────────────────────┼───────────────────────┐
           ▼                       ▼                       ▼
┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐
│   ROUTER (US)       │  │   ROUTER (EU)       │  │   ROUTER (APAC)     │
│   Fly.io / EKS      │  │   Fly.io / EKS      │  │   Fly.io / EKS      │
│                     │  │                     │  │                     │
│ ┌─────────────────┐ │  │ ┌─────────────────┐ │  │ ┌─────────────────┐ │
│ │ Capacity        │ │  │ │ Capacity        │ │  │ │ Capacity        │ │
│ │ Aggregator      │ │  │ │ Aggregator      │ │  │ │ Aggregator      │ │
│ │ (polls all      │ │  │ │ (polls all      │ │  │ │ (polls all      │ │
│ │  Prometheus)    │ │  │ │  Prometheus)    │ │  │ │  Prometheus)    │ │
│ └─────────────────┘ │  │ └─────────────────┘ │  │ └─────────────────┘ │
│                     │  │                     │  │                     │
│ ┌─────────────────┐ │  │ ┌─────────────────┐ │  │ ┌─────────────────┐ │
│ │ Config Syncer   │ │  │ │ Config Syncer   │ │  │ │ Config Syncer   │ │
│ │ (DynamoDB)      │ │  │ │ (DynamoDB)      │ │  │ │ (DynamoDB)      │ │
│ └─────────────────┘ │  │ └─────────────────┘ │  │ └─────────────────┘ │
│                     │  │                     │  │                     │
│ ┌─────────────────┐ │  │ ┌─────────────────┐ │  │ ┌─────────────────┐ │
│ │ HTTP/WS Proxy   │ │  │ │ HTTP/WS Proxy   │ │  │ │ HTTP/WS Proxy   │ │
│ │ + Failover      │ │  │ │ + Failover      │ │  │ │ + Failover      │ │
│ └─────────────────┘ │  │ └─────────────────┘ │  │ └─────────────────┘ │
│                     │  │                     │  │                     │
│ ┌─────────────────┐ │  │ ┌─────────────────┐ │  │ ┌─────────────────┐ │
│ │ In-Memory State │ │  │ │ In-Memory State │ │  │ │ In-Memory State │ │
│ │ • Capacities    │ │  │ │ • Capacities    │ │  │ │ • Capacities    │ │
│ │ • App configs   │ │  │ │ • App configs   │ │  │ │ • App configs   │ │
│ │ • Scale history │ │  │ │ • Scale history │ │  │ │ • Scale history │ │
│ └─────────────────┘ │  │ └─────────────────┘ │  │ └─────────────────┘ │
└──────────┬──────────┘  └──────────┬──────────┘  └──────────┬──────────┘
           │                        │                        │
           │     Can route to ANY cluster (not just local)   │
           │                        │                        │
           └────────────────────────┼────────────────────────┘
                                    │
          ┌─────────────────────────┼─────────────────────────┐
          ▼                         ▼                         ▼
   ┌─────────────┐           ┌─────────────┐           ┌─────────────┐
   │ AWS US-East │           │ AWS EU-West │           │ Crusoe US   │
   │ Kourier     │           │ Kourier     │           │ Kourier     │
   │ Prometheus  │           │ Prometheus  │           │ Prometheus  │
   └─────────────┘           └─────────────┘           └─────────────┘
```

### Full System Architecture (with Data Distribution)

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                              COMPLETE SYSTEM ARCHITECTURE                             │
│                                                                                       │
│  ┌─────────────────────────────────────────────────────────────────────────────────┐ │
│  │                               ROUTING LAYER                                      │ │
│  │                      (Cloudflare Workers OR Go Services)                         │ │
│  │                                                                                  │ │
│  │   api.hivemind.dev ──► Route based on:                                          │ │
│  │                        • App requirements (GPU type, region)                     │ │
│  │                        • Cluster capacity + scalability                          │ │
│  │                        • Data locality (where is image cached?)                  │ │
│  │                        • Cost optimization                                       │ │
│  └────────────────────────────────────┬────────────────────────────────────────────┘ │
│                                       │                                              │
│          ┌────────────────────────────┼────────────────────────────┐                │
│          ▼                            ▼                            ▼                │
│  ┌───────────────┐            ┌───────────────┐            ┌───────────────┐        │
│  │  US CLUSTERS  │            │  EU CLUSTERS  │            │ APAC CLUSTERS │        │
│  │               │            │               │            │               │        │
│  │ ┌───────────┐ │            │ ┌───────────┐ │            │ ┌───────────┐ │        │
│  │ │AWS US-E   │ │            │ │AWS EU-W   │ │            │ │AWS APAC   │ │        │
│  │ │Crusoe US-E│ │            │ └───────────┘ │            │ └───────────┘ │        │
│  │ │Crusoe US-W│ │            │               │            │               │        │
│  │ └───────────┘ │            │               │            │               │        │
│  │               │            │               │            │               │        │
│  │  Knative      │            │  Knative      │            │  Knative      │        │
│  │  Kourier      │            │  Kourier      │            │  Kourier      │        │
│  │  DCGM         │            │  DCGM         │            │  DCGM         │        │
│  │  Prometheus   │            │  Prometheus   │            │  Prometheus   │        │
│  └───────┬───────┘            └───────┬───────┘            └───────┬───────┘        │
│          │                            │                            │                │
│          │         REGISTRY PULLS     │                            │                │
│          │                            │                            │                │
│          ▼                            ▼                            ▼                │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │                           DATA LAYER                                          │   │
│  │                                                                               │   │
│  │   CURRENT STATE:                          TARGET STATE:                       │   │
│  │   ┌────────────────────────┐              ┌────────────────────────┐         │   │
│  │   │  AWS S3 us-east-1      │              │  TIGRIS                │         │   │
│  │   │  AWS S3 eu-west-2      │      ──►     │  (Global Edge)         │         │   │
│  │   │  (JuiceFS backend)     │              │  (JuiceFS backend)     │         │   │
│  │   │                        │              │                        │         │   │
│  │   │  ⚠️ Cross-region       │              │  ✓ Edge-local access   │         │   │
│  │   │    latency for         │              │    from all clusters   │         │   │
│  │   │    Crusoe + APAC       │              │                        │         │   │
│  │   └────────────────────────┘              └────────────────────────┘         │   │
│  │                                                                               │   │
│  │   Per-cluster registries pull from backing store                              │   │
│  │   Locality scoring prefers clusters with cached images                        │   │
│  │                                                                               │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                       │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │                           CONFIG & STATE                                      │   │
│  │                                                                               │   │
│  │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                      │   │
│  │   │ DynamoDB    │    │ Prometheus  │    │ Karpenter/  │                      │   │
│  │   │ (App Config)│    │ (Metrics)   │    │ Autoscaler  │                      │   │
│  │   └─────────────┘    └─────────────┘    └─────────────┘                      │   │
│  │         │                   │                  │                              │   │
│  │         └───────────────────┴──────────────────┘                              │   │
│  │                             │                                                 │   │
│  │                             ▼                                                 │   │
│  │                    Router reads these to make                                 │   │
│  │                    informed routing decisions                                 │   │
│  │                                                                               │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                       │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Each regional router:
- Runs capacity aggregation (all routers poll all clusters - redundancy)
- Syncs app config from DynamoDB
- Can route to ANY cluster (not just local)
- Factors data locality into scoring

---

## Metrics & Observability

### Router Metrics

```
# Request routing
router_requests_total{app_id, target_cluster, status_code}
router_request_duration_seconds{app_id, target_cluster}
router_routing_decisions_total{app_id, target_cluster, reason}
router_failovers_total{app_id, from_cluster, to_cluster}

# Capacity
router_cluster_health_score{cluster_id}
router_cluster_available_gpus{cluster_id}
router_cluster_queue_depth{cluster_id}

# Errors
router_errors_total{type}  # "no_capacity", "all_clusters_down", "config_error"
```

### Alerting

```yaml
alerts:
  - name: RouterHighErrorRate
    expr: rate(router_errors_total[5m]) > 0.01
    for: 2m
    severity: critical

  - name: ClusterCapacityLow
    expr: router_cluster_available_gpus < 4
    for: 5m
    severity: warning

  - name: AllClustersUnhealthy
    expr: sum(router_cluster_health_score > 20) == 0
    for: 1m
    severity: critical
```

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Prometheus unreachable | Medium | Medium | Cache last known capacity, mark cluster "unknown" |
| DynamoDB sync fails | Low | Medium | Keep serving with stale config, alert |
| All clusters at capacity | Low | High | Return 503 with Retry-After, alert ops |
| Router itself overloaded | Low | High | Horizontal scaling, connection limits |
| Metrics lag causes bad routing | Medium | Low | 30s lag is acceptable, queue depth is real-time signal |

---

## Future Evolution

This router is the foundation for full Hivemind:

```
Week 10          →    Month 4           →    Month 6+
─────────────────────────────────────────────────────────
Smart Router          + Queue mgmt           Full Hivemind
(capacity routing)    (in-router queuing)    (control plane)
                      + Autoscaler signals   + Honeycomb
                                             + Beekeeper
                                             + Agent
```

The router evolves by adding:
1. **Queue management**: Hold requests during cold starts instead of 503
2. **Autoscaler integration**: Signal demand to Knative
3. **Control plane**: Becomes the Hivemind control plane
4. **Direct pod management**: Eventually bypass Knative

---

## Data Distribution (Registry + Storage)

> **Critical dependency**: Routing is useless if the app can't access its data where it's routed. Data distribution is IN SCOPE for the 10-week plan.

### Current Problem

| Component | Current State | Issue |
|-----------|--------------|-------|
| **JuiceFS (us-east-1)** | AWS S3 backend | Crusoe clusters access cross-provider (latency) |
| **JuiceFS (eu-west-2)** | AWS S3 backend | Only serves EU |
| **Registry** | Per-cluster, backed by JuiceFS | Single-region S3 dependency |
| **APAC** | No local storage | Must pull from US/EU |

**The problem**: If we route a request to Crusoe US-Southwest but the container image is in AWS us-east-1, cold starts will be slow. If persistent storage is in eu-west-2 but workload runs in APAC, latency is unacceptable.

### Architecture: Current State

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CURRENT DATA DISTRIBUTION                             │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         AWS S3 us-east-1                             │   │
│   │                         (JuiceFS backend)                            │   │
│   │                              │                                       │   │
│   │              ┌───────────────┼───────────────┐                       │   │
│   │              │               │               │                       │   │
│   │              ▼               ▼               ▼                       │   │
│   │     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐              │   │
│   │     │ AWS US-East  │ │ Crusoe US-E  │ │ Crusoe US-SW │              │   │
│   │     │ Registry     │ │ Registry     │ │ Registry     │              │   │
│   │     │ (local)      │ │ (cross-prov) │ │ (cross-prov) │              │   │
│   │     └──────────────┘ └──────────────┘ └──────────────┘              │   │
│   │            ▲                 ▲                 ▲                     │   │
│   │            │                 │                 │                     │   │
│   │         ~5ms             ~20-50ms          ~30-60ms                  │   │
│   │        latency            latency           latency                  │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                         AWS S3 eu-west-2                             │   │
│   │                         (JuiceFS backend)                            │   │
│   │                              │                                       │   │
│   │                              ▼                                       │   │
│   │                     ┌──────────────┐                                 │   │
│   │                     │ AWS EU-West  │                                 │   │
│   │                     │ Registry     │                                 │   │
│   │                     │ (local)      │                                 │   │
│   │                     └──────────────┘                                 │   │
│   └─────────────────────────────────────────────────────────────────────┘   │
│                                                                              │
│   AWS APAC: No local storage - pulls from US                                 │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Options for Global Object Storage

| Option | JuiceFS Compatible | Global Distribution | Egress Cost | Notes |
|--------|-------------------|---------------------|-------------|-------|
| **AWS S3** (current) | Yes | No (single region) | High | What you have now |
| **Cloudflare R2** | Partial | Via Cloudflare edge | Zero | ListObjects API incompatible (breaks `gc`, `fsck`, `sync`) |
| **Tigris** | Yes | Fly.io edge network | Zero | Full S3 API, better small object performance |
| **S3 Cross-Region Replication** | Yes | Multi-region but not edge | High | AWS-only, complex setup |

### Research Findings

#### Cloudflare R2 Limitations

From [JuiceFS docs](https://juicefs.com/docs/community/reference/how_to_set_up_object_storage/):
> Cloudflare R2 ListObjects API is not fully S3 compatible (result list is not sorted), so some features of JuiceFS do not work. For example, `juicefs gc`, `juicefs fsck`, `juicefs sync`, `juicefs destroy`.

This means:
- Cannot garbage collect orphaned objects
- Cannot verify filesystem integrity
- Cannot sync between JuiceFS instances
- **Not recommended for production JuiceFS**

#### Tigris Advantages

From [Tigris benchmarks](https://www.tigrisdata.com/blog/benchmark-small-objects/):
- 5-86x faster than R2 for small objects
- Full S3 API compatibility
- Global distribution via Fly.io edge
- Zero egress fees

[JuiceFS + Tigris example](https://dev.to/tigrisdata/sharing-your-ollama-models-between-fly-machines-using-juicefs-and-tigris-171p) shows production usage.

### Architecture: Target State (with Tigris)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TARGET DATA DISTRIBUTION                              │
│                                                                              │
│   ┌─────────────────────────────────────────────────────────────────────┐   │
│   │                           TIGRIS                                     │   │
│   │                    (Global Object Storage)                           │   │
│   │                                                                      │   │
│   │   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐            │   │
│   │   │ US Edge │   │ EU Edge │   │APAC Edge│   │ + more  │            │   │
│   │   └────┬────┘   └────┬────┘   └────┬────┘   └────┬────┘            │   │
│   │        │             │             │             │                  │   │
│   │        └─────────────┴──────┬──────┴─────────────┘                  │   │
│   │                             │                                       │   │
│   │                    ┌────────┴────────┐                              │   │
│   │                    │  JuiceFS Layer  │                              │   │
│   │                    │  (metadata DB)  │                              │   │
│   │                    └────────┬────────┘                              │   │
│   │                             │                                       │   │
│   └─────────────────────────────┼───────────────────────────────────────┘   │
│                                 │                                            │
│       ┌─────────────────────────┼─────────────────────────┐                 │
│       │                         │                         │                 │
│       ▼                         ▼                         ▼                 │
│  ┌──────────┐             ┌──────────┐             ┌──────────┐            │
│  │ US Clusters            │ EU Clusters            │APAC Clusters           │
│  │ AWS + Crusoe │         │ AWS       │            │ AWS       │            │
│  │              │         │           │            │           │            │
│  │ Registry ◄───┼─────────┼─ Registry ◄────────────┼─ Registry │            │
│  │ (edge-local) │         │(edge-local)│           │(edge-local)│           │
│  └──────────────┘         └───────────┘            └───────────┘            │
│                                                                              │
│   All clusters get ~same latency to storage (edge-local)                     │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Approach Options

| Approach | Complexity | Timeline | Outcome |
|----------|------------|----------|---------|
| **A: Data locality in routing** | Low | Week 5-6 | Route prefers clusters near existing data; doesn't fix the underlying issue |
| **B: Registry layer caching** | Medium | Week 3-6 | Cache popular layers at each cluster; reduces but doesn't eliminate cross-region pulls |
| **C: Migrate to Tigris** | High | Week 3-8 | Global storage; fixes the problem properly |
| **D: Hybrid** | Medium | Throughout | Start with A, add B, evaluate C |

### Recommended Approach: Hybrid (D)

**Weeks 1-4**: Factor data locality into routing
- Add `data_locality_score` to cluster selection
- Prefer clusters where app's container is already cached
- Track which clusters have pulled which images (via registry metrics)

**Weeks 5-6**: Registry layer caching
- Evaluate adding a caching layer (e.g., pull-through cache) per region
- Or: pre-warm registries with popular images

**Weeks 7-8**: Tigris evaluation
- Set up Tigris in staging
- Test JuiceFS with Tigris backend
- Benchmark cold-start times vs current

**Week 9-10**: Migration decision
- If Tigris works: plan migration for Month 4
- If not: continue with caching approach

### JuiceFS with Tigris Configuration

```bash
# Format JuiceFS with Tigris backend
juicefs format \
  --storage s3 \
  --bucket https://fly.storage.tigris.dev/hivemind-registry \
  --access-key $AWS_ACCESS_KEY_ID \
  --secret-key $AWS_SECRET_ACCESS_KEY \
  $METADATA_DB_URL \
  hivemind-fs
```

### Impact on Routing

Data locality becomes a scoring factor:

```python
def compute_selection_score(cluster: Cluster, app: AppConfig) -> float:
    score = 0.0

    # ... existing scoring (capacity, queue, cost) ...

    # DATA LOCALITY (0-15 points)
    if cluster.has_cached_image(app.image_ref):
        score += 15  # Image already pulled - fast cold start
    elif cluster.region == app.primary_data_region:
        score += 10  # Same region as primary storage
    elif cluster.provider == "aws" and app.storage_backend == "aws_s3":
        score += 5   # Same provider - better peering
    # else: 0 points - cross-provider/cross-region pull

    return score
```

### Data Needed for Locality Scoring

```go
type ClusterDataState struct {
    ClusterID       string
    CachedImages    []string  // Image refs this cluster has pulled
    LastPullTime    map[string]time.Time
    StorageLatency  float64   // Measured latency to primary storage
}
```

This can be populated by:
1. Querying each cluster's registry for cached layers
2. Tracking routing decisions + cold start times
3. Periodic latency probes to storage backends

---

## Resolved Questions

| Question | Answer |
|----------|--------|
| Prometheus access | TBD - need to verify networking |
| DynamoDB schema | Not blocking - will map as needed |
| Auth handling | Start passthrough, add validation in hardening phase |
| WebSocket support | Required day 1 - included in plan |
| Kourier endpoints | Directly reachable |
| Crusoe capacity API | No public API - track failures internally |
| Autoscaler type | Karpenter (EKS), custom (Crusoe) |
| Staleness tolerance | ~30s acceptable, but track failures for faster signal |

---

## Open Questions (Remaining)

1. **Prometheus networking**: What's the path from router pods to each cluster's Prometheus? VPN, private link, or public with auth?

2. **DynamoDB app schema**: What fields exist? Need to map to router's `AppConfig` struct.

3. **JWT public keys**: Where are they stored? Need access for router-level auth validation (if we go that route).

## Action Items (Before Implementation)

1. **Add metrics to Crusoe autoscaler**: Implement `hivemind_autoscaler_pending_requests` and `hivemind_autoscaler_failures_total` (see Scalability Signals section).

2. **Validate Prometheus access**: Test connectivity from potential router locations to each cluster's Prometheus.

3. **Choose router implementation**: Workers vs Go - validate blockers for Workers (Prometheus access from Cron Trigger).

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Added latency (P50) | < 10ms |
| Added latency (P99) | < 50ms |
| Availability | 99.9% |
| Failover time | < 2s |
| Capacity staleness | < 60s |
| Routing accuracy | > 95% (requests go to cluster with capacity) |

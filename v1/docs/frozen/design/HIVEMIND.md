# Hivemind Control Plane Technical Design

**Phase 4 of Hivemind Migration**
**Status**: Draft
**Dependency**: Phases 1-3 (Router, Honeycomb, Beekeeper) stable

## Overview

The Hivemind Control Plane provides unified workload management across all Hivemind clusters. It replaces the current Lambda-based deployment pipeline and Knative autoscaling with a purpose-built control plane optimized for AI workloads.

### Workload Types

Hivemind supports three distinct workload types with different lifecycle behaviors:

| Type | Description | Lifecycle | Access Pattern |
|------|-------------|-----------|----------------|
| **Serverless** | Request/response inference | Scale 0→N based on demand | HTTP/gRPC via Router |
| **Job** | Run-to-completion tasks | Start → Run → Complete | API submission, async results |
| **Instance** | Persistent VM-like workloads | Always-on or timed lease | SSH shell, HTTP endpoints |

See [WORKLOAD_TYPES.md](WORKLOAD_TYPES.md) for detailed design of Jobs and Instances.

### Design Principles

1. **Unified API**: Single API for all operations, regardless of underlying infrastructure
2. **Cross-Cluster Aware**: Schedule workloads across multiple clusters globally
3. **Demand-Driven**: Router queue depth drives autoscaling, not just metrics
4. **Honeycomb-Aware**: Co-locate workloads with cached data
5. **Progressive Migration**: Support gradual transition from current architecture

## Architecture Evolution

```
Phase 4a:  CLI → Hivemind API → Lambda API → K8s/Knative
Phase 4b:  CLI → Hivemind API ────────────→ K8s/Knative
Phase 4c:  CLI → Hivemind API → Scheduler → K8s/Knative (multi-cluster)
Phase 4d:  CLI → Hivemind API → Scheduler → K8s (no Knative)
```

## Current State Analysis

### Lambda + Knative (Current)

From `dashboard-backend/go-build-service/src/libs/knative/knative.go`:

```go
// Current deployment flow:
// 1. Lambda receives deploy request
// 2. Creates/updates Knative Service with autoscaling annotations
// 3. Knative KPA handles scaling based on concurrency/CPU/memory
// 4. Knative activator handles cold starts

type ServiceConfig struct {
    AppId                 string
    ImageURL              string
    GPUCount              int
    CPU, MemoryGb         float64
    MaxScale, MinScale    int
    CooldownSeconds       int
    ScalingMetric         string    // "concurrency", "cpu", "memory", "rps"
    ScalingTarget         int
    ReplicaConcurrency    int
    // ... more config
}

// Autoscaling annotations control Knative KPA
annotations := map[string]string{
    "autoscaling.knative.dev/max-scale": "10",
    "autoscaling.knative.dev/min-scale": "0",
    "autoscaling.knative.dev/scale-down-delay": "60s",
    "autoscaling.knative.dev/metric": "concurrency",
    "autoscaling.knative.dev/target": "1",
}
```

**What Knative Provides:**
- Autoscaling based on metrics (concurrency, CPU, memory)
- Scale-to-zero capability
- Revision management for rollouts
- Request activation (cold start queueing)

**Limitations:**
- Single cluster scope (no cross-cluster scheduling)
- Reactive scaling (responds to metrics, not predictive)
- Limited control over scaling algorithms
- No direct integration with queue depth from router

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       HIVEMIND CONTROL PLANE                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                      HIVEMIND API                                │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │   Deploy     │  │   Invoke     │  │    Status/Metrics    │   │    │
│  │  │   Service    │  │   Service    │  │    Service           │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                           Workload Intent                                │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    WORKLOAD STATE MACHINE                        │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │   Pending    │─►│   Running    │─►│   Terminating        │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  │         ▼                  │                                     │    │
│  │  ┌──────────────┐          │         ┌──────────────────────┐   │    │
│  │  │   Scaled     │◄─────────┘         │   Failed             │   │    │
│  │  │   ToZero     │                    └──────────────────────┘   │    │
│  │  └──────────────┘                                                │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                    │                                     │
│                    ┌───────────────┴───────────────┐                    │
│                    ▼                               ▼                    │
│  ┌──────────────────────────┐    ┌──────────────────────────────┐      │
│  │      SCHEDULER           │    │      AUTOSCALER              │      │
│  │  ┌────────────────────┐  │    │  ┌────────────────────────┐  │      │
│  │  │ Cluster Selection  │  │    │  │ Demand-Driven Scaling  │  │      │
│  │  │ Node Scoring       │  │    │  │ Router Queue Depth     │  │      │
│  │  │ Data Locality      │  │    │  │ Predictive Scaling     │  │      │
│  │  │ GPU Bin Packing    │  │    │  │ Scale-to-Zero          │  │      │
│  │  └────────────────────┘  │    │  └────────────────────────┘  │      │
│  └──────────────────────────┘    └──────────────────────────────┘      │
│                    │                               │                    │
│                    └───────────────┬───────────────┘                    │
│                                    ▼                                     │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    CLUSTER ADAPTERS                              │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │    │
│  │  │  us-east-1   │  │  us-west-2   │  │    eu-west-1         │   │    │
│  │  │  (AWS EKS)   │  │  (AWS EKS)   │  │    (AWS EKS)         │   │    │
│  │  └──────────────┘  └──────────────┘  └──────────────────────┘   │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

## Component Details

### 1. Hivemind API

Unified API for all deployment and management operations.

```go
// Hivemind API service
type HivemindAPI struct {
    workloads  *WorkloadStore
    scheduler  *Scheduler
    autoscaler *Autoscaler           // Serverless scaling
    jobCtrl    *JobController        // Job/CronJob management
    instanceCtrl *InstanceController // Instance lifecycle
    clusters   map[string]*ClusterAdapter
    router     *RouterClient
    honeycomb  *HoneycombClient
    sshGateway *SSHGatewayClient
}

// Workload kinds
type WorkloadKind string

const (
    WorkloadKindServerless WorkloadKind = "serverless"  // Request/response, scale 0→N
    WorkloadKindJob        WorkloadKind = "job"         // Run-to-completion
    WorkloadKindCronJob    WorkloadKind = "cronjob"     // Scheduled recurring jobs
    WorkloadKindInstance   WorkloadKind = "instance"    // Persistent VM-like workloads
)

// Core API types
type Workload struct {
    ID          string            `json:"id"`
    ProjectID   string            `json:"project_id"`
    AppID       string            `json:"app_id"`
    Name        string            `json:"name"`
    Kind        WorkloadKind      `json:"kind"`           // serverless, job, cronjob, instance
    Spec        WorkloadSpec      `json:"spec"`
    Status      WorkloadStatus    `json:"status"`
    Placement   *PlacementDecision `json:"placement,omitempty"`
    CreatedAt   time.Time         `json:"created_at"`
    UpdatedAt   time.Time         `json:"updated_at"`
}

type WorkloadSpec struct {
    // Image from Honeycomb
    Image       string            `json:"image"`         // sha256:... or tag
    ImagePullPolicy string        `json:"image_pull_policy"`

    // Resources
    CPU         float64           `json:"cpu"`           // Cores
    Memory      int64             `json:"memory"`        // Bytes
    GPU         GPUSpec           `json:"gpu,omitempty"`

    // Scaling (serverless only - ignored for jobs/instances)
    Scaling     ScalingSpec       `json:"scaling,omitempty"`

    // Type-specific specs (see WORKLOAD_TYPES.md for full definitions)
    Job         *JobSpec          `json:"job,omitempty"`      // For kind=job/cronjob
    Instance    *InstanceSpec     `json:"instance,omitempty"` // For kind=instance

    // Runtime
    Port        int               `json:"port"`
    Env         map[string]string `json:"env,omitempty"`
    Secrets     []SecretRef       `json:"secrets,omitempty"`
    Volumes     []VolumeSpec      `json:"volumes,omitempty"`

    // Health
    LivenessProbe  *ProbeSpec     `json:"liveness_probe,omitempty"`
    ReadinessProbe *ProbeSpec     `json:"readiness_probe,omitempty"`

    // Deployment
    DeploymentTimeout int         `json:"deployment_timeout"`  // Seconds
    RolloutDuration   int         `json:"rollout_duration"`    // Seconds
}

// JobSpec defines job-specific configuration (see WORKLOAD_TYPES.md for full spec)
type JobSpec struct {
    Parallelism       int           `json:"parallelism"`        // Concurrent pods
    Completions       int           `json:"completions"`        // Total completions needed
    BackoffLimit      int           `json:"backoff_limit"`      // Retry attempts
    ActiveDeadline    int           `json:"active_deadline"`    // Max runtime in seconds
    Schedule          string        `json:"schedule,omitempty"` // Cron expression (cronjob only)
    ConcurrencyPolicy string        `json:"concurrency_policy,omitempty"` // allow/forbid/replace
}

// InstanceSpec defines instance-specific configuration (see WORKLOAD_TYPES.md for full spec)
type InstanceSpec struct {
    SSH           SSHSpec           `json:"ssh"`
    Workspace     WorkspaceSpec     `json:"workspace,omitempty"`
    Lifecycle     InstanceLifecycle `json:"lifecycle"`
    HTTPEndpoints []HTTPEndpoint    `json:"http_endpoints,omitempty"`
}

// InstanceLifecycle defines instance duration and termination behavior
type InstanceLifecycle struct {
    Mode              string `json:"mode"`                 // "persistent" or "timed"
    Duration          int    `json:"duration,omitempty"`   // Seconds (timed only)
    Extendable        bool   `json:"extendable,omitempty"`
    MaxDuration       int    `json:"max_duration,omitempty"`
    GracePeriod       int    `json:"grace_period"`         // Seconds before termination
    PreserveWorkspace bool   `json:"preserve_workspace"`
}

type GPUSpec struct {
    Type    string `json:"type"`     // "A100_40GB", "L40", "A10", etc.
    Count   int    `json:"count"`
    Memory  int64  `json:"memory"`   // Optional: specific GPU memory requirement
}

type ScalingSpec struct {
    MinReplicas     int           `json:"min_replicas"`
    MaxReplicas     int           `json:"max_replicas"`
    Concurrency     int           `json:"concurrency"`      // Requests per replica
    ScaleDownDelay  int           `json:"scale_down_delay"` // Seconds
    Metric          string        `json:"metric"`           // "concurrency", "queue_depth", "cpu"
    Target          int           `json:"target"`
    Buffer          int           `json:"buffer"`           // Extra replicas to maintain
}

type PlacementConstraints struct {
    Regions       []string          `json:"regions,omitempty"`       // Preferred regions
    ExcludeRegions []string         `json:"exclude_regions,omitempty"`
    NodeSelector  map[string]string `json:"node_selector,omitempty"`
    Affinity      *AffinitySpec     `json:"affinity,omitempty"`
}
```

#### API Endpoints

```go
// REST API endpoints
// POST /v1/workloads                       # Create/deploy workload
// GET  /v1/workloads/{id}                  # Get workload status
// PUT  /v1/workloads/{id}                  # Update workload
// DELETE /v1/workloads/{id}                # Delete workload
// POST /v1/workloads/{id}/scale            # Manual scale
// GET  /v1/workloads/{id}/replicas         # List replicas
// GET  /v1/workloads/{id}/logs             # Stream logs
// GET  /v1/workloads/{id}/metrics          # Get metrics

// Project-level endpoints
// GET  /v1/projects/{project_id}/workloads # List workloads in project
// GET  /v1/projects/{project_id}/usage     # Get project resource usage

// Cluster management
// GET  /v1/clusters                        # List clusters
// GET  /v1/clusters/{id}/capacity          # Get cluster capacity
// GET  /v1/clusters/{id}/health            # Get cluster health

func (api *HivemindAPI) CreateWorkload(ctx context.Context, req CreateWorkloadRequest) (*Workload, error) {
    // 1. Validate request
    if err := req.Validate(); err != nil {
        return nil, err
    }

    // 2. Create workload record
    workload := &Workload{
        ID:        generateWorkloadID(req.ProjectID, req.AppID),
        ProjectID: req.ProjectID,
        AppID:     req.AppID,
        Name:      req.Name,
        Spec:      req.Spec,
        Status: WorkloadStatus{
            Phase: WorkloadPhasePending,
        },
        CreatedAt: time.Now(),
    }

    // 3. Store workload
    if err := api.workloads.Create(ctx, workload); err != nil {
        return nil, err
    }

    // 4. Trigger scheduling
    go api.scheduleWorkload(ctx, workload)

    return workload, nil
}

func (api *HivemindAPI) scheduleWorkload(ctx context.Context, workload *Workload) {
    // 1. Ask scheduler for placement decision
    placement, err := api.scheduler.Schedule(ctx, workload)
    if err != nil {
        api.workloads.UpdateStatus(ctx, workload.ID, WorkloadStatus{
            Phase:   WorkloadPhaseFailed,
            Message: fmt.Sprintf("scheduling failed: %v", err),
        })
        return
    }

    // 2. Update workload with placement
    workload.Placement = placement
    api.workloads.Update(ctx, workload)

    // 3. Deploy to target cluster
    adapter := api.clusters[placement.ClusterID]
    if err := adapter.Deploy(ctx, workload); err != nil {
        api.workloads.UpdateStatus(ctx, workload.ID, WorkloadStatus{
            Phase:   WorkloadPhaseFailed,
            Message: fmt.Sprintf("deployment failed: %v", err),
        })
        return
    }

    // 4. Register with router
    if err := api.router.RegisterWorkload(ctx, workload); err != nil {
        log.Printf("Warning: failed to register workload with router: %v", err)
    }

    // 5. Update status
    api.workloads.UpdateStatus(ctx, workload.ID, WorkloadStatus{
        Phase: WorkloadPhaseRunning,
    })
}
```

### 2. Workload State Machine

Tracks workload lifecycle across all states.

```go
type WorkloadPhase string

const (
    WorkloadPhasePending      WorkloadPhase = "pending"       // Awaiting scheduling
    WorkloadPhaseScheduling   WorkloadPhase = "scheduling"    // Scheduler working
    WorkloadPhaseDeploying    WorkloadPhase = "deploying"     // Being deployed to cluster
    WorkloadPhaseRunning      WorkloadPhase = "running"       // At least one replica running
    WorkloadPhaseScaledToZero WorkloadPhase = "scaled_to_zero" // Healthy but no replicas
    WorkloadPhaseTerminating  WorkloadPhase = "terminating"   // Being deleted
    WorkloadPhaseFailed       WorkloadPhase = "failed"        // Failed to deploy/run
)

type WorkloadStatus struct {
    Phase           WorkloadPhase     `json:"phase"`
    Message         string            `json:"message,omitempty"`
    Replicas        ReplicaStatus     `json:"replicas"`
    Conditions      []Condition       `json:"conditions,omitempty"`
    LastScaleTime   *time.Time        `json:"last_scale_time,omitempty"`
}

type ReplicaStatus struct {
    Desired   int `json:"desired"`
    Ready     int `json:"ready"`
    Available int `json:"available"`
    Pending   int `json:"pending"`
}

type Condition struct {
    Type    string    `json:"type"`
    Status  string    `json:"status"`   // "True", "False", "Unknown"
    Reason  string    `json:"reason"`
    Message string    `json:"message"`
    LastTransition time.Time `json:"last_transition"`
}

// State machine transitions
type WorkloadStateMachine struct {
    workload  *Workload
    store     *WorkloadStore
    scheduler *Scheduler
    adapter   *ClusterAdapter
}

func (sm *WorkloadStateMachine) Transition(ctx context.Context, targetPhase WorkloadPhase) error {
    currentPhase := sm.workload.Status.Phase

    // Validate transition
    if !isValidTransition(currentPhase, targetPhase) {
        return fmt.Errorf("invalid transition from %s to %s", currentPhase, targetPhase)
    }

    // Execute transition
    switch targetPhase {
    case WorkloadPhaseRunning:
        return sm.transitionToRunning(ctx)
    case WorkloadPhaseScaledToZero:
        return sm.transitionToScaledToZero(ctx)
    case WorkloadPhaseTerminating:
        return sm.transitionToTerminating(ctx)
    default:
        return fmt.Errorf("unhandled target phase: %s", targetPhase)
    }
}

func isValidTransition(from, to WorkloadPhase) bool {
    validTransitions := map[WorkloadPhase][]WorkloadPhase{
        WorkloadPhasePending:      {WorkloadPhaseScheduling, WorkloadPhaseFailed},
        WorkloadPhaseScheduling:   {WorkloadPhaseDeploying, WorkloadPhaseFailed},
        WorkloadPhaseDeploying:    {WorkloadPhaseRunning, WorkloadPhaseFailed},
        WorkloadPhaseRunning:      {WorkloadPhaseScaledToZero, WorkloadPhaseTerminating, WorkloadPhaseFailed},
        WorkloadPhaseScaledToZero: {WorkloadPhaseRunning, WorkloadPhaseTerminating},
        WorkloadPhaseFailed:       {WorkloadPhasePending, WorkloadPhaseTerminating},
    }

    for _, valid := range validTransitions[from] {
        if valid == to {
            return true
        }
    }
    return false
}
```

### 3. Cross-Cluster Scheduler

Makes global placement decisions across all clusters.

```go
type Scheduler struct {
    clusters   map[string]*ClusterAdapter
    honeycomb  *HoneycombClient
    router     *RouterClient
    scorer     *NodeScorer
}

type PlacementDecision struct {
    ClusterID string            `json:"cluster_id"`
    Region    string            `json:"region"`
    NodePool  string            `json:"node_pool,omitempty"`
    Score     float64           `json:"score"`
    Reasons   []string          `json:"reasons"`
}

type SchedulingContext struct {
    Workload       *Workload
    Constraints    *PlacementConstraints
    CacheLocations []CacheLocation       // From Honeycomb
    QueueDepth     map[string]int        // Per-region queue depth from Router
    ClusterCapacity map[string]Capacity  // Available resources per cluster
}

func (s *Scheduler) Schedule(ctx context.Context, workload *Workload) (*PlacementDecision, error) {
    // 1. Build scheduling context
    schedCtx := &SchedulingContext{
        Workload: workload,
    }

    // Get cache locations from Honeycomb
    if locations, err := s.honeycomb.GetLocations(ctx, workload.Spec.Image); err == nil {
        schedCtx.CacheLocations = locations
    }

    // Get queue depth from Router
    if queueDepth, err := s.router.GetQueueDepth(ctx, workload.ID); err == nil {
        schedCtx.QueueDepth = queueDepth
    }

    // Get cluster capacity
    for id, cluster := range s.clusters {
        if capacity, err := cluster.GetCapacity(ctx); err == nil {
            schedCtx.ClusterCapacity[id] = capacity
        }
    }

    // 2. Filter clusters that can satisfy requirements
    feasibleClusters := s.filterClusters(schedCtx)
    if len(feasibleClusters) == 0 {
        return nil, fmt.Errorf("no cluster can satisfy workload requirements")
    }

    // 3. Score feasible clusters
    var best *PlacementDecision
    var bestScore float64

    for _, clusterID := range feasibleClusters {
        score, reasons := s.scoreCluster(schedCtx, clusterID)
        if best == nil || score > bestScore {
            best = &PlacementDecision{
                ClusterID: clusterID,
                Region:    s.clusters[clusterID].Region(),
                Score:     score,
                Reasons:   reasons,
            }
            bestScore = score
        }
    }

    return best, nil
}

func (s *Scheduler) filterClusters(ctx *SchedulingContext) []string {
    var feasible []string

    for clusterID, cluster := range s.clusters {
        // Check region constraints
        if len(ctx.Workload.Spec.Constraints.Regions) > 0 {
            if !contains(ctx.Workload.Spec.Constraints.Regions, cluster.Region()) {
                continue
            }
        }

        // Check excluded regions
        if contains(ctx.Workload.Spec.Constraints.ExcludeRegions, cluster.Region()) {
            continue
        }

        // Check GPU availability
        if ctx.Workload.Spec.GPU.Count > 0 {
            capacity := ctx.ClusterCapacity[clusterID]
            if !capacity.HasGPU(ctx.Workload.Spec.GPU.Type, ctx.Workload.Spec.GPU.Count) {
                continue
            }
        }

        // Check CPU/memory capacity
        capacity := ctx.ClusterCapacity[clusterID]
        if !capacity.HasResources(ctx.Workload.Spec.CPU, ctx.Workload.Spec.Memory) {
            continue
        }

        feasible = append(feasible, clusterID)
    }

    return feasible
}

func (s *Scheduler) scoreCluster(ctx *SchedulingContext, clusterID string) (float64, []string) {
    var score float64
    var reasons []string
    cluster := s.clusters[clusterID]

    // 1. Data locality score (0-40 points)
    // Prefer clusters where the image is already cached
    localityScore := s.scoreDataLocality(ctx, clusterID)
    score += localityScore * 40
    if localityScore > 0.5 {
        reasons = append(reasons, fmt.Sprintf("image cached in region (%.0f%%)", localityScore*100))
    }

    // 2. Queue depth score (0-25 points)
    // Prefer regions with higher queue depth (where demand is)
    queueScore := s.scoreQueueDepth(ctx, cluster.Region())
    score += queueScore * 25
    if queueScore > 0.5 {
        reasons = append(reasons, "high demand in region")
    }

    // 3. Capacity score (0-20 points)
    // Prefer clusters with more available resources
    capacityScore := s.scoreCapacity(ctx, clusterID)
    score += capacityScore * 20
    if capacityScore > 0.7 {
        reasons = append(reasons, "good capacity available")
    }

    // 4. Bin packing score (0-15 points)
    // Prefer clusters where we can pack efficiently
    packingScore := s.scoreBinPacking(ctx, clusterID)
    score += packingScore * 15

    return score, reasons
}

func (s *Scheduler) scoreDataLocality(ctx *SchedulingContext, clusterID string) float64 {
    if len(ctx.CacheLocations) == 0 {
        return 0
    }

    cluster := s.clusters[clusterID]
    region := cluster.Region()

    // Check if image is cached in this region
    for _, loc := range ctx.CacheLocations {
        if loc.Region == region {
            // Score based on cache tier
            switch loc.CacheType {
            case "local":
                return 1.0  // Best: cached on node
            case "regional":
                return 0.8  // Good: cached in region
            case "origin":
                return 0.3  // OK: at origin
            }
        }
    }

    return 0.1 // Will need to pull from another region
}

func (s *Scheduler) scoreQueueDepth(ctx *SchedulingContext, region string) float64 {
    if len(ctx.QueueDepth) == 0 {
        return 0.5 // No data, neutral score
    }

    totalDepth := 0
    regionDepth := ctx.QueueDepth[region]

    for _, depth := range ctx.QueueDepth {
        totalDepth += depth
    }

    if totalDepth == 0 {
        return 0.5
    }

    // Higher proportion of queue in this region = higher score
    return float64(regionDepth) / float64(totalDepth)
}
```

### 4. Autoscaler (Serverless Only)

Demand-driven autoscaling for serverless workloads using router queue depth and metrics. Jobs and instances use their own controllers (see sections 5 and 6).

```go
type Autoscaler struct {
    workloads *WorkloadStore
    router    *RouterClient
    clusters  map[string]*ClusterAdapter
    ticker    *time.Ticker
}

type ScalingDecision struct {
    WorkloadID    string
    CurrentScale  int
    DesiredScale  int
    Reason        string
    Confidence    float64
}

func (a *Autoscaler) Start(ctx context.Context) {
    a.ticker = time.NewTicker(5 * time.Second)

    for {
        select {
        case <-ctx.Done():
            return
        case <-a.ticker.C:
            a.evaluateAll(ctx)
        }
    }
}

func (a *Autoscaler) evaluateAll(ctx context.Context) {
    workloads, err := a.workloads.ListActive(ctx)
    if err != nil {
        log.Printf("Error listing workloads: %v", err)
        return
    }

    for _, workload := range workloads {
        decision := a.evaluate(ctx, workload)
        if decision.DesiredScale != decision.CurrentScale {
            a.applyScaling(ctx, workload, decision)
        }
    }
}

func (a *Autoscaler) evaluate(ctx context.Context, workload *Workload) ScalingDecision {
    decision := ScalingDecision{
        WorkloadID:   workload.ID,
        CurrentScale: workload.Status.Replicas.Ready,
    }

    spec := workload.Spec.Scaling

    // Get queue depth from router
    queueDepth, err := a.router.GetWorkloadQueueDepth(ctx, workload.ID)
    if err != nil {
        log.Printf("Warning: failed to get queue depth for %s: %v", workload.ID, err)
        queueDepth = 0
    }

    // Get current metrics
    metrics, err := a.getWorkloadMetrics(ctx, workload)
    if err != nil {
        log.Printf("Warning: failed to get metrics for %s: %v", workload.ID, err)
    }

    // Calculate desired replicas based on scaling metric
    var desiredReplicas int

    switch spec.Metric {
    case "queue_depth":
        // Primary: queue depth driven scaling
        desiredReplicas = a.calculateFromQueueDepth(queueDepth, spec)
        decision.Reason = fmt.Sprintf("queue_depth=%d", queueDepth)

    case "concurrency":
        // Fallback: concurrency based
        desiredReplicas = a.calculateFromConcurrency(metrics.Concurrency, spec)
        decision.Reason = fmt.Sprintf("concurrency=%.2f", metrics.Concurrency)

    case "cpu":
        desiredReplicas = a.calculateFromCPU(metrics.CPUUtilization, spec)
        decision.Reason = fmt.Sprintf("cpu=%.1f%%", metrics.CPUUtilization*100)

    default:
        // Default to queue depth
        desiredReplicas = a.calculateFromQueueDepth(queueDepth, spec)
    }

    // Apply buffer
    desiredReplicas += spec.Buffer

    // Clamp to min/max
    desiredReplicas = max(spec.MinReplicas, min(spec.MaxReplicas, desiredReplicas))

    // Scale-down delay
    if desiredReplicas < decision.CurrentScale {
        if !a.canScaleDown(workload) {
            desiredReplicas = decision.CurrentScale
            decision.Reason += " (scale-down delayed)"
        }
    }

    decision.DesiredScale = desiredReplicas
    return decision
}

func (a *Autoscaler) calculateFromQueueDepth(queueDepth int, spec ScalingSpec) int {
    if queueDepth == 0 {
        return spec.MinReplicas
    }

    // Each replica can handle `Concurrency` concurrent requests
    // Target utilization based on `Target` percentage
    targetConcurrency := float64(spec.Concurrency) * float64(spec.Target) / 100

    // Calculate replicas needed for queue
    replicasNeeded := int(math.Ceil(float64(queueDepth) / targetConcurrency))

    return replicasNeeded
}

func (a *Autoscaler) calculateFromConcurrency(concurrency float64, spec ScalingSpec) int {
    if concurrency == 0 {
        return spec.MinReplicas
    }

    targetConcurrency := float64(spec.Target)
    replicasNeeded := int(math.Ceil(concurrency / targetConcurrency))

    return replicasNeeded
}

func (a *Autoscaler) canScaleDown(workload *Workload) bool {
    if workload.Status.LastScaleTime == nil {
        return true
    }

    delay := time.Duration(workload.Spec.Scaling.ScaleDownDelay) * time.Second
    return time.Since(*workload.Status.LastScaleTime) > delay
}

func (a *Autoscaler) applyScaling(ctx context.Context, workload *Workload, decision ScalingDecision) {
    log.Printf("Scaling %s: %d → %d (%s)",
        workload.ID, decision.CurrentScale, decision.DesiredScale, decision.Reason)

    adapter := a.clusters[workload.Placement.ClusterID]

    if err := adapter.Scale(ctx, workload.ID, decision.DesiredScale); err != nil {
        log.Printf("Error scaling %s: %v", workload.ID, err)
        return
    }

    // Update workload status
    now := time.Now()
    a.workloads.UpdateStatus(ctx, workload.ID, WorkloadStatus{
        Phase:         workload.Status.Phase,
        LastScaleTime: &now,
        Replicas: ReplicaStatus{
            Desired: decision.DesiredScale,
        },
    })
}
```

### 5. Job Controller

Manages job and cronjob workloads. Unlike the Autoscaler (which handles serverless scaling), the Job Controller handles run-to-completion semantics.

```go
type JobController struct {
    workloads *WorkloadStore
    scheduler *Scheduler
    clusters  map[string]*ClusterAdapter
    cronParser *CronParser
    ticker    *time.Ticker
}

type JobStatus struct {
    Phase       JobPhase   `json:"phase"`
    StartTime   *time.Time `json:"start_time,omitempty"`
    CompletionTime *time.Time `json:"completion_time,omitempty"`
    Succeeded   int        `json:"succeeded"`
    Failed      int        `json:"failed"`
    Active      int        `json:"active"`
}

type JobPhase string

const (
    JobPhasePending   JobPhase = "pending"
    JobPhaseRunning   JobPhase = "running"
    JobPhaseSucceeded JobPhase = "succeeded"
    JobPhaseFailed    JobPhase = "failed"
)

func (c *JobController) Start(ctx context.Context) {
    c.ticker = time.NewTicker(10 * time.Second)

    for {
        select {
        case <-ctx.Done():
            return
        case <-c.ticker.C:
            c.evaluateCronJobs(ctx)
            c.reconcileJobs(ctx)
        }
    }
}

func (c *JobController) evaluateCronJobs(ctx context.Context) {
    cronjobs, _ := c.workloads.ListByKind(ctx, WorkloadKindCronJob)

    for _, cronjob := range cronjobs {
        if c.shouldTrigger(cronjob) {
            // Create job instance from cronjob template
            job := c.createJobFromCronJob(cronjob)
            c.submitJob(ctx, job)
        }
    }
}

func (c *JobController) submitJob(ctx context.Context, job *Workload) error {
    // 1. Schedule job to a cluster
    placement, err := c.scheduler.Schedule(ctx, job)
    if err != nil {
        return err
    }

    // 2. Create K8s Job resource
    adapter := c.clusters[placement.ClusterID]
    return adapter.CreateJob(ctx, job)
}

func (c *JobController) reconcileJobs(ctx context.Context) {
    jobs, _ := c.workloads.ListByKind(ctx, WorkloadKindJob)

    for _, job := range jobs {
        // Check job status from cluster
        status, _ := c.getJobStatus(ctx, job)

        // Update workload status
        c.workloads.UpdateJobStatus(ctx, job.ID, status)

        // Handle completion/failure
        if status.Phase == JobPhaseSucceeded || status.Phase == JobPhaseFailed {
            c.handleJobCompletion(ctx, job, status)
        }

        // Check active deadline
        if job.Spec.Job.ActiveDeadline > 0 && status.StartTime != nil {
            elapsed := time.Since(*status.StartTime)
            if elapsed > time.Duration(job.Spec.Job.ActiveDeadline)*time.Second {
                c.terminateJob(ctx, job, "active deadline exceeded")
            }
        }
    }
}
```

**Key differences from serverless Autoscaler:**
- No demand-based scaling (jobs run to completion)
- Tracks succeeded/failed pod counts toward completion goal
- Enforces active deadline timeouts
- Handles cron scheduling for recurring jobs
- Manages backoff/retry logic

### 6. Instance Controller

Manages persistent instance workloads with SSH access and workspace storage.

```go
type InstanceController struct {
    workloads  *WorkloadStore
    scheduler  *Scheduler
    clusters   map[string]*ClusterAdapter
    sshGateway *SSHGatewayClient
    ticker     *time.Ticker
}

type InstanceStatus struct {
    Phase        InstancePhase `json:"phase"`
    Address      string        `json:"address"`      // Internal pod IP
    SSHEndpoint  string        `json:"ssh_endpoint"` // SSH gateway endpoint
    StartTime    *time.Time    `json:"start_time,omitempty"`

    // Timed instance fields
    ExpiresAt    *time.Time    `json:"expires_at,omitempty"`
    GraceEndsAt  *time.Time    `json:"grace_ends_at,omitempty"`
    ExtendedCount int          `json:"extended_count,omitempty"`
}

type InstancePhase string

const (
    InstancePhasePending      InstancePhase = "pending"
    InstancePhaseProvisioning InstancePhase = "provisioning"  // Creating workspace storage
    InstancePhaseStarting     InstancePhase = "starting"
    InstancePhaseRunning      InstancePhase = "running"
    InstancePhaseExpiring     InstancePhase = "expiring"      // Timed: in grace period
    InstancePhaseStopped      InstancePhase = "stopped"
    InstancePhaseTerminating  InstancePhase = "terminating"
)

func (c *InstanceController) Start(ctx context.Context) {
    c.ticker = time.NewTicker(10 * time.Second)

    for {
        select {
        case <-ctx.Done():
            return
        case <-c.ticker.C:
            c.reconcileInstances(ctx)
            c.checkLeaseExpirations(ctx)
        }
    }
}

func (c *InstanceController) CreateInstance(ctx context.Context, workload *Workload) error {
    spec := workload.Spec.Instance

    // 1. Schedule to cluster
    placement, err := c.scheduler.Schedule(ctx, workload)
    if err != nil {
        return err
    }

    // 2. Provision workspace storage if requested
    if spec.Workspace.Size > 0 {
        if err := c.provisionWorkspace(ctx, workload, placement); err != nil {
            return err
        }
    }

    // 3. Create pod with SSH server
    adapter := c.clusters[placement.ClusterID]
    if err := adapter.CreateInstance(ctx, workload); err != nil {
        return err
    }

    // 4. Register with SSH gateway
    if spec.SSH.Enabled {
        if err := c.registerSSHEndpoint(ctx, workload); err != nil {
            log.Printf("Warning: SSH registration failed: %v", err)
        }
    }

    // 5. Set expiration for timed instances
    if spec.Lifecycle.Mode == "timed" && spec.Lifecycle.Duration > 0 {
        expiresAt := time.Now().Add(time.Duration(spec.Lifecycle.Duration) * time.Second)
        c.workloads.UpdateInstanceExpiration(ctx, workload.ID, expiresAt)
    }

    return nil
}

func (c *InstanceController) checkLeaseExpirations(ctx context.Context) {
    instances, _ := c.workloads.ListByKind(ctx, WorkloadKindInstance)

    for _, instance := range instances {
        status := instance.Status.Instance
        if status == nil || status.ExpiresAt == nil {
            continue // Not a timed instance or not expiring
        }

        now := time.Now()
        spec := instance.Spec.Instance

        // Already in grace period?
        if status.Phase == InstancePhaseExpiring {
            if status.GraceEndsAt != nil && now.After(*status.GraceEndsAt) {
                // Grace period over - terminate
                c.terminateInstance(ctx, instance, "lease expired")
            }
            continue
        }

        // Check if lease is expiring
        if now.After(*status.ExpiresAt) {
            // Enter grace period
            graceEnds := now.Add(time.Duration(spec.Lifecycle.GracePeriod) * time.Second)
            c.workloads.UpdateInstanceStatus(ctx, instance.ID, InstanceStatus{
                Phase:       InstancePhaseExpiring,
                GraceEndsAt: &graceEnds,
            })

            // Notify user
            c.notifyLeaseExpiring(ctx, instance, graceEnds)
        }
    }
}

func (c *InstanceController) ExtendLease(ctx context.Context, instanceID string, duration int) error {
    instance, err := c.workloads.Get(ctx, instanceID)
    if err != nil {
        return err
    }

    spec := instance.Spec.Instance
    status := instance.Status.Instance

    // Validate extension is allowed
    if !spec.Lifecycle.Extendable {
        return fmt.Errorf("instance does not allow lease extensions")
    }

    // Check max duration
    totalDuration := time.Since(*status.StartTime) + time.Duration(duration)*time.Second
    if spec.Lifecycle.MaxDuration > 0 && totalDuration > time.Duration(spec.Lifecycle.MaxDuration)*time.Second {
        return fmt.Errorf("extension would exceed maximum duration")
    }

    // Extend lease
    newExpiry := time.Now().Add(time.Duration(duration) * time.Second)
    return c.workloads.UpdateInstanceExpiration(ctx, instanceID, newExpiry)
}
```

**Key differences from serverless:**
- Single replica, always running (no scaling)
- Manages workspace block storage lifecycle
- SSH gateway registration for shell access
- Lease/expiration management for timed instances
- Idle timeout handling

### 7. Cluster Adapter

Abstraction for managing workloads on a Kubernetes cluster.

```go
type ClusterAdapter interface {
    ID() string
    Region() string
    GetCapacity(ctx context.Context) (Capacity, error)
    Deploy(ctx context.Context, workload *Workload) error
    Update(ctx context.Context, workload *Workload) error
    Delete(ctx context.Context, workloadID string) error
    Scale(ctx context.Context, workloadID string, replicas int) error
    GetReplicas(ctx context.Context, workloadID string) ([]Replica, error)
    GetMetrics(ctx context.Context, workloadID string) (*WorkloadMetrics, error)
}

// Phase 4b: Knative-based adapter
type KnativeClusterAdapter struct {
    id            string
    region        string
    kubeClient    *kubernetes.Clientset
    knativeClient *knativeversioned.Clientset
    namespace     string
}

func (a *KnativeClusterAdapter) Deploy(ctx context.Context, workload *Workload) error {
    // Convert Hivemind Workload to Knative Service
    service := a.toKnativeService(workload)

    // Apply to cluster
    _, err := a.knativeClient.ServingV1().Services(a.namespace).Create(
        ctx, service, metav1.CreateOptions{},
    )
    if k8serrors.IsAlreadyExists(err) {
        _, err = a.knativeClient.ServingV1().Services(a.namespace).Update(
            ctx, service, metav1.UpdateOptions{},
        )
    }

    return err
}

func (a *KnativeClusterAdapter) toKnativeService(workload *Workload) *servingv1.Service {
    // Convert Hivemind workload spec to Knative service
    // Similar to current CreateKnativeService but driven by Hivemind spec

    annotations := map[string]string{
        "autoscaling.knative.dev/max-scale":        strconv.Itoa(workload.Spec.Scaling.MaxReplicas),
        "autoscaling.knative.dev/min-scale":        strconv.Itoa(workload.Spec.Scaling.MinReplicas),
        "autoscaling.knative.dev/scale-down-delay": strconv.Itoa(workload.Spec.Scaling.ScaleDownDelay) + "s",
        "autoscaling.knative.dev/target":           strconv.Itoa(workload.Spec.Scaling.Concurrency),
    }

    return &servingv1.Service{
        ObjectMeta: metav1.ObjectMeta{
            Name:      workload.ID,
            Namespace: a.namespace,
            Labels: map[string]string{
                "hivemind.hivemind.dev/workload-id": workload.ID,
                "hivemind.hivemind.dev/project-id":  workload.ProjectID,
            },
        },
        Spec: servingv1.ServiceSpec{
            ConfigurationSpec: servingv1.ConfigurationSpec{
                Template: servingv1.RevisionTemplateSpec{
                    ObjectMeta: metav1.ObjectMeta{
                        Annotations: annotations,
                    },
                    Spec: servingv1.RevisionSpec{
                        ContainerConcurrency: ptr.Int64(int64(workload.Spec.Scaling.Concurrency)),
                        PodSpec: a.buildPodSpec(workload),
                    },
                },
            },
        },
    }
}

// Phase 4d: Direct pod management adapter (replaces Knative)
type DirectClusterAdapter struct {
    id          string
    region      string
    kubeClient  *kubernetes.Clientset
    namespace   string
}

func (a *DirectClusterAdapter) Deploy(ctx context.Context, workload *Workload) error {
    // Create Deployment directly (no Knative)
    deployment := a.toDeployment(workload)

    _, err := a.kubeClient.AppsV1().Deployments(a.namespace).Create(
        ctx, deployment, metav1.CreateOptions{},
    )
    if k8serrors.IsAlreadyExists(err) {
        _, err = a.kubeClient.AppsV1().Deployments(a.namespace).Update(
            ctx, deployment, metav1.UpdateOptions{},
        )
    }
    if err != nil {
        return err
    }

    // Create Service
    service := a.toService(workload)
    _, err = a.kubeClient.CoreV1().Services(a.namespace).Create(
        ctx, service, metav1.CreateOptions{},
    )
    if k8serrors.IsAlreadyExists(err) {
        _, err = a.kubeClient.CoreV1().Services(a.namespace).Update(
            ctx, service, metav1.UpdateOptions{},
        )
    }

    return err
}

func (a *DirectClusterAdapter) Scale(ctx context.Context, workloadID string, replicas int) error {
    // Scale deployment directly
    return retry.RetryOnConflict(retry.DefaultRetry, func() error {
        deployment, err := a.kubeClient.AppsV1().Deployments(a.namespace).Get(
            ctx, workloadID, metav1.GetOptions{},
        )
        if err != nil {
            return err
        }

        deployment.Spec.Replicas = ptr.Int32(int32(replicas))

        _, err = a.kubeClient.AppsV1().Deployments(a.namespace).Update(
            ctx, deployment, metav1.UpdateOptions{},
        )
        return err
    })
}

func (a *DirectClusterAdapter) toDeployment(workload *Workload) *appsv1.Deployment {
    return &appsv1.Deployment{
        ObjectMeta: metav1.ObjectMeta{
            Name:      workload.ID,
            Namespace: a.namespace,
            Labels: map[string]string{
                "hivemind.hivemind.dev/workload-id": workload.ID,
                "hivemind.hivemind.dev/project-id":  workload.ProjectID,
            },
        },
        Spec: appsv1.DeploymentSpec{
            Replicas: ptr.Int32(int32(workload.Spec.Scaling.MinReplicas)),
            Selector: &metav1.LabelSelector{
                MatchLabels: map[string]string{
                    "hivemind.hivemind.dev/workload-id": workload.ID,
                },
            },
            Template: corev1.PodTemplateSpec{
                ObjectMeta: metav1.ObjectMeta{
                    Labels: map[string]string{
                        "hivemind.hivemind.dev/workload-id": workload.ID,
                        "hivemind.hivemind.dev/project-id":  workload.ProjectID,
                    },
                },
                Spec: a.buildPodSpec(workload),
            },
        },
    }
}
```

## Router Integration

Bidirectional communication between Router and Control Plane.

```go
// Router → Control Plane (demand signals)
type DemandSignal struct {
    WorkloadID    string    `json:"workload_id"`
    Region        string    `json:"region"`
    QueueDepth    int       `json:"queue_depth"`
    AvgLatencyMs  int64     `json:"avg_latency_ms"`
    P99LatencyMs  int64     `json:"p99_latency_ms"`
    ColdStartWait int       `json:"cold_start_wait"`  // Requests waiting for cold start
    Timestamp     time.Time `json:"timestamp"`
}

// Control Plane → Router (instance updates)
type InstanceUpdate struct {
    Type       string    `json:"type"`      // "ready", "draining", "removed"
    WorkloadID string    `json:"workload_id"`
    InstanceID string    `json:"instance_id"`
    Address    string    `json:"address"`
    Region     string    `json:"region"`
    Timestamp  time.Time `json:"timestamp"`
}

// Callback handler for router signals
func (api *HivemindAPI) HandleDemandSignal(ctx context.Context, signal DemandSignal) {
    // Update metrics
    metrics.RecordQueueDepth(signal.WorkloadID, signal.Region, signal.QueueDepth)

    // Trigger immediate scale evaluation if queue is growing
    if signal.QueueDepth > 10 && signal.ColdStartWait > 0 {
        api.autoscaler.EvaluateNow(ctx, signal.WorkloadID)
    }
}

// Notify router when instances are ready
func (api *HivemindAPI) notifyRouterInstanceReady(ctx context.Context, workload *Workload, replica Replica) {
    update := InstanceUpdate{
        Type:       "ready",
        WorkloadID: workload.ID,
        InstanceID: replica.ID,
        Address:    replica.Address,
        Region:     workload.Placement.Region,
        Timestamp:  time.Now(),
    }

    if err := api.router.NotifyInstanceUpdate(ctx, update); err != nil {
        log.Printf("Warning: failed to notify router of instance ready: %v", err)
    }
}
```

## Observability

### Metrics

```go
var (
    workloadPhaseGauge = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "hivemind_workload_phase",
            Help: "Current phase of workloads",
        },
        []string{"workload_id", "phase"},
    )

    workloadReplicasGauge = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "hivemind_workload_replicas",
            Help: "Number of replicas",
        },
        []string{"workload_id", "type"}, // type: desired, ready, available
    )

    schedulingLatency = prometheus.NewHistogram(
        prometheus.HistogramOpts{
            Name:    "hivemind_scheduling_latency_seconds",
            Help:    "Time to make scheduling decision",
            Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1},
        },
    )

    scalingDecisions = prometheus.NewCounterVec(
        prometheus.CounterOpts{
            Name: "hivemind_scaling_decisions_total",
            Help: "Total scaling decisions",
        },
        []string{"workload_id", "direction"}, // direction: up, down, none
    )

    clusterCapacity = prometheus.NewGaugeVec(
        prometheus.GaugeOpts{
            Name: "hivemind_cluster_capacity",
            Help: "Cluster resource capacity",
        },
        []string{"cluster_id", "resource"}, // resource: cpu, memory, gpu
    )
)
```

## Migration Phases

### Phase 4a: API Wrapper (Week 1-3)

Hivemind API accepts requests and forwards to Lambda API.

```go
// Phase 4a: Pass-through to Lambda
type LambdaPassthroughAdapter struct {
    lambdaClient *lambda.Client
}

func (a *LambdaPassthroughAdapter) Deploy(ctx context.Context, workload *Workload) error {
    // Convert to Lambda API format
    payload := convertToLambdaPayload(workload)

    // Invoke Lambda
    _, err := a.lambdaClient.Invoke(ctx, &lambda.InvokeInput{
        FunctionName: aws.String("deploy-app-knative"),
        Payload:      payload,
    })

    return err
}
```

**CLI Update:**
```go
// CLI points to Hivemind API instead of Lambda
func (c *CLI) Deploy(ctx context.Context, config DeployConfig) error {
    // Before: Direct Lambda invocation
    // After: Hivemind API call

    return c.hivemindClient.CreateWorkload(ctx, CreateWorkloadRequest{
        ProjectID: config.ProjectID,
        AppID:     config.AppID,
        Spec:      convertToWorkloadSpec(config),
    })
}
```

### Phase 4b: Direct K8s Management (Week 4-7)

Hivemind directly creates Knative services, bypassing Lambda.

```go
// Phase 4b: Direct Knative management
func (api *HivemindAPI) CreateWorkload(ctx context.Context, req CreateWorkloadRequest) (*Workload, error) {
    // ... validation, workload creation ...

    // Use KnativeClusterAdapter instead of Lambda
    adapter := api.clusters[placement.ClusterID].(*KnativeClusterAdapter)
    if err := adapter.Deploy(ctx, workload); err != nil {
        return nil, err
    }

    return workload, nil
}
```

### Phase 4c: Cross-Cluster Scheduler (Week 8-12)

Scheduler makes global placement decisions.

```go
// Phase 4c: Full cross-cluster scheduling
func (api *HivemindAPI) CreateWorkload(ctx context.Context, req CreateWorkloadRequest) (*Workload, error) {
    // ... validation, workload creation ...

    // Scheduler picks best cluster
    placement, err := api.scheduler.Schedule(ctx, workload)
    if err != nil {
        return nil, err
    }

    workload.Placement = placement

    // Deploy to selected cluster
    adapter := api.clusters[placement.ClusterID]
    if err := adapter.Deploy(ctx, workload); err != nil {
        return nil, err
    }

    return workload, nil
}
```

### Phase 4d: Replace Knative (Week 13-16)

Direct pod lifecycle management without Knative.

```go
// Phase 4d: Switch from Knative to Direct adapter
func (api *HivemindAPI) initClusterAdapters() {
    for _, clusterConfig := range api.config.Clusters {
        // Before: KnativeClusterAdapter
        // After: DirectClusterAdapter

        adapter := NewDirectClusterAdapter(clusterConfig)
        api.clusters[clusterConfig.ID] = adapter
    }
}
```

---

## Technology Choice

### Language: Zig

**Decision**: Zig

The Hivemind Control Plane makes scheduling decisions that affect all workloads across all clusters. This is the most DST-critical component in the system, and likely requires VSR consensus for multi-cluster coordination.

#### Why Zig?

| Factor | Zig Advantage |
|--------|---------------|
| **Scheduling DST** | Must verify scheduling decisions are deterministic given identical cluster state |
| **VSR consensus** | Multi-cluster coordination likely needs consensus; TigerBeetle proves Zig works |
| **State machine testing** | Workload lifecycle (Pending→Scheduled→Running→...) needs exhaustive testing |
| **Autoscaler verification** | Queue-depth → scale decisions must be reproducible |
| **No GC** | Predictable latency for scheduling decisions (<100ms target) |

#### Why Not Go?

| Factor | Go Consideration |
|--------|------------------|
| **Team familiarity** | Team knows Go; Zig requires investment |
| **K8s client** | client-go is mature; would need to write Zig K8s client or use REST |
| **Faster prototyping** | Could prototype in Go first, then port critical paths to Zig |
| **Goroutines** | Easy concurrency model, though non-deterministic scheduling |

#### Why Not Rust?

| Factor | Rust Consideration |
|--------|-------------------|
| **K8s client** | kube-rs exists and is reasonably mature |
| **Safety** | Memory safety via borrow checker |
| **DST difficulty** | Tokio runtime non-determinism makes VSR implementation harder |
| **Complexity** | More cognitive load than Zig for the team to adopt |

#### Decision Rationale

The Control Plane is where scheduling bugs have the widest blast radius:

1. **Wrong scheduling decision** → Workloads on wrong nodes → Performance degradation
2. **Autoscaler bug** → Over/under scaling → Cost or availability issues
3. **State machine bug** → Stuck workloads → Customer impact
4. **Consensus bug** → Split-brain across clusters → Data inconsistency

These scenarios must be testable through deterministic simulation. The potential need for VSR consensus (multi-cluster coordination) strongly favors Zig, where TigerBeetle has already proven this approach works.

**Migration consideration**: Could start with Go for Phase 4a/4b (API wrapper, single-cluster), then implement scheduler/autoscaler core in Zig for Phase 4c/4d (cross-cluster). This reduces initial risk while building toward the right architecture.

### Key Libraries (Zig)

```
HTTP Server:     Custom (DST-compatible)
K8s Client:      REST API via std.http or thin wrapper
Database:        SQLite via C bindings or Turso REST
Metrics:         Custom prometheus exporter
Consensus:       VSR implementation (reference: TigerBeetle)
```

---

## Configuration

```yaml
# hivemind-config.yaml
api:
  address: ":8080"
  tls:
    enabled: true
    cert: /etc/hivemind/tls/cert.pem
    key: /etc/hivemind/tls/key.pem

clusters:
  - id: us-east-1
    region: us-east-1
    provider: aws
    kubeconfig: /etc/hivemind/kubeconfig/us-east-1
    namespace: hivemind-prod

  - id: us-west-2
    region: us-west-2
    provider: aws
    kubeconfig: /etc/hivemind/kubeconfig/us-west-2
    namespace: hivemind-prod

  - id: eu-west-1
    region: eu-west-1
    provider: aws
    kubeconfig: /etc/hivemind/kubeconfig/eu-west-1
    namespace: hivemind-prod

scheduler:
  data_locality_weight: 40
  queue_depth_weight: 25
  capacity_weight: 20
  bin_packing_weight: 15

autoscaler:
  evaluation_interval: 5s
  default_scale_down_delay: 60s
  default_buffer: 0

router:
  endpoint: https://router.hivemind.internal
  signal_interval: 5s

honeycomb:
  endpoint: https://registry.honeycomb.internal
  auth_token: ${HONEYCOMB_TOKEN}

database:
  type: turso
  url: ${TURSO_URL}
  token: ${TURSO_TOKEN}
```

## Testing Strategy

### Unit Tests

```go
func TestSchedulerDataLocality(t *testing.T) {
    scheduler := &Scheduler{
        clusters: map[string]*ClusterAdapter{
            "us-east-1": mockCluster("us-east-1"),
            "us-west-2": mockCluster("us-west-2"),
        },
    }

    ctx := &SchedulingContext{
        Workload: &Workload{
            Spec: WorkloadSpec{
                Image: "sha256:abc123",
            },
        },
        CacheLocations: []CacheLocation{
            {Region: "us-east-1", CacheType: "regional"},
        },
    }

    score := scheduler.scoreDataLocality(ctx, "us-east-1")
    assert.Equal(t, 0.8, score) // Regional cache = 0.8

    score = scheduler.scoreDataLocality(ctx, "us-west-2")
    assert.Equal(t, 0.1, score) // No cache
}
```

### Integration Tests

```go
func TestWorkloadLifecycle(t *testing.T) {
    api := setupTestAPI(t)

    // Create workload
    workload, err := api.CreateWorkload(context.Background(), CreateWorkloadRequest{
        ProjectID: "test-project",
        AppID:     "test-app",
        Spec: WorkloadSpec{
            Image: "sha256:test",
            CPU:   1,
            Memory: 1 << 30,
            Scaling: ScalingSpec{
                MinReplicas: 0,
                MaxReplicas: 10,
                Concurrency: 1,
            },
        },
    })
    require.NoError(t, err)

    // Wait for running
    assert.Eventually(t, func() bool {
        w, _ := api.GetWorkload(context.Background(), workload.ID)
        return w.Status.Phase == WorkloadPhaseRunning
    }, 30*time.Second, 1*time.Second)

    // Delete workload
    err = api.DeleteWorkload(context.Background(), workload.ID)
    require.NoError(t, err)
}
```

## Rollback Procedures

### Phase 4a/4b Rollback

```bash
# Revert CLI to use Lambda API directly
hivemind config set api.endpoint https://api.hivemind.dev

# No cluster changes needed - Lambda still functional
```

### Phase 4c/4d Rollback

```bash
# Per-cluster rollback
# 1. Disable Hivemind adapter for cluster
kubectl -n hivemind annotate cluster ${CLUSTER_ID} hivemind.hivemind.dev/enabled=false

# 2. Re-enable Knative autoscaler
kubectl -n knative-serving patch configmap config-autoscaler \
  --patch '{"data": {"enable-scale-to-zero": "true"}}'

# 3. Migrate workloads back to Knative management
hivemind admin migrate-to-knative --cluster ${CLUSTER_ID}
```

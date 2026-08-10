> **DESIGN STAGE**: Multi-cloud provider abstraction. Current implementation supports manual node provisioning only. Auto-provisioning is a future goal.

# Hivemind Provider Abstraction - Technical Design

## Overview

Hivemind must operate across multiple compute providers to achieve:

1. **Regional coverage** - Different providers have different geographic presence
2. **Scarce compute access** - H100, H200, B200 availability varies by provider
3. **Cost optimization** - Take advantage of pricing differences between providers
4. **Resilience** - No single provider dependency

This document defines the abstraction layer that allows any compute provider to participate in Hivemind.

---

## The Core Insight

**The Agent is the unifier.**

Once the Hivemind Agent is running on any compute—VM, bare metal, Kubernetes pod—it becomes a standard Hivemind node. Provider-specific complexity is contained at the provisioning and lifecycle layer.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       HIVEMIND CONTROL PLANE                             │
│                                                                         │
│   Scheduler sees: Homogeneous pool of "Nodes" with capabilities         │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      NODE POOL                                   │   │
│   │                                                                 │   │
│   │   [Node: 8xH100, us-east, $X/hr] [Node: 4xA100, eu-west, $Y/hr] │   │
│   │   [Node: 8xH200, us-west, $Z/hr] [Node: 8xB200, ap-south, $W/hr]│   │
│   │                                                                 │   │
│   │   Scheduler doesn't care WHERE these came from                  │   │
│   │                                                                 │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└────────────────────────────────┬────────────────────────────────────────┘
                                 │
        ┌────────────────────────┼────────────────────────────────┐
        │                        │                                │
        ▼                        ▼                                ▼
┌───────────────┐        ┌───────────────┐        ┌───────────────────┐
│   Provider    │        │   Provider    │        │     Provider      │
│   Adapter:    │        │   Adapter:    │        │     Adapter:      │
│   Crusoe      │        │   AWS EC2     │        │   Kubernetes      │
│               │        │               │        │                   │
│  Bare metal   │        │  VM instances │        │  Node pools       │
│  API          │        │  API          │        │  or virtual-      │
│               │        │               │        │  kubelet          │
└───────┬───────┘        └───────┬───────┘        └─────────┬─────────┘
        │                        │                          │
        ▼                        ▼                          ▼
┌───────────────┐        ┌───────────────┐        ┌───────────────────┐
│  Bare Metal   │        │ EC2 Instance  │        │    K8s Node       │
│  Server       │        │               │        │                   │
│  + Agent      │        │  + Agent      │        │    + Agent        │
└───────────────┘        └───────────────┘        └───────────────────┘
```

---

## Provider Types

### Type 1: VM/Instance Providers

Providers that offer virtual machines or dedicated instances.

| Provider | API Style | GPU Access | Examples |
|----------|-----------|------------|----------|
| AWS EC2 | REST API | GPU instances (P4d, P5) | p4d.24xlarge, p5.48xlarge |
| GCP Compute | REST API | GPU attached | a2-highgpu-8g, a3-highgpu-8g |
| Azure | REST API | GPU VMs | NC, ND series |
| Crusoe | REST API | Bare metal | H100 SXM |
| Lambda Labs | REST API | GPU instances | 8xH100 |
| CoreWeave | K8s + API | GPU instances | H100, H200 |

**Provisioning model**: API call → Instance created → SSH/cloud-init → Agent installed

### Type 2: Kubernetes Providers

Providers where we deploy into existing Kubernetes clusters.

| Provider | Access Model | GPU Access |
|----------|--------------|------------|
| EKS | K8s API | Node groups with GPUs |
| GKE | K8s API | GPU node pools |
| On-prem K8s | K8s API | GPU nodes |

**Provisioning model**: Already have nodes → Deploy Agent DaemonSet → Nodes join Hivemind

### Type 3: Bare Metal Providers

Direct access to physical servers.

| Provider | Access Model | GPU Access |
|----------|--------------|------------|
| Equinix Metal | API + IPMI | GPU servers |
| Vultr Bare Metal | API | GPU servers |
| OVH | API | GPU dedicated |

**Provisioning model**: API call → Server provisioned → PXE/cloud-init → Agent installed

### Type 4: Serverless/Managed GPU

Providers with higher-level abstractions (may require different integration pattern).

| Provider | Model | Integration Approach |
|----------|-------|---------------------|
| RunPod | Pod-based | Custom adapter or skip |
| Modal | Function-based | May not fit model |
| Replicate | Model-based | May not fit model |

**Note**: These may not fit our model well since they don't expose raw compute.

---

## Provider Interface

Every provider adapter must implement this interface:

```zig
const Provider = struct {
    // Identity
    id: ProviderId,
    name: []const u8,

    // Capabilities
    regions: []Region,
    instance_types: []InstanceType,

    // Operations (function pointers for polymorphism)
    listCapacityFn: *const fn (*Provider) Error![]Capacity,
    createNodeFn: *const fn (*Provider, NodeSpec) Error!NodeId,
    getNodeFn: *const fn (*Provider, NodeId) Error!?Node,
    deleteNodeFn: *const fn (*Provider, NodeId) Error!void,
    getPricingFn: *const fn (*Provider) Error![]Pricing,
};
```

### Core Operations

#### 1. ListCapacity

Returns current available capacity across all regions.

```zig
const Capacity = struct {
    region: RegionId,
    instance_type: InstanceTypeId,
    available: u32,           // How many can we provision right now?
    max_capacity: u32,        // Our quota/limit with this provider
    gpu_type: GpuType,
    gpu_count: u8,
    vcpus: u32,
    memory_gb: u32,
    spot_available: bool,     // Is spot/preemptible available?
};

pub fn listCapacity(self: *Provider) Error![]Capacity {
    // Provider-specific API calls to check availability
}
```

**Open Questions:**
- How often do we poll capacity? Real-time vs cached?
- How do we handle providers that don't expose availability?
- Should capacity include "pending" (requested but not ready)?

#### 2. CreateNode

Provisions a new compute node with the Agent installed.

```zig
const NodeSpec = struct {
    instance_type: InstanceTypeId,
    region: RegionId,

    // Agent configuration
    agent_version: []const u8,
    control_plane_endpoint: []const u8,
    node_token: []const u8,          // Auth token for this node

    // Optional
    spot: bool,                       // Use spot/preemptible if available
    labels: []Label,                  // Custom labels for scheduling
    taints: []Taint,                  // Scheduling restrictions

    // Networking
    vpc_config: ?VpcConfig,           // Provider-specific networking
    security_groups: []SecurityGroupId,
};

const CreateResult = struct {
    node_id: NodeId,
    provider_instance_id: []const u8,  // Provider's ID (e.g., i-abc123)
    expected_ready_time: i64,           // When should we expect Agent connection?
};

pub fn createNode(self: *Provider, spec: NodeSpec) Error!CreateResult {
    // 1. Call provider API to create instance
    // 2. Configure cloud-init/user-data to install Agent
    // 3. Return immediately (don't wait for ready)
}
```

**Open Questions:**
- How do we handle cloud-init vs SSH-based provisioning?
- What's the timeout before we consider provisioning failed?
- How do we pass secrets (node token) securely?

#### 3. GetNode

Returns current state of a node.

```zig
const NodeState = enum {
    provisioning,     // Provider is creating the instance
    starting,         // Instance exists, Agent not connected yet
    ready,            // Agent connected and healthy
    unhealthy,        // Agent connected but reporting issues
    draining,         // Marked for termination, finishing work
    terminating,      // Being deleted
    terminated,       // Gone
    failed,           // Provisioning failed
};

const Node = struct {
    id: NodeId,
    provider_id: ProviderId,
    provider_instance_id: []const u8,

    state: NodeState,

    // Capabilities (confirmed by Agent)
    gpus: []Gpu,
    vcpus: u32,
    memory_bytes: u64,

    // Location
    region: RegionId,
    zone: ?ZoneId,

    // Networking
    private_ip: ?IpAddress,
    public_ip: ?IpAddress,

    // Timestamps
    created_at: i64,
    ready_at: ?i64,
    last_heartbeat: ?i64,

    // Cost
    hourly_cost: Money,
    spot: bool,

    // Utilization (from Agent)
    allocated_gpus: u8,
    allocated_memory_bytes: u64,
    workload_count: u32,
};
```

#### 4. DeleteNode

Terminates a node and cleans up resources.

```zig
pub fn deleteNode(self: *Provider, node_id: NodeId) Error!void {
    // 1. Signal Agent to drain (if connected)
    // 2. Wait for drain or timeout
    // 3. Call provider API to terminate
    // 4. Clean up any provider-specific resources (EBS, etc.)
}
```

**Open Questions:**
- How long do we wait for drain before force-terminating?
- How do we handle orphaned resources (volumes, IPs)?
- What if provider API is down?

#### 5. GetPricing

Returns current pricing for cost-aware scheduling.

```zig
const Pricing = struct {
    instance_type: InstanceTypeId,
    region: RegionId,

    on_demand_hourly: Money,
    spot_hourly: ?Money,           // Current spot price if available

    // Commitments (if applicable)
    reserved_1yr_hourly: ?Money,
    reserved_3yr_hourly: ?Money,

    // Metadata
    last_updated: i64,
};

const Money = struct {
    amount_micros: i64,  // Millionths of a dollar for precision
    currency: Currency,
};
```

**Open Questions:**
- How often does pricing update? (Spot can change frequently)
- Do we track historical pricing for prediction?
- How do we handle providers with non-hourly billing?

---

## Topology & Pool Model

With multi-provider, we need a flexible way to group nodes. Rather than hardcoded "clusters," we use **dynamic pools** defined by constraints.

### The Hierarchy

```
                    ┌─────────────────────────────────────┐
                    │         ALL HIVEMIND NODES          │
                    │                                     │
                    │   The global pool of compute        │
                    └─────────────────┬───────────────────┘
                                      │
        ┌─────────────────────────────┼─────────────────────────────┐
        │                             │                             │
        ▼                             ▼                             ▼
┌───────────────┐           ┌───────────────┐           ┌───────────────┐
│    REGION     │           │    REGION     │           │    REGION     │
│   us-east     │           │   eu-west     │           │   ap-south    │
│               │           │               │           │               │
│ Latency pool  │           │ Latency pool  │           │ Latency pool  │
└───────┬───────┘           └───────┬───────┘           └───────┬───────┘
        │                           │                           │
   ┌────┴────┐                 ┌────┴────┐                 ┌────┴────┐
   │         │                 │         │                 │         │
   ▼         ▼                 ▼         ▼                 ▼         ▼
┌──────┐ ┌──────┐           ┌──────┐ ┌──────┐           ┌──────┐ ┌──────┐
│ AWS  │ │Crusoe│           │ AWS  │ │ GCP  │           │ AWS  │ │Lambda│
│      │ │      │           │      │ │      │           │      │ │ Labs │
└──┬───┘ └──┬───┘           └──┬───┘ └──┬───┘           └──┬───┘ └──┬───┘
   │        │                  │        │                  │        │
   ▼        ▼                  ▼        ▼                  ▼        ▼
┌──────┐ ┌──────┐           ┌──────┐ ┌──────┐           ┌──────┐ ┌──────┐
│ H100 │ │ H100 │           │ A100 │ │ H100 │           │ H200 │ │ H100 │
│ pool │ │ pool │           │ pool │ │ pool │           │ pool │ │ pool │
└──────┘ └──────┘           └──────┘ └──────┘           └──────┘ └──────┘
```

### Application Deployment Requirements

Every application specifies topology requirements:

```zig
const DeploymentRequirements = struct {
    // REQUIRED: Hardware specification
    hardware: HardwareRequirements,

    // OPTIONAL: Region constraints (empty = any region)
    regions: []const RegionId,

    // OPTIONAL: Provider constraints (empty = any provider)
    providers: []const ProviderId,

    // Capacity bounds
    capacity: CapacityRequirements,
};

const HardwareRequirements = struct {
    gpu_type: GpuType,          // e.g., h100_sxm
    gpu_count: u8,              // e.g., 8
    min_gpu_memory_gb: ?u32,    // e.g., 80 (for H100 80GB vs 40GB)
    nvlink_required: bool,      // Multi-GPU communication needed?
    min_memory_gb: ?u32,        // Host memory
    min_vcpus: ?u32,            // vCPUs
};

const CapacityRequirements = struct {
    min_replicas: u32,          // Always keep this many warm
    max_replicas: u32,          // Never exceed this many
    target_replicas: ?u32,      // Target for autoscaler (if set)

    // Preemptible/spot tolerance
    spot_allowed: bool,
    max_spot_percentage: ?f32,  // e.g., 0.5 = max 50% spot instances
};
```

### Example Configurations

**Minimal (just hardware):**
```yaml
app: my-model
requirements:
  hardware:
    gpu_type: h100_sxm
    gpu_count: 8
  capacity:
    min_replicas: 0
    max_replicas: 10
# No region/provider constraints → runs anywhere with H100s
```

**Region-constrained (EU data residency):**
```yaml
app: eu-customer-model
requirements:
  hardware:
    gpu_type: a100_80gb
    gpu_count: 4
  regions:
    - eu-west
    - eu-central
  capacity:
    min_replicas: 2
    max_replicas: 20
# Must stay in EU, any provider
```

**Provider-constrained (cost optimization):**
```yaml
app: cost-sensitive-batch
requirements:
  hardware:
    gpu_type: h100_sxm
    gpu_count: 8
  providers:
    - crusoe      # Cheaper
    - lambda      # Cheaper
  capacity:
    min_replicas: 0
    max_replicas: 50
    spot_allowed: true
# Any region, but only cheap providers, spot OK
```

**Fully constrained (enterprise):**
```yaml
app: enterprise-critical
requirements:
  hardware:
    gpu_type: h100_sxm
    gpu_count: 8
    nvlink_required: true
  regions:
    - us-east
  providers:
    - aws         # Enterprise contract
  capacity:
    min_replicas: 4
    max_replicas: 16
    spot_allowed: false
# Specific region, specific provider, no spot
```

### Pool Resolution

The Router and Scheduler resolve requirements to concrete pools:

```zig
const Pool = struct {
    id: PoolId,                     // e.g., "us-east:aws:h100_sxm_8x"

    // Filter criteria (derived from app requirements)
    filter: PoolFilter,

    // Current state (updated by Hivemind)
    nodes: []const NodeId,          // Nodes currently in this pool
    healthy_nodes: u32,
    total_capacity: u32,            // Total GPU count
    available_capacity: u32,        // Unallocated GPU count

    // Workloads running in this pool
    workloads: []const WorkloadId,
    queue_depth: u32,               // Requests waiting for capacity
};

const PoolFilter = struct {
    gpu_type: GpuType,
    gpu_count: u8,
    regions: ?[]const RegionId,     // null = any
    providers: ?[]const ProviderId, // null = any
    spot_only: bool,
    on_demand_only: bool,
};

fn resolvePool(requirements: DeploymentRequirements) PoolId {
    // Generate pool ID from requirements
    // Pools are created lazily when first app needs them
}

fn getNodesInPool(pool: Pool) []const Node {
    // Filter all nodes by pool criteria
    return nodes.filter(|node| {
        matchesGpuType(node, pool.filter.gpu_type) and
        matchesGpuCount(node, pool.filter.gpu_count) and
        matchesRegion(node, pool.filter.regions) and
        matchesProvider(node, pool.filter.providers) and
        matchesSpotConstraint(node, pool.filter)
    });
}
```

### Router Pool Awareness

The Router maintains pool state for routing decisions:

```zig
const RouterPoolState = struct {
    // Pool health and capacity
    pools: std.StringHashMap(PoolState),

    // App → Pools mapping
    app_pools: std.StringHashMap([]const PoolId),

    pub fn getPoolsForApp(self: *RouterPoolState, app_id: AppId) []const PoolId {
        return self.app_pools.get(app_id) orelse &[_]PoolId{};
    }

    pub fn selectPool(self: *RouterPoolState, app_id: AppId, client_region: ?RegionId) !PoolId {
        const pools = self.getPoolsForApp(app_id);

        // Score each pool
        var best_pool: ?PoolId = null;
        var best_score: f32 = 0;

        for (pools) |pool_id| {
            const pool = self.pools.get(pool_id) orelse continue;

            var score: f32 = 0;

            // Capacity score (prefer pools with available capacity)
            score += capacityScore(pool);

            // Latency score (prefer pools in same region as client)
            if (client_region) |region| {
                score += latencyScore(pool, region);
            }

            // Queue depth score (prefer pools with shorter queues)
            score += queueScore(pool);

            // Cost score (prefer cheaper pools)
            score += costScore(pool);

            if (score > best_score) {
                best_score = score;
                best_pool = pool_id;
            }
        }

        return best_pool orelse error.NoPoolAvailable;
    }
};

const PoolState = struct {
    pool_id: PoolId,
    region: RegionId,
    provider: ProviderId,
    gpu_type: GpuType,

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
```

### Pool Lifecycle

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         POOL LIFECYCLE                                   │
│                                                                         │
│   1. App Created                                                        │
│      └─► Requirements parsed                                            │
│          └─► Pool filter generated                                      │
│              └─► Pool ID computed (deterministic from filter)           │
│                                                                         │
│   2. Pool Materialized (first app needing this pool)                    │
│      └─► Hivemind creates pool entry                                    │
│          └─► Queries nodes matching filter                              │
│              └─► Registers pool with Router                             │
│                                                                         │
│   3. Pool Active                                                        │
│      └─► Nodes join/leave as they match/unmatch filter                  │
│          └─► Capacity updated in real-time                              │
│              └─► Router receives updates                                │
│                                                                         │
│   4. Pool Scaling                                                       │
│      └─► Queue depth increases → signal to Hivemind                     │
│          └─► Hivemind requests new nodes from providers                 │
│              └─► New nodes join pool when ready                         │
│                                                                         │
│   5. Pool Draining (no more apps need this pool)                        │
│      └─► Mark pool as draining                                          │
│          └─► Stop accepting new workloads                               │
│              └─► Terminate nodes as workloads complete                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Cross-Pool Failover

When a pool is unhealthy or full, the Router can fail over to alternative pools:

```zig
const FailoverStrategy = enum {
    // Fail to any pool matching requirements
    any_matching,

    // Fail to pools in order of latency
    nearest_first,

    // Fail to pools in order of cost
    cheapest_first,

    // Don't fail over (reject if primary pool unavailable)
    reject,
};

fn selectPoolWithFailover(
    app_id: AppId,
    primary_pool: PoolId,
    strategy: FailoverStrategy,
) !PoolId {
    const primary = pools.get(primary_pool);

    // Try primary first
    if (primary.status == .healthy and primary.available_capacity > 0) {
        return primary_pool;
    }

    // Get all pools matching app requirements
    const alternatives = getPoolsForApp(app_id);

    switch (strategy) {
        .any_matching => return selectFirstHealthy(alternatives),
        .nearest_first => return selectByLatency(alternatives, client_region),
        .cheapest_first => return selectByCost(alternatives),
        .reject => return error.PrimaryPoolUnavailable,
    }
}
```

### Capacity Reservation

For `min_replicas > 0`, we need to ensure capacity is reserved:

```zig
const CapacityReservation = struct {
    app_id: AppId,
    pool_id: PoolId,
    reserved_count: u32,      // Number of instances to keep warm
    priority: u32,            // Higher priority = harder to preempt

    // Reservation can span multiple pools for redundancy
    // e.g., min_replicas=4 might be 2 in us-east + 2 in eu-west
};

fn reserveCapacity(app_id: AppId, requirements: CapacityRequirements) ![]CapacityReservation {
    const pools = getPoolsForApp(app_id);

    if (requirements.min_replicas == 0) {
        return &[_]CapacityReservation{};
    }

    // Distribute reservations across pools for redundancy
    var reservations = std.ArrayList(CapacityReservation).init(allocator);

    const per_pool = requirements.min_replicas / pools.len;
    const remainder = requirements.min_replicas % pools.len;

    for (pools, 0..) |pool_id, i| {
        const count = per_pool + (if (i < remainder) 1 else 0);
        if (count > 0) {
            try reservations.append(.{
                .app_id = app_id,
                .pool_id = pool_id,
                .reserved_count = count,
                .priority = requirements.reservation_priority,
            });
        }
    }

    return reservations.toOwnedSlice();
}
```

### Open Questions: Topology

| Question | Options | Impact |
|----------|---------|--------|
| How granular are pools? | Per GPU-count? Per NVLink? | Pool explosion vs routing precision |
| How do we handle pool fragmentation? | Consolidate? Allow fragmented? | Cost vs availability |
| Cross-region failover latency? | Accept latency? Reject? | User experience vs availability |
| Min-replica distribution strategy? | Even? Weighted? Customer-specified? | Reliability vs cost |
| How do we handle provider outages? | Auto-failover? Manual? | Automation vs control |

---

## Capacity Model

### GPU Normalization

Different providers name GPUs differently. We need a canonical model:

```zig
const GpuType = enum {
    // NVIDIA Ampere
    a100_40gb,
    a100_80gb,
    a10,
    a10g,

    // NVIDIA Hopper
    h100_sxm,
    h100_pcie,
    h100_nvl,

    // NVIDIA Blackwell
    h200,
    b100,
    b200,
    gb200,

    // AMD
    mi250x,
    mi300x,

    // Intel
    gaudi2,
    gaudi3,

    // Unknown/Other
    unknown,
};

const Gpu = struct {
    gpu_type: GpuType,
    memory_bytes: u64,
    uuid: [36]u8,           // GPU UUID from nvidia-smi
    pcie_bus_id: ?[]const u8,
    nvlink: bool,           // Connected via NVLink?
    mig_enabled: bool,      // Multi-Instance GPU mode?
    mig_profile: ?MigProfile,
};
```

### Provider → GPU Mapping

```zig
const InstanceTypeMapping = struct {
    provider: ProviderId,
    provider_instance_type: []const u8,  // e.g., "p5.48xlarge"
    gpu_type: GpuType,
    gpu_count: u8,
    nvlink: bool,
};

// Example mappings
const mappings = [_]InstanceTypeMapping{
    // AWS
    .{ .provider = .aws, .provider_instance_type = "p4d.24xlarge", .gpu_type = .a100_40gb, .gpu_count = 8, .nvlink = true },
    .{ .provider = .aws, .provider_instance_type = "p5.48xlarge", .gpu_type = .h100_sxm, .gpu_count = 8, .nvlink = true },

    // Crusoe
    .{ .provider = .crusoe, .provider_instance_type = "h100-80gb-sxm-8", .gpu_type = .h100_sxm, .gpu_count = 8, .nvlink = true },

    // Lambda Labs
    .{ .provider = .lambda, .provider_instance_type = "gpu_8x_h100_sxm5", .gpu_type = .h100_sxm, .gpu_count = 8, .nvlink = true },

    // CoreWeave
    .{ .provider = .coreweave, .provider_instance_type = "h100-80gb-hgx", .gpu_type = .h100_sxm, .gpu_count = 8, .nvlink = true },
};
```

### Region Normalization

Map provider regions to canonical regions:

```zig
const CanonicalRegion = enum {
    // North America
    us_east_1,      // Virginia
    us_east_2,      // Ohio
    us_west_1,      // N. California
    us_west_2,      // Oregon
    us_central_1,   // Iowa/Texas
    ca_central_1,   // Canada

    // Europe
    eu_west_1,      // Ireland
    eu_west_2,      // London
    eu_central_1,   // Frankfurt
    eu_north_1,     // Stockholm

    // Asia Pacific
    ap_northeast_1, // Tokyo
    ap_southeast_1, // Singapore
    ap_south_1,     // Mumbai

    // Other
    unknown,
};

const RegionMapping = struct {
    provider: ProviderId,
    provider_region: []const u8,
    canonical: CanonicalRegion,
    latitude: f64,
    longitude: f64,
};

// Example
const region_mappings = [_]RegionMapping{
    .{ .provider = .aws, .provider_region = "us-east-1", .canonical = .us_east_1, .latitude = 38.9, .longitude = -77.0 },
    .{ .provider = .crusoe, .provider_region = "us-northcentral-a", .canonical = .us_central_1, .latitude = 41.8, .longitude = -87.6 },
    .{ .provider = .gcp, .provider_region = "us-east4", .canonical = .us_east_1, .latitude = 39.0, .longitude = -77.5 },
};
```

---

## Provisioning Flow

### VM/Instance Providers (Type 1)

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Hivemind   │     │  Provider   │     │  Provider   │     │    Node     │
│  Control    │     │  Adapter    │     │  API        │     │             │
│  Plane      │     │             │     │             │     │             │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │                   │
       │ 1. CreateNode()   │                   │                   │
       │──────────────────►│                   │                   │
       │                   │                   │                   │
       │                   │ 2. Create instance │                   │
       │                   │   (with user-data) │                   │
       │                   │──────────────────►│                   │
       │                   │                   │                   │
       │                   │ 3. Instance ID     │                   │
       │                   │◄──────────────────│                   │
       │                   │                   │                   │
       │ 4. NodeId +       │                   │                   │
       │    expected_ready │                   │                   │
       │◄──────────────────│                   │                   │
       │                   │                   │                   │
       │                   │                   │ 5. Instance boots │
       │                   │                   │──────────────────►│
       │                   │                   │                   │
       │                   │                   │ 6. Cloud-init runs│
       │                   │                   │    - Downloads Agent
       │                   │                   │    - Configures Agent
       │                   │                   │    - Starts Agent │
       │                   │                   │                   │
       │ 7. Agent connects │                   │                   │
       │   (with node_token)                   │                   │
       │◄──────────────────────────────────────────────────────────│
       │                   │                   │                   │
       │ 8. Validate token,│                   │                   │
       │    register node  │                   │                   │
       │                   │                   │                   │
       │ 9. Node READY     │                   │                   │
       │                   │                   │                   │
```

### Cloud-Init Template

```yaml
#cloud-config
write_files:
  - path: /etc/hivemind/agent.yaml
    content: |
      control_plane:
        endpoint: "${CONTROL_PLANE_ENDPOINT}"
        token: "${NODE_TOKEN}"

      node:
        id: "${NODE_ID}"
        provider: "${PROVIDER_ID}"
        region: "${REGION}"
        labels:
          gpu-type: "${GPU_TYPE}"
          instance-type: "${INSTANCE_TYPE}"

      modules:
        metrics: true
        logs: true
        gpu: true
        storage: true
        p2p: true

runcmd:
  # Install NVIDIA drivers (if not in AMI)
  - |
    if ! command -v nvidia-smi &> /dev/null; then
      # Install drivers
    fi

  # Download and install Agent
  - curl -sSL https://releases.hivemind.dev/agent/${AGENT_VERSION}/hivemind-agent -o /usr/local/bin/hivemind-agent
  - chmod +x /usr/local/bin/hivemind-agent

  # Start Agent
  - systemctl enable hivemind-agent
  - systemctl start hivemind-agent
```

### Kubernetes Providers (Type 2)

For K8s providers, we have two models:

#### Model A: DaemonSet on GPU Nodes

Deploy Agent as a DaemonSet that runs on all GPU nodes:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: hivemind-agent
  namespace: hivemind-system
spec:
  selector:
    matchLabels:
      app: hivemind-agent
  template:
    metadata:
      labels:
        app: hivemind-agent
    spec:
      nodeSelector:
        nvidia.com/gpu.present: "true"  # Only GPU nodes
      tolerations:
        - operator: Exists  # Tolerate all taints
      hostPID: true
      hostNetwork: true
      containers:
        - name: agent
          image: hivemind/agent:${VERSION}
          securityContext:
            privileged: true
          env:
            - name: CONTROL_PLANE_ENDPOINT
              value: "${CONTROL_PLANE_ENDPOINT}"
            - name: NODE_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hivemind-agent-token
                  key: token
          volumeMounts:
            - name: host-root
              mountPath: /host
            - name: nvidia
              mountPath: /usr/local/nvidia
      volumes:
        - name: host-root
          hostPath:
            path: /
        - name: nvidia
          hostPath:
            path: /usr/local/nvidia
```

#### Model B: Virtual Kubelet (Future)

For tighter integration, implement a Virtual Kubelet that:
- Presents Hivemind capacity as K8s nodes
- Schedules K8s pods onto Hivemind nodes
- Enables K8s workloads to use multi-provider capacity

**Open Questions:**
- Do we need to support both models?
- How do we handle K8s RBAC and network policies?
- What about K8s-native features (ConfigMaps, Secrets)?

---

## Networking Across Providers

### The Challenge

Nodes from different providers need to communicate for:
- Agent ↔ Control Plane communication
- P2P layer distribution (Honeycomb)
- Workload-to-workload traffic (if needed)

### Option 1: Public Internet + mTLS

Simplest approach - all communication over public internet with mTLS.

```
Pros:
  - Works with any provider
  - No networking setup required
  - Easy to reason about

Cons:
  - Latency for P2P (though may be acceptable)
  - Bandwidth costs for public traffic
  - Requires public IPs
```

### Option 2: Overlay Network (WireGuard/Tailscale)

Create a mesh network across all providers.

```
Pros:
  - Private communication
  - Lower latency within mesh
  - Works without public IPs

Cons:
  - Additional complexity
  - Performance overhead
  - Another component to manage
```

### Option 3: Hybrid

- Control Plane communication: Public + mTLS
- P2P within same provider: Private network
- P2P cross-provider: Public + mTLS or overlay

**Recommendation**: Start with Option 1 (Public + mTLS). Simple, works everywhere. Optimize later if P2P latency becomes an issue.

---

## Cost-Aware Scheduling

The scheduler should factor in provider pricing:

### Scoring Function

```zig
const SchedulingScore = struct {
    // Existing factors
    data_locality: f32,      // 0-40 points
    queue_depth: f32,        // 0-25 points
    capacity: f32,           // 0-20 points
    bin_packing: f32,        // 0-15 points

    // New: Cost factor
    cost: f32,               // 0-20 points (or configurable weight)

    // New: Provider preference
    provider_preference: f32, // 0-10 points (customer may prefer certain providers)
};

fn calculateCostScore(node: *const Node, workload: *const Workload) f32 {
    const base_hourly = node.hourly_cost.amount_micros;

    // Normalize to cheapest available option
    const cheapest = findCheapestNodeForWorkload(workload);
    const cost_ratio = @intToFloat(f32, base_hourly) / @intToFloat(f32, cheapest.hourly_cost.amount_micros);

    // Invert: cheaper = higher score
    // cost_ratio of 1.0 (cheapest) → 20 points
    // cost_ratio of 2.0 (2x price) → 10 points
    // cost_ratio of 4.0 (4x price) → 5 points
    return 20.0 / cost_ratio;
}
```

### Spot/Preemptible Handling

```zig
const SpotPolicy = enum {
    never,           // Never use spot instances
    prefer,          // Use spot if available, fall back to on-demand
    require,         // Only use spot (fail if unavailable)
    cost_threshold,  // Use spot if savings > threshold
};

const WorkloadSpotConfig = struct {
    policy: SpotPolicy,
    savings_threshold: ?f32,  // e.g., 0.5 = use spot if 50% cheaper
    max_interruption_rate: ?f32,  // e.g., 0.1 = accept 10% interruption rate

    // Checkpointing for spot
    checkpoint_enabled: bool,
    checkpoint_interval: ?u64,  // How often to checkpoint
};
```

**Open Questions:**
- How do we handle spot interruption? (2-minute warning on AWS)
- Can we migrate workloads when spot is about to be reclaimed?
- How do we track spot reliability per provider/region?

---

## Provider Adapter Implementation

### AWS EC2 Adapter

```zig
const AwsEc2Provider = struct {
    config: AwsConfig,
    ec2_client: *Ec2Client,

    pub fn listCapacity(self: *AwsEc2Provider) Error![]Capacity {
        // Call DescribeInstanceTypeOfferings for each region
        // Filter by GPU instance types
        // Check our quota via ServiceQuotas API
    }

    pub fn createNode(self: *AwsEc2Provider, spec: NodeSpec) Error!CreateResult {
        const user_data = generateCloudInit(spec);

        const request = RunInstancesRequest{
            .image_id = self.config.ami_id,
            .instance_type = mapToAwsInstanceType(spec.instance_type),
            .min_count = 1,
            .max_count = 1,
            .user_data = base64Encode(user_data),
            .subnet_id = self.config.subnet_id,
            .security_group_ids = spec.security_groups,
            .iam_instance_profile = self.config.instance_profile,
            .tag_specifications = &[_]TagSpec{
                .{ .resource_type = .instance, .tags = &[_]Tag{
                    .{ .key = "Name", .value = "hivemind-" ++ spec.node_id },
                    .{ .key = "hivemind-node-id", .value = spec.node_id },
                }},
            },
        };

        const response = try self.ec2_client.runInstances(request);

        return CreateResult{
            .node_id = spec.node_id,
            .provider_instance_id = response.instances[0].instance_id,
            .expected_ready_time = std.time.timestamp() + 300,  // ~5 min
        };
    }

    pub fn deleteNode(self: *AwsEc2Provider, node_id: NodeId) Error!void {
        const instance_id = try self.lookupInstanceId(node_id);
        try self.ec2_client.terminateInstances(&[_][]const u8{instance_id});
    }
};
```

### Kubernetes Adapter

```zig
const K8sProvider = struct {
    config: K8sConfig,
    client: *K8sClient,

    pub fn listCapacity(self: *K8sProvider) Error![]Capacity {
        // List nodes with GPU label
        const nodes = try self.client.listNodes(.{
            .label_selector = "nvidia.com/gpu.present=true",
        });

        var capacity = std.ArrayList(Capacity).init(self.allocator);

        for (nodes.items) |node| {
            const gpus = parseGpuCapacity(node);
            const allocatable = node.status.allocatable;

            try capacity.append(.{
                .region = mapK8sRegion(node.labels.get("topology.kubernetes.io/region")),
                .gpu_type = gpus.gpu_type,
                .gpu_count = gpus.count,
                .available = gpus.available,
                // ...
            });
        }

        return capacity.toOwnedSlice();
    }

    pub fn createNode(self: *K8sProvider, spec: NodeSpec) Error!CreateResult {
        // For K8s, we don't create nodes - they already exist
        // Instead, we deploy/update the Agent DaemonSet
        // Or, for dynamic node pools, we scale the node group

        if (self.config.dynamic_scaling) {
            try self.scaleNodeGroup(spec);
        } else {
            return error.StaticCluster;
        }
    }
};
```

---

## Security Considerations

### Node Authentication

Each node gets a unique token for authenticating with the control plane:

```zig
const NodeToken = struct {
    node_id: NodeId,
    provider_id: ProviderId,
    created_at: i64,
    expires_at: i64,
    signature: [64]u8,  // Ed25519 signature
};

fn generateNodeToken(node_id: NodeId, provider_id: ProviderId) NodeToken {
    const now = std.time.timestamp();
    const expires = now + (24 * 60 * 60);  // 24 hours

    const payload = .{
        .node_id = node_id,
        .provider_id = provider_id,
        .created_at = now,
        .expires_at = expires,
    };

    const signature = ed25519.sign(serializePayload(payload), signing_key);

    return NodeToken{
        .node_id = node_id,
        .provider_id = provider_id,
        .created_at = now,
        .expires_at = expires,
        .signature = signature,
    };
}
```

### Provider Credential Management

Provider credentials should be:
- Stored encrypted (Vault, AWS Secrets Manager)
- Scoped to minimum permissions
- Rotated regularly
- Never logged

```zig
const ProviderCredentials = struct {
    provider_id: ProviderId,
    credentials: union(enum) {
        aws: AwsCredentials,
        gcp: GcpCredentials,
        k8s: K8sCredentials,
        api_key: ApiKeyCredentials,
    },

    // Metadata
    created_at: i64,
    rotated_at: i64,
    expires_at: ?i64,
};
```

### Network Security

- All control plane communication: mTLS
- All P2P communication: mTLS
- Node-to-node within provider: Can use provider's private networking
- Cross-provider: mTLS over public internet

---

## Open Questions

### 1. Provisioning

| Question | Options | Impact |
|----------|---------|--------|
| How do we handle failed provisioning? | Retry with backoff? Try different provider? | Reliability |
| What's the provisioning timeout? | 5 min? 10 min? Provider-specific? | User experience |
| How do we handle partial failures? | Instance up but Agent won't start? | Cleanup complexity |
| Pre-baked AMIs vs cloud-init? | Speed vs flexibility | Provisioning latency |

### 2. Capacity Management

| Question | Options | Impact |
|----------|---------|--------|
| How do we track quotas? | API polling? Webhooks? Manual config? | Scheduling accuracy |
| How do we handle quota increases? | Auto-request? Alert? | Growth |
| Should we pre-provision capacity? | Warm pools? Reserved instances? | Cost vs latency |
| How do we handle capacity exhaustion? | Queue? Reject? Try another provider? | User experience |

### 3. Cost Optimization

| Question | Options | Impact |
|----------|---------|--------|
| How do we get real-time spot pricing? | Poll? Websocket? Provider feeds? | Cost accuracy |
| How do we handle spot interruptions? | Checkpoint? Migrate? Accept failure? | Reliability |
| Should we use reserved instances? | 1yr? 3yr? Which providers? | Cost vs flexibility |
| How do we expose cost to customers? | Pass-through? Markup? Flat rate? | Business model |

### 4. Networking

| Question | Options | Impact |
|----------|---------|--------|
| Do we need private networking? | mTLS everywhere? Overlay? Both? | Complexity |
| How do we handle NAT/firewall? | Provider-specific rules? Relay? | Compatibility |
| What about IPv6-only providers? | Require IPv4? NAT64? | Provider support |

### 5. Provider Onboarding

| Question | Options | Impact |
|----------|---------|--------|
| What's the minimum viable adapter? | Just create/delete? Full capacity API? | Time to integrate |
| How do we test new providers? | Staging env? Customer beta? | Risk |
| How do we handle provider-specific features? | Ignore? Expose via extensions? | Feature parity |

---

## Technology Choice

### Language: Zig

The Provider Abstraction layer is part of the Hivemind Control Plane and requires:

1. **DST for scheduling decisions** - Provider selection must be deterministic
2. **Cost calculation testing** - Price-aware scheduling needs simulation
3. **Failure mode testing** - Provider API failures, timeouts, partial failures

See [HIVEMIND.md](HIVEMIND.md#technology-choice) for full rationale.

---

## Implementation Plan

### Phase 0: Core Interface (Week 1-2)

```
Deliverables:
  [ ] Provider interface definition
  [ ] Node/Capacity/Pricing data structures
  [ ] Provider registry (add/remove providers)
  [ ] Basic AWS EC2 adapter (create, get, delete)
```

### Phase 1: AWS EC2 Full Support (Week 3-4)

```
Deliverables:
  [ ] Capacity listing via EC2 API
  [ ] Spot instance support
  [ ] AMI management
  [ ] Security group configuration
  [ ] CloudWatch metrics integration
```

### Phase 2: Second Provider (Week 5-6)

Pick one based on priority:
- Crusoe (if bare metal access needed)
- GCP (if multi-cloud important)
- Lambda Labs (if H100 access needed)

```
Deliverables:
  [ ] Provider adapter implementation
  [ ] Region/instance type mappings
  [ ] Testing with real workloads
```

### Phase 3: Kubernetes Integration (Week 7-8)

```
Deliverables:
  [ ] K8s adapter (DaemonSet model)
  [ ] GPU node discovery
  [ ] Integration with existing EKS clusters
```

### Phase 4: Cost Optimization (Week 9-10)

```
Deliverables:
  [ ] Real-time pricing integration
  [ ] Cost-aware scheduling
  [ ] Spot instance handling
  [ ] Cost reporting/dashboards
```

### Phase 5: Additional Providers (Ongoing)

Add providers based on customer demand and GPU availability.

---

## Appendix: Provider Research

### Provider Comparison

| Provider | API Quality | GPU Availability | Pricing | Notes |
|----------|-------------|------------------|---------|-------|
| AWS EC2 | Excellent | Good (H100 limited) | High | Most mature |
| GCP | Excellent | Good | High | TPU option |
| Azure | Good | Good | High | Enterprise |
| Crusoe | Good | Excellent (H100) | Medium | Climate-focused |
| Lambda Labs | Good | Good (H100) | Low | GPU-focused |
| CoreWeave | Good | Excellent | Medium | K8s-native |
| Vultr | Basic | Limited | Low | Budget option |
| Paperspace | Good | Good | Medium | ML-focused |

### GPU Availability by Provider (as of 2024)

| GPU | AWS | GCP | Azure | Crusoe | Lambda | CoreWeave |
|-----|-----|-----|-------|--------|--------|-----------|
| A100 40GB | ✓ | ✓ | ✓ | - | ✓ | ✓ |
| A100 80GB | ✓ | ✓ | ✓ | - | ✓ | ✓ |
| H100 SXM | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| H100 NVL | - | - | - | - | - | ✓ |
| H200 | Coming | Coming | Coming | Coming | Coming | ✓ |
| B200 | 2025 | 2025 | 2025 | 2025 | 2025 | 2025 |

---

## Related Documents

- [ARCHITECTURE.md](../ARCHITECTURE.md) - Overall system architecture
- [HIVEMIND.md](HIVEMIND.md) - Control plane that uses provider abstraction
- [AGENT.md](AGENT.md) - Agent that runs on provisioned nodes
- [ENGINEERING.md](../ENGINEERING.md) - Engineering principles for implementation

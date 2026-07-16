> **LEGACY**: This is a historical planning document from before the current `core/` implementation. For current state and roadmap, see [`docs/STATUS.md`](../STATUS.md) and [`docs/FINDINGS_AND_ISSUES.md`](../FINDINGS_AND_ISSUES.md).

# Migration Strategy: Current Infrastructure → Hivemind Platform

## Overview

This document outlines the incremental migration path from the previous Knative/Kubernetes stack to the Hivemind/Honeycomb/Beekeeper platform. The core principle is **work from the edges inward** - don't replace the core until the edges are solid.

---

## Current Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         CURRENT STATE                            │
│                                                                 │
│   ┌─────────────┐         ┌─────────────┐                       │
│   │   Go CLI    │────────►│  Lambda API │                       │
│   └─────────────┘         │  (Go)       │                       │
│                           └──────┬──────┘                       │
│                                  │                              │
│               ┌──────────────────┼──────────────────┐           │
│               │                  │                  │           │
│               ▼                  ▼                  ▼           │
│        ┌───────────┐      ┌───────────┐      ┌───────────┐     │
│        │  Depot    │      │EKS us-east│      │EKS eu-west│     │
│        │  (build)  │      │           │      │           │     │
│        └─────┬─────┘      │ Knative   │      │ Knative   │     │
│              │            │ Registry  │      │ Registry  │     │
│              │            │ JuiceFS   │      │ JuiceFS   │     │
│              │            │ Proxies   │      │ Proxies   │     │
│              ▼            └───────────┘      └───────────┘     │
│        Regional                  │                  │           │
│        Registries          ISOLATED          ISOLATED          │
│                           (no sharing)      (no sharing)       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Current Components

| Component | Technology | Notes |
|-----------|------------|-------|
| **Backend API** | Go AWS Lambda | Hosts API, creates Knative services |
| **CLI** | Go | Communicates with Lambda for builds, scaling, info |
| **Build System** | Depot (outsourced) | Docker builds with distributed cache |
| **Compute** | EKS / managed K8s | One cluster per region/provider |
| **Serverless** | Knative | With custom autoscaler patches |
| **Node Provisioning** | Karpenter | Custom autoscaler in some clusters |
| **Registry** | Docker registry | Per-cluster, backed by JuiceFS |
| **Storage** | JuiceFS | Distributed filesystem, S3 backend |
| **Image Acceleration** | Nydus | Lazy-loading via custom AMI |
| **Proxies** | L0 → Kourier → pods | L0 attached to load balancer |

### Key Pain Points

1. **Clusters are isolated** - Cannot route requests between regions
2. **Data doesn't sync** - Images must be rebuilt/pushed per region
3. **Build outsourced** - Depot costs, limited control over optimizations
4. **No unified capacity view** - Each cluster managed independently
5. **DaemonSet sprawl** - Many system components to manage per node

---

## Migration Principle

**Don't replace the core until the edges are solid.**

```
Migration Order (outside → inside):

  1. Router (edge)           ← Start here, lowest risk
  2. Data layer (Honeycomb)  ← Enables multi-region
  3. Build (Beekeeper)       ← Replace Depot
  4. Control plane           ← Wrap existing K8s first
  5. Node runtime            ← Last, most disruptive
```

Each phase delivers value independently and can be rolled back without affecting other phases.

---

## Phase 1: Distributed Router

**Goal**: Route requests across existing clusters without changing them.

**Duration estimate**: 4-6 weeks

### What Changes

- New: Hivemind Router deployed on edge (Cloudflare Workers, Fly.io, or regional deployments)
- Router receives all traffic at `api.hivemind.dev`
- Routes to appropriate cluster based on app region, user preferences, latency

### What Stays the Same

- Lambda API (still creates Knative services)
- Clusters (still run independently)
- Depot (still builds)
- Registries (still per-cluster)

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│             ┌─────────────────────────────┐                     │
│             │     Hivemind Router         │                     │
│             │     (edge deployment)       │                     │
│             └──────────────┬──────────────┘                     │
│                            │                                    │
│          ┌─────────────────┼─────────────────┐                  │
│          ▼                 ▼                 ▼                  │
│   ┌───────────┐     ┌───────────┐     ┌───────────┐            │
│   │EKS us-east│     │EKS eu-west│     │  Crusoe   │            │
│   │  (as-is)  │     │  (as-is)  │     │  (as-is)  │            │
│   └───────────┘     └───────────┘     └───────────┘            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Deliverables

| Deliverable | Description |
|-------------|-------------|
| **Router service** | Stateless, edge-deployable request router |
| **Cluster registry** | Database of clusters, endpoints, capacity |
| **Routing rules engine** | Region, latency, user preference rules |
| **Health checker** | Monitors backend cluster health |
| **Metrics/observability** | Request routing decisions, latency |

### Migration Steps

1. Deploy router alongside existing L0 proxies
2. Route new apps through router (opt-in)
3. Gradually migrate existing apps
4. Router becomes the only entry point
5. Deprecate per-cluster L0 proxies

### Value Unlocked

- Users can deploy to "best available" region
- Cross-region failover possible
- Foundation for multi-region apps
- Unified traffic metrics across all clusters

### Rollback

- DNS switch back to direct cluster endpoints
- No cluster changes required

---

## Phase 2: Honeycomb (Data Layer)

**Goal**: Unified data layer that syncs across regions.

**Duration estimate**: 6-8 weeks

**Dependency**: Phase 1 (Router) should be stable

### What Changes

- New: Honeycomb origin registry (S3-backed, global)
- New: Regional cache in each cluster
- New: P2P distribution between nodes (re-enable Dragonfly or custom)
- Replaces: Per-cluster Docker registries

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│                    ┌─────────────────┐                          │
│                    │ Honeycomb Origin│                          │
│                    │ (S3 + metadata) │                          │
│                    └────────┬────────┘                          │
│                             │                                   │
│          ┌──────────────────┼──────────────────┐                │
│          ▼                  ▼                  ▼                │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐        │
│   │  Regional   │    │  Regional   │    │  Regional   │        │
│   │  Cache      │    │  Cache      │    │  Cache      │        │
│   │  us-east    │◄──►│  eu-west    │◄──►│  crusoe     │        │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘        │
│          │                  │                  │                │
│          │ P2P              │ P2P              │ P2P            │
│          ▼                  ▼                  ▼                │
│   ┌───────────┐      ┌───────────┐      ┌───────────┐          │
│   │  Nodes    │      │  Nodes    │      │  Nodes    │          │
│   └───────────┘      └───────────┘      └───────────┘          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Deliverables

| Deliverable | Description |
|-------------|-------------|
| **Honeycomb origin** | OCI registry API, S3 backend |
| **Regional cache** | Per-cluster cache service |
| **P2P agent** | Node-level P2P distribution (DaemonSet initially) |
| **Sync protocol** | Cross-region replication |
| **JuiceFS adapter** | Use existing JuiceFS as storage backend |
| **Warmup service** | Proactive cache warming |

### Migration Steps

1. Deploy Honeycomb origin alongside existing infrastructure
2. Deploy regional caches in each cluster
3. Configure Depot to push to Honeycomb (dual-write initially)
4. Update Knative services to pull from Honeycomb
5. Verify parity with existing registries
6. Deprecate per-cluster registries

### Value Unlocked

- Images available in all regions immediately after build
- P2P reduces pull times significantly
- Foundation for instant multi-region deployment
- Layer deduplication across tenants

### Rollback

- Revert Knative services to pull from old registries
- No data loss (origin retains all images)

---

## Phase 3: Beekeeper (Build)

**Goal**: Replace Depot with in-house build system.

**Duration estimate**: 6-8 weeks

**Dependency**: Phase 2 (Honeycomb) should be stable

### What Changes

- New: Beekeeper build service
- New: Build cluster (dedicated nodes or Lambda/Fargate)
- New: Distributed build cache
- Replaces: Depot

### Build Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   CLI ──► Lambda API ──► Beekeeper ──► Honeycomb Origin        │
│                              │                                  │
│                              ▼                                  │
│                        Build Cluster                            │
│                        ├── BuildKit executor                    │
│                        ├── Distributed cache                    │
│                        └── Layer optimization                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Deliverables

| Deliverable | Description |
|-------------|-------------|
| **Beekeeper API** | Build request handling, status tracking |
| **Build executor** | BuildKit-based image building |
| **Distributed cache** | Layer cache across builds |
| **app.toml parser** | Infer Dockerfile from config |
| **Honeycomb integration** | Push images to origin |
| **Build metrics** | Duration, cache hit rate, layer sizes |

### Migration Steps

1. Deploy Beekeeper alongside Depot
2. Feature flag: route new builds to Beekeeper
3. Compare build outputs (should be identical)
4. Monitor build times, cache efficiency
5. Gradually migrate existing apps
6. Deprecate Depot integration

### Value Unlocked

- Cost reduction (no Depot fees)
- Faster iteration on build optimizations
- Tighter Honeycomb integration (layer sharing hints)
- Custom optimizations (pre-compilation, model embedding)

### Rollback

- Feature flag back to Depot
- Depot contract should remain active during migration

---

## Phase 4: Hivemind Control Plane

**Goal**: Unified control plane that wraps existing clusters.

**Duration estimate**: 12-16 weeks (sub-phases)

**Dependency**: Phases 1-3 should be stable

### Sub-Phases

#### Phase 4a: API Wrapper (2-3 weeks)

```
CLI ──► Hivemind API ──► Lambda API ──► K8s
              │
              └── (pass-through, no behavior change)
```

- Hivemind API accepts requests, forwards to Lambda
- Allows CLI migration without backend changes
- Introduces Hivemind API contract

#### Phase 4b: Direct K8s Management (4-6 weeks)

```
CLI ──► Hivemind API ──► K8s (directly)
              │
              └── (bypasses Lambda, creates Knative services)
```

- Hivemind directly creates Knative services
- Lambda API deprecated for deployment operations
- Still using Knative for serverless semantics

#### Phase 4c: Cross-Cluster Scheduler (4-6 weeks)

```
CLI ──► Hivemind API ──► Scheduler ──► K8s clusters
              │              │
              │              └── (decides which cluster)
              │
        Router ──► Scheduler
              │
              └── (feeds demand signals)
```

- Scheduler makes cross-cluster placement decisions
- Router provides demand signals (queue depth, latency)
- Knative still handles per-cluster autoscaling

#### Phase 4d: Replace Knative (4-6 weeks)

```
CLI ──► Hivemind API ──► Scheduler ──► Pod management
                             │
                             └── (direct pod lifecycle, no Knative)
```

- Hivemind manages pod lifecycle directly
- Custom autoscaling based on router queue depth
- Knative removed from clusters

### Architecture Evolution

```
Phase 4a:  CLI → Hivemind → Lambda → K8s/Knative
Phase 4b:  CLI → Hivemind ────────→ K8s/Knative
Phase 4c:  CLI → Hivemind → Scheduler → K8s/Knative (multi-cluster)
Phase 4d:  CLI → Hivemind → Scheduler → K8s (no Knative)
```

### Deliverables

| Deliverable | Description |
|-------------|-------------|
| **Hivemind API** | Unified API for all operations |
| **Cluster adapter** | Talks to Kubernetes API per cluster |
| **Cross-cluster scheduler** | Placement decisions across clusters |
| **Workload state machine** | Tracks workload lifecycle |
| **Autoscaler** | Replaces Knative KPA |
| **CLI updates** | Point to Hivemind API |

### Value Unlocked

- Unified API for all clusters
- Cross-cluster scheduling (place workload in best cluster)
- Custom autoscaling tuned for AI workloads
- Foundation for non-K8s compute sources

### Rollback

- Phase 4a/4b: Revert CLI to Lambda API
- Phase 4c/4d: More complex, requires per-cluster rollback

---

## Phase 5: Battery-Included Node Agent

**Goal**: Replace DaemonSet sprawl with unified agent.

**Duration estimate**: 12-16 weeks

**Dependency**: Phase 4 should be stable

### What Gets Replaced

| Current (DaemonSets) | Replaced By |
|---------------------|-------------|
| NVIDIA device plugin | Node agent GPU module |
| DCGM exporter | Node agent metrics |
| Fluent Bit | Node agent log collector |
| Node exporter | Node agent metrics |
| JuiceFS mount pod | Node agent storage driver |
| P2P agent | Node agent P2P module |
| VPC CNI (eventually) | Node agent network module |

### Migration Order (by risk)

```
1. Metrics exporter     (low risk, easy to validate)
2. Log collector        (medium risk, need log parity)
3. P2P agent           (already new from Phase 2)
4. Storage driver      (medium risk, affects mounts)
5. GPU device plugin   (high risk, test extensively)
6. Container runtime   (highest risk, last)
```

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    HIVEMIND NODE AGENT                           │
│                                                                 │
│   Single binary, feature flags per capability                   │
│                                                                 │
│   ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐  │
│   │ Metrics │ │  Logs   │ │   P2P   │ │ Storage │ │   GPU   │  │
│   │         │ │         │ │         │ │         │ │         │  │
│   │ --enable│ │ --enable│ │ --enable│ │ --enable│ │ --enable│  │
│   │ -metrics│ │ -logs   │ │ -p2p    │ │ -storage│ │ -gpu    │  │
│   └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Migration Steps (per capability)

1. Deploy agent with capability enabled (alongside DaemonSet)
2. Validate parity (metrics match, logs complete, etc.)
3. Disable DaemonSet via node selector
4. Monitor for issues
5. Remove DaemonSet entirely
6. Repeat for next capability

### Deliverables

| Deliverable | Description |
|-------------|-------------|
| **Node agent binary** | Single binary with all capabilities |
| **Feature flags** | Enable/disable capabilities |
| **New AMI** | Base OS + agent only |
| **Rollback mechanism** | Re-enable DaemonSets if needed |
| **Validation suite** | Parity tests per capability |

### Value Unlocked

- Single thing to deploy, upgrade, debug
- Faster node bootstrap (no DaemonSet scheduling)
- Consistent versions across capabilities
- Simplified AMI (just OS + agent)

### Rollback

- Re-enable DaemonSets (kept in repo but disabled)
- Agent can coexist with DaemonSets during transition

---

## Phase 6: Full Platform (Long-term)

**Goal**: Remove Kubernetes dependency entirely.

**This phase is optional and represents the long-term vision.**

### What Changes

- VSR consensus replaces etcd
- Custom scheduler replaces kube-scheduler
- Direct container management (no kubelet)
- Actor-based control plane

### Prerequisites

- Phases 1-5 fully stable
- Significant operational experience with Hivemind
- Clear benefits over K8s justify the complexity

### Note

Phases 1-5 deliver substantial value while keeping Kubernetes as a stable foundation. Phase 6 should only be pursued if there are clear limitations that Kubernetes cannot address.

---

## Parallel Tracks

The phases can be parallelized where dependencies allow:

```
Timeline:

Track A: Data Plane          Track B: Control Plane
─────────────────────        ──────────────────────

Phase 1: Router ◄────────────────────────────────► Lambda API (unchanged)
    │
    ▼
Phase 2: Honeycomb ◄─────────────────────────────► Lambda API (unchanged)
    │
    ▼
Phase 3: Beekeeper ◄─────────────────────────────► Lambda API (unchanged)
    │                                                     │
    │                                                     ▼
    │                              Phase 4a: API wrapper
    │                                                     │
    │                                                     ▼
    │                              Phase 4b: Direct K8s
    │                                                     │
    ▼                                                     ▼
Phase 5: Node Agent ◄────────────────────────────► Phase 4c/4d: Scheduler
```

---

## Quick Wins

Start with these low-risk, high-value items:

| Item | Effort | Value | Risk | Phase |
|------|--------|-------|------|-------|
| Router prototype | 2-3 weeks | High | Low | 1 |
| Re-enable Dragonfly P2P | 1 week | Medium | Low | 2 |
| Honeycomb registry API | 2-3 weeks | High | Low | 2 |
| Hivemind API wrapper | 1-2 weeks | Medium | Low | 4a |

---

## Risk Mitigation

### General Principles

1. **Dual-run everything**: New system runs alongside old before cutover
2. **Feature flags**: Gradual rollout, instant rollback
3. **Metrics parity**: New system must match old system metrics before migration
4. **Canary regions**: Test in one region before global rollout

### Per-Phase Risks

| Phase | Primary Risk | Mitigation |
|-------|--------------|------------|
| 1: Router | Latency increase | Edge deployment, measure P50/P99 |
| 2: Honeycomb | Image pull failures | Dual-write, fallback to old registry |
| 3: Beekeeper | Build failures | Feature flag, Depot as fallback |
| 4: Control Plane | Deployment failures | Gradual migration, Lambda fallback |
| 5: Node Agent | Node instability | Per-capability rollout, DaemonSet fallback |

---

## Success Criteria

### Phase 1: Router
- [ ] All traffic routes through Hivemind Router
- [ ] P99 latency within 10ms of direct routing
- [ ] Cross-region failover works

### Phase 2: Honeycomb
- [ ] All images stored in Honeycomb origin
- [ ] P2P reduces average pull time by 50%+
- [ ] Per-cluster registries deprecated

### Phase 3: Beekeeper
- [ ] All builds run through Beekeeper
- [ ] Build times match or beat Depot
- [ ] Depot contract terminated

### Phase 4: Control Plane
- [ ] All deployments via Hivemind API
- [ ] Lambda API deprecated
- [ ] Cross-cluster scheduling works
- [ ] Knative removed (Phase 4d)

### Phase 5: Node Agent
- [ ] All DaemonSets replaced by agent
- [ ] Node bootstrap time < 60 seconds
- [ ] Single AMI across all clusters

---

## Related Documents

- [PLATFORM.md](./PLATFORM.md) - Platform architecture design
- [STATUS.md](../STATUS.md) - Current implementation state

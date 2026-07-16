# Hivemind: Technical Summary

> A unified control plane for serverless GPU compute across any provider.

---

## The Problems We're Solving

### 1. Vendor Lock-in & Limited GPU Access

| Problem | Impact |
|---------|--------|
| Tied to AWS/EKS for orchestration | Can't easily use Crusoe, Lambda Labs, CoreWeave |
| H100/H200/B200 availability varies by provider | Missing out on scarce compute |
| Each provider requires different integration | Slow to onboard new capacity sources |

### 2. Knative Limitations

| Problem | Impact |
|---------|--------|
| Replica-based autoscaling | Doesn't understand GPU utilization or queue depth |
| No cross-cluster scheduling | Can't route to cheapest/nearest provider |
| Cold starts cause request failures | Poor user experience, 502s during scale-up |
| Complex stack (Knative + Kourier + Istio) | Hard to debug, many moving parts |

### 3. Operational Overhead

| Problem | Impact |
|---------|--------|
| 6+ DaemonSets per node | 185MB+ memory overhead, complex upgrades |
| Depot for builds | External dependency, cost, no control |
| No unified observability | Metrics scattered across systems |

---

## The Solution: Hivemind

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           HIVEMIND ARCHITECTURE                          │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                         ROUTER                                   │   │
│   │   • Entry point for all traffic                                 │   │
│   │   • Queue requests during cold starts (don't fail)              │   │
│   │   • Route to optimal pool based on latency, cost, capacity      │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│                                    ▼                                    │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    HIVEMIND CONTROL PLANE                        │   │
│   │   • Cross-provider scheduler                                    │   │
│   │   • Queue-depth autoscaling                                     │   │
│   │   • Cost-aware placement                                        │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                    │
│          ┌─────────────────────────┼─────────────────────────┐          │
│          │                         │                         │          │
│          ▼                         ▼                         ▼          │
│   ┌─────────────┐           ┌─────────────┐           ┌─────────────┐   │
│   │    AWS      │           │   Crusoe    │           │   Lambda    │   │
│   │   H100s     │           │   H100s     │           │   H100s     │   │
│   │   Agent     │           │   Agent     │           │   Agent     │   │
│   └─────────────┘           └─────────────┘           └─────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                        HONEYCOMB                                 │   │
│   │   • OCI registry (replace ECR dependency)                       │   │
│   │   • P2P layer distribution                                      │   │
│   │   • Fast image pulls                                            │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                        BEEKEEPER                                 │   │
│   │   • Container build service (replace Depot)                     │   │
│   │   • BuildKit pool management                                    │   │
│   │   • Shared build cache                                          │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### 1. Router
**What**: Entry point for all user traffic. Routes requests to the optimal pool.

**Key Features**:
- Queue requests during cold starts instead of failing
- Route based on latency, cost, and available capacity
- Signal demand to control plane for autoscaling
- Auth validation at the edge

**Why it matters**: No more 502s during scale-up. Smarter routing across providers.

---

### 2. Honeycomb
**What**: OCI-compliant container registry with P2P distribution.

**Key Features**:
- Store images in S3 (any region, any provider)
- P2P layer distribution between nodes
- Turso for metadata (globally distributed SQLite)

**Why it matters**: Faster image pulls, no ECR dependency, works across providers.

---

### 3. Beekeeper
**What**: Container build service replacing Depot.

**Key Features**:
- BuildKit builder pool (spot instances)
- SQS-based build queue
- Shared S3 build cache

**Why it matters**: Full control over builds, lower cost, no external dependency.

---

### 4. Hivemind Control Plane
**What**: The brain. Schedules workloads, manages capacity, autoscales.

**Key Features**:
- Cross-provider scheduling (AWS, Crusoe, Lambda Labs, etc.)
- Queue-depth based autoscaling (not just replicas)
- Cost-aware placement decisions
- Dynamic pool management

**Why it matters**: Run workloads on the best available compute, automatically.

---

### 5. Agent
**What**: Single binary running on every node, replacing 6+ DaemonSets.

**Key Features**:
- Metrics collection (replaces prometheus exporters)
- Log forwarding (replaces fluent-bit)
- P2P participation (for Honeycomb)
- GPU management
- Storage management (JuiceFS)

**Why it matters**: ~5MB vs 185MB current overhead. Single upgrade path.

---

## The Pool Model

Apps specify **requirements**, not specific clusters:

```yaml
# Customer specifies hardware (required) + optional constraints
requirements:
  hardware:
    gpu_type: h100_sxm
    gpu_count: 8
  regions: [eu-west]      # Optional: data residency
  providers: [crusoe]     # Optional: cost optimization
```

Hivemind automatically:
1. Finds all pools matching requirements
2. Routes to optimal pool (latency, cost, capacity)
3. Fails over to alternatives if primary unavailable
4. Scales capacity across pools as needed

**Result**: Workloads float to best available compute. Customers don't manage infrastructure.

---

## Implementation Plan

### Phase 1: Router (Month 1)
```
Deliverables:
  • Request routing to existing clusters
  • Queue management (no more cold-start failures)
  • Auth at the edge
  • Metrics and observability

Risk: Low - additive, works with existing infrastructure
```

### Phase 2: Honeycomb (Month 2)
```
Deliverables:
  • OCI registry service
  • S3 layer storage
  • Basic P2P distribution

Risk: Medium - new component, but isolated from critical path initially
```

### Phase 3: Beekeeper (Month 3)
```
Deliverables:
  • BuildKit builder pool
  • SQS build queue
  • S3 build cache
  • Depot migration

Risk: Medium - replaces external service, needs careful migration
```

### Phase 4: Hivemind Control Plane (Month 4)
```
Deliverables:
  • Single-cluster scheduler (first)
  • Queue-depth autoscaler
  • Provider abstraction layer
  • Cross-cluster scheduling (later)

Risk: High - core scheduling logic, needs extensive testing
```

### Phase 5: Agent (Month 5)
```
Deliverables:
  • Metrics module
  • Logs module
  • P2P module
  • Storage module
  • (GPU module deferred)

Risk: Medium - replaces many components, but can migrate incrementally
```

### Phase 6: Advanced Features (Month 6+)
```
Deliverables:
  • Cross-cluster scheduling
  • GPU module in Agent
  • Nydus lazy loading
  • Additional providers

Risk: Lower - building on proven foundation
```

---

## Migration Strategy

Each phase is **additive** - we don't rip out existing infrastructure until new components are proven.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        MIGRATION APPROACH                                │
│                                                                         │
│   Phase 1: Router in front of existing Kourier                          │
│            • Shadow traffic first, then gradual cutover                 │
│            • Rollback: just remove Router from path                     │
│                                                                         │
│   Phase 2-3: Honeycomb + Beekeeper alongside existing                   │
│            • New builds go to Beekeeper                                 │
│            • New images go to Honeycomb                                 │
│            • Existing images still work from ECR                        │
│                                                                         │
│   Phase 4: Hivemind Control Plane with feature flags                    │
│            • Canary apps use new scheduler                              │
│            • Gradual migration by customer/app                          │
│            • Knative still available as fallback                        │
│                                                                         │
│   Phase 5: Agent replaces DaemonSets incrementally                      │
│            • One module at a time                                       │
│            • Node-by-node rollout                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Technology Choices

| Component | Language | Rationale |
|-----------|----------|-----------|
| Router | Zig | DST for queue/routing logic, <10ms P99 latency |
| Honeycomb | Zig + Go | Zig for P2P core, Go for OCI API |
| Beekeeper | Go | Orchestration around BuildKit, no DST needed |
| Hivemind | Zig | DST-critical scheduler, potential consensus (VSR) |
| Agent | Zig | Binary size (~5MB), memory efficiency, GPU DST |

**Why Zig over Rust?**
- Simpler language, closer to C
- Zig 0.16’s `Io` interface (perfect for DST)
- No async runtime complexity
- Natural C-bindings

**Why not Go everywhere?**
- GC makes true deterministic simulation harder
- Higher memory footprint for Agent
- Less control over performance-critical paths

---

## Expected Outcomes

| Metric | Current | Target |
|--------|---------|--------|
| Cold-start failures | ~5% of requests | 0% (queued) |
| Provider options | AWS only | AWS, Crusoe, Lambda, CoreWeave, bare metal |
| Node overhead | 185MB (DaemonSets) | ~5MB (Agent) |
| Build dependency | Depot (external) | Beekeeper (internal) |
| Image pull time | 30-60s | <10s (P2P + caching) |
| Cross-region routing | Manual | Automatic |

---

## Open Questions & Next Steps

35 open questions documented in `docs/REVIEW.md`, including:

- Performance SLAs (cold-start latency target, queue depth limits)
- Provider priorities (which to integrate first)
- Spot instance strategy
- Multi-tenant isolation model
- Cost attribution model

**Immediate next steps**:
1. Answer critical open questions (REVIEW.md)
2. Set up Zig development environment
3. Begin Phase 1 Router implementation
4. Define success metrics for each phase

---

## Documentation

| Document | Purpose |
|----------|---------|
| `docs/ARCHITECTURE.md` | System overview |
| `docs/ENGINEERING.md` | Engineering principles, DST patterns |
| `docs/REVIEW.md` | Gaps, questions, compromises |
| `docs/TODO_DISCUSSIONS.md` | Pending design discussions checklist |
| `docs/design/ROUTER.md` | Phase 1 detailed design |
| `docs/design/HONEYCOMB.md` | Phase 2 detailed design |
| `docs/design/BEEKEEPER.md` | Phase 3 detailed design |
| `docs/design/HIVEMIND.md` | Phase 4 detailed design |
| `docs/design/AGENT.md` | Phase 5 detailed design |
| `docs/design/PROVIDERS.md` | Multi-provider abstraction |
| `docs/design/CONSENSUS.md` | Consensus topology, VRR, failure modes |

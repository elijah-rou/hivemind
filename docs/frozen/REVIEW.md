# Hivemind Design Review

> Comprehensive review of all design documentation identifying gaps, potential compromises, areas for refinement, and the current implementation plan.

---

## Current Plan Summary

### Timeline Overview (5 Months)

| Month | Phase | Component | Key Deliverable |
|-------|-------|-----------|-----------------|
| 1 | 1 | **Router** | In-process Rust router, queue-based routing, graceful scaling |
| 2 | 2 | **Honeycomb** | OCI registry, layer storage, P2P distribution |
| 3 | 3 | **Beekeeper** | BuildKit builder pool, SQS queue, Depot replacement |
| 4 | 4 | **Hivemind** | Control plane, cross-cluster scheduler, autoscaler |
| 5 | 5 | **Agent** | Single binary replacing 6+ DaemonSets |

### Phase Dependencies

```
Router → Honeycomb → Beekeeper → Hivemind → Agent
   ↑         ↑           ↑          ↑         ↑
   └─────────┴───────────┴──────────┴─────────┘
              All depend on Router being stable
```

Each phase builds on the stability of previous phases. This creates a critical path where issues discovered late can cascade backwards.

---

## Gaps Identified

### 1. Failure Mode Documentation

**Current State**: Rollback procedures are documented per-phase, but edge cases are underspecified.

**Missing Details**:
- Cross-cluster scheduling failure recovery: What happens when a workload is partially migrated between clusters?
- Hivemind unavailability during scale-up: How does the router handle queue buildup when the control plane is down?
- P2P network partition handling: How do nodes recover when BitTorrent swarm is partitioned?
- Turso metadata corruption recovery: What's the backup/restore strategy for the metadata database?

**Impact**: Without clear failure mode handling, on-call engineers will lack runbooks for incident response.

---

### 2. Observability of Hivemind Itself

**Current State**: Strong focus on workload observability, but limited self-monitoring.

**Missing Details**:
- Scheduler decision quality metrics: Was the placement optimal? How do we measure?
- Cross-cluster communication health: Latency, error rates, connection pool status
- Queue depth → scale decision latency: Time from queue threshold breach to pod running
- Control plane availability SLOs: What's acceptable downtime?

**Impact**: We can monitor workloads but may be blind to Hivemind's own degradation.

---

### 3. Security Model

**Current State**: Security is mentioned in context of specific features but no unified model.

**Missing Details**:
- Multi-tenant isolation in direct pod management: How do we prevent cross-tenant access when bypassing Knative?
- Secret rotation during migration: How do workloads get new credentials when migrating between systems?
- Network policies between clusters: What traffic is allowed between regions?
- Agent authentication to control plane: mTLS? API keys? Service accounts?
- Registry authentication: How does Honeycomb validate pull requests?

**Impact**: Security gaps could lead to data leakage or unauthorized access.

---

### 4. Testing Strategy

**Current State**: Canary rollouts mentioned but no comprehensive testing plan.

**Missing Details**:
- Load testing plan for queue-depth autoscaler: How do we validate scaling decisions under load?
- Cross-cluster scheduler correctness validation: How do we prove optimal placement?
- Chaos engineering approach: Failure injection, network partitions, node failures
- Integration test environment: Do we have a staging environment that spans all phases?
- Performance benchmarks: What are our baseline metrics for regression detection?

**Impact**: Without testing strategy, we risk discovering bugs in production.

---

### 5. Cost Attribution

**Current State**: Beekeeper has cost analysis comparing Depot, but no unified model.

**Missing Details**:
- Per-workload cost tracking across clusters: How do we attribute GPU hours to specific customers?
- GPU utilization → billing integration: How does actual usage translate to invoices?
- Spot instance handling in scheduler: Can we leverage spot for cost savings? How does preemption work?
- Storage cost attribution: How do we charge for Honeycomb layer storage?

**Impact**: Inability to accurately bill customers or optimize infrastructure spend.

---

### 6. Cache Invalidation

**Current State**: Caching strategies defined but lifecycle management unclear.

**Missing Details**:
- Honeycomb layer garbage collection: When do we delete unused layers? After X days? X pulls?
- P2P cache invalidation: When an image is updated, how do we purge stale layers from the swarm?
- Stale metadata cleanup: How does Turso handle orphaned records?
- Build cache expiration: How long do we keep BuildKit cache layers?

**Impact**: Unbounded storage growth and potential serving of stale content.

---

## Areas for Compromise

### 1. Defer Agent GPU Module to Phase 6

**Current Plan**: Agent replaces NVIDIA device plugin in Month 5.

**Risk Assessment**:
- GPU device plugin is the most critical component for inference workloads
- NVIDIA's plugin is battle-tested and actively maintained
- Custom implementation requires deep NVML expertise
- Failure means GPUs become unavailable to all workloads

**Recommendation**: Keep existing NVIDIA device plugin. Focus Agent on metrics, logs, P2P, and storage modules. Revisit GPU module after Agent is proven stable.

**Risk Reduction**: High - removes highest-risk component from critical path.

---

### 2. Single-Cluster Scheduling First

**Current Plan**: Hivemind implements cross-cluster scheduling in Month 4.

**Risk Assessment**:
- Cross-cluster scheduling adds significant complexity
- Requires robust network handling between regions
- Failure modes multiply with each cluster added
- Can be added incrementally after single-cluster is stable

**Recommendation**: Month 4 focuses on single-cluster Hivemind. Cross-cluster scheduling becomes Phase 4.5 or Month 5 scope.

**Risk Reduction**: Medium - allows proving scheduler correctness in simpler environment.

---

### 3. Defer Nydus Lazy Loading

**Current Plan**: Honeycomb includes Nydus integration for lazy loading.

**Risk Assessment**:
- Requires containerd configuration changes across all nodes
- Complex integration with existing container runtime
- Primary benefit is cold-start optimization
- Not critical for MVP functionality

**Recommendation**: Move Nydus to Phase 6 or later. Standard OCI pulls are sufficient for initial release.

**Risk Reduction**: Medium - removes containerd integration complexity.

---

### 4. Simplify P2P Distribution

**Current Plan**: BitTorrent-based P2P distribution for image layers.

**Risk Assessment**:
- BitTorrent adds protocol complexity
- Requires tracker infrastructure or DHT
- At current scale, HTTP from regional caches may suffice
- P2P benefits increase with scale but add debugging complexity

**Recommendation**: Start with simple cache hierarchy (local → regional → origin). Add P2P when scale justifies complexity.

**Risk Reduction**: Low-Medium - simplifies Honeycomb but may need revisiting at scale.

---

### 5. Simplify Beekeeper Build Cache

**Current Plan**: Full distributed S3 cache with cross-region replication.

**Risk Assessment**:
- Distributed cache adds consistency challenges
- Cache invalidation is notoriously difficult
- Simple per-region cache may achieve 80% of benefit with 20% of complexity

**Recommendation**: Start with per-region S3 cache. Add cross-region fallback only if cache miss rates justify it.

**Risk Reduction**: Low - simplifies initial implementation.

---

## Areas Needing Refinement

### 1. Scheduler Scoring Weights

**Current Definition**:
```
Score = Data Locality (40) + Queue Depth (25) + Capacity (20) + Bin Packing (15)
```

**Issues**:
- Weights are arbitrary without production data
- No mechanism to tune weights dynamically
- Different workload types may need different weights

**Refinements Needed**:
- Make weights configurable per workload class
- Add observability for scoring decisions
- Implement A/B testing framework for weight optimization
- Define metrics that indicate suboptimal placement

---

### 2. Queue Depth Autoscaler Thresholds

**Current Definition**: "Tune based on p99 latency"

**Issues**:
- No concrete threshold values defined
- No hysteresis to prevent scaling flap
- No guidance on initial values

**Refinements Needed**:
- Define default thresholds: scale-up at queue depth > X for Y seconds
- Define scale-down thresholds with cooldown period
- Specify hysteresis parameters
- Create dashboard for threshold tuning
- Document how to calibrate for specific workload patterns

---

### 3. Router ↔ Hivemind Protocol

**Current Definition**: "Bidirectional communication"

**Issues**:
- Protocol not specified (gRPC vs HTTP vs WebSocket)
- Failure handling undefined
- No backpressure mechanism

**Refinements Needed**:
- Choose protocol: Recommend gRPC for bidirectional streaming
- Define failure modes: What does Router do when Hivemind is unavailable?
- Specify rate limiting and backpressure
- Define message schemas and versioning strategy
- Document connection pooling and retry logic

---

### 4. Agent Module Dependencies

**Current Definition**: Module initialization order defined (Metrics → Logs → P2P → Storage → GPU)

**Issues**:
- Inter-module communication not specified
- Shared state management unclear
- What if GPU module needs real-time metrics data?

**Refinements Needed**:
- Define inter-module API contracts
- Specify shared memory or IPC mechanisms
- Document dependency injection pattern
- Define health check aggregation across modules

---

### 5. Migration Rollback Triggers

**Current Definition**: Each phase has manual rollback procedures

**Issues**:
- No automatic rollback triggers defined
- Human-in-the-loop timing not specified
- No time bounds for migration phases

**Refinements Needed**:
- Define specific metrics that trigger automatic rollback
- Specify human approval gates vs automated decisions
- Set maximum duration for each migration phase
- Define "point of no return" criteria
- Document partial rollback scenarios

---

### 6. Honeycomb Storage Lifecycle

**Current Definition**: Layer storage in S3 with Turso metadata

**Issues**:
- No garbage collection policy
- Storage quotas not defined
- Cross-region replication strategy unclear

**Refinements Needed**:
- Define GC policy: Delete layers not pulled in X days
- Set per-customer storage quotas
- Specify replication strategy: sync vs async, which regions
- Document orphan detection and cleanup
- Define retention policy for build artifacts

---

## Recommended Revised Plan

### Original Timeline (5 Months)

```
Month 1: Router
Month 2: Honeycomb
Month 3: Beekeeper
Month 4: Hivemind (full cross-cluster)
Month 5: Agent (full with GPU)
```

### Revised Timeline (6 Months)

```
Month 1: Router
Month 2: Honeycomb (without Nydus, simplified P2P)
Month 3: Beekeeper (simplified cache)
Month 4: Hivemind (single-cluster only)
Month 5: Agent (without GPU module)
Month 6: Cross-cluster scheduling + GPU module + Nydus
```

### Rationale

| Change | Risk Reduction | Trade-off |
|--------|---------------|-----------|
| Defer Nydus | Removes containerd complexity | Slower cold starts initially |
| Simplify P2P | Reduces Honeycomb scope | May need P2P later at scale |
| Single-cluster first | Proves scheduler in isolation | Delays cross-region optimization |
| Defer GPU module | Removes highest-risk component | Continues NVIDIA dependency |
| Add Month 6 | Buffer for deferred scope | Extended timeline |

---

## Open Questions

### Performance & SLAs

1. **What's the acceptable cold-start latency target?**
   - Drives priority of Nydus lazy loading
   - Current baseline needed for comparison
   - Target: < X seconds from request to first response?

2. **What's the maximum acceptable queue depth before SLA breach?**
   - Defines autoscaler urgency thresholds
   - Ties to customer-facing latency guarantees
   - Different thresholds for different workload tiers?

3. **What's the target image pull time?**
   - Affects Honeycomb cache strategy
   - Determines if P2P is necessary
   - Baseline for different image sizes needed

4. **What's the GPU utilization target before scaling?**
   - Too low = wasted resources, too high = latency spikes
   - Different targets for inference vs training?

5. **What's our cross-cluster network latency budget?**
   - Affects scheduler design and timeouts
   - May influence cluster placement decisions
   - Defines feasibility of cross-region scheduling

### Capacity & Limits

6. **How many concurrent builds do we need to support?**
   - Drives Beekeeper builder pool sizing
   - Affects SQS queue configuration
   - Peak vs sustained load?

7. **What's the maximum container image size we support?**
   - Affects storage capacity planning
   - Influences P2P chunk sizing
   - Registry timeout configuration

8. **What's the build timeout?**
   - Prevents runaway builds consuming resources
   - Customer communication if builds are killed
   - Different timeouts for different tiers?

9. **What's the expected cluster scale?**
   - Nodes per cluster?
   - Total GPUs across all clusters?
   - Affects Agent resource footprint decisions

### Architecture & Design

10. **Should Hivemind control plane be active-passive or active-active?**
    - Active-active adds complexity but improves availability
    - Affects database choice and consistency model
    - Leader election mechanism if active-passive

11. **What's the consistency model for Turso?**
    - Strong consistency vs eventual consistency trade-offs
    - Affects cross-region read/write patterns
    - Conflict resolution strategy

12. **How do we handle clock skew between nodes?**
    - Affects distributed timing decisions
    - Log correlation across components
    - Queue ordering guarantees

13. **What storage backend do we use for JuiceFS?**
    - S3? EBS? Local NVMe?
    - Affects latency and cost characteristics
    - Cross-region data access patterns

### Security & Isolation

14. **What are the multi-tenant isolation requirements?**
    - Affects security model design
    - May require network policy changes
    - GPU isolation between tenants?

15. **How do workloads authenticate to Honeycomb registry?**
    - Per-workload credentials vs shared?
    - Credential rotation strategy
    - Audit logging requirements

16. **What network policies exist between clusters?**
    - Which traffic is allowed cross-region?
    - VPN/private link requirements
    - Firewall rule management

### Operations & Migration

17. **What's the rollback SLA?**
    - How fast must we be able to revert each phase?
    - Drives automation requirements
    - Maximum acceptable downtime during rollback

18. **How do we handle node failures during migration?**
    - Graceful degradation strategy
    - Workload rescheduling during transition
    - Data durability guarantees

19. **What's the monitoring and alerting strategy?**
    - Which metrics trigger pages?
    - Alert fatigue prevention
    - Dashboard requirements per phase

20. **What's the capacity planning process?**
    - Lead time for new GPU nodes
    - Demand forecasting approach
    - Buffer capacity requirements

### Process & Ownership

21. **Who owns each phase?**
    - Clear ownership for accountability
    - On-call rotation during migration
    - Decision-making authority

22. **What's the staging environment strategy?**
    - Do we have a full staging cluster?
    - How do we test cross-cluster features?
    - Production-like data in staging?

23. **What's the customer communication plan?**
    - Which migrations are customer-visible?
    - Maintenance window requirements
    - Feature flag rollout communication

24. **What's the incident response playbook structure?**
    - Escalation paths per component
    - Runbook requirements before go-live
    - Post-incident review process

### Cost & Business

25. **What's the cost attribution model?**
    - Per-workload GPU hour tracking
    - Storage cost allocation
    - Network egress charging

26. **What's the Depot contract end date?**
    - Drives Beekeeper migration urgency
    - Parallel running cost implications

27. **What's the acceptable infrastructure cost increase during migration?**
    - Running old + new systems in parallel
    - Buffer for unexpected scaling needs

### Multi-Provider Strategy

28. **Which providers are highest priority?**
    - Current providers in use (AWS, Crusoe, etc.)
    - Providers with scarce GPU availability (H100, H200)
    - Cost optimization targets
    - See [PROVIDERS.md](design/PROVIDERS.md) for full analysis

29. **What's the provisioning model per provider?**
    - Pre-baked AMIs vs cloud-init for VM providers?
    - DaemonSet vs dynamic node pools for K8s providers?
    - Bare metal provisioning (IPMI, PXE)?

30. **How do we handle provider-specific networking?**
    - mTLS over public internet (simplest)?
    - Overlay network (WireGuard/Tailscale)?
    - Provider VPC peering where available?

31. **What's the spot/preemptible strategy?**
    - Which workloads can tolerate interruption?
    - Checkpointing requirements for spot instances?
    - Maximum acceptable interruption rate?

32. **How do we track and manage quotas?**
    - API polling vs manual configuration?
    - Automatic quota increase requests?
    - Alert thresholds when approaching limits?

33. **What's the cost optimization strategy?**
    - Real-time spot pricing integration?
    - Reserved instance commitments?
    - Cost pass-through vs markup model?

34. **How do we onboard new providers?**
    - Minimum viable adapter requirements?
    - Testing and validation process?
    - Customer beta program for new providers?

35. **What about provider-specific features?**
    - Ignore and use lowest common denominator?
    - Expose via provider-specific extensions?
    - Which features are must-have vs nice-to-have?

---

## Next Steps

1. **Address Critical Gaps**
   - Document failure modes for each phase
   - Define security model
   - Create testing strategy

2. **Decide on Compromises**
   - Confirm or reject each proposed compromise
   - Update phase documents accordingly

3. **Refine Specifications**
   - Add concrete values to autoscaler thresholds
   - Specify Router ↔ Hivemind protocol
   - Define rollback triggers

4. **Answer Open Questions**
   - Technical questions drive design decisions
   - Process questions drive project planning

5. **Update PROJECT_PLAN.md**
   - Reflect any timeline changes
   - Add stability criteria between phases
   - Define go/no-go checkpoints

---

## Appendix: Document Cross-Reference

| Document | Primary Focus | Key Dependencies |
|----------|--------------|------------------|
| ARCHITECTURE.md | System overview | - |
| ENGINEERING.md | Engineering principles | VISION.md |
| VISION.md | Long-term aspirations | - |
| PLATFORM.md | Current state | - |
| MIGRATION.md | Migration strategy | All phase docs |
| PROJECT_PLAN.md | Timeline and milestones | All phase docs |
| ROUTER.md | Phase 1 design | - |
| HONEYCOMB.md | Phase 2 design | Router |
| BEEKEEPER.md | Phase 3 design | Honeycomb |
| HIVEMIND.md | Phase 4 design | Router, Honeycomb |
| WORKER.md | Phase 5 design | Hivemind |
| PROVIDERS.md | Multi-provider abstraction | Hivemind, Agent |
| SECURITY.md | Security and compliance | All components |
| TESTING.md | Testing strategy | All components |

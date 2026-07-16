# Hivemind: Pending Design Discussions

> Areas that still need exploration and documentation.

---

## Completed ✓

- [x] Consensus topology options (A, B, C) - see `design/CONSENSUS.md`
- [x] VRR implementation approach
- [x] Request lifecycle & routing
- [x] Hot potato routing model
- [x] Response path options (symmetric vs asymmetric)
- [x] Comprehensive failure mode analysis

---

## Pending Discussions

### 1. VRR State Machine Design
- What operations/commands does the control plane need?
- What's the state schema?
- Which operations are reads vs writes?
- Log compaction strategy

### 2. Security Model
- Multi-tenant isolation when bypassing Knative
- Agent ↔ control plane authentication (mTLS? API keys?)
- Honeycomb registry authentication
- Cross-region network policies
- Secret rotation during migration

### 3. Observability Strategy
- Self-monitoring of Hivemind components
- Scheduler decision quality metrics
- Cross-cluster communication health
- What triggers alerts vs pages?
- Dashboard requirements per component

### 4. Testing & Validation
- DST test harness design for Zig components
- Chaos engineering approach
- Load testing for autoscaler
- Integration test environment spanning all phases
- Performance benchmarks / regression detection

### 5. Cost Attribution Model
- Per-workload GPU hour tracking
- Storage cost allocation (Honeycomb)
- Spot instance handling in scheduler
- Billing integration
- Network egress charging

### 6. Cache & Storage Lifecycle
- Honeycomb layer garbage collection policy
- P2P cache invalidation when images updated
- Build cache expiration (Beekeeper)
- Turso metadata cleanup / orphan detection
- Storage quotas per customer

### 7. Scheduler Scoring
- Weight tuning mechanism
- A/B testing framework for weight optimization
- Per-workload-class weights
- Metrics indicating suboptimal placement

### 8. Autoscaler Thresholds
- Concrete default values (scale-up at queue depth > X for Y seconds)
- Scale-down thresholds with cooldown
- Hysteresis parameters to prevent flapping
- Calibration guidance per workload type

### 9. Workload Types (NEW)
- See `design/WORKLOAD_TYPES.md` for draft design
- **Jobs & CronJobs**: Run-to-completion workloads
  - Job queue ordering and priority
  - Preemption policy (can serverless preempt jobs?)
  - Spot instance tolerance for jobs
- **Instances**: Persistent/timed VM-like workloads
  - Workspace storage backend (EBS vs JuiceFS vs other)
  - SSH key management model (per-instance vs project-level)
  - Instance hibernation vs simple stop
  - Live migration support
- **Timed Instances**: Lease model questions
  - Pricing model (prepaid blocks vs pay-as-you-go with cap)
  - Grace period duration before forced termination
  - Extension limits and pricing

---

## Open Questions from REVIEW.md

See `docs/REVIEW.md` for the full list of 35 open questions covering:
- Performance & SLAs
- Capacity & Limits
- Architecture & Design
- Security & Isolation
- Operations & Migration
- Process & Ownership
- Cost & Business
- Multi-Provider Strategy

---

## Priority Suggestions

High priority (blocks implementation):
1. VRR State Machine Design
2. Security Model
3. Autoscaler Thresholds

Medium priority (needed before production):
4. Testing & Validation
5. Observability Strategy
6. Cache & Storage Lifecycle

Lower priority (can iterate):
7. Scheduler Scoring
8. Cost Attribution Model

**New - Workload Types (Phase 4.5-4.6):**
9. Workload Types - Jobs, CronJobs, Instances (see `design/WORKLOAD_TYPES.md`)

---

## Future Vision (Phase 6+)

### 10. Agent-Native Infrastructure
- See `design/WORKER_NATIVE.md` for vision document
- **Not part of 5-month timeline** - design must be extensible toward this

Core challenges (from A16Z analysis):
- Recursive fan-out: Single agent goal → 5,000+ sub-tasks
- Thundering herd as default state
- Traffic patterns that "look like DDoS" to legacy systems
- Coordination bottleneck: routing, locking, state management

Future components:
- **Task Graph Engine**: DAG-based task submission, not individual requests
- **Coordination Service**: Distributed locks, barriers, shared state
- **Agent Identity Layer**: Distinguish agent vs human traffic for rate limiting
- **Priority Scheduler**: SLA tiers, preemption, deadline-aware
- **Agent Sandbox**: Isolated environments for root agents with security controls
- **Speculative Pre-warming**: Predict agent behavior, pre-warm capacity

**Current design extensibility checklist** (validate during Phases 1-5):
- [ ] Data models support hierarchical task relationships
- [ ] Scheduler weights configurable at runtime
- [ ] Rate limit policies selectable per-request
- [ ] Controllers can be added without modifying core
- [ ] Agent module supports sandbox enforcement

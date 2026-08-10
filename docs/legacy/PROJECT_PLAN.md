> **LEGACY**: This is a historical planning document from before the current `core/` implementation. For current state and roadmap, see [`docs/STATUS.md`](../STATUS.md) and [`docs/FINDINGS_AND_ISSUES.md`](../FINDINGS_AND_ISSUES.md).

# Hivemind Project Plan

**Timeline**: 5 months (20 weeks)
**Start Date**: TBD
**Target Completion**: TBD + 5 months

## Overview

This document outlines the project structure for migrating from the current EKS/Knative/Lambda architecture to the Hivemind platform. Use this as a template for creating milestones and issues in Linear.

---

## Project Structure

```
Hivemind Migration
├── Phase 1: Router (Weeks 1-4)
├── Phase 2: Honeycomb (Weeks 3-8)
├── Phase 3: Beekeeper (Weeks 6-12)
├── Phase 4: Control Plane (Weeks 10-18)
└── Phase 5: Node Agent (Weeks 14-20)
```

**Note**: Phases overlap intentionally to parallelize work where dependencies allow.

---

## Phase 1: Router

**Duration**: Weeks 1-4
**Owner**: TBD
**Dependencies**: None

### Milestone 1.1: Router Core (Week 1-2)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Set up router Go project structure | P0 | 2d | `infrastructure`, `setup` |
| Implement HTTP request handling | P0 | 3d | `core`, `networking` |
| Implement WebSocket proxying | P0 | 2d | `core`, `networking` |
| Implement SSE streaming support | P1 | 1d | `core`, `networking` |
| Add request routing logic (app ID extraction) | P0 | 2d | `core` |
| Implement connection pooling to backends | P0 | 2d | `core`, `performance` |
| Write unit tests for request handling | P1 | 2d | `testing` |

### Milestone 1.2: Authentication & Rate Limiting (Week 2-3)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Integrate Turso for auth lookups | P0 | 2d | `auth`, `database` |
| Implement JWT validation | P0 | 2d | `auth`, `security` |
| Implement API key validation | P0 | 1d | `auth`, `security` |
| Add auth caching layer | P1 | 1d | `auth`, `performance` |
| Implement token bucket rate limiter | P0 | 2d | `rate-limiting` |
| Add per-project rate limit configuration | P1 | 1d | `rate-limiting` |
| Write integration tests for auth flow | P1 | 2d | `testing` |

### Milestone 1.3: Queue & Backpressure (Week 3)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement per-app request queue | P0 | 2d | `core`, `queueing` |
| Add queue depth monitoring | P0 | 1d | `observability` |
| Implement backpressure signals | P1 | 2d | `core` |
| Add request timeout handling | P0 | 1d | `core` |
| Implement graceful request draining | P1 | 1d | `core` |

### Milestone 1.4: Observability & Deployment (Week 4)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Add Prometheus metrics | P0 | 2d | `observability` |
| Add OpenTelemetry tracing | P1 | 2d | `observability` |
| Create Grafana dashboards | P1 | 1d | `observability` |
| Write Terraform for router deployment | P0 | 2d | `infrastructure` |
| Create Helm chart | P1 | 1d | `infrastructure` |
| Deploy to staging environment | P0 | 1d | `deployment` |
| Run load tests | P0 | 2d | `testing`, `performance` |
| Document router API and configuration | P1 | 1d | `documentation` |

### Phase 1 Deliverables

- [ ] Router binary handling 10k+ RPS
- [ ] WebSocket and SSE proxying working
- [ ] Auth integration with Turso
- [ ] Rate limiting functional
- [ ] Deployed to staging
- [ ] Load test results documented

---

## Phase 2: Honeycomb

**Duration**: Weeks 3-8
**Owner**: TBD
**Dependencies**: None (can start parallel to Phase 1)

### Milestone 2.1: Origin Registry (Week 3-4)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Set up Honeycomb Go project structure | P0 | 1d | `infrastructure`, `setup` |
| Implement OCI Distribution API (v2) | P0 | 4d | `core`, `registry` |
| Implement manifest storage in Turso | P0 | 2d | `core`, `database` |
| Implement blob storage in S3 | P0 | 2d | `core`, `storage` |
| Add content-addressable blob deduplication | P1 | 1d | `core`, `storage` |
| Implement tag management | P0 | 1d | `core`, `registry` |
| Add registry authentication (htpasswd) | P0 | 2d | `auth`, `security` |
| Write OCI compliance tests | P1 | 2d | `testing` |

### Milestone 2.2: Regional Cache (Week 5-6)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement regional cache service | P0 | 3d | `core`, `caching` |
| Integrate JuiceFS as cache backend | P0 | 2d | `storage`, `integration` |
| Implement cache eviction policy (LRU + priority) | P0 | 2d | `core`, `caching` |
| Add origin fallback logic | P0 | 1d | `core` |
| Implement peer cache discovery | P1 | 2d | `core`, `networking` |
| Add cache hit/miss metrics | P0 | 1d | `observability` |
| Write cache integration tests | P1 | 2d | `testing` |

### Milestone 2.3: P2P Agent (Week 6-7)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement P2P agent daemon | P0 | 3d | `core`, `p2p` |
| Add content gossip protocol | P0 | 2d | `core`, `networking` |
| Implement BitTorrent-style chunk transfer | P1 | 3d | `core`, `p2p` |
| Add local SSD cache management | P0 | 2d | `storage` |
| Implement peer discovery via gossip | P0 | 2d | `networking` |
| Add P2P transfer metrics | P1 | 1d | `observability` |

### Milestone 2.4: Nydus & Warmup (Week 7-8)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement Nydus backend for Honeycomb | P1 | 3d | `integration`, `nydus` |
| Add image conversion pipeline (OCI → Nydus) | P2 | 2d | `integration`, `nydus` |
| Implement warmup service | P0 | 2d | `core`, `warming` |
| Add pre-positioning API for Hivemind | P0 | 1d | `api` |
| Implement cross-region sync protocol | P1 | 3d | `core`, `replication` |
| Deploy Honeycomb to staging | P0 | 2d | `deployment` |
| Run pull latency benchmarks | P0 | 1d | `testing`, `performance` |

### Phase 2 Deliverables

- [ ] OCI-compliant registry API
- [ ] Regional cache with JuiceFS backend
- [ ] P2P agent for node-level distribution
- [ ] Warmup service for proactive caching
- [ ] Cross-region sync working
- [ ] Sub-second pulls for cached content

---

## Phase 3: Beekeeper

**Duration**: Weeks 6-12
**Owner**: TBD
**Dependencies**: Phase 2 Milestone 2.1 (Origin Registry)

### Milestone 3.1: Build Infrastructure (Week 6-7)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Set up Beekeeper Go project structure | P0 | 1d | `infrastructure`, `setup` |
| Deploy BuildKit instances | P0 | 2d | `infrastructure` |
| Implement builder pool management | P0 | 3d | `core` |
| Add builder health checks | P0 | 1d | `core`, `health` |
| Implement build queue (SQS) | P0 | 2d | `core`, `queueing` |
| Create builder node Terraform | P0 | 2d | `infrastructure` |

### Milestone 3.2: Build Execution (Week 8-9)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement build executor (BuildKit client) | P0 | 3d | `core`, `builds` |
| Add Dockerfile generator from app.toml | P0 | 3d | `core`, `builds` |
| Implement custom Dockerfile support | P0 | 1d | `core`, `builds` |
| Add build argument injection | P0 | 1d | `core` |
| Implement Nydus compression option | P1 | 2d | `builds`, `nydus` |
| Add build cancellation support | P1 | 1d | `core` |

### Milestone 3.3: Caching & Optimization (Week 9-10)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement S3 layer cache | P0 | 2d | `caching`, `performance` |
| Add per-project cache namespacing | P0 | 1d | `caching` |
| Implement global cache for common layers | P1 | 2d | `caching`, `performance` |
| Add cache affinity for builder selection | P1 | 2d | `performance` |
| Optimize Dockerfile layer ordering | P1 | 1d | `performance` |
| Add dependency deduplication analysis | P2 | 2d | `performance` |

### Milestone 3.4: Integration & Deployment (Week 11-12)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement log streaming to ClickHouse | P0 | 2d | `logging`, `integration` |
| Add WebSocket log streaming for clients | P0 | 2d | `logging` |
| Integrate with Honeycomb for image push | P0 | 2d | `integration` |
| Implement build status API | P0 | 1d | `api` |
| Add build metrics (duration, cache rate) | P0 | 1d | `observability` |
| Deploy Beekeeper to staging | P0 | 2d | `deployment` |
| Run parallel build load tests | P0 | 2d | `testing`, `performance` |
| Create migration plan from Depot | P1 | 1d | `documentation`, `migration` |

### Phase 3 Deliverables

- [ ] BuildKit-based build system
- [ ] Distributed S3 layer cache
- [ ] Log streaming working
- [ ] Honeycomb integration for image push
- [ ] Build times comparable to Depot
- [ ] Ready for canary migration from Depot

---

## Phase 4: Hivemind Control Plane

**Duration**: Weeks 10-18
**Owner**: TBD
**Dependencies**: Phase 1 (Router), Phase 2 (Honeycomb)

### Milestone 4.1: API Wrapper (Week 10-11)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Set up Hivemind API project structure | P0 | 1d | `infrastructure`, `setup` |
| Define Workload API types | P0 | 2d | `api`, `design` |
| Implement API endpoints (CRUD) | P0 | 3d | `api`, `core` |
| Add Lambda API pass-through adapter | P0 | 2d | `integration`, `migration` |
| Implement workload store (Turso) | P0 | 2d | `database` |
| Add API authentication | P0 | 1d | `auth`, `security` |
| Update CLI to use Hivemind API | P0 | 2d | `cli`, `integration` |
| Write API integration tests | P1 | 2d | `testing` |

### Milestone 4.2: Direct K8s Management (Week 12-14)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement Knative cluster adapter | P0 | 3d | `core`, `kubernetes` |
| Add multi-cluster kubeconfig management | P0 | 2d | `infrastructure` |
| Implement workload state machine | P0 | 3d | `core` |
| Add Knative service creation/update | P0 | 2d | `kubernetes` |
| Implement service deletion and cleanup | P0 | 1d | `kubernetes` |
| Add deployment status tracking | P0 | 2d | `core` |
| Implement rollout management | P1 | 2d | `core` |
| Deprecate Lambda deploy path | P1 | 1d | `migration` |

### Milestone 4.3: Cross-Cluster Scheduler (Week 14-16)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement scheduler framework | P0 | 2d | `core`, `scheduler` |
| Add cluster capacity tracking | P0 | 2d | `scheduler` |
| Implement data locality scoring (Honeycomb) | P0 | 2d | `scheduler`, `integration` |
| Add queue depth scoring (Router) | P0 | 2d | `scheduler`, `integration` |
| Implement GPU availability checking | P0 | 1d | `scheduler` |
| Add bin packing optimization | P1 | 2d | `scheduler`, `performance` |
| Implement placement constraints | P1 | 1d | `scheduler` |
| Add scheduler metrics and tracing | P0 | 1d | `observability` |

### Milestone 4.4: Custom Autoscaler (Week 16-18)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement autoscaler framework | P0 | 2d | `core`, `autoscaling` |
| Add queue depth-driven scaling | P0 | 3d | `autoscaling` |
| Implement scale-to-zero logic | P0 | 2d | `autoscaling` |
| Add scale-down delay and stabilization | P0 | 1d | `autoscaling` |
| Implement router ↔ control plane signals | P0 | 2d | `integration` |
| Add scaling buffer configuration | P1 | 1d | `autoscaling` |
| Implement direct pod adapter (replace Knative) | P1 | 4d | `core`, `kubernetes` |
| Add autoscaler metrics | P0 | 1d | `observability` |
| Deploy control plane to staging | P0 | 2d | `deployment` |
| Run end-to-end scaling tests | P0 | 2d | `testing` |

### Phase 4 Deliverables

- [ ] Unified Hivemind API
- [ ] Direct Kubernetes management (bypass Lambda)
- [ ] Cross-cluster scheduler with data locality
- [ ] Queue depth-driven autoscaling
- [ ] CLI updated to use Hivemind API
- [ ] Ready to deprecate Knative KPA

---

## Phase 5: Node Agent

**Duration**: Weeks 14-20
**Owner**: TBD
**Dependencies**: Phase 4 Milestone 4.1 (basic control plane)

### Milestone 5.1: Agent Core (Week 14-15)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Set up agent Go project structure | P0 | 1d | `infrastructure`, `setup` |
| Implement agent core framework | P0 | 2d | `core` |
| Add module registration system | P0 | 1d | `core` |
| Implement control plane connection | P0 | 2d | `core`, `networking` |
| Add health monitoring and reporting | P0 | 1d | `health` |
| Create systemd service definition | P0 | 1d | `infrastructure` |
| Implement configuration loading | P0 | 1d | `core` |

### Milestone 5.2: Metrics Module (Week 15-16)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement node metrics collector | P0 | 2d | `metrics` |
| Add GPU metrics via NVML | P0 | 2d | `metrics`, `gpu` |
| Implement Prometheus exporter | P0 | 1d | `metrics` |
| Add process metrics (optional) | P2 | 1d | `metrics` |
| Run parity tests vs node_exporter | P0 | 1d | `testing` |
| Run parity tests vs DCGM exporter | P0 | 1d | `testing` |

### Milestone 5.3: Logs Module (Week 16-17)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement container log tailer | P0 | 2d | `logging` |
| Add Kubernetes metadata enrichment | P0 | 2d | `logging` |
| Implement ClickHouse output | P0 | 2d | `logging`, `integration` |
| Implement Redpanda output | P0 | 2d | `logging`, `integration` |
| Add log filtering and processing | P1 | 1d | `logging` |
| Run log parity tests vs Fluent Bit | P0 | 2d | `testing` |

### Milestone 5.4: P2P & Storage Modules (Week 17-18)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Integrate P2P module from Honeycomb | P0 | 2d | `p2p`, `integration` |
| Implement storage module (JuiceFS) | P0 | 3d | `storage` |
| Add mount/unmount operations | P0 | 1d | `storage` |
| Implement cache management | P1 | 1d | `storage` |
| Test storage parity vs JuiceFS CSI | P0 | 1d | `testing` |

### Milestone 5.5: GPU Module (Week 18-19)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Implement GPU discovery via NVML | P0 | 2d | `gpu` |
| Add Kubernetes device plugin interface | P0 | 3d | `gpu`, `kubernetes` |
| Implement GPU allocator | P0 | 2d | `gpu` |
| Add MIG support (if needed) | P2 | 2d | `gpu` |
| Test GPU allocation vs NVIDIA plugin | P0 | 2d | `testing` |

### Milestone 5.6: AMI & Deployment (Week 19-20)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Create AMI build script | P0 | 2d | `infrastructure` |
| Build and test AMI | P0 | 1d | `infrastructure`, `testing` |
| Create agent deployment Terraform | P0 | 2d | `infrastructure` |
| Document rollback procedures | P0 | 1d | `documentation` |
| Deploy agent to staging nodes | P0 | 1d | `deployment` |
| Run full integration tests | P0 | 2d | `testing` |
| Create migration runbook | P1 | 1d | `documentation` |

### Phase 5 Deliverables

- [ ] Single agent binary with all modules
- [ ] Metrics parity with node_exporter + DCGM
- [ ] Log parity with Fluent Bit
- [ ] GPU allocation working
- [ ] AMI ready for production
- [ ] DaemonSets ready to disable

---

## Cross-Cutting Concerns

### Documentation (Ongoing)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Write architecture overview | P1 | 2d | `documentation` |
| Create runbooks for each component | P1 | 3d | `documentation`, `operations` |
| Document API references | P1 | 2d | `documentation`, `api` |
| Write troubleshooting guides | P2 | 2d | `documentation`, `operations` |
| Create onboarding guide for team | P2 | 1d | `documentation` |

### Testing Infrastructure (Week 2-4)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Set up staging environment | P0 | 3d | `infrastructure`, `testing` |
| Create integration test framework | P0 | 2d | `testing` |
| Set up load testing infrastructure | P1 | 2d | `testing`, `performance` |
| Create CI/CD pipelines | P0 | 2d | `infrastructure`, `ci-cd` |
| Set up test data generators | P1 | 1d | `testing` |

### Observability (Ongoing)

| Task | Priority | Estimate | Labels |
|------|----------|----------|--------|
| Create unified Grafana dashboards | P1 | 3d | `observability` |
| Set up alerting rules | P1 | 2d | `observability`, `operations` |
| Configure distributed tracing | P1 | 2d | `observability` |
| Create SLO definitions | P2 | 1d | `observability` |

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| BuildKit performance differs from Depot | High | Medium | Early benchmarking, fallback to Depot |
| Cross-cluster scheduling complexity | Medium | Medium | Start with single-cluster, add multi later |
| GPU module breaks workloads | High | Low | Extensive testing, gradual rollout |
| Log completeness issues | Medium | Medium | Run parallel with Fluent Bit, compare counts |
| Timeline slippage | Medium | Medium | Prioritize P0 tasks, defer P2 items |

---

## Success Criteria

### Phase 1 (Router)
- [ ] Handles 10k RPS with <10ms p99 latency added
- [ ] WebSocket connections stable for 24+ hours
- [ ] Zero auth-related incidents in staging

### Phase 2 (Honeycomb)
- [ ] Cached image pull <500ms
- [ ] Cross-region sync lag <30s
- [ ] P2P reduces origin egress by 50%+

### Phase 3 (Beekeeper)
- [ ] Build times within 10% of Depot
- [ ] Cache hit rate >60% for repeat builds
- [ ] Zero build failures due to infrastructure

### Phase 4 (Control Plane)
- [ ] Scale-up latency <5s from demand signal
- [ ] Cross-cluster placement working for 3+ clusters
- [ ] Zero workload disruption during migration

### Phase 5 (Node Agent)
- [ ] Node bootstrap time reduced by 50%
- [ ] Metrics/logs parity >99%
- [ ] GPU allocation success rate >99.9%

---

## Team Allocation Suggestion

| Role | Phase 1 | Phase 2 | Phase 3 | Phase 4 | Phase 5 |
|------|---------|---------|---------|---------|---------|
| Engineer A | Lead | Support | - | Support | - |
| Engineer B | Support | Lead | Support | - | - |
| Engineer C | - | Support | Lead | - | Support |
| Engineer D | - | - | Support | Lead | Support |
| Engineer E | - | - | - | Support | Lead |

---

## Linear Project Structure

### Recommended Linear Setup

**Project**: Hivemind Migration

**Teams/Labels**:
- `router`
- `honeycomb`
- `beekeeper`
- `control-plane`
- `node-agent`
- `infrastructure`
- `testing`
- `documentation`

**Priority Labels**:
- `P0` - Must have for phase completion
- `P1` - Should have, important for production readiness
- `P2` - Nice to have, can defer

**Cycles** (2-week sprints):
- Cycle 1-2: Phase 1 (Router)
- Cycle 2-4: Phase 2 (Honeycomb)
- Cycle 3-6: Phase 3 (Beekeeper)
- Cycle 5-9: Phase 4 (Control Plane)
- Cycle 7-10: Phase 5 (Node Agent)

**Milestones**: Map to the milestones defined above (1.1, 1.2, 2.1, etc.)

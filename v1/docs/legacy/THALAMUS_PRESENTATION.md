# Thalamus: Inter-Cluster Router
## Presentation Summary

> **LEGACY — not Hivemind `core/` in-repo:** Presentation / narrative for the **Thalamus** inter-cluster router concept. For **Hivemind `core/`** in this repository, see **`docs/STATUS.md`**. Listed in **`docs/legacy/README.md`**.

---

## The Problem

```
TODAY:
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   api.hivemind.dev                                               │
│         │                                                        │
│         ▼                                                        │
│   ┌─────────────────┐                                           │
│   │  Cloudflare     │  ← Only ratio-based split (50/50)         │
│   │  (dumb split)   │  ← Only 2 clusters supported              │
│   └────────┬────────┘  ← No capacity awareness                  │
│            │                                                     │
│      ┌─────┴─────┐                                              │
│      ▼           ▼                                              │
│  AWS US-E    Crusoe US     AWS EU    AWS APAC    Crusoe SW      │
│    ✓            ✓            ✗          ✗           ✗           │
│                                                                  │
│   Problem: Can't add more clusters, can't route intelligently   │
└─────────────────────────────────────────────────────────────────┘
```

**Pain Points:**
- Running out of capacity in existing clusters
- Can't add new clusters (no way to route to them)
- No awareness of GPU availability, queue depth, or cost
- No failover when clusters are unhealthy

---

## The Solution: Thalamus

```
THALAMUS:
┌─────────────────────────────────────────────────────────────────┐
│                                                                  │
│   api.hivemind.dev                                               │
│         │                                                        │
│         ▼                                                        │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                    THALAMUS ROUTER                       │   │
│   │                                                          │   │
│   │  • Knows GPU availability per cluster                    │   │
│   │  • Knows queue depth per cluster                         │   │
│   │  • Knows which clusters can scale                        │   │
│   │  • Routes based on app requirements                      │   │
│   │  • Fails over automatically                              │   │
│   │                                                          │   │
│   └─────────────────────────────────────────────────────────┘   │
│            │                                                     │
│   ┌────────┼────────┬────────┬────────┐                         │
│   ▼        ▼        ▼        ▼        ▼                         │
│  AWS     Crusoe    AWS      AWS     Crusoe                      │
│  US-E    US-E      EU       APAC    US-SW     + any new cluster │
│   ✓        ✓        ✓        ✓        ✓                         │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## How It Works

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           REQUEST FLOW                                   │
│                                                                          │
│  ① User Request                                                          │
│       │                                                                  │
│       ▼                                                                  │
│  ② THALAMUS reads app requirements                                       │
│       │   • GPU type needed (H100, A100, etc)                           │
│       │   • Region constraints (EU only, etc)                           │
│       │   • Provider constraints (AWS only, etc)                        │
│       │                                                                  │
│       ▼                                                                  │
│  ③ THALAMUS reads cluster state (from Turso DB)                         │
│       │   • Available GPUs per cluster                                  │
│       │   • Queue depth per cluster                                     │
│       │   • Can cluster scale up?                                       │
│       │                                                                  │
│       ▼                                                                  │
│  ④ THALAMUS picks best cluster                                          │
│       │   • Filter: only clusters meeting requirements                  │
│       │   • Score: capacity + cost + data locality                      │
│       │                                                                  │
│       ▼                                                                  │
│  ⑤ Proxy request with failover list                                     │
│       │   X-Thalamus-Metadata: [backup clusters]                        │
│       │                                                                  │
│       ▼                                                                  │
│  ⑥ If cluster overloaded → Axon sheds to backup                         │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## State Push Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│                         ┌─────────────────┐                              │
│                         │  TURSO PRIMARY  │                              │
│                         │  (SQLite DB)    │                              │
│                         └────────┬────────┘                              │
│                                  │                                       │
│              ┌───────────────────┼───────────────────┐                   │
│              │                   │                   │                   │
│              ▼                   ▼                   ▼                   │
│      ┌──────────────┐   ┌──────────────┐   ┌──────────────┐             │
│      │ Edge Replica │   │ Edge Replica │   │ Edge Replica │             │
│      │   (US)       │   │   (EU)       │   │   (APAC)     │             │
│      └──────┬───────┘   └──────┬───────┘   └──────┬───────┘             │
│             │                  │                  │                      │
│             ▼                  ▼                  ▼                      │
│      ┌──────────────┐   ┌──────────────┐   ┌──────────────┐             │
│      │   Router     │   │   Router     │   │   Router     │             │
│      │  (reads)     │   │  (reads)     │   │  (reads)     │             │
│      └──────────────┘   └──────────────┘   └──────────────┘             │
│                                                                          │
│  ▲                                                                       │
│  │ PUSH every 10-30s                                                     │
│  │                                                                       │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────┐                 │
│  │ AWS US-East  │   │ Crusoe US    │   │ AWS EU       │  ...            │
│  │ StatePusher  │   │ StatePusher  │   │ StatePusher  │                 │
│  │              │   │              │   │              │                 │
│  │ • GPU avail  │   │ • GPU avail  │   │ • GPU avail  │                 │
│  │ • Queue depth│   │ • Queue depth│   │ • Queue depth│                 │
│  │ • Can scale? │   │ • Can scale? │   │ • Can scale? │                 │
│  └──────────────┘   └──────────────┘   └──────────────┘                 │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘

Key: Clusters PUSH state → Turso replicates → Routers READ locally (sub-ms)
```

---

## Routing Strategies

| Strategy | What It Does | Score Weight |
|----------|--------------|--------------|
| **Capacity-Weighted** | Prefer clusters with more free GPUs | High |
| **Cost-Optimized** | Prefer cheaper providers (Crusoe > AWS) | Medium |
| **Geo-Proximity** | Prefer clusters near the user | Medium |
| **Data-Locality** | Prefer clusters where image is cached | High |
| **Least-Concurrent** | Prefer clusters with shorter queues | Medium |

```
Example Decision:

App requires: H100, any region
User location: EU

Cluster         GPUs Avail   Queue   Cost    Score
─────────────────────────────────────────────────
AWS EU             8          2      $$$     0.85  ← Selected (near user, has capacity)
Crusoe US-E       12          5      $       0.72
AWS US-E           4         10      $$$     0.45
Crusoe US-SW       2          1      $       0.40
```

---

## Two-Tier Failover

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   TIER 1: Router Failover (based on 30s-stale state)                    │
│   ─────────────────────────────────────────────────────                 │
│                                                                          │
│   Request → Thalamus picks Cluster A                                    │
│                    │                                                     │
│                    ▼                                                     │
│             Cluster A returns 503?                                       │
│                    │                                                     │
│              YES   │   NO                                               │
│                ▼   │    └──→ Success ✓                                  │
│         Retry Cluster B                                                  │
│                                                                          │
│   TIER 2: Axon Load Shedding (real-time)                                │
│   ─────────────────────────────────────────                             │
│                                                                          │
│   Request arrives at Cluster A with header:                             │
│   X-Thalamus-Metadata: {alternatives: [B, C, D]}                        │
│                    │                                                     │
│                    ▼                                                     │
│         Axon: Can I process this?                                        │
│                    │                                                     │
│              NO    │   YES                                              │
│               ▼    │    └──→ Process locally ✓                          │
│         Forward to Cluster B                                             │
│         (remove self from alternatives)                                  │
│                                                                          │
│   Why both? Router state is 30s stale. Axon knows real-time state.      │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Deployment Options

```
OPTION A: Cloudflare Workers (Simple)              OPTION B: Go Service (Flexible)
─────────────────────────────────                  ─────────────────────────────────

┌─────────────────────────────┐                    ┌─────────────────────────────┐
│       CLOUDFLARE            │                    │       CLOUDFLARE            │
│                             │                    │   (DNS + DDoS only)         │
│  ┌───────────────────────┐  │                    └──────────────┬──────────────┘
│  │  Worker (TypeScript)  │  │                                   │
│  │                       │  │                    ┌──────────────┼──────────────┐
│  │  • Turso via HTTP     │  │                    ▼              ▼              ▼
│  │  • Runs at edge       │  │                 ┌──────┐      ┌──────┐      ┌──────┐
│  │  • 50ms CPU limit     │  │                 │Router│      │Router│      │Router│
│  └───────────────────────┘  │                 │ (US) │      │ (EU) │      │(APAC)│
│                             │                 │      │      │      │      │      │
└─────────────────────────────┘                 │Turso │      │Turso │      │Turso │
                                                │embed │      │embed │      │embed │
Pros: No infra, global                          └──────┘      └──────┘      └──────┘
Cons: 50ms limit, debugging

                                                Pros: Sub-ms reads, full control
                                                Cons: More infra to manage
```

**Go Service Deployment Options:**

| Option | Best For | Notes |
|--------|----------|-------|
| **Fly.io** | Speed | 30+ regions, native Turso, ~$5-10/region |
| **Bunny.net** | Scale | 100+ PoPs, pay-per-request |
| **In-cluster K8s** | Cost | Uses existing infra |
| **Dedicated VMs** | Isolation | Router independent of clusters |

---

## 10-Week Timeline

```
Week 1-2          Week 3-4          Week 5-6          Week 7-8          Week 9-10
────────────────────────────────────────────────────────────────────────────────────

┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐      ┌─────────┐
│FOUNDATION│      │STATE PUSH│      │ ROUTING │      │ AXON +  │      │MIGRATION│
│         │      │         │      │ ENGINE  │      │HARDENING│      │         │
│• Proxy  │  →   │• Pusher │  →   │• Strats │  →   │• Load   │  →   │• Shadow │
│• Turso  │      │• Metrics│      │• Filter │      │  shed   │      │• Canary │
│• Deploy │      │• 5 clust│      │• Failovr│      │• Metrics│      │• 100%   │
└─────────┘      └─────────┘      └─────────┘      └─────────┘      └─────────┘

Exit:            Exit:            Exit:            Exit:            Exit:
Requests reach   All clusters     Routes by        E2E failover     100% traffic
single cluster   push state       requirements     works            stable 48h
```

---

## Key Metrics

| What We Track | Why |
|---------------|-----|
| `thalamus_routing_decisions_total{origin, strategy}` | Which clusters get traffic, why |
| `thalamus_failovers_total{from, to, level}` | How often failover happens |
| `thalamus_origin_available_gpus{origin}` | Capacity per cluster |
| `thalamus_origin_queue_depth{origin}` | Load per cluster |
| `thalamus_request_duration_seconds` | Latency overhead |

---

## Success Criteria

| Metric | Target |
|--------|--------|
| Added latency (P50) | **< 10ms** |
| Added latency (P99) | **< 50ms** |
| Availability | **99.9%** |
| Failover time | **< 2 seconds** |
| State freshness | **< 60 seconds** |

---

## Data Distribution: Why It Must Stay In Scope

**Routing is useless if the app can't access its data where it's routed.**

```
CURRENT PROBLEM:
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   JuiceFS (us-east-1)          JuiceFS (eu-west-2)                      │
│   ┌─────────────────┐          ┌─────────────────┐                      │
│   │    AWS S3       │          │    AWS S3       │                      │
│   └────────┬────────┘          └────────┬────────┘                      │
│            │                            │                                │
│     ┌──────┴──────┐              ┌──────┴──────┐                        │
│     ▼             ▼              ▼             ▼                        │
│  AWS US-E    Crusoe US        AWS EU       AWS APAC                     │
│     ✓        ✗ Cross-         ✓            ✗ Must pull                  │
│              provider!                      from US/EU                   │
│                                                                          │
│   Problems:                                                              │
│   • Crusoe clusters pull from AWS S3 (cross-provider = slow + costly)   │
│   • APAC has no local storage (cold starts are brutal)                  │
│   • Can't route to "best" cluster if data isn't there                   │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**Why This Matters for Routing:**

| Scenario | Without Data Locality | With Data Locality |
|----------|----------------------|-------------------|
| Route to Crusoe | 30s+ cold start (pull from AWS S3) | 5s cold start (local) |
| Route to APAC | 45s+ cold start (pull from US) | 8s cold start (regional) |
| Cost optimization | Can't use cheaper Crusoe effectively | Full utilization |

**Solution: Tigris (Global Object Storage)**

```
TARGET STATE:
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│                              TIGRIS                                      │
│                    (Global Object Storage)                               │
│                                                                          │
│   ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐                │
│   │ US Edge │   │ EU Edge │   │APAC Edge│   │ + more  │                │
│   └────┬────┘   └────┬────┘   └────┬────┘   └────┬────┘                │
│        │            │             │             │                        │
│        └────────────┴──────┬──────┴─────────────┘                        │
│                            │                                             │
│                   ┌────────┴────────┐                                    │
│                   │  JuiceFS Layer  │                                    │
│                   └─────────────────┘                                    │
│                            │                                             │
│        ┌───────────────────┼───────────────────┐                        │
│        ▼                   ▼                   ▼                        │
│   All clusters        All clusters        All clusters                  │
│   read locally        read locally        read locally                  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

**Benchmark Data (JuiceFS backing store comparison):**

I tested S3, Tigris, and Bunny as JuiceFS backing stores across regions:

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

**Key Insight: Read performance is what matters for cold starts.**

| Region | S3 Small Read | Tigris Small Read | Improvement |
|--------|---------------|-------------------|-------------|
| us-east-1 | 30 IOPS | 86 IOPS | **2.9x faster** |
| eu-west-2 | 9 IOPS | 43 IOPS | **4.8x faster** |
| ap-southeast-1 | 4 IOPS | 118 IOPS | **29.5x faster** |
| us-west-2 | 11 IOPS | 33 IOPS | **3x faster** |

Tigris wins on reads globally because of edge replication. Writes are slower (replication cost), but we write once and read many times.

**Why Tigris over R2:**

| Feature | Tigris | R2 |
|---------|--------|-----|
| S3 API compatibility | Full | Partial (breaks JuiceFS gc, fsck, sync) |
| Global read perf | 3-30x faster than S3 | Not tested |
| Egress | Zero | Zero |

**Data Locality Strategy in Router:**

```
When routing, we score clusters by data availability:

Cluster has image cached?     → Score: 1.0  (fastest cold start)
Cluster in same region as S3? → Score: 0.7  (good peering)
Cluster same provider as S3?  → Score: 0.4  (okay peering)
No data locality?             → Score: 0.0  (no bonus)
```

**Bottom Line:** Smart routing + dumb storage = still slow cold starts. We need both.

---

## What We're NOT Doing (in 10 weeks)

| Keep As-Is | Why |
|------------|-----|
| Knative | Works fine for intra-cluster scaling |
| Container Registry | No need to replace |
| Depot (builds) | Works fine |
| DaemonSets | No need for custom agent yet |

**Scope = Routing only.** Everything else stays.

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| State model | **Push to Turso** | Sub-ms reads, no admin worker needed |
| State store | **Turso** | Edge-replicated SQLite, simple |
| Implementation | **Go (Fly.io)** or **Workers** | TBD based on team preference |
| Failover | **Two-tier** | Router retry + Axon load shed |

---

## Next Steps

1. **Set up Turso** - Create DB, test replication latency
2. **Build state pusher PoC** - One cluster pushing metrics
3. **Choose: Workers vs Go** - Team decision
4. **Scope Axon changes** - What's needed for X-Thalamus-Metadata
5. **Start Week 1** - Basic proxy infrastructure

---

## Questions?

**Full technical details:** `docs/legacy/THALAMUS.md`

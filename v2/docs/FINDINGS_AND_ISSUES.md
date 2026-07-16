# Findings and issues tracker

*Created to consolidate production gaps, design review items, and actionable backlog. Update this file as items land or priorities shift.*

## Sources

| Source | What it captures |
|--------|------------------|
| `docs/STATUS.md` | Implemented features, test counts, **What's Missing**, roadmap phases A–D, bugs already fixed |
| `docs/frozen/REVIEW.md` | Frozen cross-phase review context (failure modes, observability, security model, testing, cost, cache lifecycle) |
| `docs/frozen/TODO_DISCUSSIONS.md` | Frozen design-thread history; active backlog belongs in this file |
| `CLAUDE.md` | High-level project context and file map |

## Production gaps (from STATUS)

### Critical — blocks production use

| # | Item | Notes |
|---|------|--------|
| C1 | TLS/mTLS | Plaintext on client, agent, peer, gossip paths |
| C2 | Authentication | API and agent connections previously had no auth |
| C3 | Provider adapter | Nodes are manual / out-of-band |
| C4 | App spec model | CreateDeployment is minimal vs probes, scaling policy, env, storage |
| C5 | Log compaction | 256-slot circular log; long-lived clusters need compaction / snapshots |

### Important — Knative / platform parity

| # | Item | Notes |
|---|------|--------|
| I1 | Thalamus integration | Router should consume gossip for cross-region routing |
| I2 | Axon integration | CLI/SDK → Hivemind API |
| I3 | Image pull secrets | Private registry auth |
| I4 | Readiness probes | Liveness exists; readiness not tied to routing |
| I5 | Graceful agent shutdown | SIGTERM, drain in flight |
| I6 | Blue-green / canary | TrafficSplit exists; not wired to run routing |

### Nice-to-have

| # | Item |
|---|------|
| N1 | Rate limiting |
| N2 | Advanced scheduling (affinity, spread, cost) |
| N3 | Tracing / structured logging |
| N4 | Multi-cluster state transfer |

## Design review themes (from frozen REVIEW)

1. **Failure modes** — partial migration, control plane down + router queues, P2P partitions, metadata corruption runbooks.
2. **Hivemind self-observability** — scheduler quality, cross-cluster comms health, queue→scale latency, control plane SLOs.
3. **Security model** — multi-tenant isolation, secret rotation, cross-region policy, agent identity, registry auth (unified doc still TBD).
4. **Testing strategy** — autoscaler load tests, scheduler correctness proofs, chaos, staging topology, perf regression baselines.
5. **Cost attribution** — GPU hours, billing, spot/preemption, storage chargeback.
6. **Cache / GC** — layer TTL, P2P invalidation, orphaned metadata, build cache expiry.


## Hivemind-native platform direction

The next platform pass should not aim for broad Kubernetes API parity. Split work into:

1. **Kubernetes parity gaps** needed by real workloads: JuiceFS/storage, env/secrets, image pull auth, logging, security/isolation, autoscaling, provider automation, Argo/GitOps integration, and operator workflows.
2. **Hivemind-native semantics** that Kubernetes does not model cleanly for fast serving: rich pod lifecycle states, readiness separate from routability, revisions as first-class objects, availability-preserving rollouts, durable event-driven state propagation, queue-proxy/activator equivalents, Thalamus ingress routing, and cert provisioning integration.

Canonical design direction: `docs/design/HIVEMIND_NATIVE_PLATFORM.md`.
POC v2 acceptance gate: `docs/POC_V2_ACCEPTANCE.md`.

Immediate implications:
- `running` must not imply `routable`; routing should require lifecycle `running`, readiness `ready`, routability `routable`, healthy node, and non-zero revision route weight.
- rollout logic should keep old revision traffic until the new revision has enough routable capacity.
- rollback should be a route decision first, then a drain/cleanup decision.
- state changes should be emitted as durable/user-facing events, not only observed by polling logs.
- queue depth and concurrency should be measured near the request path, via a Hivemind queue-proxy/forwarder concept, before implementing a production autoscaler.

Simulation requirement:
- revision/routing/rollout/routability semantics need Zig VOPR coverage; worker readiness/routability transitions need Rust worker simulation coverage.

## Pending discussions checklist (folded from frozen TODO_DISCUSSIONS)

- [ ] VRR state machine: command set, schema, read vs write paths, compaction strategy
- [ ] Security model (detailed)
- [ ] Observability strategy (alerts vs pages, dashboards)
- [ ] Testing & validation (DST harness details, chaos, integration env)
- [ ] Cost attribution model
- [ ] Cache & storage lifecycle policies
- [ ] Scheduler scoring weights and tuning
- [ ] Autoscaler default thresholds and hysteresis
- [ ] Workload types (`docs/frozen/design/WORKLOAD_TYPES.md`) — jobs/cron, instances, timed instances

## In-cluster HTTP naming (Hivemind + agents)

This repo’s operational surface is the **Hivemind replica** (Zig), the **Go API gateway** (`api/`), and the **`hivemind-agent`** (Rust). We are **not** trying to mirror Knative queue-proxy paths like `/forward/metrics`, `/forward/debug`, or `/forward/state`.

**Keep / standardise**

- **Prometheus:** keep plain **`/metrics`** on components that already expose scrape text (replica and agent per `docs/STATUS.md`). That convention is widely understood and belongs on the hot path.
- **Gateway:** keep **`GET /v1/health`** (and future readiness) as small JSON for orchestrators.

**Avoid vague “forward/*”**

- Do not introduce opaque **`/forward/...`** prefixes on the gateway for “misc” traffic.

**If/when we add introspection beyond health**

- Prefer **resource-shaped** routes, e.g. **`GET /v1/deployments`**, **`GET /v1/nodes`**, **`GET /v1/capacity`** (names illustrative), rather than a catch-all **`/state`** blob.
- For operator-only dumps (debug), use an explicit prefix such as **`/v1/internal/...`** or **`/v1/observability/...`**, require auth, and document retention/redaction—rather than a hollow **`/debug`**.

## Codebase notes (quick grep / hygiene)

| Location | Note |
|----------|------|
| `docs/legacy/Edge Routing.md` | **Legacy** (not `core/` in-repo): edge/Thalamus sketch; see top banner + `docs/legacy/README.md` |
| `v1/` | Removed old implementation; `core/` is now the only Zig control-plane implementation in-tree |
| `hivemind/` | Removed zero-byte skeleton files |
| `honeybee/` | Removed inactive prototype component |

## Recently completed (context)

- VOPR gossip simulation; unit tests for gossip, S3 backup, metrics
- Cross-region UDP gossip; S3 journal backup; GPU + ctr timeouts (see git history)

## In progress / landed in repo (update as you go)

| Item | Status |
|------|--------|
| Optional API gateway token (`HIVEMIND_API_TOKEN` + `Authorization: Bearer`) | Landed — see `api/main.go`; `GET /v1/health` stays unauthenticated when token is set (load balancer / probe friendly). Trailing slashes are stripped before auth so `/v1/health/` matches the health exemption. |
| Agent SIGTERM drain (`I5` slice) | Landed — `Agent::shutdown` now unmounts JuiceFS, uses 30s default stop grace (or pod `grace_period_ms`), calls `remove_pod` after stop for container cleanup, avoids duplicate GPU decrements / status spam for already-terminal pods; see `agent/src/agent.rs` |
| Image pull credentials (`I3` slice) | Landed — `CreateDeployment` wire extension (optional 449 bytes after the 398-byte base) carries `image_pull_registry`, `image_pull_username`, `image_pull_password`, `image_pull_password_is_secret`; replica appends StartPod trailer (`0x01` + fields); agent resolves secret-named passwords via Doppler like env vars and passes `ctr images pull --user user:pass` in `containerd` runtime. JSON fields on `POST /v1/deployments`: `image_pull_registry`, `image_pull_username`, `image_pull_password`, `image_pull_password_is_secret`. |
| Reconnecting nodes / agents | Landed — `handleRegisterNode` dedupes by active hostname (returns existing `node_id`); `AgentConnection.register_seq` makes each agent (re)registration a fresh VRR `request_id`; `Replica.onAgentDisconnect` + `ConnectionManager` reuse agent TCP slots and sync disconnect; Rust agent calls `on_connection_lost()` so `NodeRegister` is resent after TCP loss. |
| Simulation coverage for this session | Landed — Zig: `state_machine` tests for hostname dedupe + image-pull fields; VOPR tests for simulated agent reconnect + deployment image-pull retention; `TestCluster.request` now works for single-replica clusters; `disconnectSimAgent` + `getAgentNodeId` sync in harness. Rust: `protocol` trailer test (existing), `sim::runtime` pull with `ImagePullAuth`, `Agent::on_connection_lost` unit test. |
| Real-node agent fingerprinting | Landed — `agent run` now fingerprints host CPU/memory/GPU and registers real inventory instead of fake `8000m/16Gi/0 GPU` defaults; falls back to conservative `1000m/1Gi/no GPU` only if fingerprinting fails. |
| Repo hygiene: remove mistaken `which mosh-server-…` artifact | Remove from tree if present |

## External integration notes

### `../ubuntu-ami` integration notes (read-only survey)

Observed in `../ubuntu-ami`:
- `containerd` socket path matches Hivemind default: `/run/containerd/containerd.sock`
- runtime names align with agent expectations: `runc` uses `io.containerd.runc.v2`, GPU runtime binary is `/usr/bin/nvidia-container-runtime`
- CRI image snapshotter default is `nydus`
- registry configuration uses `/etc/containerd/certs.d/<registry>/hosts.toml` with optional `authorization = "Basic ..."`
- AWS CLI is installed in the AMI; useful if replicas also use that image for `aws s3 cp` backup flow

Addenda to verify before first real-node POC:
- [ ] install + manage `hivemind-agent` binary/systemd unit in the AMI or cloud-init layer (repo currently has no Hivemind integration)
- [ ] ensure `juicefs` CLI is present if Hivemind will use `juicefs_path` mounts; current survey found JuiceFS images/docs, not a host-side CLI install
- [ ] verify `ctr images pull` in our direct-`ctr` path honors the AMI's `/etc/containerd/certs.d` `hosts.toml` auth for private/ECR registries
- [ ] decide whether Hivemind should rely on AMI-level static registry auth, per-deployment pull creds, or both
- [ ] verify `nydus` snapshotter name/availability for direct `ctr` operations, not only CRI/Kubernetes flows
- [ ] confirm GPU nodes expose runtime name `nvidia` exactly as Hivemind expects
- [ ] decide whether replicas also run on this AMI; if yes, document required open ports and systemd services there too

Potential Hivemind-side addenda from that repo:
- [ ] runtime/snapshotter config should probably become explicit agent config instead of ad hoc CLI flags only
- [ ] registry auth precedence should be documented: per-deployment secret > AMI `hosts.toml` > public pull
- [ ] add a real-node smoke test against one `ubuntu-ami` CPU node and one GPU node using `ctr` directly

## Repo cleanup decisions landed

- `v2/` was renamed to `core/` because the old name encoded history, not purpose.
- `v1/`, `hivemind/`, and `honeybee/` were removed from active tree.
- Build outputs and deploy binaries remain ignored; local generated artifacts should not be committed.
- Historical/aspirational docs were moved under `docs/legacy/` or `docs/frozen/` so active truth is limited to `STATUS`, `POC_ACCEPTANCE`, `POC_CHANGELOG`, `FINDINGS_AND_ISSUES`, and `ENGINEERING`.

## Suggested execution order (next engineering passes)

Use `docs/POC_V2_ACCEPTANCE.md` as the acceptance gate before team-facing replacement claims.

1. **AppSpec v1** — env, secret refs, image pull auth, JuiceFS, probes, resources, isolation profile.
2. **Readiness/routability/revisions** — split running from routable, add immutable revisions and route weights.
3. **Rollout safety** — keep old revision routed until new revision has routable capacity; rollback route-first.
4. **Events/logs** — durable state events plus pod log retrieval without SSH.
5. **Security/isolation baseline** — auth, encrypted/authenticated component links, resource/device restrictions, explicit limitations.
6. **Queue-aware serving/autoscaling** — queue-proxy/forwarder metrics, concurrency policy, scale-to-zero activation.
7. **GitOps/integration** — declarative apply/status path and Thalamus routing integration.
8. **Compaction / snapshots** — bounded replay time at restarts.

---

*When closing an item, prefer a one-line pointer to the PR or commit in the "Landed" table rather than duplicating full spec here.*

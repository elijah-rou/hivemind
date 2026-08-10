# Remaining work & recommendations

This document complements **`WORK_COMPLETED.md`** in this directory (what was already done). Here: **gaps, backlog, and concrete recommendations** the project still needs—synthesized from `docs/STATUS.md`, `docs/FINDINGS_AND_ISSUES.md`, `docs/REVIEW.md`, `docs/TODO_DISCUSSIONS.md`, and recent direction (e.g. **core observability in Zig + Rust**, not the Go gateway).

**Canonical trackers (keep these updated as you ship):**

| Doc | Role |
|-----|------|
| `docs/STATUS.md` | What exists, ports, roadmap phases A–D |
| `docs/FINDINGS_AND_ISSUES.md` | Gaps table, naming decisions, quick codebase notes |
| `docs/REVIEW.md` | Deeper design risks & open questions |
| `docs/TODO_DISCUSSIONS.md` | Thread-level checklists (security, compaction, observability, …) |

This file is a **handoff / prioritization aid**; it will drift if not edited alongside those.

---

## 1. Critical — production blockers

| Area | What to do |
|------|------------|
| **TLS / mTLS** | Encrypt client, agent, peer, and gossip paths; cert issuance, rotation, and identity binding. |
| **Authentication** | Strong story for **API** (if you keep `api/`), **replica client port**, **agent TCP**, and **peer replication**; align with `HIVEMIND_API_TOKEN`-style patterns where already started. |
| **Provider / nodes** | Automate node lifecycle (interfaces in STATUS Phase C); until then, runbooks for manual nodes. |
| **App spec** | Evolve beyond minimal CreateDeployment: probes, scaling policy, env/storage, full Knative-parity fields (see C4 / Phase A in STATUS). |
| **Log compaction / snapshots** | 256-slot journal is not sufficient forever; periodic snapshots + compaction strategy (VRR ops, read paths) — see FINDINGS + TODO_DISCUSSIONS. |

---

## 2. Important — Knative / platform parity

| Area | What to do |
|------|------------|
| **Readiness vs liveness** | Readiness not tied to routing (I4); define semantics for workloads and for **control plane** components. |
| **TrafficSplit → run routing** | Wire canary/blue-green to actual request path (I6). |
| **Image pull secrets** | Private registry auth end-to-end (I3); STATUS already notes partial API fields—verify agent + scheduler path. |
| **Graceful shutdown** | Agent drain on SIGTERM (I5); replica graceful leave where applicable. |
| **Thalamus / Axon** | Router consumes gossip; CLI/SDK targets the right API (I1–I2) — **legacy** edge docs live under `docs/legacy/README.md`; implementation truth stays `v2/` + STATUS. |

---

## 3. Observability (recommended: **Zig replica + Rust agent**)

**Direction:** Treat **Hivemind core** observability as **Zig + Rust** surfaces. The Go `api/` gateway is optional integration glue, not the source of truth for replica/agent health.

| Item | Recommendation |
|------|----------------|
| **Prometheus** | Keep **`/metrics`**-style exposition on **replica** (`v2/src/metrics.zig`, metrics port) and **agent** (`agent/src/metrics.rs`). Extend series as needed (queue depth, scheduler decisions, agent reconnects). |
| **Probes (k8s-style)** | On the **replica metrics HTTP server** (or a dedicated tiny HTTP listener), add explicit **`GET /internal/live`** and **`GET /internal/ready`** with documented semantics (e.g. ready = `status == .normal` vs leader-only for client traffic). |
| **State / “dashboard” data** | Prefer **small JSON** on the same operator-only port, e.g. **`GET /internal/summary`**, not a vague `/state` blob—aligned with `docs/FINDINGS_AND_ISSUES.md` (*In-cluster HTTP naming*). Optionally a minimal **server-rendered HTML** page for humans (`GET /internal/dashboard`) if you want zero separate frontend. |
| **Auth** | Anything beyond `/metrics` scrape should eventually require **mTLS or token** on the operator network. |
| **Tracing / logs** | STATUS “nice-to-have”: OpenTelemetry, structured logging (Phase D). |

**Not yet implemented in code** (as of this write-up): path-based routing on the Zig metrics server and matching patterns on the agent; only the recommendation is recorded here.

---

## 4. Nice-to-have & polish

- Rate limiting (API / client port).
- Advanced scheduling (affinity, spread, cost).
- Multi-cluster state transfer.
- Chaos on real infra, perf regression baselines (`docs/REVIEW.md` themes).

---

## 5. Documentation & repo hygiene

| Item | Notes |
|------|--------|
| **Legacy index** | Expand `docs/legacy/README.md` if other files are purely historical (strategy-only, pre–`v2/`). |
| **FINDINGS “Landed” table** | When you ship items above, move rows from gaps to landed in `docs/FINDINGS_AND_ISSUES.md`. |
| **`WORK_COMPLETED.md`** | Refresh or fold into a real `CHANGELOG.md` when you want release-grade history. |

---

## 6. Toolchain

| Item | Notes |
|------|--------|
| **Zig patch** | Repo pins **`minimum_zig_version = "0.16.0"`** in `v1/build.zig.zon` and `v2/build.zig.zon`. When the team standardizes on a **newer 0.16.x patch**, bump **both** files together. |
| **Rust / Go** | Keep `agent/` and `api/` toolchains aligned with whatever CI image you use; document in `docs/STATUS.md` or a small “Developing” section if missing. |

---

## 7. Security & operations (cross-cutting)

From FINDINGS / REVIEW — turn into explicit tickets when ready:

- Multi-tenant isolation, secret rotation, agent identity, cross-region policy (single consolidated security doc still TBD).
- Failure-mode runbooks: control plane down + queued work, partitions, metadata corruption.
- Cost attribution (GPU hours, spot/preemption, storage).

---

## 8. Suggested order of attack (opinionated)

1. **TLS + auth** on agent + peer + client paths (unblocks everything else in untrusted networks).
2. **Compaction / snapshots** (unblocks long-lived clusters).
3. **Observability on Zig + Rust** (live/ready + `/internal/summary` + richer Prometheus) so you can **see** production behavior while hardening.
4. **App spec + readiness + TrafficSplit routing** (user-visible correctness).
5. **Integration** (Thalamus/Axon) and **provider automation** once one region is stable.

---

*This is a living handoff document; edit freely.*

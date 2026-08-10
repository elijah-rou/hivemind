# Work completed (assistant session log)

This file summarizes changes and decisions from recent work so you don’t have to re-derive them from chat history.

**Backlog & recommendations (not limited to completed work):** see **`WORK_REMAINING_AND_RECOMMENDED.md`** in this directory.

---

## 1. Legacy documentation (not Hivemind `v2/` in-repo)

**Goal:** Keep older design notes; label them clearly as **legacy** (not the in-repo `v2/` control plane + Rust agent).

**What landed**

- **`docs/Edge Routing.md`**
  - Top **LEGACY** banner pointing to `docs/STATUS.md`, `docs/ARCHITECTURE.md`, `docs/FINDINGS_AND_ISSUES.md`, and **`docs/legacy/README.md`**.
  - Restored the **“Edge ingestion API naming (not Knative queue-proxy)”** subsection (edge/public API naming sketch), with a pointer to **`docs/FINDINGS_AND_ISSUES.md`** for in-cluster Hivemind + agent naming.
- **`docs/THALAMUS.md`** and **`docs/THALAMUS_PRESENTATION.md`**
  - **LEGACY** banners at the top + pointers to `STATUS` / legacy index.
  - `THALAMUS.md` link to Edge Routing corrected to same-directory **`Edge%20Routing.md`** (was `../`, wrong from `docs/`).
- **`docs/legacy/README.md`** (new)
  - Index of legacy docs and explicit “**`v2/` + `STATUS.md`** win when docs disagree.”
- **`docs/FINDINGS_AND_ISSUES.md`**
  - Codebase-notes row for `Edge Routing.md` updated to **Legacy** + link to `docs/legacy/README.md`.

---

## 2. Zig **0.16.0** (stable) — toolchain + docs

**Goal:** Align the repo with **Zig 0.16.0** (no RC/dev pin in docs; `minimum_zig_version` set to the stable line).

**What landed**

- **`v2/build.zig.zon`** — `minimum_zig_version = "0.16.0"` (was `0.16.0-dev.3006+…`).
- **`v1/build.zig.zon`** — same `minimum_zig_version` bump.
- **`docs/STATUS.md`** — Zig bullet calls out **0.16.0** and `v2/build.zig.zon`.
- **`docs/ARCHITECTURE.md`** — Io / determinism wording updated from “0.15+” to **Zig 0.16** / **`Io`**.
- **`docs/ENGINEERING.md`** — Zig **0.16 `Io`**.
- **`docs/SUMMARY.md`** — **0.16’s `Io`** for DST.
- **`docs/VISION.md`** — **0.16** framing (replaces older “0.15.1” wording in that section).
- **`docs/design/ROUTER.md`** — table row **Zig 0.16 I/O**.
- **`CLAUDE.md`** — short **Toolchain:** Zig **0.16.0** + pointer to `minimum_zig_version`.

**Not done (optional follow-up)**

- Bumping to a **newer patch** (e.g. `0.16.1`) once you standardize the team on it: change `minimum_zig_version` in **both** `v1/build.zig.zon` and `v2/build.zig.zon` together.

---

## 3. Direction / clarifications (no or partial code)

- **Observability (metrics / probes / “state dashboard”)** in **Zig + Rust only** — agreed direction: do **not** treat the Go `api/` gateway as the place for core Hivemind observability. **No** `/internal/...` HTTP routes or JSON summary were added to `v2/src/metrics.zig` or `agent/src/metrics.rs` in this log’s scope; replica/agent behavior remains Prometheus-on-metrics-port as before (`docs/STATUS.md`).

---

## 4. How to use this file

- Treat it as a **human handoff**, not a release changelog.
- For **what still needs doing** (production gaps, observability plan, doc hygiene, opinionated ordering), use **`WORK_REMAINING_AND_RECOMMENDED.md`**.
- Update or delete when the information is merged into something permanent (e.g. `CHANGELOG.md`) or is no longer true.

*Last updated: session assistant write-up.*

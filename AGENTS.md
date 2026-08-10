# Hivemind v2 contributor rules

Read this file before implementation work. Read [docs/TESTING.md](docs/TESTING.md) before changing control-plane, worker, wire, E2E, or infrastructure behavior. Script operation belongs in [tests/README.md](tests/README.md); handoffs use [docs/HANDOFF.md](docs/HANDOFF.md).

## Simulation-first

Simulation is mandatory, not optional polish.

- Control-plane, replica, scheduler, gossip, recovery, liveness, and failover behavior representable in simulation requires a named Zig `core/src/vopr/` scenario.
- Worker lifecycle, runtime, registration, heartbeat, pod state, forwarding, and failure behavior representable in simulation requires a named Rust `worker/src/sim/` scenario.
- Every behavior change names its deterministic scenario, not merely a test file.
- Real-infrastructure glue still requires the nearest deterministic coverage and an explicit reason the remaining boundary cannot be simulated.

For E2E-relevant changes, state which real boundary is covered: process, socket, filesystem, kernel/containerd, GPU, or cloud. Local process evidence is not containerd or live evidence.

## Wire and evidence

Wire changes update Zig, Rust, Go API, and Go bench consumers together with the bounded canonical protocol-v6 corpus in `tests/wire/contract-v6.json`. Version agreement is compatibility validation, not peer authentication.

Record every skipped capability explicitly. This includes `--skip-containerd`, Docker-missing containerd auto-skip, `--skip-smoke`, and unavailable live execution. A skip is not a pass.

POC handoffs must include a fresh live-resource inventory and current `up`, `destroyed`, or `mixed` state. If inventory was not checked, mark current state blocked and keep any last-known state explicitly historical.

## Workflow

1. Read `docs/STATUS.md`, `docs/FINDINGS_AND_ISSUES.md`, and `docs/ENGINEERING.md`.
2. Identify control-plane, worker, wire, and real-boundary coverage.
3. Add failing deterministic coverage first where practical; implement; run focused then broader gates.
4. Update documentation when behavior, evidence, scope, or POC readiness changes.
5. For POC-facing work, update `docs/POC_CHANGELOG.md` with date, what/why, concrete acceptance progress, next actions, blockers, explicit skips, and live state.
6. Complete `docs/HANDOFF.md` without mutable totals, temporary paths, or commit hashes in this rules file.

`v1/` at repository root is frozen. Active work belongs under `v2/`.

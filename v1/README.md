# Hivemind

Deterministic workload orchestration for serverless AI/ML inference.

## Active Components

- `core/` — Zig control plane: VRR consensus, scheduler, gossip, persistence, VOPR simulation
- `worker/` — Rust node agent: containerd runtime, GPU allocation, secrets, volumes, runtime simulation
- `api/` — Go REST/dashboard gateway over the replica binary protocol
- `tests/` — local smoke/build checks
- `bench/` — benchmark tooling
- `infra/` — frozen/local-use deployment glue; do not touch cloud unless explicitly reopened

## Build

```bash
cd core && zig build
cd ../worker && cargo build
cd ../api && go build ./...
```

## Test

```bash
cd core && zig test src/unit_tests.zig
cd core && zig test src/unit_tests.zig -OReleaseFast
cd core && zig build test
cd worker && cargo test --quiet
cd api && go test ./...
```

## Source Of Truth

Read these first:

1. `docs/STATUS.md` — current implementation state
2. `docs/POC_ACCEPTANCE.md` — POC pass/fail checklist
3. `docs/POC_CHANGELOG.md` — dated POC progress
4. `docs/FINDINGS_AND_ISSUES.md` — production gaps and backlog
5. `docs/ENGINEERING.md` — engineering principles

Historical or aspirational material lives under `docs/legacy/` and `docs/frozen/`. It is not authoritative when it disagrees with `core/` or `docs/STATUS.md`.

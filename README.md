# Hivemind

Deterministic workload orchestration for serverless AI/ML inference.

## Versions

- [`v1/`](v1/) is the final POC V1 snapshot. It preserves the implementation, simulations, infrastructure tooling, and evidence at the V1 boundary.
- [`v2/`](v2/) is the current implementation and the active development line.

Both snapshots are self-contained. Run commands from the version directory you intend to use.

## Build V2

```bash
cd v2/core && zig build
cd ../worker && cargo build
cd ../api && go build ./...
```

V1 uses the same component layout under `v1/`.

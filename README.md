# Hivemind v2

Hivemind v2 is the active deterministic workload-orchestration development line. POC v1 evidence is historical and does not establish v2 parity or readiness.

## Start here

1. [Contributor rules](AGENTS.md)
2. [Testing and evidence semantics](docs/TESTING.md)
3. [Handoff contract](docs/HANDOFF.md)
4. [Executable harness catalog](tests/README.md)
5. [POC v2 acceptance gate](docs/POC_V2_ACCEPTANCE.md)
6. [Engineering principles and test boundaries](docs/ENGINEERING.md)
7. [Control-plane contract](docs/design/CONTROL_PLANE_CONTRACT.md)

The [wire fixture contract](tests/wire/README.md) is the current bounded normative protocol-v6 corpus consumed by Zig, Rust, Go API, and Go bench. The [live safety contract](tests/live/README.md) documents the prepared, fail-closed guarded entry point. Wire fixtures are deterministic compatibility evidence; the live path remains unexecuted and blocked before ownership on missing strict capabilities.

## Components

- `core/`: Zig control plane, VRR consensus, scheduler, persistence, gossip, and VOPR simulation
- `worker/`: Rust node agent, runtimes, GPU/resource accounting, secrets, volumes, and worker simulation
- `api/`: Go REST/dashboard gateway
- `bench/`: Go benchmark tooling
- `tests/`: deterministic fixtures and local/runtime harnesses
- `infra/`: deployment and benchmark tooling; live use requires separate authorization

## Build

```bash
cd core && zig build
cd ../worker && cargo build
cd ../api && go build ./...
```

## Current versus historical material

Active status and product guidance:

- [Current implementation status](docs/STATUS.md)
- [POC v2 acceptance](docs/POC_V2_ACCEPTANCE.md)
- [Findings and production gaps](docs/FINDINGS_AND_ISSUES.md)
- [Hivemind-native platform design](docs/design/HIVEMIND_NATIVE_PLATFORM.md)

Historical records, not current-head evidence:

- [POC v1 acceptance](docs/POC_ACCEPTANCE.md)
- [POC changelog](docs/POC_CHANGELOG.md)
- [`docs/frozen/`](docs/frozen/) and [`docs/legacy/`](docs/legacy/)

When prose conflicts with source or a maintained harness, source and harness behavior win. No POC v2 parity claim is made.

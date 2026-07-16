# Hivemind Project Context

## What is Hivemind?

Hivemind is a next-generation infrastructure for serverless AI/ML workloads. It replaces the current Knative-based platform with a custom control plane that can:

1. **Route requests** across multiple clusters/providers
2. **Schedule workloads** based on hardware requirements, cost, and locality
3. **Manage compute** from any provider (AWS, Crusoe, Lambda Labs, bare metal, etc.)
4. **Autoscale** based on queue depth rather than just replicas

## Current State (2026-04-23)

**Working prototype** with 5-node VRR consensus, agent pod lifecycle, HTTP API, cross-region gossip, S3 backup, clean 10k mutated core fuzz gate, and local deterministic federated selector proof inputs. See `docs/STATUS.md` for full technical details.

**Toolchain:** Zig **0.16.0** stable (`core/build.zig.zon` → `minimum_zig_version`).

### What's Built

- **VRR consensus** (Zig) - 5-node, view change, log repair, disk persistence, crash recovery
- **Agent** (Rust) - containerd via ctr CLI, GPU (nvidia runtime), secrets (Doppler), JuiceFS, Nydus, metrics
- **HTTP API** (Go) - REST gateway for deployment CRUD + run requests
- **Cross-region gossip** (Zig) - UDP capacity broadcast between regional leaders
- **S3 backup** (Zig) - periodic journal upload via forked aws s3 cp
- **VOPR simulation** - deterministic testing including gossip scenarios
- **122 Zig tests** passing in Debug and ReleaseFast
- **89 Rust tests** passing
- **10000/10000** mutated core fuzz seeds passing
- **10000/10000** mutated worker fuzz seeds passing
- **33x faster than K8s** on AWS benchmarks (p50 2.2ms vs 72.7ms)

### What's Missing for Production

Critical: TLS/mTLS, API auth, provider auto-provisioning, full app spec model, log compaction.
See `docs/STATUS.md` → "What's Missing" and "Recommended Roadmap" sections.

## Project Structure

```
core/src/           # Zig - VRR consensus, scheduler, networking, gossip
  main.zig        # CLI flags, main loop (poll → tick → dispatch → metrics → s3 → gossip)
  replica.zig     # VRR protocol handlers
  connection.zig  # Wire protocol, TCP listeners, frame I/O
  state_machine.zig # Node/deployment/pod state
  scheduler.zig   # Bin-packing pod placement
  gossip.zig      # Cross-region UDP gossip
  s3_backup.zig   # Forked journal upload
  disk.zig        # mmap'd journal persistence
  metrics.zig     # Prometheus export
  message.zig     # VRR message types, field-by-field serialization
  request_queue.zig # Leader-local run request queue
  vopr/           # VOPR simulation testing

worker/src/        # Rust - node agent
  worker.rs        # Pod orchestration, GPU alloc, secret/volume integration
  protocol.rs     # Binary protocol parsing
  runtime/
    containerd.rs # ctr CLI wrapper (pull, create, start, stop)
    process.rs    # Local process runtime (dev/test)
  secrets.rs      # Doppler API, 5min cache
  volumes.rs      # JuiceFS mount/unmount
  metrics.rs      # Agent Prometheus endpoint

api/              # Go - HTTP API gateway
  handlers.go     # REST endpoints → binary protocol
  client.go       # TCP connection management

bench/            # Go - benchmarking
  main.go         # Deploy + workload benchmarks
  k8s_bench.go    # K8s comparison benchmark

infra/            # Terraform
  bench/          # 5x c5.xlarge EC2 for benchmarking
  gpu-test/       # g4dn.xlarge for GPU/containerd tests

docs/
  STATUS.md       # CURRENT STATUS, architecture, roadmap ← START HERE
  POC_ACCEPTANCE.md # POC pass/fail checklist
  POC_CHANGELOG.md # Dated POC progress
  FINDINGS_AND_ISSUES.md # Production gaps and backlog
  ENGINEERING.md  # Engineering principles, DST patterns
  design/         # Active low-level design notes
  legacy/         # Historical routing/planning docs
  frozen/         # Aspirational/superseded docs, not authoritative
```

## Key Design Decisions

### Language Choice

- **Zig** for consensus, networking, scheduling (DST-critical)
- **Rust** for agent (containerd integration, system calls)
- **Go** for HTTP API and benchmarking tools
- Decision framework: needs DST? → Zig. System calls + containerd? → Rust. HTTP/orchestration? → Go.

### Wire Protocol

```
Client/Agent: [4B LE len][2B LE version][1B tag][payload...]
Peer (VRR):   [4B len][1B from_id][VRR payload]
PROTOCOL_VERSION = 1
```

### Pool Model (not static clusters)

Apps specify requirements (GPU type, count, optional region/provider), not clusters. Pools dynamically form from matching nodes. The current implementation truth is `docs/STATUS.md`; frozen provider-design notes live under `docs/frozen/design/`.

### Zero External Dependencies (core components only)

**Scope:** this rule applies to the **Hivemind core** (Zig VRR consensus, scheduler, networking, gossip, disk in `core/src/`) and the **worker core** (Rust agent in `worker/src/` that runs user workloads). These must have no runtime dependencies beyond the OS. No etcd, no Zookeeper, no external DB, no CDN-hosted assets. Consensus is built-in. Gossip is UDP. Backup is S3 via fork-exec.

**Out of scope:** the Go HTTP API gateway (`api/`), CLIs (`bench/`), admin dashboards, benchmarking tools, and other auxiliary surfaces. These can pull in standard web-ecosystem dependencies (CDN htmx, external libs, etc.) as needed — they are not in the fault-tolerance critical path.

### No committed build artifacts

Never commit compiled binaries (`api/api`, `api/hivemind-api`, `bench/hivemind-bench`, Rust target/, Zig zig-out/, etc.) or regenerated fuzz corpora (`core/fuzz_failures.jsonl`). Build outputs belong in `.gitignore`. If a reviewer sees a binary in a diff, that's a bug.

### VOPR-Driven Development

All features must be validated through VOPR fault injection simulation, not just unit tests. If it can go in simulation testing, it must go in simulation testing.

## When Continuing Work

1. **Read `docs/STATUS.md`** - current state, architecture, what's working, what's missing, roadmap
2. **Read `docs/FINDINGS_AND_ISSUES.md`** - production gaps and backlog
3. **Read `docs/ENGINEERING.md`** - DST patterns and code style
4. **Check git log** - recent commits show current trajectory

### Roadmap Priority Order

1. **Production hardening** - full app spec, TLS, auth, graceful shutdown, log compaction
2. **Integration** - Thalamus (router), Axon (CLI), image pull secrets, traffic splitting
3. **Provider automation** - EC2/Crusoe adapters, cost-aware scheduling
4. **Scale** - multi-region production, chaos testing, observability

## Critical Implementation Notes

- **Struct serialization**: VRR messages use field-by-field copy into zeroed buffers. Never use `std.mem.asBytes` on structs (padding UB in release builds).
- **containerd**: Use `ctr` CLI, not gRPC. tokio block_on deadlocks on tonic lazy connector.
- **Stack size**: 16MB stack in build.zig. ConnectionManager is heap-allocated (initInPlace) to avoid stack overflow.
- **VOPR clock**: 1 tick = 10ms simulated time. Keeps VRR timeouts reachable in test budgets.
- **Peer retry**: PeerTarget stores unconnected peers, retries every 2s from poll loop.
- **S3 backup**: Forks child process, SIGCHLD ignored to prevent zombies.
- **GPU pods**: Runtime set to "nvidia" when gpu_count > 0. Standard runc doesn't inject GPU devices.

## Design Extensibility

Core design should remain extensible toward agent-native workloads (Phase 6+):
- Data models support hierarchical task relationships
- Scheduler weights configurable at runtime
- Controllers addable without modifying core
- Agent modules support sandbox enforcement

See `design/WORKER_NATIVE.md` for future vision.

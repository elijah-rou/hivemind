# Worker Implementation Plan

## Language & Architecture Decision

**Rust** for the worker binary. Rationale:

1. **Deterministic simulation testing**: Go's goroutine scheduler is non-deterministic. Rust lets us own the execution model and build a DST framework matching the VOPR approach in the Zig control plane.
2. **Memory safety without GC**: No stop-the-world pauses on a node managing GPU workloads.
3. **Direct C FFI**: No cgo overhead. Cleaner type interface with the Zig control plane (both languages can share C ABI structs).
4. **Path to zero dependencies**: Long-term goal is replacing gvisor with a lighter Rust sandbox runtime. Rust makes this achievable.

## Co-Development Model

The worker and hivemind core evolve together through an iterative interface refinement loop:

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│   1. Define interface (WORKER_INTERFACE.md)               │
│         │                                               │
│         ├──► 2a. Build worker PoC (Rust)                 │
│         │         │                                     │
│         │         ▼                                     │
│         │    3a. Discover missing states/messages        │
│         │         │                                     │
│         ├──► 2b. Build protocol in hivemind (Zig)       │
│         │         │                                     │
│         │         ▼                                     │
│         │    3b. VOPR test with simulated workers         │
│         │         │                                     │
│         ▼         ▼                                     │
│   4. Adjust interface based on learnings                │
│         │                                               │
│         └──► repeat from 2a/2b                          │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

Each iteration tightens the contract. The interface spec (`docs/design/WORKER_INTERFACE.md`) is the shared truth.

## Development Phases

### Phase 1: Rust Worker PoC (validates interface)

**Goal**: Thinnest worker that can register, receive a pod assignment, run a container, and report status. Uses external dependencies (containerd, gvisor) as-is.

**Crate**: `worker/` subdirectory in the hivemind monorepo.

```
worker/
├── Cargo.toml
├── src/
│   ├── main.rs           # Entry point, CLI
│   ├── fingerprint.rs    # Hardware discovery (CPU, memory, GPU)
│   ├── runtime.rs        # Runtime trait + containerd implementation
│   ├── protocol.rs       # TCP message protocol (matches Zig serialization)
│   ├── pod.rs            # Pod state machine
│   └── probe.rs          # Health probe execution
```

**Key crates:**
| Crate | Purpose | Phase |
|-------|---------|-------|
| `containerd-client` | ttrpc client for containerd API | Phase 1 |
| `ttrpc` | Low-level containerd protocol | Phase 1 |
| `nix` | Linux syscalls (namespaces, cgroups, mounts) | Phase 1, later native |
| `nvml-wrapper` | NVIDIA GPU discovery via NVML | Phase 1 |
| `tokio` (optional) | Async runtime, only if needed for containerd client | Phase 1 |
| `serde` | Serialization for config, NOT for wire protocol | Phase 1 |
| `seccompiler` | Seccomp filter generation | Phase 3 |
| `landlock` | Landlock LSM for filesystem sandboxing | Phase 3 |
| `oci-spec` | OCI runtime spec types | Phase 2+ |

**Wire protocol**: Hand-rolled binary serialization matching the Zig message format. No serde/protobuf on the wire. Length-prefixed messages: `[4-byte len][1-byte type][payload]`. This ensures the Zig control plane and Rust worker can exchange messages without any serialization framework dependency.

**Commits:**

1. **Worker skeleton + fingerprinting**
   - `main.rs`: CLI with `fingerprint` subcommand
   - `fingerprint.rs`: read `/proc/cpuinfo`, `/proc/meminfo`, call NVML for GPUs
   - Prints `NodeFingerprint` as structured output
   - Test: runs on any Linux machine, GPU discovery optional

2. **Runtime trait + containerd backend**
   - `runtime.rs`: define `Runtime` trait:
     ```rust
     trait Runtime {
         fn pull_image(&self, image: &str) -> Result<()>;
         fn create_pod(&self, spec: &PodSpec) -> Result<PodHandle>;
         fn start_pod(&self, handle: &PodHandle) -> Result<()>;
         fn stop_pod(&self, handle: &PodHandle, grace_ms: u64) -> Result<()>;
         fn pod_status(&self, handle: &PodHandle) -> Result<PodPhase>;
     }
     ```
   - `ContainerdRuntime`: implements `Runtime` via containerd-client crate
   - GPU passthrough via NVIDIA Container Toolkit device mounts
   - Test: requires containerd running, but trait allows mock

3. **TCP protocol + control plane communication**
   - `protocol.rs`: binary message encode/decode matching Zig format
   - Worker connects to replica, sends `NodeRegister`
   - Receives `StartPod`, dispatches to runtime
   - Sends `PodStatusEvent` on state changes
   - Reconnect with backoff on disconnect

4. **Pod state machine + heartbeat + probes**
   - `pod.rs`: explicit state machine (pending -> pulling -> creating -> running -> stopped/failed)
   - Heartbeat every 5s with CPU/memory/GPU metrics
   - HTTP liveness probe (GET to configured path)
   - Batched status reporting

**Testing environment**: Deploy to a cloud VM (AWS p-series or Crusoe bare metal) with NVIDIA GPUs, containerd, and gvisor pre-installed.

### Phase 2: Deterministic Simulation Testing for Worker

**Goal**: Build a DST framework for the worker, similar to VOPR but for container lifecycle. Validate the worker under fault injection without real hardware.

**SimulatedRuntime**: Implements the `Runtime` trait with deterministic behavior:
```rust
struct SimulatedRuntime {
    prng: Prng,
    // Configurable fault injection
    image_pull_failure_rate: f32,
    container_crash_rate: f32,
    gpu_failure_rate: f32,
    start_latency_ticks: u64,
}

impl Runtime for SimulatedRuntime {
    fn pull_image(&self, image: &str) -> Result<()> {
        if self.prng.should_fail(self.image_pull_failure_rate) {
            return Err(Error::ImagePullFailed);
        }
        self.prng.sleep(self.start_latency_ticks);
        Ok(())
    }
    // ...
}
```

**SimulatedNetwork**: Matches the Zig SimulatedNetwork - configurable delays, drops, partitions. The worker and control plane exchange messages through simulated channels.

**Worker VOPR**: Deterministic simulation that:
- Runs N simulated workers + 1 hivemind replica (in-process or via message passing)
- Injects faults: image pull failures, container crashes, GPU failures, network partitions, worker crashes
- Verifies invariants: pod state consistency, no orphaned containers, GPU accounting correct
- Seed-based reproducibility

**Key design**: No `tokio` in the simulation path. The worker's event loop must be drivable by a deterministic tick function, not an async runtime. Options:
- Synchronous event loop with injectable time (like the Zig approach)
- Custom single-threaded executor with deterministic scheduling
- `mio`-based polling with simulated fd readiness

### Phase 3: Hivemind Core Worker Protocol (Zig side)

**Goal**: Add worker message handling to the Zig control plane. VOPR tests with simulated workers.

**Changes to hivemind:**

`src/message.zig`: New message types for worker protocol
```zig
// Worker -> Replica
worker_register: WorkerRegisterMsg,
worker_heartbeat: WorkerHeartbeatMsg,
worker_pod_status: WorkerPodStatusMsg,

// Replica -> Worker
worker_start_pod: WorkerStartPodMsg,
worker_stop_pod: WorkerStopPodMsg,
```

`src/consensus.zig`: Worker message handlers
- `onWorkerRegister`: submits `RegisterNode` command through consensus
- `onWorkerHeartbeat`: updates local health cache (NOT through consensus)
- `onWorkerPodStatus`: submits `UpdatePodStatus` command through consensus
- Leader sends `WorkerStartPod` when scheduler binds a pod to a node

`src/vopr.zig`: Simulated workers in the VOPR
- Each simulated node has a fake worker that responds to StartPod
- Worker reports status transitions after configurable delay
- Worker can be "crashed" (stops sending heartbeats)
- Verifies: pod states converge, GPU accounting stays consistent, scheduling decisions are correct

### Phase 4: Zero-Dependency Runtime (long-term)

**Goal**: Replace containerd+gvisor with a Rust-native container runtime.

**Layers to replace:**

1. **Image management**: Replace containerd's image service with direct OCI image pulling and layer extraction. Crates: `oci-distribution` for registry protocol, custom layer unpacking.

2. **Container creation**: Replace containerd's container service with direct Linux namespace/cgroup setup via `nix` crate. Create namespaces (mount, pid, net, user, ipc, uts), set up cgroups v2, mount rootfs from OCI layers.

3. **Sandbox isolation** (gvisor replacement): This is the hardest piece. Options:
   - **Seccomp + Landlock**: Syscall filtering + filesystem sandboxing. Lighter than gvisor but less isolation. Good for trusted workloads.
   - **User namespaces + seccomp**: Unprivileged containers with aggressive syscall filtering. Medium isolation.
   - **Rust gvisor equivalent**: Intercept syscalls via ptrace or seccomp-notify and handle them in userspace. Massive effort but maximum isolation.
   - **Pragmatic path**: Start with seccomp+landlock for most workloads, keep gvisor as an option for untrusted code. Build the isolation layer incrementally.

4. **GPU passthrough**: Direct NVIDIA device management. Mount `/dev/nvidia*` devices, set up cgroup device permissions, configure CUDA visible devices. The NVIDIA Container Toolkit does this via hooks; we can do it directly.

**This phase is 6-12 months of work** and should only start after Phases 1-3 are solid.

## Interface Evolution Checkpoints

After each phase, review and adjust the interface:

| Checkpoint | Questions to Answer |
|------------|-------------------|
| After Phase 1 PoC | What's missing from PodSpec? Volume mounts? Network config? Secrets? What error cases does containerd surface? How fast is cold start? |
| After Phase 2 DST | Does the state machine cover all transitions? What faults revealed interface gaps? Is the heartbeat interval right? |
| After Phase 3 Core | Does the VOPR with simulated workers find safety issues? Does scheduling work correctly with real worker latency? |
| After Phase 4 Runtime | Does the zero-dep runtime match containerd's behavior? Performance comparison? |

## Dependency Summary

**Phase 1 (external deps, PoC):**
- containerd (daemon on node)
- gvisor runsc (containerd shim)
- NVIDIA Container Toolkit (GPU passthrough)
- NVIDIA drivers (on GPU nodes)

**Phase 2 (simulation, no hardware needed):**
- No external deps (simulated runtime)

**Phase 3 (Zig side, no new deps):**
- Existing hivemind infrastructure

**Phase 4 (zero-dep target):**
- Linux kernel (namespaces, cgroups, seccomp, landlock)
- NVIDIA drivers (unavoidable for GPU access)
- Nothing else

## Project Structure

```
hivemind/
├── src/                    # Zig control plane
│   ├── consensus.zig
│   ├── state_machine.zig
│   ├── scheduler.zig
│   └── ...
├── worker/                  # Rust worker binary
│   ├── Cargo.toml
│   ├── src/
│   │   ├── main.rs
│   │   ├── fingerprint.rs
│   │   ├── runtime.rs      # Runtime trait
│   │   ├── runtime/
│   │   │   ├── containerd.rs   # Phase 1: containerd backend
│   │   │   ├── simulated.rs    # Phase 2: DST backend
│   │   │   └── native.rs       # Phase 4: zero-dep backend
│   │   ├── protocol.rs
│   │   ├── pod.rs
│   │   └── probe.rs
│   └── tests/
│       └── simulation.rs   # Phase 2: worker DST
└── docs/design/
    ├── WORKER_INTERFACE.md   # Shared contract
    └── WORKER_IMPLEMENTATION.md  # This document
```

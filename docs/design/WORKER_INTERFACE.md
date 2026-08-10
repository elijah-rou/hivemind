# Worker Interface Specification

## Overview

The worker is a binary running on every compute node (bare metal or VM). It manages container lifecycle via containerd+gvisor, discovers hardware capabilities, and communicates with the nearest hivemind replica.

This document defines the **contract** between the worker and the control plane. The hivemind core (Zig) and worker binary (Go) both implement their side of this contract.

## Message Protocol

Length-prefixed binary messages over TCP. Each message: `[4-byte length][1-byte type][payload]`.

### Control Plane -> Worker

| Type | Message | Description |
|------|---------|-------------|
| 0x01 | StartPod | Pull image, create container, start it |
| 0x02 | StopPod | SIGTERM -> grace period -> SIGKILL |
| 0x03 | ProbePod | Execute health probe, return result |

### Worker -> Control Plane

| Type | Message | Description |
|------|---------|-------------|
| 0x10 | NodeRegister | Announce capabilities on connect |
| 0x11 | NodeHeartbeat | Periodic health + metrics |
| 0x12 | PodStatusEvent | Pod state transition |
| 0x13 | ProbeResult | Health probe response |

## Message Payloads

### StartPod (CP -> Worker)
```
pod_id:          u64
deployment_id:   u64
image:           [256]u8    // OCI image reference
gpu_count:       u8
gpu_type:        u8         // GpuType enum
cpu_millicores:  u32
memory_megabytes: u32
```

### StopPod (CP -> Worker)
```
pod_id:          u64
grace_period_ms: u64
```

### NodeRegister (Worker -> CP)
```
hostname:        [64]u8
cpu_cores:       u32
cpu_mhz:         u32
memory_megabytes: u32
gpu_count:       u8
gpu_devices:     [8]GpuDevice
os:              [32]u8
kernel:          [32]u8
runtime:         [32]u8     // "containerd+gvisor"
provider:        [32]u8
region:          [32]u8
```

### GpuDevice
```
gpu_type:        u8
memory_megabytes: u32
device_id:       [32]u8    // "/dev/nvidia0"
driver_version:  [16]u8
```

### NodeHeartbeat (Worker -> CP)
```
timestamp:       u64
cpu_usage_pct:   u8
memory_used_mb:  u32
gpu_utilization: [8]u8     // per-device %
pods_running:    u16
```

### PodStatusEvent (Worker -> CP)
```
pod_id:          u64
old_phase:       u8         // PodPhase enum
new_phase:       u8
timestamp:       u64
exit_code:       i32
message:         [128]u8
```

## Worker Lifecycle

```
1. Worker starts on node
2. Worker fingerprints hardware (CPU, memory, GPUs)
3. Worker connects to nearest hivemind replica (TCP)
4. Worker sends NodeRegister with fingerprint
5. Control plane creates Node object via consensus (RegisterNode command)
6. Control plane scheduler may assign pods to this node
7. Worker receives StartPod for each assigned pod
8. Worker pulls image, creates gvisor container, starts it
9. Worker sends PodStatusEvent (pending -> scheduled -> running)
10. Worker sends periodic NodeHeartbeat (every 5s)
11. On shutdown: Worker sends PodStatusEvent (running -> terminating) for each pod
```

## Pod State Machine (Worker-side)

```
pending -> pulling -> creating -> running -> stopping -> stopped
                                    |                      |
                                    +-> failed             +-> failed
```

The worker is the source of truth for pod state on its node. The control plane records these transitions through consensus.

## Health Probes

Three types (matching Kubernetes model):
- **Liveness**: Is the container process alive? HTTP GET to configured path.
- **Readiness**: Can the container accept traffic? HTTP GET to configured path.
- **Startup**: Has the container finished initializing? Blocks other probes.

## Failure Modes

| Failure | Worker Behavior | Control Plane Behavior |
|---------|---------------|----------------------|
| Container crashes | Detect via containerd event, report PodStatusEvent(failed) | Scheduler may reschedule |
| Worker crashes | Containers keep running (containerd is separate) | Heartbeat timeout -> mark node suspect |
| Network partition | Worker buffers status events, retries on reconnect | Heartbeat timeout -> mark node suspect |
| GPU failure | Detect via nvidia-smi, report NodeHeartbeat with degraded capacity | Scheduler avoids this node |
| Node shutdown | Worker receives SIGTERM, stops all pods gracefully, disconnects | Heartbeat timeout -> reschedule pods |

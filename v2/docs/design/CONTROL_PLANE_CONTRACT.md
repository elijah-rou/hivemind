# Hivemind Control Plane Contract

## Core Architecture

The Router, Scheduler, and API are **co-located with VRR consensus replicas**, not external clients. Each Hivemind process runs one replica plus all application components. Components read directly from the local state machine copy (zero network latency) and only go through consensus when mutating state.

```
┌─────────────────────────────────────────────────────────┐
│                  HIVEMIND PROCESS                        │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐             │
│  │  Router   │  │ Scheduler│  │   API    │             │
│  │  reads    │  │  reads   │  │  reads   │             │
│  │ local SM  │  │ local SM │  │ local SM │             │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘             │
│       │writes       │writes       │writes              │
│       ▼             ▼             ▼                     │
│  ┌─────────────────────────────────────────────┐       │
│  │           VRR REPLICA (consensus.zig)        │       │
│  │  journal ──── state_machine ──── disk        │       │
│  └──────────────────┬──────────────────────────┘       │
│                     │ VRR protocol                       │
└─────────────────────┼───────────────────────────────────┘
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
     [Replica 1] [Replica 2] [Replica 3]  (3-5 globally)
```

## Why Co-location

**Reads are free.** The state machine is an in-memory data structure. Every committed entry is applied deterministically on every replica. Any component on that replica reads the latest committed state at memory speed. No network hop, no serialization, no staleness window.

**Only writes need consensus.** Creating a deployment, binding a pod to a node, changing a scaling target - these mutations go through VRR (leader replicates to quorum). Cross-region latency (100-300ms) only applies to writes.

**"Worst case consensus, best case local."** For latency-sensitive decisions (routing, scheduling):
- Best case: read local state machine. Zero latency. 99.9% of operations.
- Worst case: read through leader (if local state is suspected stale). One RTT.

## State Categories

### In Consensus (strongly consistent, low write rate)

| State | Writes | Examples |
|-------|--------|---------|
| Deployments | On deploy/update/delete | App config, image, resource requirements, scaling policy |
| Node registrations | On join/leave | Node capabilities (GPUs, CPU, memory, region, provider) |
| Pod bindings | On schedule/terminate | Which pod runs on which node |
| Routing rules | On deploy/scale | Which backends serve which app |
| Scaling decisions | On scale event | Target replica count changes |

Expected write rate at 1000+ nodes: ~100-1000 ops/sec. Within VRR capacity.

### Outside Consensus (eventual consistency, high frequency)

| State | Location | Update Method |
|-------|----------|--------------|
| Node health/liveness | Local cache per replica | Agent heartbeat push |
| GPU utilization metrics | Local cache per replica | Agent metrics push |
| Request queue depth | Router-local | Router tracks internally |
| Pod readiness probes | Local cache | Agent reports |

## Component Contracts

### Router

**Reads**: local state machine routing table (which app -> which pod endpoints).
**Writes**: scale events only (queue depth exceeds threshold, no requests for cooldown period).

```
routeRequest(app_id):
  backends = state_machine.getBackends(app_id)  // LOCAL
  forward(request, backends)

onQueueDepthChange(app_id, depth):
  if depth > threshold:
    submit(ScaleDeployment { app_id, target: current + 1 })  // CONSENSUS
```

### Scheduler

**Reads**: local state machine (deployments, node capacity, pod placement).
**Writes**: pod binding decisions.

```
onScaleEvent(app_id, target):
  deployment = state_machine.getDeployment(app_id)          // LOCAL
  nodes = state_machine.getNodesWithCapacity(requirements)  // LOCAL
  node = pickBestNode(nodes, deployment)                    // LOCAL
  submit(BindPodToNode { pod_id, node_id })                 // CONSENSUS
```

### API (gRPC/HTTP)

**Reads**: local state machine for queries (list deployments, get status).
**Writes**: all user-initiated mutations (create deployment, delete, update config).

### Agent (on each compute node)

**Writes to consensus**: RegisterNode (once), UpdateNodeStatus (on state change), UpdatePodStatus (lifecycle transitions).
**Writes to local cache**: health heartbeats, GPU metrics (too frequent for consensus).

## Deployment Topology

3-5 VRR replicas geographically distributed (e.g., us-east, eu-west, ap-south). Each runs the full Hivemind process. Agents connect to their nearest replica. The VRR leader handles all writes; followers serve local reads.

## State Machine Extensions Needed

Current `state_machine.zig` has nodes, deployments, pods with basic lifecycle. Needs:

1. **Routing table** - app_id -> list of backend endpoints (pod IP:port)
2. **Capacity index** - lookup: "nodes with N available GPUs of type X"
3. **Scaling state** - current vs desired replica count, cooldown timers
4. **Pool membership** - which nodes match filter criteria (region, provider, GPU type)

These are materialized views built from consensus mutations. Every replica computes them identically.

## Client and Agent Frame Validation

Client and agent streams use one frame contract in Zig core, Go API, and Rust worker:

- Outer layout is `[4B little-endian length][1B flags][body]`; length includes flags and body, not the four-byte length field.
- Flags are exactly `0x00` for plaintext or `0x01` for XChaCha20-Poly1305. Other values are invalid.
- Encryption is required if and only if that connection has a key configured. Plaintext on a keyed connection and encrypted data on an unkeyed connection are invalid.
- Plaintext body is `[2B little-endian protocol_version][1B tag][payload]`. Encrypted body is `[24B nonce][ciphertext of the same version/tag/payload body][16B authentication tag]`.
- A receiver validates the declared frame bound before slicing or allocating. A complete plaintext or decrypted body must contain at least the version and tag. `protocol_version` must equal `PROTOCOL_VERSION` before tag dispatch.
- One decode consumes exactly the declared frame. Bytes after it remain available as the next stream frame; they are not part of the current payload.

Receiver limits remain explicit per connection role: Zig connection staging is 64 KiB, Rust agent payloads are at most 16 KiB, and Go callers supply a bounded receive buffer sized for the expected response. A declaration may exactly fill its receiver's bound; larger declarations are rejected before body read/allocation.

Peer VRR frames share the exact flags, encryption-mode, and declaration-bound rules, but retain their existing unversioned body (`from_id` plus VRR payload). They do not use the client/agent version-and-tag body.

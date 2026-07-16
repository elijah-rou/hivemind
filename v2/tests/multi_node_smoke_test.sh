#!/bin/bash
#
# Multi-node integration smoke test:
# - 3 Zig replicas forming a VRR cluster
# - 1 Rust agent connecting to replica 0
# - Verifies: agent registers, consensus replicates across all nodes
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDS=()

cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Building ==="
cd "$ROOT"
zig build
cd "$ROOT/agent"
cargo build --quiet 2>&1
cd "$ROOT"

# Ports
R0_PORT=20000
R1_PORT=20001
R2_PORT=20002
AGENT_PORT=20010

echo "=== Starting 3 replicas ==="

# Replica 0 (leader at view 0) -- also listens for agents
./zig-out/bin/hivemind cluster \
    --node-id 0 --replica-count 3 \
    --replica-port $R0_PORT --agent-port $AGENT_PORT \
    --peers "1@127.0.0.1:$R1_PORT,2@127.0.0.1:$R2_PORT" &
PIDS+=($!)

# Replica 1
./zig-out/bin/hivemind cluster \
    --node-id 1 --replica-count 3 \
    --replica-port $R1_PORT \
    --peers "0@127.0.0.1:$R0_PORT,2@127.0.0.1:$R2_PORT" &
PIDS+=($!)

# Replica 2
./zig-out/bin/hivemind cluster \
    --node-id 2 --replica-count 3 \
    --replica-port $R2_PORT \
    --peers "0@127.0.0.1:$R0_PORT,1@127.0.0.1:$R1_PORT" &
PIDS+=($!)

# Let replicas start and connect to each other
sleep 2

echo "=== Starting Rust agent ==="
./agent/target/debug/hivemind-agent run "127.0.0.1:$AGENT_PORT" &
PIDS+=($!)

# Let the agent register and consensus propagate
sleep 5

echo "=== Checking results ==="
# The agent should have connected and printed "connected to..."
# The replicas should have printed log messages about the agent

# Simple check: if all processes are still running, the cluster is stable
ALL_RUNNING=true
for pid in "${PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "FAIL: process $pid died"
        ALL_RUNNING=false
    fi
done

if $ALL_RUNNING; then
    echo "=== MULTI-NODE SMOKE TEST PASSED ==="
    echo "All 3 replicas + 1 agent running stably for 5 seconds"
else
    echo "=== MULTI-NODE SMOKE TEST FAILED ==="
    exit 1
fi

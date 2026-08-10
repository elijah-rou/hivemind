#!/bin/bash
set -euo pipefail

echo "==> Starting containerd..."
containerd &
sleep 2

# Verify containerd is running
ctr version || { echo "containerd failed to start"; exit 1; }

echo "==> Running containerd integration tests..."
cd /hivemind/worker
cargo test --release --features containerd-integration -- --test-threads=1 containerd 2>&1

echo "==> Done"

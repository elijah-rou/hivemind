#!/bin/bash
#
# Integration smoke test: Zig control plane + Rust agent over TCP.
# Verifies the agent can connect and register with the control plane.
#
set -euo pipefail

PORT=19876
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

cleanup() {
    kill "$RUST_PID" 2>/dev/null || true
    kill "$ZIG_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Building Zig control plane ==="
cd "$ROOT"
zig build smoke-test

echo "=== Building Rust agent ==="
cd "$ROOT/agent"
cargo build --quiet 2>&1

echo "=== Starting Zig smoke test (port $PORT) ==="
cd "$ROOT"
./zig-out/bin/hivemind-smoke-test "$PORT" &
ZIG_PID=$!
sleep 0.5

echo "=== Starting Rust agent ==="
./agent/target/debug/hivemind-agent run "127.0.0.1:$PORT" &
RUST_PID=$!

echo "=== Waiting for result ==="
wait "$ZIG_PID"
ZIG_EXIT=$?

if [ "$ZIG_EXIT" -eq 0 ]; then
    echo "=== SMOKE TEST PASSED ==="
else
    echo "=== SMOKE TEST FAILED (exit $ZIG_EXIT) ==="
fi

exit "$ZIG_EXIT"

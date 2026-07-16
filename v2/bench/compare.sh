#!/usr/bin/env bash
#
# Side-by-side Hivemind vs Kubernetes scheduling latency comparison.
# Set HIVEMIND_ONLY=1 to run the three-node Hivemind path without kind.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$ROOT/core"
BENCH_DIR="$ROOT/bench"
REPLICA_BIN="$CORE_DIR/zig-out/bin/hivemind"
BENCH_BIN="$BENCH_DIR/hivemind-bench"
NUM="${1:-20}"
HIVEMIND_ONLY="${HIVEMIND_ONLY:-0}"
PIDS=()
BENCH_DATA=""

cleanup() {
    local pid
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    if [[ -n "$BENCH_DATA" ]]; then
        rm -rf "$BENCH_DATA"
    fi
}
trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Hivemind vs Kubernetes Scheduling Latency Benchmark ║"
echo "║  Deployments: $NUM                                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

echo "━━━ HIVEMIND (3-node VRR cluster) ━━━"
echo ""

echo "==> Building core..."
(cd "$CORE_DIR" && zig build -Doptimize=ReleaseFast)

echo "==> Building bench client..."
(cd "$BENCH_DIR" && go build -o "$BENCH_BIN" .)

if [[ ! -x "$REPLICA_BIN" ]]; then
    echo "FAIL: missing replica binary: $REPLICA_BIN" >&2
    exit 1
fi
if [[ ! -x "$BENCH_BIN" ]]; then
    echo "FAIL: missing bench binary: $BENCH_BIN" >&2
    exit 1
fi

BENCH_DATA="$(mktemp -d "${TMPDIR:-/tmp}/hivemind-bench.XXXXXX")"
# Unique high ports per PID to avoid collision across parallel benchmark jobs.
BASE=$((20000 + ($$ % 20000)))
BASE_REPLICA_PORT=$((BASE + 0))
BASE_CLIENT_PORT=$((BASE + 10))
BASE_WORKER_PORT=$((BASE + 20))

for i in 0 1 2; do
    rport=$((BASE_REPLICA_PORT + i))
    cport=$((BASE_CLIENT_PORT + i))
    wport=$((BASE_WORKER_PORT + i))
    peers=""
    for j in 0 1 2; do
        [[ "$j" == "$i" ]] && continue
        [[ -n "$peers" ]] && peers+=","
        peers+="${j}@127.0.0.1:$((BASE_REPLICA_PORT + j))"
    done
    dd="$BENCH_DATA/replica-$i"
    mkdir -m 700 -p "$dd"
    "$REPLICA_BIN" \
        --node-id "$i" \
        --replica-count 3 \
        --worker-port "$wport" \
        --replica-port "$rport" \
        --client-port "$cport" \
        --peers "$peers" \
        --data-dir "$dd" \
        >"$BENCH_DATA/replica-$i.log" 2>&1 &
    PIDS+=("$!")
done

sleep 10

for pid in "${PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "FAIL: replica process $pid exited early" >&2
        for i in 0 1 2; do
            echo "--- replica-$i.log ---" >&2
            cat "$BENCH_DATA/replica-$i.log" >&2 || true
        done
        exit 1
    fi
done

"$BENCH_BIN" \
    --addrs "127.0.0.1:$((BASE_CLIENT_PORT + 0)),127.0.0.1:$((BASE_CLIENT_PORT + 1)),127.0.0.1:$((BASE_CLIENT_PORT + 2))" \
    --n "$NUM" \
    --replicas 1 \
    --gpus 0

# Tear down Hivemind children before optional k8s path.
for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true
PIDS=()

if [[ "$HIVEMIND_ONLY" == "1" ]]; then
    echo ""
    echo "HIVEMIND_ONLY=1: skipping Kubernetes/kind path."
    exit 0
fi

echo ""
echo ""
echo "━━━ KUBERNETES (3-node kind cluster) ━━━"
echo ""

bash "$BENCH_DIR/k8s_bench.sh" "$NUM"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done. Compare the results above."

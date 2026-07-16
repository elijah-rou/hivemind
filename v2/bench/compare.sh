#!/bin/bash
#
# Side-by-side Hivemind vs Kubernetes scheduling latency comparison.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NUM=${1:-20}

echo "╔══════════════════════════════════════════════════════╗"
echo "║  Hivemind vs Kubernetes Scheduling Latency Benchmark ║"
echo "║  Deployments: $NUM                                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# --- Hivemind ---
echo "━━━ HIVEMIND (3-node VRR cluster) ━━━"
echo ""

cd "$ROOT"
zig build 2>/dev/null

pkill -f "hivemind cluster" 2>/dev/null; sleep 1

BENCH_DATA="${TMPDIR:-/tmp}/hivemind-bench-$$"
mkdir -p "$BENCH_DATA"
trap 'pkill -f "hivemind cluster" 2>/dev/null || true; rm -rf "$BENCH_DATA"' EXIT

for i in 0 1 2; do
    RPORT=$((55000 + $i))
    CPORT=$((55060 + $i))
    PEERS=""
    for j in 0 1 2; do
        [ "$j" = "$i" ] && continue
        [ -n "$PEERS" ] && PEERS="$PEERS,"
        PEERS="${PEERS}${j}@127.0.0.1:$((55000 + $j))"
    done
    DD="$BENCH_DATA/replica-$i"
    mkdir -m 700 -p "$DD"
    ./zig-out/bin/hivemind cluster --node-id $i --replica-count 3 --replica-port $RPORT --client-port $CPORT --peers "$PEERS" --data-dir "$DD" 2>/dev/null &
done

sleep 10

./bench/hivemind-bench --addrs "127.0.0.1:55060,127.0.0.1:55061,127.0.0.1:55062" --n "$NUM" --replicas 1 --gpus 0 2>&1

pkill -f "hivemind cluster" 2>/dev/null; wait 2>/dev/null; sleep 1

echo ""
echo ""

# --- Kubernetes ---
echo "━━━ KUBERNETES (3-node kind cluster) ━━━"
echo ""

bash "$ROOT/bench/k8s_bench.sh" "$NUM" 2>&1

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done. Compare the results above."

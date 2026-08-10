#!/bin/bash
set -euo pipefail

# Hivemind POC local harness
#
# Mirrors the AWS POC topology (5 replicas + API + worker) on loopback so the
# same smoke-test.sh passes before we ever provision cloud resources.
#
# Usage:
#   ./run-local.sh up       # start cluster, print API url
#   ./run-local.sh down     # stop cluster, clean state dir
#   ./run-local.sh smoke    # run smoke-test.sh against running local cluster

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${HIVEMIND_LOCAL_STATE:-/tmp/hivemind-local}"
LOG_DIR="$STATE_DIR/logs"
PID_DIR="$STATE_DIR/pids"
DATA_DIR="$STATE_DIR/data"

ZIG_BIN="$ROOT/core/zig-out/bin/hivemind"
API_BIN="/tmp/hivemind-native/hivemind-api"
WORKER_BIN="$ROOT/worker/target/release/hivemind-worker"

REPLICA_COUNT=5
BASE_WORKER=9000
BASE_CLIENT=9001
BASE_PEER=9102
BASE_METRICS=9200
API_PORT=8080

build_peers() {
    local peers=""
    for i in $(seq 0 $((REPLICA_COUNT - 1))); do
        local port=$((BASE_PEER + i * 10))
        [ -n "$peers" ] && peers+="," || true
        peers+="${i}@127.0.0.1:${port}"
    done
    echo "$peers"
}

up() {
    command -v "$ZIG_BIN" >/dev/null 2>&1 || [ -x "$ZIG_BIN" ] || { echo "missing $ZIG_BIN — run: cd $ROOT/core && zig build -Doptimize=ReleaseSafe"; exit 1; }
    [ -x "$API_BIN" ] || { echo "missing $API_BIN — run: cd $ROOT/api && go build -o $API_BIN ."; exit 1; }
    [ -x "$WORKER_BIN" ] || { echo "missing $WORKER_BIN — run: cd $ROOT/worker && cargo build --release"; exit 1; }

    mkdir -p "$LOG_DIR" "$PID_DIR" "$DATA_DIR"
    local peers
    peers=$(build_peers)
    echo "==> Peers: $peers"

    for i in $(seq 0 $((REPLICA_COUNT - 1))); do
        local wp=$((BASE_WORKER + i * 10))
        local cp=$((BASE_CLIENT + i * 10))
        local pp=$((BASE_PEER + i * 10))
        local mp=$((BASE_METRICS + i * 10))
        local dd="$DATA_DIR/replica-$i"
        mkdir -p "$dd"
        echo "==> replica $i  worker=$wp client=$cp peer=$pp metrics=$mp"
        nohup "$ZIG_BIN" \
            --node-id "$i" \
            --replica-count "$REPLICA_COUNT" \
            --worker-port "$wp" \
            --client-port "$cp" \
            --replica-port "$pp" \
            --peers "$peers" \
            --data-dir "$dd" \
            --metrics-port "$mp" \
            --region local \
            >"$LOG_DIR/replica-$i.log" 2>&1 &
        echo $! >"$PID_DIR/replica-$i.pid"
    done

    sleep 3
    echo "==> api  listen=:$API_PORT → 127.0.0.1:$BASE_CLIENT"
    nohup "$API_BIN" \
        --listen ":$API_PORT" \
        --addrs "127.0.0.1:$BASE_CLIENT" \
        >"$LOG_DIR/api.log" 2>&1 &
    echo $! >"$PID_DIR/api.pid"

    sleep 2
    echo "==> worker  runtime=process → 127.0.0.1:$BASE_WORKER"
    nohup "$WORKER_BIN" run "127.0.0.1:$BASE_WORKER" \
        --runtime process \
        --metrics-port 8081 \
        >"$LOG_DIR/worker.log" 2>&1 &
    echo $! >"$PID_DIR/worker.pid"

    sleep 2
    echo ""
    echo "cluster up."
    echo "  api:       http://127.0.0.1:$API_PORT"
    echo "  dashboard: http://127.0.0.1:$API_PORT/dashboard"
    echo "  logs:      $LOG_DIR"
}

down() {
    if [ ! -d "$PID_DIR" ]; then
        echo "no state dir at $PID_DIR"
        return 0
    fi
    for pidfile in "$PID_DIR"/*.pid; do
        [ -e "$pidfile" ] || continue
        local pid
        pid=$(cat "$pidfile" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "==> kill $(basename "$pidfile" .pid) pid=$pid"
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    done
    sleep 1
    # fallback cleanup of any stragglers bound to our ports
    for port in $(seq $BASE_WORKER 10 $((BASE_WORKER + (REPLICA_COUNT - 1) * 10))) \
                 $(seq $BASE_CLIENT 10 $((BASE_CLIENT + (REPLICA_COUNT - 1) * 10))) \
                 $(seq $BASE_PEER 10 $((BASE_PEER + (REPLICA_COUNT - 1) * 10))) \
                 $API_PORT 8081; do
        lsof -ti ":$port" 2>/dev/null | xargs -r kill 2>/dev/null || true
    done
    rm -rf "$DATA_DIR"
    echo "cluster down, state wiped."
}

smoke() {
    "$(dirname "$0")/smoke-test.sh" "http://127.0.0.1:$API_PORT"
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    smoke) smoke ;;
    *) echo "Usage: $0 {up|down|smoke}"; exit 1 ;;
esac

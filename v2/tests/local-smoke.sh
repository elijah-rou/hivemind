#!/bin/bash
set -eo pipefail

# Local smoke test: starts a single-node replica + worker + API on localhost,
# runs the smoke test, then tears everything down.
#
# Prerequisites: zig, cargo, go built (or pass --build)
# Uses process runtime (no containerd needed)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD=false
PIDS=""
REPLICA_PID=""
AGENT_PID=""
API_PID=""

cleanup() {
    echo "==> Cleaning up..."
    for pid in $REPLICA_PID $AGENT_PID $API_PID; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    rm -f /tmp/hivemind-smoke-*.log
    if [[ -n "${DATA_DIR:-}" && -d "$DATA_DIR" ]]; then
        rm -rf "$DATA_DIR"
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# Build if requested
if [ "$BUILD" = true ]; then
    echo "==> Building replica..."
    cd "$REPO_ROOT/core" && zig build -Doptimize=ReleaseFast 2>&1
    echo "==> Building worker..."
    cd "$REPO_ROOT/worker" && cargo build --release 2>&1
    echo "==> Building API..."
    cd "$REPO_ROOT/api" && go build -o "$REPO_ROOT/api/hivemind-api" . 2>&1
fi

REPLICA_BIN="$REPO_ROOT/core/zig-out/bin/hivemind"
AGENT_BIN="$REPO_ROOT/worker/target/release/hivemind-worker"
API_BIN="$REPO_ROOT/api/hivemind-api"

for bin in "$REPLICA_BIN" "$AGENT_BIN" "$API_BIN"; do
    if [ ! -f "$bin" ]; then
        echo "Binary not found: $bin (pass --build to compile)"
        exit 1
    fi
done

# Create temp data dir
DATA_DIR=$(mktemp -d /tmp/hivemind-smoke-data.XXXXXX)

echo "==> Starting single-node replica on ports 9000/9001..."
"$REPLICA_BIN" \
    --node-id 0 \
    --replica-count 1 \
    --worker-port 19000 \
    --client-port 19001 \
    --data-dir "$DATA_DIR" \
    --metrics-port 19200 \
    > /tmp/hivemind-smoke-replica.log 2>&1 &
REPLICA_PID=$!
sleep 2

if ! kill -0 "$REPLICA_PID" 2>/dev/null; then
    echo "FAIL: replica failed to start"
    cat /tmp/hivemind-smoke-replica.log
    exit 1
fi
echo "    replica PID=$REPLICA_PID"

echo "==> Starting worker (process runtime)..."
"$AGENT_BIN" run 127.0.0.1:19000 \
    --runtime process \
    --metrics-port 18081 \
    > /tmp/hivemind-smoke-worker.log 2>&1 &
AGENT_PID=$!
sleep 2

if ! kill -0 "$AGENT_PID" 2>/dev/null; then
    echo "FAIL: worker failed to start"
    cat /tmp/hivemind-smoke-worker.log
    exit 1
fi
echo "    worker PID=$AGENT_PID"

echo "==> Starting API gateway..."
"$API_BIN" \
    --listen :18080 \
    --addrs 127.0.0.1:19001 \
    > /tmp/hivemind-smoke-api.log 2>&1 &
API_PID=$!
sleep 2

if ! kill -0 "$API_PID" 2>/dev/null; then
    echo "FAIL: API failed to start"
    cat /tmp/hivemind-smoke-api.log
    exit 1
fi
echo "    API PID=$API_PID"

echo "==> Waiting 3s for worker registration..."
sleep 3

echo ""
echo "=== Running smoke tests ==="
echo ""

PASS=0
FAIL=0

check() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if echo "$actual" | grep -q "$expected"; then
        echo "  PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

wait_for_match() {
    local name="$1"
    local cmd="$2"
    local expected="$3"
    local max_attempts="${4:-12}"
    local delay="${5:-2}"

    for i in $(seq 1 "$max_attempts"); do
        local result
        result=$(eval "$cmd" 2>/dev/null || echo "")
        if echo "$result" | grep -q "$expected"; then
            echo "  PASS: $name (attempt $i)"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep "$delay"
    done

    echo "  FAIL: $name (timed out after $((max_attempts * delay))s)"
    FAIL=$((FAIL + 1))
    return 1
}

wait_for_run_response() {
    local name="$1"
    local url="$2"
    local payload="$3"
    local expected="$4"
    local max_attempts="${5:-12}"
    local delay="${6:-2}"

    for i in $(seq 1 "$max_attempts"); do
        local result
        result=$(curl -sf -X POST "$url" \
            -H "Content-Type: application/json" \
            -d "$payload" || echo "")
        if echo "$result" | grep -q "$expected" && [ "$result" != "$payload" ]; then
            echo "  PASS: $name (attempt $i)"
            PASS=$((PASS + 1))
            return 0
        fi
        sleep "$delay"
    done

    echo "  FAIL: $name (timed out after $((max_attempts * delay))s)"
    FAIL=$((FAIL + 1))
    return 1
}

API="http://127.0.0.1:18080"

# 1. Health
echo "[1/8] Health check..."
HEALTH=$(curl -sf "$API/v1/health" || echo "FAIL")
check "health responds" "connected" "$HEALTH"

# 2. Dashboard
echo "[2/8] Dashboard..."
DASH=$(curl -sf -o /dev/null -w "%{http_code}" "$API/dashboard")
check "dashboard 200" "200" "$DASH"

# 3. Cluster state
echo "[3/8] Cluster state partial..."
CLUSTER=$(curl -s "$API/dashboard" || echo "FAIL")
check "dashboard html renders" "Hivemind Cluster" "$CLUSTER"

# 4. Nodes (worker should have registered)
echo "[4/8] Nodes..."
wait_for_match "nodes section" "curl -sf \"$API/dashboard/nodes\"" "Nodes" 12 2
NODES=$(curl -sf "$API/dashboard/nodes" || echo "FAIL")
check "nodes section" "Nodes" "$NODES"

# 5. Create deployment
echo "[5/9] Create deployment..."
DEPLOY=$(curl -sf -X POST "$API/v1/deployments" \
    -H "Content-Type: application/json" \
    -d '{"name":"smoke-echo","image":"docker.io/mendhak/http-https-echo:31","replicas":1,"cpu":500,"memory":512,"gpu_type":"none","gpu_count":0}' || echo "FAIL")
check "deployment created" "ok" "$DEPLOY"

# 6. Deployment visible on dashboard
echo "[6/9] Deployment on dashboard..."
wait_for_match "deployment listed" "curl -sf \"$API/dashboard/deployments\"" "smoke-echo" 12 2
DEPS=$(curl -sf "$API/dashboard/deployments" || echo "FAIL")
check "deployment listed" "smoke-echo" "$DEPS"

# 7. Run request
echo "[7/9] Run request..."
RUN_PAYLOAD='{"probe":"local-poc-run"}'
wait_for_run_response "run echoes payload" "$API/v1/deployments/smoke-echo/run" "$RUN_PAYLOAD" "local-poc-run" 12 2

# 8. Queue stats
echo "[8/9] Queue stats..."
QUEUE=$(curl -sf "$API/dashboard/queue" || echo "FAIL")
check "queue section" "Queued" "$QUEUE"

# 9. Metrics endpoints
echo "[9/9] Metrics..."
REPLICA_METRICS=$(curl -sf "http://127.0.0.1:19200/metrics" || echo "FAIL")
check "replica metrics" "hivemind_consensus_view" "$REPLICA_METRICS"
check "leader_id metric" "hivemind_leader_id" "$REPLICA_METRICS"
check "connections metric" "hivemind_connections" "$REPLICA_METRICS"

AGENT_METRICS=$(curl -sf "http://127.0.0.1:18081/metrics" || echo "FAIL")
check "worker metrics" "hivemind_worker_connected" "$AGENT_METRICS"
check "worker uptime" "hivemind_worker_uptime_seconds" "$AGENT_METRICS"

# Agent healthz
HEALTHZ=$(curl -sf "http://127.0.0.1:18081/healthz" || echo "FAIL")
check "worker healthz" "ok" "$HEALTHZ"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "--- Replica log ---"
    tail -20 /tmp/hivemind-smoke-replica.log
    echo "--- Agent log ---"
    tail -20 /tmp/hivemind-smoke-worker.log
    echo "--- API log ---"
    tail -20 /tmp/hivemind-smoke-api.log
fi

[ "$FAIL" -eq 0 ] && exit 0 || exit 1

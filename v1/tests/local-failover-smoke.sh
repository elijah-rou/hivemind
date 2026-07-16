#!/usr/bin/env bash
set -euo pipefail

# Local live failover smoke:
# - starts real Zig replica processes + one Go API gateway
# - commits work through the API
# - kills the current leader process
# - verifies API reconnects to a different leader and can commit more work
# - restarts the killed replica and verifies the cluster converges again
#
# This intentionally exercises local processes before spending on cloud.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD=false
BASE_PORT="${BASE_PORT:-21000}"
PIDS=()
REPLICA_PIDS=()
DATA_DIRS=()
LOG_DIR="$(mktemp -d /tmp/hivemind-failover-smoke.XXXXXX)"
API_PID=""

dump_diagnostics() {
    set +e
    echo "==> Diagnostics: $LOG_DIR"
    for i in $(seq 0 $((replica_count - 1)) 2>/dev/null || echo); do
        [[ -z "$i" ]] && continue
        curl -fsS "http://127.0.0.1:$(metrics_port "$i")/metrics" > "$LOG_DIR/metrics-$i.txt" 2>/dev/null || true
    done
    curl -fsS "http://127.0.0.1:18080/v1/health" > "$LOG_DIR/health.json" 2>/dev/null || true
}

cleanup() {
    status=$?
    set +e
    if [[ "$status" -ne 0 ]]; then
        dump_diagnostics
    fi
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
    for dir in "${DATA_DIRS[@]}"; do
        rm -rf "$dir"
    done
    if [[ "$status" -ne 0 || "${KEEP_LOGS:-false}" == "true" ]]; then
        echo "logs=$LOG_DIR"
    else
        rm -rf "$LOG_DIR"
    fi
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) BUILD=true; shift ;;
        *) echo "unknown arg: $1"; exit 1 ;;
    esac
done

if [[ "$BUILD" == true ]]; then
    echo "==> Building replica..."
    (cd "$REPO_ROOT/core" && zig build -Doptimize=ReleaseFast)
    echo "==> Building API..."
    (cd "$REPO_ROOT/api" && go build -o "$REPO_ROOT/api/hivemind-api" .)
fi

REPLICA_BIN="$REPO_ROOT/core/zig-out/bin/hivemind"
API_BIN="$REPO_ROOT/api/hivemind-api"
for bin in "$REPLICA_BIN" "$API_BIN"; do
    if [[ ! -x "$bin" ]]; then
        echo "missing binary: $bin (pass --build)"
        exit 1
    fi
done

replica_count="${REPLICA_COUNT:-3}"
worker_port() { echo $((BASE_PORT + 100 + $1)); }
client_port() { echo $((BASE_PORT + 200 + $1)); }
peer_port() { echo $((BASE_PORT + 300 + $1)); }
metrics_port() { echo $((BASE_PORT + 400 + $1)); }

peer_list() {
    local self="$1"
    local out=""
    for i in $(seq 0 $((replica_count - 1))); do
        if [[ "$i" == "$self" ]]; then
            continue
        fi
        local entry="$i@127.0.0.1:$(peer_port "$i")"
        if [[ -z "$out" ]]; then
            out="$entry"
        else
            out="$out,$entry"
        fi
    done
    echo "$out"
}

client_addrs() {
    local out=""
    for i in $(seq 0 $((replica_count - 1))); do
        local entry="127.0.0.1:$(client_port "$i")"
        if [[ -z "$out" ]]; then
            out="$entry"
        else
            out="$out,$entry"
        fi
    done
    echo "$out"
}

start_replica() {
    local id="$1"
    local data_dir="${DATA_DIRS[$id]}"
    "$REPLICA_BIN" \
        --node-id "$id" \
        --replica-count "$replica_count" \
        --worker-port "$(worker_port "$id")" \
        --client-port "$(client_port "$id")" \
        --replica-port "$(peer_port "$id")" \
        --metrics-port "$(metrics_port "$id")" \
        --data-dir "$data_dir" \
        --peers "$(peer_list "$id")" \
        > "$LOG_DIR/replica-$id.log" 2>&1 &
    local pid=$!
    REPLICA_PIDS[$id]="$pid"
    PIDS+=("$pid")
    echo "    replica $id pid=$pid client=:$(client_port "$id") peer=:$(peer_port "$id")"
}

for i in $(seq 0 $((replica_count - 1))); do
    DATA_DIRS[$i]="$(mktemp -d /tmp/hivemind-failover-data-$i.XXXXXX)"
done

cleanup_dead_pids() {
    local live=()
    for pid in "${PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            live+=("$pid")
        fi
    done
    PIDS=("${live[@]}")
}

wait_http_contains() {
    local name="$1"
    local url="$2"
    local expected="$3"
    local attempts="${4:-60}"
    local delay="${5:-1}"
    for attempt in $(seq 1 "$attempts"); do
        local body
        body="$(curl -fsS "$url" 2>/dev/null || true)"
        if echo "$body" | grep -q "$expected"; then
            echo "  PASS: $name (attempt $attempt)"
            return 0
        fi
        sleep "$delay"
    done
    echo "  FAIL: $name"
    return 1
}

health_json() {
    curl -fsS "http://127.0.0.1:18080/v1/health"
}

leader_addr() {
    health_json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("leader", ""))'
}

leader_id_from_addr() {
    local addr="$1"
    local port="${addr##*:}"
    for i in $(seq 0 $((replica_count - 1))); do
        if [[ "$(client_port "$i")" == "$port" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

create_deployment() {
    local name="$1"
    curl -fsS -X POST "http://127.0.0.1:18080/v1/deployments" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"$name\",\"image\":\"local-smoke:v1\",\"replicas\":1,\"cpu\":500,\"memory\":512,\"gpu_type\":\"none\",\"gpu_count\":0}"
}

echo "==> Starting replicas..."
for i in $(seq 0 $((replica_count - 1))); do
    start_replica "$i"
done

sleep 4
for pid in "${REPLICA_PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "FAIL: replica pid $pid exited"
        exit 1
    fi
done

echo "==> Starting API gateway..."
"$API_BIN" --listen :18080 --addrs "$(client_addrs)" > "$LOG_DIR/api.log" 2>&1 &
API_PID=$!
PIDS+=("$API_PID")
echo "    api pid=$API_PID"

wait_http_contains "API health connected" "http://127.0.0.1:18080/v1/health" '"connected":true' 80 1
leader_before="$(leader_addr)"
leader_id="$(leader_id_from_addr "$leader_before")"
echo "    leader_before=$leader_before id=$leader_id"

initial_name="failover-before-$(date +%s)"
echo "==> Committing deployment before leader kill..."
create_deployment "$initial_name" | tee "$LOG_DIR/create-before.json"
wait_http_contains "deployment visible before kill" "http://127.0.0.1:18080/dashboard/deployments" "$initial_name" 60 1

echo "==> Killing leader replica $leader_id..."
kill "${REPLICA_PIDS[$leader_id]}"
wait "${REPLICA_PIDS[$leader_id]}" 2>/dev/null || true
cleanup_dead_pids

wait_http_contains "API reconnects after leader loss" "http://127.0.0.1:18080/v1/health" '"connected":true' 120 1
leader_after="$(leader_addr)"
if [[ -z "$leader_after" || "$leader_after" == "$leader_before" ]]; then
    echo "FAIL: expected different leader after kill, before=$leader_before after=$leader_after"
    exit 1
fi
echo "    leader_after=$leader_after"

post_name="failover-after-$(date +%s)"
echo "==> Committing deployment after leader kill..."
create_deployment "$post_name" | tee "$LOG_DIR/create-after.json"
wait_http_contains "deployment visible after kill" "http://127.0.0.1:18080/dashboard/deployments" "$post_name" 60 1

echo "==> Restarting killed replica $leader_id..."
start_replica "$leader_id"
wait_http_contains "API remains connected after restart" "http://127.0.0.1:18080/v1/health" '"connected":true' 120 1
sleep 5

for i in $(seq 0 $((replica_count - 1))); do
    wait_http_contains "replica $i metrics normal" "http://127.0.0.1:$(metrics_port "$i")/metrics" 'hivemind_replica_status 0' 80 1
done

echo "==> Local failover smoke passed"

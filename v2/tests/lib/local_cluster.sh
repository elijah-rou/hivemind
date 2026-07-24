#!/usr/bin/env bash
# Shared bounded three-replica local-process cluster. Source only.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "local_cluster.sh must be sourced" >&2
    exit 2
fi

LOCAL_CLUSTER_REPLICA_COUNT=3
LOCAL_CLUSTER_PIDS=()
LOCAL_CLUSTER_REPLICA_PIDS=("" "" "")
LOCAL_CLUSTER_API_PID=""
LOCAL_CLUSTER_WORKER_PID=""
LOCAL_CLUSTER_ROOT=""
LOCAL_CLUSTER_PORT_LOCK=""
LOCAL_CLUSTER_PORT_LOCK_TOKEN=""
LOCAL_CLUSTER_KEEP="${LOCAL_CLUSTER_KEEP:-false}"
LOCAL_CLUSTER_BUILD=false
LOCAL_CLUSTER_TEST_CONTROLS=false
declare -A LOCAL_CLUSTER_PID_START_TIMES=()

local_cluster_pid_start_time() {
    local pid="$1"
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "/proc/$pid/stat" ]] || return 1
    awk '{print $22}' "/proc/$pid/stat"
}

local_cluster_record_pid() {
    local pid="$1" start_time attempt pgid=""
    for attempt in $(seq 1 50); do
        pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ "$pgid" == "$pid" ]] && break
        sleep 0.01
    done
    [[ "$pgid" == "$pid" ]] || {
        echo "owned process $pid must lead its own process group" >&2
        return 1
    }
    start_time="$(local_cluster_pid_start_time "$pid")" || {
        echo "cannot inventory owned process $pid" >&2
        return 1
    }
    LOCAL_CLUSTER_PID_START_TIMES["$pid"]="$start_time"
    LOCAL_CLUSTER_PIDS+=("$pid")
}

local_cluster_pid_owned() {
    local pid="$1" expected="${LOCAL_CLUSTER_PID_START_TIMES[$1]:-}" actual
    [[ -n "$expected" ]] || return 1
    actual="$(local_cluster_pid_start_time "$pid" 2>/dev/null)" || return 1
    [[ "$actual" == "$expected" ]]
}

local_cluster_pid_running() {
    local pid="$1" state
    local_cluster_pid_owned "$pid" || return 1
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
    [[ -n "$state" && "${state:0:1}" != Z ]]
}

local_cluster_group_members() {
    local pgid="$1"
    [[ "$pgid" =~ ^[1-9][0-9]*$ ]] || return 1
    ps -eo pid=,pgid=,stat= | awk -v pgid="$pgid" '$2 == pgid && substr($3, 1, 1) != "Z" {print $1}'
}

local_cluster_group_running() {
    local members
    members="$(local_cluster_group_members "$1")" || return 1
    [[ -n "$members" ]]
}

local_cluster_stop_pid() {
    local pid="$1" attempt
    [[ -n "$pid" ]] || return 0
    [[ -n "${LOCAL_CLUSTER_PID_START_TIMES[$pid]:-}" ]] || return 0
    if [[ -r "/proc/$pid/stat" ]] && ! local_cluster_pid_owned "$pid"; then
        echo "owned process leader $pid changed identity before cleanup" >&2
        return 1
    fi
    if ! local_cluster_group_running "$pid"; then
        wait "$pid" 2>/dev/null || true
        unset 'LOCAL_CLUSTER_PID_START_TIMES[$pid]'
        return 0
    fi

    # A stopped process cannot handle TERM. Resume the complete owned group first.
    kill -CONT -- "-$pid" 2>/dev/null || true
    kill -TERM -- "-$pid" 2>/dev/null || true
    for attempt in $(seq 1 30); do
        local_cluster_group_running "$pid" || break
        sleep 0.1
    done
    if local_cluster_group_running "$pid"; then
        kill -KILL -- "-$pid" 2>/dev/null || true
        for attempt in $(seq 1 20); do
            local_cluster_group_running "$pid" || break
            sleep 0.1
        done
    fi
    if local_cluster_group_running "$pid"; then
        echo "owned process group $pid survived bounded TERM/KILL cleanup: $(local_cluster_group_members "$pid" | tr '\n' ' ')" >&2
        return 1
    fi
    wait "$pid" 2>/dev/null || true
    unset 'LOCAL_CLUSTER_PID_START_TIMES[$pid]'
}

local_cluster_cleanup_inventory() {
    local pid failed=0
    for pid in "${LOCAL_CLUSTER_PIDS[@]}"; do
        [[ -n "$pid" ]] || continue
        if local_cluster_group_running "$pid"; then
            echo "cleanup residue: owned process group $pid members $(local_cluster_group_members "$pid" | tr '\n' ' ')" >&2
            failed=1
        fi
    done
    if [[ -n "${LOCAL_CLUSTER_BASE_PORT:-}" ]]; then
        local offset port
        for offset in {1..12} 20 21 22 30 31 32 40 41 42; do
            port=$((LOCAL_CLUSTER_BASE_PORT + offset))
            if ss -H -ltn 2>/dev/null | awk -v port="$port" '{address=$4; sub(/^.*:/, "", address); if (address == port) found=1} END {exit !found}'; then
                echo "cleanup residue: listener on owned port $port" >&2
                failed=1
            fi
        done
    fi
    if [[ -n "$LOCAL_CLUSTER_PORT_LOCK" && -e "$LOCAL_CLUSTER_PORT_LOCK" ]]; then
        echo "cleanup residue: owned port lock $LOCAL_CLUSTER_PORT_LOCK" >&2
        failed=1
    fi
    return "$failed"
}

local_cluster_release_port_lock() {
    [[ -n "$LOCAL_CLUSTER_PORT_LOCK" && -d "$LOCAL_CLUSTER_PORT_LOCK" ]] || return 0
    [[ -n "$LOCAL_CLUSTER_PORT_LOCK_TOKEN" ]] || return 0
    [[ "$(cat "$LOCAL_CLUSTER_PORT_LOCK/owner" 2>/dev/null || true)" == "$LOCAL_CLUSTER_PORT_LOCK_TOKEN" ]] || {
        echo "refusing to release unowned port lock $LOCAL_CLUSTER_PORT_LOCK" >&2
        return 1
    }
    rm -f "$LOCAL_CLUSTER_PORT_LOCK/owner"
    rmdir "$LOCAL_CLUSTER_PORT_LOCK"
}

local_cluster_cleanup() {
    local status=$? pid cleanup_failed=0
    trap - EXIT INT TERM
    set +e
    for pid in "${LOCAL_CLUSTER_PIDS[@]}"; do
        [[ -n "$pid" ]] || continue
        local_cluster_stop_pid "$pid" || cleanup_failed=1
    done
    local_cluster_release_port_lock || cleanup_failed=1
    local_cluster_cleanup_inventory || cleanup_failed=1
    if [[ -n "$LOCAL_CLUSTER_ROOT" ]]; then
        if [[ "$status" -ne 0 || "$LOCAL_CLUSTER_KEEP" == true || "$cleanup_failed" -ne 0 ]]; then
            echo "local cluster artifacts: $LOCAL_CLUSTER_ROOT" >&2
        else
            rm -rf "$LOCAL_CLUSTER_ROOT"
        fi
    fi
    [[ "$cleanup_failed" -eq 0 ]] || return 1
    return "$status"
}

local_cluster_init() {
    local build="${1:-false}"
    local test_controls="${2:-false}"
    local candidate attempt

    trap local_cluster_cleanup EXIT
    trap 'exit 130' INT TERM
    LOCAL_CLUSTER_BUILD="$build"
    LOCAL_CLUSTER_TEST_CONTROLS="$test_controls"
    command -v ss >/dev/null 2>&1 || {
        echo "local cluster requires ss for mandatory listener inventory" >&2
        return 1
    }

    for attempt in $(seq 0 99); do
        candidate=$((24000 + (($$ + attempt * 37) % 1200) * 20))
        LOCAL_CLUSTER_PORT_LOCK="/tmp/hivemind-local-ports-$candidate.lock"
        local ports_free=true offset port
        for offset in {1..12} 20 21 22 30 31 32 40 41 42; do
            port=$((candidate + offset))
            if ss -H -ltn 2>/dev/null | awk -v port="$port" '{address=$4; sub(/^.*:/, "", address); if (address == port) found=1} END {exit !found}'; then
                ports_free=false
                break
            fi
        done
        [[ "$ports_free" == true ]] || continue
        if mkdir "$LOCAL_CLUSTER_PORT_LOCK" 2>/dev/null; then
            LOCAL_CLUSTER_PORT_LOCK_TOKEN="$$:$RANDOM:$candidate"
            printf '%s\n' "$LOCAL_CLUSTER_PORT_LOCK_TOKEN" >"$LOCAL_CLUSTER_PORT_LOCK/owner"
            LOCAL_CLUSTER_BASE_PORT="$candidate"
            break
        fi
        LOCAL_CLUSTER_PORT_LOCK=""
    done
    [[ -n "$LOCAL_CLUSTER_PORT_LOCK" ]] || { echo "failed to reserve bounded local port range" >&2; return 1; }

    LOCAL_CLUSTER_ROOT="$(mktemp -d /tmp/hivemind-local-cluster.XXXXXX)"
    mkdir -p "$LOCAL_CLUSTER_ROOT/logs"
    for id in 0 1 2; do mkdir -p "$LOCAL_CLUSTER_ROOT/replica-$id"; done

    LOCAL_CLUSTER_API_PORT=$((LOCAL_CLUSTER_BASE_PORT + 1))
    LOCAL_CLUSTER_WORKER_METRICS_PORT=$((LOCAL_CLUSTER_BASE_PORT + 2))
    LOCAL_CLUSTER_PROCESS_BASE_PORT=$((LOCAL_CLUSTER_BASE_PORT + 3))

    if [[ "$LOCAL_CLUSTER_BUILD" == true ]]; then
        (cd "$LOCAL_CLUSTER_REPO_ROOT/core" && zig build -Doptimize=ReleaseFast)
        (cd "$LOCAL_CLUSTER_REPO_ROOT/worker" && cargo build --release)
        (cd "$LOCAL_CLUSTER_REPO_ROOT/api" && go build -o hivemind-api .)
        (cd "$LOCAL_CLUSTER_REPO_ROOT/bench" && go build -o hivemind-bench .)
    fi

    LOCAL_CLUSTER_REPLICA_BIN="$LOCAL_CLUSTER_REPO_ROOT/core/zig-out/bin/hivemind"
    LOCAL_CLUSTER_WORKER_BIN="$LOCAL_CLUSTER_REPO_ROOT/worker/target/release/hivemind-worker"
    LOCAL_CLUSTER_API_BIN="$LOCAL_CLUSTER_REPO_ROOT/api/hivemind-api"
    LOCAL_CLUSTER_BENCH_BIN="$LOCAL_CLUSTER_REPO_ROOT/bench/hivemind-bench"
    for binary in "$LOCAL_CLUSTER_REPLICA_BIN" "$LOCAL_CLUSTER_WORKER_BIN" "$LOCAL_CLUSTER_API_BIN" "$LOCAL_CLUSTER_BENCH_BIN"; do
        [[ -x "$binary" ]] || { echo "missing binary: $binary (use --build)" >&2; return 1; }
    done
}

local_cluster_worker_port() { echo $((LOCAL_CLUSTER_BASE_PORT + 10 + $1)); }
local_cluster_client_port() { echo $((LOCAL_CLUSTER_BASE_PORT + 20 + $1)); }
local_cluster_peer_port() { echo $((LOCAL_CLUSTER_BASE_PORT + 30 + $1)); }
local_cluster_metrics_port() { echo $((LOCAL_CLUSTER_BASE_PORT + 40 + $1)); }

local_cluster_peer_list() {
    local self="$1" id out=""
    for id in 0 1 2; do
        [[ "$id" == "$self" ]] && continue
        out+="${out:+,}$id@127.0.0.1:$(local_cluster_peer_port "$id")"
    done
    printf '%s\n' "$out"
}

local_cluster_client_addrs() {
    printf '127.0.0.1:%s,127.0.0.1:%s,127.0.0.1:%s\n' \
        "$(local_cluster_client_port 0)" "$(local_cluster_client_port 1)" "$(local_cluster_client_port 2)"
}

local_cluster_worker_addrs() {
    printf '127.0.0.1:%s,127.0.0.1:%s,127.0.0.1:%s\n' \
        "$(local_cluster_worker_port 0)" "$(local_cluster_worker_port 1)" "$(local_cluster_worker_port 2)"
}

local_cluster_start_replica() {
    local id="$1" pid
    setsid "$LOCAL_CLUSTER_REPLICA_BIN" \
        --node-id "$id" --replica-count "$LOCAL_CLUSTER_REPLICA_COUNT" \
        --worker-port "$(local_cluster_worker_port "$id")" \
        --client-port "$(local_cluster_client_port "$id")" \
        --replica-port "$(local_cluster_peer_port "$id")" \
        --metrics-port "$(local_cluster_metrics_port "$id")" \
        --data-dir "$LOCAL_CLUSTER_ROOT/replica-$id" \
        --peers "$(local_cluster_peer_list "$id")" \
        >"$LOCAL_CLUSTER_ROOT/logs/replica-$id.log" 2>&1 &
    pid=$!
    local_cluster_record_pid "$pid"
    LOCAL_CLUSTER_REPLICA_PIDS[id]="$pid"
}

local_cluster_start_replicas() { local id; for id in 0 1 2; do local_cluster_start_replica "$id"; done; }

local_cluster_start_api() {
    local addrs="${1:-$(local_cluster_client_addrs)}"
    setsid "$LOCAL_CLUSTER_API_BIN" --listen "127.0.0.1:$LOCAL_CLUSTER_API_PORT" --addrs "$addrs" \
        >"$LOCAL_CLUSTER_ROOT/logs/api.log" 2>&1 &
    LOCAL_CLUSTER_API_PID=$!
    local_cluster_record_pid "$LOCAL_CLUSTER_API_PID"
}

local_cluster_start_worker() {
    local args=(run "$(local_cluster_worker_addrs)" --runtime process --metrics-port "$LOCAL_CLUSTER_WORKER_METRICS_PORT")
    if [[ "$LOCAL_CLUSTER_TEST_CONTROLS" == true ]]; then
        args+=(--test-process-controls --test-process-base-port "$LOCAL_CLUSTER_PROCESS_BASE_PORT")
    fi
    setsid "$LOCAL_CLUSTER_WORKER_BIN" "${args[@]}" >"$LOCAL_CLUSTER_ROOT/logs/worker.log" 2>&1 &
    LOCAL_CLUSTER_WORKER_PID=$!
    local_cluster_record_pid "$LOCAL_CLUSTER_WORKER_PID"
}

local_cluster_stop_replica() { local id="$1"; local_cluster_stop_pid "${LOCAL_CLUSTER_REPLICA_PIDS[id]}"; LOCAL_CLUSTER_REPLICA_PIDS[id]=""; }
local_cluster_stop_api() { local_cluster_stop_pid "$LOCAL_CLUSTER_API_PID"; LOCAL_CLUSTER_API_PID=""; }
local_cluster_stop_all() {
    local_cluster_stop_pid "$LOCAL_CLUSTER_WORKER_PID"; LOCAL_CLUSTER_WORKER_PID=""
    local_cluster_stop_api
    local id; for id in 0 1 2; do local_cluster_stop_replica "$id"; done
}

local_cluster_health() { curl --connect-timeout 1 --max-time 2 -fsS "http://127.0.0.1:$LOCAL_CLUSTER_API_PORT/v1/health"; }

local_cluster_wait_health() {
    local attempts="${1:-100}" body
    for _ in $(seq 1 "$attempts"); do
        body="$(local_cluster_health 2>/dev/null || true)"
        if python3 -c 'import json,sys; h=json.load(sys.stdin); assert h.get("connected") is True; assert isinstance(h.get("leader"),str) and h["leader"]' <<<"$body" 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    echo "health did not report connected=true with a leader" >&2
    return 1
}

local_cluster_leader_id() {
    local leader port id
    leader="$(local_cluster_health | python3 -c 'import json,sys; print(json.load(sys.stdin)["leader"])')"
    port="${leader##*:}"
    for id in 0 1 2; do [[ "$port" == "$(local_cluster_client_port "$id")" ]] && { echo "$id"; return 0; }; done
    return 1
}

local_cluster_wait_new_leader() {
    local excluded="$1" id
    for _ in $(seq 1 600); do
        for id in 0 1 2; do
            [[ "$id" == "$excluded" ]] && continue
            if [[ "$(local_cluster_metric "$id" hivemind_is_leader 2>/dev/null || echo 0)" == 1 ]]; then
                echo "$id"
                return 0
            fi
        done
        sleep 0.2
    done
    echo "no replacement leader elected" >&2
    return 1
}

local_cluster_create_deployment() {
    local name="$1" replicas="${2:-1}"
    curl --connect-timeout 1 --max-time 8 -fsS -X POST "http://127.0.0.1:$LOCAL_CLUSTER_API_PORT/v1/deployments" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"$name\",\"image\":\"process-test\",\"replicas\":$replicas,\"cpu\":100,\"memory\":128,\"gpu_type\":\"none\",\"gpu_count\":0}"
}

local_cluster_wait_deployment() {
    local name="$1"
    for _ in $(seq 1 100); do
        curl --connect-timeout 1 --max-time 2 -fsS "http://127.0.0.1:$LOCAL_CLUSTER_API_PORT/dashboard/deployments" 2>/dev/null | grep -qF "$name" && return 0
        sleep 0.2
    done
    echo "deployment not visible: $name" >&2
    return 1
}

local_cluster_metric() {
    local id="$1" metric="$2"
    curl --connect-timeout 1 --max-time 2 -fsS "http://127.0.0.1:$(local_cluster_metrics_port "$id")/metrics" |
        awk -v key="$metric" '$1 == key {print $2; found=1; exit} END {if (!found) exit 1}'
}

local_cluster_wait_convergence() {
    local expected_name="$1" expected_min_commit="$2" id commit deployments digests
    for _ in $(seq 1 150); do
        commit=""; deployments=""; digests=""; local ok=true
        for id in 0 1 2; do
            kill -0 "${LOCAL_CLUSTER_REPLICA_PIDS[$id]}" 2>/dev/null || { ok=false; break; }
            local c d g
            c="$(local_cluster_metric "$id" hivemind_consensus_commit 2>/dev/null || true)"
            d="$(local_cluster_metric "$id" hivemind_deployments_total 2>/dev/null || true)"
            g="$(local_cluster_metric "$id" hivemind_committed_state_digest 2>/dev/null || true)"
            [[ "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ && "$g" =~ ^[0-9]+$ && "$c" -ge "$expected_min_commit" ]] || { ok=false; break; }
            commit+="${commit:+,}$c"; deployments+="${deployments:+,}$d"; digests+="${digests:+,}$g"
        done
        if [[ "$ok" == true && "$commit" == "${commit%%,*},${commit%%,*},${commit%%,*}" && "$deployments" == "${deployments%%,*},${deployments%%,*},${deployments%%,*}" && "$digests" == "${digests%%,*},${digests%%,*},${digests%%,*}" ]]; then
            local_cluster_wait_deployment "$expected_name" && return 0
        fi
        sleep 0.2
    done
    echo "replicas did not converge above commit $expected_min_commit" >&2
    return 1
}

local_cluster_wait_queue_zero() {
    local id
    for _ in $(seq 1 100); do
        local ok=true
        for id in 0 1 2; do
            [[ "$(local_cluster_metric "$id" hivemind_queue_depth_total 2>/dev/null || echo x)" == 0 ]] || ok=false
            [[ "$(local_cluster_metric "$id" hivemind_queue_in_flight 2>/dev/null || echo x)" == 0 ]] || ok=false
        done
        [[ "$ok" == true ]] && return 0
        sleep 0.2
    done
    echo "queue/in-flight metrics did not return exactly to zero" >&2
    return 1
}

local_cluster_run() {
    local deployment="$1" payload="$2" output="$3"
    curl --connect-timeout 1 --max-time 8 -sS -o "$output" -w '%{http_code}' -X POST \
        "http://127.0.0.1:$LOCAL_CLUSTER_API_PORT/v1/deployments/$deployment/run" --data-binary "$payload"
}

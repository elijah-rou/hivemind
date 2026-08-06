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
REPLICA_PGIDS=()
REPLICA_START_TIMES=()
BENCH_DATA=""
BENCH_CLEANUP_TIMEOUT_SEC="${BENCH_CLEANUP_TIMEOUT_SEC:-5}"
BENCH_STARTUP_WAIT_SEC="${BENCH_STARTUP_WAIT_SEC:-10}"
[[ "$BENCH_CLEANUP_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || {
    echo "FAIL: BENCH_CLEANUP_TIMEOUT_SEC must be a positive integer" >&2
    exit 2
}
[[ "$BENCH_STARTUP_WAIT_SEC" =~ ^[1-9][0-9]*$ ]] || {
    echo "FAIL: BENCH_STARTUP_WAIT_SEC must be a positive integer" >&2
    exit 2
}

replica_start_time() {
    local pid="$1" process_stat remainder
    local -a stat_fields=()
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    IFS= read -r process_stat <"/proc/$pid/stat" || return 1
    remainder="${process_stat##*) }"
    read -r -a stat_fields <<<"$remainder"
    [[ "${stat_fields[19]:-}" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "${stat_fields[19]}"
}

stop_unrecorded_replica() {
    local pid="$1" pgid="" watchdog
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || true
    if [[ "$pgid" == "$pid" ]]; then
        kill -TERM -- "-$pgid" 2>/dev/null || true
    else
        # The PID is still an owned child even when setsid identity capture lost
        # the race. Never infer deletion authority over an unverified group.
        kill -TERM -- "$pid" 2>/dev/null || true
    fi
    (
        sleep "$BENCH_CLEANUP_TIMEOUT_SEC"
        if [[ "$pgid" == "$pid" ]]; then
            kill -KILL -- "-$pgid" 2>/dev/null || true
        else
            kill -KILL -- "$pid" 2>/dev/null || true
        fi
    ) &
    watchdog=$!
    wait "$pid" 2>/dev/null || true
    kill -TERM "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
}

cleanup_replica_groups() {
    local index pid pgid start_time current_pgid current_start_time watchdog
    local tuple_count="${#PIDS[@]}" cleanup_failed=0 groups_alive=0
    local -a verified_pids=() verified_pgids=()

    if (( ${#REPLICA_PGIDS[@]} < tuple_count )); then tuple_count="${#REPLICA_PGIDS[@]}"; fi
    if (( ${#REPLICA_START_TIMES[@]} < tuple_count )); then tuple_count="${#REPLICA_START_TIMES[@]}"; fi
    if (( ${#PIDS[@]} != ${#REPLICA_PGIDS[@]} )); then cleanup_failed=1; fi
    if (( ${#PIDS[@]} != ${#REPLICA_START_TIMES[@]} )); then cleanup_failed=1; fi
    if (( cleanup_failed != 0 )); then
        echo "FAIL: replica ownership record count mismatch; cleaning proven tuples independently" >&2
    fi

    for ((index = 0; index < tuple_count; index++)); do
        pid="${PIDS[$index]}"
        pgid="${REPLICA_PGIDS[$index]}"
        start_time="${REPLICA_START_TIMES[$index]}"
        if ! current_start_time="$(replica_start_time "$pid")"; then
            # An exited leader can already have been reaped by Bash. Reap the
            # owned child, but never signal a group whose leader identity is gone.
            wait "$pid" 2>/dev/null || true
            continue
        fi
        current_pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || {
            echo "FAIL: unable to revalidate replica process group for $pid" >&2
            cleanup_failed=1
            continue
        }
        if [[ "$current_start_time" != "$start_time" || "$current_pgid" != "$pgid" || "$pid" != "$pgid" ]]; then
            echo "FAIL: refusing cleanup of changed replica process group: pid=$pid pgid=$pgid" >&2
            cleanup_failed=1
            continue
        fi
        verified_pids+=("$pid")
        verified_pgids+=("$pgid")
    done

    for pgid in "${verified_pgids[@]}"; do
        kill -TERM -- "-$pgid" 2>/dev/null || true
    done
    if (( ${#verified_pgids[@]} > 0 )); then
        (
            sleep "$BENCH_CLEANUP_TIMEOUT_SEC"
            for pgid in "${verified_pgids[@]}"; do
                kill -KILL -- "-$pgid" 2>/dev/null || true
            done
        ) &
        watchdog=$!
        for pid in "${verified_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        for pgid in "${verified_pgids[@]}"; do
            if kill -0 -- "-$pgid" 2>/dev/null; then groups_alive=1; break; fi
        done
        if (( groups_alive == 1 )); then
            wait "$watchdog" 2>/dev/null || true
        else
            kill -TERM "$watchdog" 2>/dev/null || true
            wait "$watchdog" 2>/dev/null || true
        fi
        for pgid in "${verified_pgids[@]}"; do
            if kill -0 -- "-$pgid" 2>/dev/null; then
                echo "FAIL: replica process group survived cleanup: $pgid" >&2
                cleanup_failed=1
            fi
        done
    fi

    # Any unmatched PID is still an owned child, but its group identity was
    # never committed. Bound leader cleanup without guessing at a process group.
    for ((index = tuple_count; index < ${#PIDS[@]}; index++)); do
        stop_unrecorded_replica "${PIDS[$index]}" || cleanup_failed=1
    done
    PIDS=()
    REPLICA_PGIDS=()
    REPLICA_START_TIMES=()
    return "$cleanup_failed"
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    local cleanup_status=0
    cleanup_replica_groups || cleanup_status=$?
    if [[ -n "$BENCH_DATA" ]]; then
        rm -rf "$BENCH_DATA" || cleanup_status=1
    fi
    if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then status="$cleanup_status"; fi
    exit "$status"
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
    mkdir -p "$dd"
    chmod 700 "$dd"
    setsid "$REPLICA_BIN" \
        --node-id "$i" \
        --replica-count 3 \
        --worker-port "$wport" \
        --replica-port "$rport" \
        --client-port "$cport" \
        --peers "$peers" \
        --data-dir "$dd" \
        >"$BENCH_DATA/replica-$i.log" 2>&1 &
    pid=$!
    pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')" || {
        echo "FAIL: unable to read replica process group for $pid" >&2
        stop_unrecorded_replica "$pid"
        exit 1
    }
    if [[ "$pgid" != "$pid" ]]; then
        echo "FAIL: replica $pid did not start as its owned process-group leader (pgid=${pgid:-unknown})" >&2
        stop_unrecorded_replica "$pid"
        exit 1
    fi
    start_time="$(replica_start_time "$pid")" || {
        echo "FAIL: unable to record replica process identity for $pid" >&2
        stop_unrecorded_replica "$pid"
        exit 1
    }
    # Commit the cleanup tuple atomically after every identity field is known.
    PIDS+=("$pid")
    REPLICA_PGIDS+=("$pgid")
    REPLICA_START_TIMES+=("$start_time")
done

sleep "$BENCH_STARTUP_WAIT_SEC"

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

# Tear down the owned Hivemind process groups before optional k8s path.
cleanup_replica_groups

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

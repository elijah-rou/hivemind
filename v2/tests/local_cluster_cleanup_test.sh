#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d /tmp/hivemind-local-cleanup-test.XXXXXX)"
CHILD_PID=""
cleanup_fixture() {
    if [[ -f "$TMP_DIR/child.pid" ]]; then
        CHILD_PID="$(cat "$TMP_DIR/child.pid")"
        kill -CONT "$CHILD_PID" 2>/dev/null || true
        kill -KILL "$CHILD_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup_fixture EXIT

run_case() {
    local expected_status="$1"
    # shellcheck disable=SC2016 # The child shell receives all values positionally.
    timeout --foreground 4 bash -c '
        set -euo pipefail
        source "$1/lib/local_cluster.sh"
        LOCAL_CLUSTER_ROOT="$2/root"
        LOCAL_CLUSTER_PORT_LOCK="$2/ports.lock"
        mkdir -p "$LOCAL_CLUSTER_ROOT" "$LOCAL_CLUSTER_PORT_LOCK"
        LOCAL_CLUSTER_PORT_LOCK_TOKEN="cleanup-test-owned"
        printf "%s\n" "$LOCAL_CLUSTER_PORT_LOCK_TOKEN" >"$LOCAL_CLUSTER_PORT_LOCK/owner"
        setsid sleep 60 &
        child=$!
        printf "%s\n" "$child" >"$2/child.pid"
        local_cluster_record_pid "$child"
        kill -STOP "$child"
        set +e
        (exit "$3")
        local_cluster_cleanup
        exit $?
    ' cleanup-case "$SCRIPT_DIR" "$TMP_DIR" "$expected_status"
}

# Cleanup must resume a stopped owned child before TERM and remain bounded.
run_case 0
CHILD_PID="$(cat "$TMP_DIR/child.pid")"
if kill -0 "$CHILD_PID" 2>/dev/null; then exit 1; fi
[[ ! -e "$TMP_DIR/ports.lock" ]]

# Failure cleanup has the same no-residue contract while preserving status.
rm -f "$TMP_DIR/child.pid"
set +e
run_case 23
status=$?
set -e
[[ "$status" -eq 23 ]]
CHILD_PID="$(cat "$TMP_DIR/child.pid")"
if kill -0 "$CHILD_PID" 2>/dev/null; then exit 1; fi
[[ ! -e "$TMP_DIR/ports.lock" ]]

echo "PASS: local cluster cleanup is owned, bounded, and residue-free on success and failure"

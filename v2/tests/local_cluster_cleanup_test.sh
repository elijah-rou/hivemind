#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$(mktemp -d /tmp/hivemind-local-cleanup-test.XXXXXX)"
CHILD_PID=""
cleanup_fixture() {
    if [[ -f "$TMP_DIR/child.pid" ]]; then
        CHILD_PID="$(cat "$TMP_DIR/child.pid")"
        kill -CONT -- "-$CHILD_PID" 2>/dev/null || true
        kill -KILL -- "-$CHILD_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup_fixture EXIT

cat >"$TMP_DIR/owned_group.py" <<'PY'
import os
import signal
import subprocess
import sys
import time

root = sys.argv[1]
descendant = subprocess.Popen(["sleep", "60"])
with open(os.path.join(root, "descendant.pid"), "w", encoding="utf-8") as output:
    output.write(f"{descendant.pid}\n")

def terminate(_signum, _frame):
    with open(os.path.join(root, "term.marker"), "w", encoding="utf-8") as output:
        output.write("TERM\n")
    descendant.terminate()
    try:
        descendant.wait(timeout=1)
    except subprocess.TimeoutExpired:
        descendant.kill()
        descendant.wait(timeout=1)
    raise SystemExit(0)

signal.signal(signal.SIGTERM, terminate)
with open(os.path.join(root, "ready"), "w", encoding="utf-8") as output:
    output.write("ready\n")
while True:
    time.sleep(1)
PY

run_case() {
    local expected_status="$1"
    rm -f "$TMP_DIR/ready" "$TMP_DIR/term.marker" "$TMP_DIR/descendant.pid"
    # shellcheck disable=SC2016 # The child shell receives all values positionally.
    timeout --foreground --kill-after=1s 8s bash -c '
        set -euo pipefail
        source "$1/lib/local_cluster.sh"
        LOCAL_CLUSTER_ROOT="$2/root"
        LOCAL_CLUSTER_PORT_LOCK="$2/ports.lock"
        mkdir -p "$LOCAL_CLUSTER_ROOT" "$LOCAL_CLUSTER_PORT_LOCK"
        LOCAL_CLUSTER_PORT_LOCK_TOKEN="cleanup-fixture"
        printf "%s\n" "$LOCAL_CLUSTER_PORT_LOCK_TOKEN" >"$LOCAL_CLUSTER_PORT_LOCK/owner"
        setsid python3 "$2/owned_group.py" "$2" &
        child=$!
        printf "%s\n" "$child" >"$2/child.pid"
        local_cluster_record_pid "$child"
        for _ in $(seq 1 100); do
            [[ -f "$2/ready" ]] && break
            sleep 0.01
        done
        [[ -f "$2/ready" ]]
        kill -STOP -- "-$child"
        set +e
        (exit "$3")
        local_cluster_cleanup
        exit $?
    ' cleanup-case "$SCRIPT_DIR" "$TMP_DIR" "$expected_status"
}

assert_cleaned_gracefully() {
    local leader descendant
    leader="$(cat "$TMP_DIR/child.pid")"
    descendant="$(cat "$TMP_DIR/descendant.pid")"
    [[ -f "$TMP_DIR/term.marker" ]]
    if kill -0 "$leader" 2>/dev/null; then return 1; fi
    if kill -0 "$descendant" 2>/dev/null; then return 1; fi
    [[ ! -e "$TMP_DIR/ports.lock" ]]
}

# Cleanup must CONT a stopped process group, deliver TERM, and reap descendants.
run_case 0
assert_cleaned_gracefully

# Failure cleanup has the same no-residue contract while preserving status.
set +e
run_case 23
status=$?
set -e
[[ "$status" -eq 23 ]]
assert_cleaned_gracefully

echo "PASS: local cluster cleanup resumes and terminates complete owned process groups without residue"

#!/bin/bash
# Deterministic real-binary storage-mode smoke (no live infra).
# Verifies startup contract for both journal modes:
#   - absent --data-dir → explicit volatile POC mode log; process stays alive
#   - present --data-dir → experimental single-copy journal warning (torn writes /
#     power loss not validated); process stays alive
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$REPO_ROOT/core"
BIN="$CORE_DIR/zig-out/bin/hivemind"

TMP_DIR="$(mktemp -d /tmp/hivemind-storage-mode.XXXXXX)"
cleanup() {
    if [[ -n "${VOL_PID:-}" ]]; then kill "$VOL_PID" 2>/dev/null || true; wait "$VOL_PID" 2>/dev/null || true; fi
    if [[ -n "${EXP_PID:-}" ]]; then kill "$EXP_PID" 2>/dev/null || true; wait "$EXP_PID" 2>/dev/null || true; fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    if ! grep -qF -- "$pattern" "$file"; then
        echo "FAIL: expected pattern not found: $pattern" >&2
        echo "--- $file ---" >&2
        cat "$file" >&2
        exit 1
    fi
}

assert_file_lacks() {
    local file="$1"
    local pattern="$2"
    if grep -qF -- "$pattern" "$file"; then
        echo "FAIL: unexpected pattern present: $pattern" >&2
        echo "--- $file ---" >&2
        cat "$file" >&2
        exit 1
    fi
}

wait_for_pattern() {
    local file="$1"
    local pattern="$2"
    local timeout_s="${3:-5}"
    local i=0
    while (( i < timeout_s * 10 )); do
        if [[ -f "$file" ]] && grep -qF -- "$pattern" "$file"; then
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    echo "FAIL: timed out waiting for pattern: $pattern" >&2
    echo "--- $file ---" >&2
    cat "$file" 2>/dev/null || true
    exit 1
}

echo "=== Building hivemind binary ==="
(
    cd "$CORE_DIR"
    zig build -Doptimize=Debug
)

if [[ ! -x "$BIN" ]]; then
    echo "FAIL: missing executable $BIN" >&2
    exit 1
fi

# Unique high ports per PID to avoid collision across parallel CI jobs.
BASE=$((20000 + ($$ % 20000)))
VOL_WORKER=$((BASE + 0))
VOL_CLIENT=$((BASE + 1))
EXP_WORKER=$((BASE + 2))
EXP_CLIENT=$((BASE + 3))

VOL_LOG="$TMP_DIR/volatile.log"
EXP_LOG="$TMP_DIR/experimental.log"
EXP_DATA="$TMP_DIR/data"
mkdir -p "$EXP_DATA"

echo "=== Mode A: absent --data-dir (volatile POC) ==="
"$BIN" \
    --node-id 0 \
    --replica-count 1 \
    --worker-port "$VOL_WORKER" \
    --client-port "$VOL_CLIENT" \
    >"$VOL_LOG" 2>&1 &
VOL_PID=$!

# Give a brief window; if the contract wrongly requires --data-dir, the
# process exits 2 before listening.
sleep 0.3
if ! kill -0 "$VOL_PID" 2>/dev/null; then
    wait "$VOL_PID" || true
    echo "FAIL: volatile-mode process exited early" >&2
    cat "$VOL_LOG" >&2
    exit 1
fi

wait_for_pattern "$VOL_LOG" 'storage mode: volatile POC'
assert_file_contains "$VOL_LOG" 'storage mode: volatile POC'
assert_file_lacks "$VOL_LOG" '--data-dir is required'
assert_file_contains "$VOL_LOG" 'listening'

kill "$VOL_PID" 2>/dev/null || true
wait "$VOL_PID" 2>/dev/null || true
VOL_PID=""

echo "=== Mode B: present --data-dir (experimental journal) ==="
"$BIN" \
    --node-id 0 \
    --replica-count 1 \
    --worker-port "$EXP_WORKER" \
    --client-port "$EXP_CLIENT" \
    --data-dir "$EXP_DATA" \
    >"$EXP_LOG" 2>&1 &
EXP_PID=$!

sleep 0.3
if ! kill -0 "$EXP_PID" 2>/dev/null; then
    wait "$EXP_PID" || true
    echo "FAIL: experimental-mode process exited early" >&2
    cat "$EXP_LOG" >&2
    exit 1
fi

wait_for_pattern "$EXP_LOG" 'storage mode: experimental single-copy journal'
assert_file_contains "$EXP_LOG" 'storage mode: experimental single-copy journal'
assert_file_contains "$EXP_LOG" 'torn writes'
assert_file_contains "$EXP_LOG" 'power loss'
assert_file_contains "$EXP_LOG" 'not validated'
assert_file_contains "$EXP_LOG" 'listening'

kill "$EXP_PID" 2>/dev/null || true
wait "$EXP_PID" 2>/dev/null || true
EXP_PID=""

echo "PASS: storage-mode smoke (volatile + experimental)"

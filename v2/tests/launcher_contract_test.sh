#!/usr/bin/env bash
# Static contract checks for active smoke/benchmark launchers (HM-BLK-04/05).
# Deterministic: source-level only; no live infra, no cluster bring-up.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FAIL=0

assert_file() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "FAIL: missing file: $path" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi
    return 0
}

assert_contains() {
    local path="$1"
    local pattern="$2"
    if ! grep -qE -- "$pattern" "$path"; then
        echo "FAIL: $path missing pattern: $pattern" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi
    return 0
}

assert_lacks() {
    local path="$1"
    local pattern="$2"
    if grep -qE -- "$pattern" "$path"; then
        echo "FAIL: $path has forbidden pattern: $pattern" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi
    return 0
}

assert_exec_wrapper() {
    local wrapper="$1"
    local target="$2"
    assert_file "$wrapper" || return 0
    assert_contains "$wrapper" "exec[[:space:]].*${target}" || true
    # Compatibility wrappers must replace the process so exit/signals propagate.
    if ! grep -qE 'exec[[:space:]]' "$wrapper"; then
        echo "FAIL: $wrapper must use exec for exit/signal propagation" >&2
        FAIL=$((FAIL + 1))
    fi
}

SMOKE="$SCRIPT_DIR/smoke_test.sh"
MULTI="$SCRIPT_DIR/multi_node_smoke_test.sh"
COMPARE="$REPO_ROOT/bench/compare.sh"
DEPLOY="$REPO_ROOT/infra/bench/deploy.sh"
SERVICE="$REPO_ROOT/infra/poc/hivemind.service"
BENCH_TF="$REPO_ROOT/infra/bench/main.tf"
GPU_TEST="$REPO_ROOT/infra/gpu-test/run-tests.sh"

echo "==> Compatibility smoke wrappers"
assert_exec_wrapper "$SMOKE" 'local-smoke\.sh'
assert_contains "$SMOKE" '--build'
assert_exec_wrapper "$MULTI" 'local-failover-smoke\.sh'
assert_contains "$MULTI" '--build'

echo "==> Stale smoke launcher patterns must be gone"
for f in "$SMOKE" "$MULTI"; do
    assert_lacks "$f" '--agent-port'
    assert_lacks "$f" 'hivemind[[:space:]]+cluster'
    assert_lacks "$f" '/agent/'
    assert_lacks "$f" 'zig build smoke-test'
done

echo "==> bench/compare.sh contract"
assert_file "$COMPARE"
assert_contains "$COMPARE" 'HIVEMIND_ONLY'
assert_contains "$COMPARE" 'CORE_DIR=|REPLICA_BIN='
assert_contains "$COMPARE" 'go build'
assert_lacks "$COMPARE" 'pkill[[:space:]]+-f[[:space:]]+"hivemind cluster"'
assert_lacks "$COMPARE" 'hivemind[[:space:]]+cluster'
assert_lacks "$COMPARE" '--agent-port'
# Exact child PID cleanup (array or tracked PID vars), not only broad pkill.
assert_contains "$COMPARE" 'PIDS\+=\('
assert_contains "$COMPARE" '--worker-port'

echo "==> bench client framing (flags byte)"
assert_file "$REPO_ROOT/bench/main.go"
assert_contains "$REPO_ROOT/bench/main.go" 'func writeFrame\('
assert_contains "$REPO_ROOT/bench/main.go" 'header\[4\] = 0x00'
assert_lacks "$REPO_ROOT/bench/main.go" 'frame\[6\] = ClientTag'

echo "==> infra/bench/deploy.sh contract"
assert_file "$DEPLOY"
assert_contains "$DEPLOY" 'SCRIPT_DIR='
assert_contains "$DEPLOY" 'SCRIPT_DIR/.*/core/zig-out/bin/hivemind|\$\{SCRIPT_DIR\}/.*/hivemind'
# Word-splitting START_COMMANDS=($(...)) breaks commands with spaces.
assert_lacks "$DEPLOY" 'START_COMMANDS=\(\$\('
assert_contains "$DEPLOY" 'mapfile[[:space:]]+-t[[:space:]]+START_COMMANDS'

echo "==> --worker-port on active core launch surfaces"
assert_file "$SERVICE"
assert_contains "$SERVICE" '--worker-port \$\{HIVEMIND_AGENT_PORT\}'
assert_lacks "$SERVICE" '--agent-port'
assert_file "$BENCH_TF"
assert_contains "$BENCH_TF" '--worker-port'
assert_lacks "$BENCH_TF" '--agent-port'

echo "==> gpu-test uses worker/ (agent/ removed)"
assert_file "$GPU_TEST"
assert_contains "$GPU_TEST" '/worker'
assert_lacks "$GPU_TEST" '/agent'
assert_lacks "$GPU_TEST" '[[:space:]]agent/'

if [[ "$FAIL" -ne 0 ]]; then
    echo "FAIL: launcher contract ($FAIL assertion(s))"
    exit 1
fi
echo "PASS: launcher contract"
exit 0

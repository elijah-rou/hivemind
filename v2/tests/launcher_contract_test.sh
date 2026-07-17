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
SYSTEMD_LIFECYCLE="$REPO_ROOT/infra/bench/systemd_lifecycle.sh"
SERVICE="$REPO_ROOT/infra/poc/hivemind.service"
BENCH_TF="$REPO_ROOT/infra/bench/main.tf"
GPU_TEST="$REPO_ROOT/infra/gpu-test/run-tests.sh"
RUN_ALL="$SCRIPT_DIR/run-all.sh"

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
# Terraform arguments remain line-preserved and the remote launch is serialized.
assert_lacks "$DEPLOY" 'START_ARGS=\(\$\('
assert_contains "$DEPLOY" 'mapfile[[:space:]]+-t[[:space:]]+START_ARGS'
assert_contains "$DEPLOY" 'flock[[:space:]]+-x[[:space:]]+-w'
assert_contains "$DEPLOY" 'hivemind_transaction_begin'
assert_contains "$DEPLOY" 'hivemind_deadline_remaining'
assert_contains "$DEPLOY" 'hivemind_unit_stop_verified'
assert_contains "$DEPLOY" 'hivemind_unit_start_verified'
assert_file "$SYSTEMD_LIFECYCLE"
assert_contains "$SYSTEMD_LIFECYCLE" 'timeout.*--signal=TERM.*--kill-after=1s'
assert_lacks "$SYSTEMD_LIFECYCLE" 'timeout.*--foreground'
assert_lacks "$DEPLOY" 'pid_lifecycle|nohup|kill[[:space:]]+-'
# Terraform must be caller-CWD independent.
assert_contains "$DEPLOY" '-chdir="\$SCRIPT_DIR"|-chdir=\$SCRIPT_DIR'
# Broad pkill must not appear in this launcher.
assert_lacks "$DEPLOY" 'pkill[[:space:]]+-f[[:space:]]+hivemind'
# SSM start commands must be polled to terminal Success (not fire-and-forget).
assert_file "$REPO_ROOT/infra/bench/ssm_wait.sh"
assert_contains "$DEPLOY" 'source[[:space:]].*ssm_wait\.sh'
assert_contains "$DEPLOY" 'hivemind_ssm_wait_invocation'
assert_contains "$DEPLOY" 'Command\.CommandId'
assert_lacks "$DEPLOY" 'Command\.CommandId.*&[[:space:]]*$'

echo "==> infra/poc/replica-init.sh secret file modes"
INIT="$REPO_ROOT/infra/poc/replica-init.sh"
assert_file "$INIT"
assert_contains "$INIT" 'umask[[:space:]]+077'
assert_contains "$INIT" 'chmod[[:space:]]+600.*/etc/hivemind/replica.env|install[[:space:]]+-m[[:space:]]+600'
assert_contains "$INIT" 'chmod[[:space:]]+600.*/etc/hivemind/api.env|install[[:space:]]+-m[[:space:]]+600'

echo "==> --worker-port on active core launch surfaces"
assert_file "$SERVICE"
assert_contains "$SERVICE" '--worker-port \$\{HIVEMIND_AGENT_PORT\}'
assert_lacks "$SERVICE" '--agent-port'
assert_file "$BENCH_TF"
assert_contains "$BENCH_TF" '--worker-port'
assert_lacks "$BENCH_TF" '--agent-port'

echo "==> run-all executes both Go module tests"
assert_file "$RUN_ALL"
assert_contains "$RUN_ALL" 'REPO_ROOT/api.*go test ./\.\.\.'
assert_contains "$RUN_ALL" 'REPO_ROOT/bench.*go test ./\.\.\.'

echo "==> gpu-test uses worker/ (agent/ removed)"
assert_file "$GPU_TEST"
assert_contains "$GPU_TEST" '/worker'
assert_lacks "$GPU_TEST" '/agent'
assert_lacks "$GPU_TEST" '[[:space:]]agent/'
# Failures must propagate; never mask cargo test with || true.
if grep -E 'cargo[[:space:]]+test' "$GPU_TEST" | grep -qF '||'; then
    echo "FAIL: $GPU_TEST cargo test must not use || true" >&2
    FAIL=$((FAIL + 1))
fi
assert_contains "$GPU_TEST" 'trap[[:space:]]+cleanup[[:space:]]+EXIT'
assert_contains "$GPU_TEST" 'KEEP_INFRA'
# Trap must be installed before terraform apply (source order).
apply_line="$(grep -nE 'terraform[[:space:]]+apply' "$GPU_TEST" | head -n1 | cut -d: -f1 || true)"
trap_line="$(grep -nE 'trap[[:space:]]+cleanup[[:space:]]+EXIT' "$GPU_TEST" | head -n1 | cut -d: -f1 || true)"
if [[ -z "$apply_line" || -z "$trap_line" || "$trap_line" -ge "$apply_line" ]]; then
    echo "FAIL: $GPU_TEST must install cleanup trap before terraform apply (trap=$trap_line apply=$apply_line)" >&2
    FAIL=$((FAIL + 1))
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo "FAIL: launcher contract ($FAIL assertion(s))"
    exit 1
fi
echo "PASS: launcher contract"
exit 0

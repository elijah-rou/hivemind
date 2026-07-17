#!/bin/bash
set -euo pipefail

# Run all Hivemind tests: unit, simulation, integration, smoke
# Usage: ./tests/run-all.sh [--skip-containerd] [--skip-smoke]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_CONTAINERD=false
SKIP_SMOKE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-containerd) SKIP_CONTAINERD=true; shift ;;
        --skip-smoke) SKIP_SMOKE=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

PASS=0
FAIL=0

run_phase() {
    local name="$1"
    shift
    echo ""
    echo "============================================"
    echo "  $name"
    echo "============================================"
    if "$@"; then
        echo "  => $name: PASSED"
        PASS=$((PASS + 1))
    else
        echo "  => $name: FAILED"
        FAIL=$((FAIL + 1))
    fi
}

# --- Phase 1: Zig unit + simulation tests (Debug + ReleaseFast) ---
run_phase "Zig tests (Debug + ReleaseFast)" \
    bash -c "cd '$REPO_ROOT/core' && zig build test"

# --- Phase 2: Rust unit + integration tests ---
run_phase "Rust tests (unit + integration)" \
    bash -c "cd '$REPO_ROOT/worker' && cargo test"

# --- Phase 3: Go tests + build (separate modules) ---
run_phase "Go API tests" \
    bash -c "cd '$REPO_ROOT/api' && go test ./..."
run_phase "Go bench tests" \
    bash -c "cd '$REPO_ROOT/bench' && go test ./..."
run_phase "Go build (API + bench)" \
    bash -c "cd '$REPO_ROOT/api' && go build ./... && cd '$REPO_ROOT/bench' && go build ./..."

# --- Phase 4: Infra POC script tests ---
run_phase "Infra POC script tests" \
    bash -c "'$REPO_ROOT/infra/poc/test-worker-env.sh'"
run_phase "POC deploy output fixtures" \
    bash -c "'$SCRIPT_DIR/poc_deploy_outputs_test.sh'"

# --- Phase 4b: Storage-mode smoke (real binary, no live infra) ---
run_phase "Storage-mode smoke (volatile + experimental)" \
    bash -c "'$SCRIPT_DIR/storage_mode_smoke_test.sh'"

# --- Phase 4c: Launcher contract (static HM-BLK-04/05 checks) ---
run_phase "Launcher contract (smoke/bench/infra)" \
    bash -c "'$SCRIPT_DIR/launcher_contract_test.sh'"

# --- Phase 4d: Bench deploy SSM wait fixtures (stub aws, no live AWS) ---
run_phase "Bench deploy SSM wait fixtures" \
    bash -c "'$SCRIPT_DIR/deploy_ssm_wait_test.sh'"
run_phase "Bench systemd lifecycle fixtures" \
    bash -c "'$SCRIPT_DIR/bench_systemd_lifecycle_test.sh'"
run_phase "Bench artifact lifecycle fixtures" \
    bash -c "'$SCRIPT_DIR/bench_artifact_lifecycle_test.sh'"

# --- Phase 4e: GPU-test cleanup trap fixture (stub terraform, no live infra) ---
run_phase "GPU-test cleanup trap fixture" \
    bash -c "'$SCRIPT_DIR/gpu_test_cleanup_trap_test.sh'"

# --- Phase 4f: Active docs layout path contract ---
run_phase "Active docs layout path contract" \
    bash -c "'$SCRIPT_DIR/docs_layout_paths_test.sh'"

# --- Phase 4g: Shared /run retry safety fixtures + active caller coverage ---
run_phase "Run retry fixtures" \
    bash -c "'$SCRIPT_DIR/run_retry_test.sh'"
run_phase "Shared bounded HTTP fixtures" \
    bash -c "'$SCRIPT_DIR/http_helper_test.sh'"

run_phase "Operator workflow retry fixtures" \
    bash -c "'$SCRIPT_DIR/operator_workflow_retry_test.sh'"

# --- Phase 5: Containerd integration (Docker/OrbStack) ---
if [ "$SKIP_CONTAINERD" = false ]; then
    if command -v docker &>/dev/null; then
        run_phase "Containerd integration (Docker)" \
            bash -c "'$SCRIPT_DIR/containerd/run-tests.sh'"
    else
        echo "  SKIP: Docker not available, skipping containerd tests"
    fi
else
    echo "  SKIP: containerd tests (--skip-containerd)"
fi

# --- Phase 6: Local smoke test ---
if [ "$SKIP_SMOKE" = false ]; then
    run_phase "Local smoke test" \
        bash -c "'$SCRIPT_DIR/local-smoke.sh' --build"
else
    echo "  SKIP: smoke test (--skip-smoke)"
fi

echo ""
echo "============================================"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "============================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

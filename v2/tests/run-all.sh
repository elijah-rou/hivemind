#!/bin/bash
set -euo pipefail

# Run all Hivemind tests: unit, simulation, integration, smoke
# Usage: ./tests/run-all.sh [--skip-containerd|--require-containerd] [--skip-smoke]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKIP_CONTAINERD=false
SKIP_SMOKE=false
REQUIRE_CONTAINERD="${REQUIRE_CONTAINERD:-0}"
REQUIRE_GPU="${REQUIRE_GPU:-0}"
REQUIRE_NYDUS="${REQUIRE_NYDUS:-0}"
REQUIRE_JUICEFS="${REQUIRE_JUICEFS:-0}"
CONTAINERD_RUNNER="${HIVEMIND_CONTAINERD_RUNNER:-$SCRIPT_DIR/containerd/run-tests.sh}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-containerd) SKIP_CONTAINERD=true; shift ;;
        --require-containerd) REQUIRE_CONTAINERD=1; shift ;;
        --skip-smoke) SKIP_SMOKE=true; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

for pair in "REQUIRE_CONTAINERD:$REQUIRE_CONTAINERD" "REQUIRE_GPU:$REQUIRE_GPU" "REQUIRE_NYDUS:$REQUIRE_NYDUS" "REQUIRE_JUICEFS:$REQUIRE_JUICEFS"; do
    name="${pair%%:*}"
    value="${pair#*:}"
    if [[ "$value" != 0 && "$value" != 1 ]]; then
        echo "$name must be 0 or 1" >&2
        exit 2
    fi
done
if [[ "$REQUIRE_GPU" == 1 || "$REQUIRE_NYDUS" == 1 || "$REQUIRE_JUICEFS" == 1 ]]; then
    REQUIRE_CONTAINERD=1
fi
if [[ "$SKIP_CONTAINERD" == true && "$REQUIRE_CONTAINERD" == "1" ]]; then
    echo "cannot combine --skip-containerd and --require-containerd" >&2
    exit 2
fi
if [[ "$REQUIRE_CONTAINERD" == "1" ]]; then
    if [[ ! -x "$CONTAINERD_RUNNER" ]]; then
        echo "required containerd runner is not executable: $CONTAINERD_RUNNER" >&2
        exit 1
    fi
    if ! "$CONTAINERD_RUNNER" --check; then
        echo "REQUIRE_CONTAINERD=1: containerd prerequisite/compatibility check failed" >&2
        exit 1
    fi
fi

PASS=0
FAIL=0
RUN_PHASE_TIMEOUT_SECONDS=900

run_phase() {
    local name="$1"
    shift
    echo ""
    echo "============================================"
    echo "  $name"
    echo "============================================"
    if timeout --foreground --kill-after=10s "${RUN_PHASE_TIMEOUT_SECONDS}s" "$@"; then
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
run_phase "Strict capability flag fixtures" \
    bash -c "'$SCRIPT_DIR/strict_capabilities_test.sh'"
run_phase "GPU CDI/in-container evidence fixtures" \
    bash -c "'$SCRIPT_DIR/gpu_evidence_test.sh'"
run_phase "ECR cold-cache evidence fixtures" \
    bash -c "'$SCRIPT_DIR/ecr_cold_pull_test.sh'"
run_phase "Live guardrail fixtures" \
    bash -c "'$SCRIPT_DIR/live_guardrails_test.sh'"
run_phase "Evidence manifest fixtures" \
    bash -c "'$SCRIPT_DIR/evidence_manifest_test.sh'"

# --- Phase 4f: Active docs and shared wire contracts ---
run_phase "Active docs layout path contract" \
    bash -c "'$SCRIPT_DIR/docs_layout_paths_test.sh'"
run_phase "Shared protocol-v6 wire contract" \
    bash -c "'$SCRIPT_DIR/wire-contract-test.sh'"

# --- Phase 4g: Shared /run retry safety fixtures + active caller coverage ---
run_phase "Run retry fixtures" \
    bash -c "'$SCRIPT_DIR/run_retry_test.sh'"
run_phase "Shared bounded HTTP fixtures" \
    bash -c "'$SCRIPT_DIR/http_helper_test.sh'"

run_phase "Operator workflow retry fixtures" \
    bash -c "'$SCRIPT_DIR/operator_workflow_retry_test.sh'"

# --- Phase 5: Containerd integration (Docker/privileged Linux) ---
if [[ "$SKIP_CONTAINERD" == true ]]; then
    echo "  SKIP: containerd component and full-stack tests (--skip-containerd)"
elif "$CONTAINERD_RUNNER" --check; then
    run_phase "Containerd integration (Docker)" "$CONTAINERD_RUNNER" --component
    if [[ "$REQUIRE_CONTAINERD" == "1" ]]; then
        run_phase "Containerd full-stack restart/adoption contract" "$CONTAINERD_RUNNER" --full-stack
    else
        echo "  SKIP: containerd full-stack restart/adoption contract (use --require-containerd)"
    fi
elif [[ "$REQUIRE_CONTAINERD" == "1" ]]; then
    echo "  REQUIRE_CONTAINERD=1: containerd unavailable or incompatible" >&2
    FAIL=$((FAIL + 1))
else
    echo "  SKIP: containerd unavailable or incompatible; component and full-stack boundaries unverified"
fi

# --- Phase 6: Mandatory local real-process contracts ---
run_phase "Local cluster cleanup contract" \
    bash -c "'$SCRIPT_DIR/local_cluster_cleanup_test.sh'"
if [ "$SKIP_SMOKE" = false ]; then
    run_phase "Local failover contract" \
        bash -c "'$SCRIPT_DIR/local-failover-smoke.sh' --build"
    run_phase "Local retained-storage recovery contract" \
        bash -c "'$SCRIPT_DIR/storage_mode_smoke_test.sh'"
    run_phase "Local run contract" \
        bash -c "'$SCRIPT_DIR/local-smoke.sh'"
else
    echo "  SKIP: local failover, retained-storage recovery, and run contracts (--skip-smoke)"
fi

echo ""
echo "============================================"
echo "  TOTAL: $PASS passed, $FAIL failed"
echo "============================================"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

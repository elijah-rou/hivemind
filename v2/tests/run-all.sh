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

# --- Phase 3: Go build ---
run_phase "Go build" \
    bash -c "cd '$REPO_ROOT/api' && go build ./..."

# --- Phase 4: Infra POC script tests ---
run_phase "Infra POC script tests" \
    bash -c "'$REPO_ROOT/infra/poc/test-worker-env.sh'"

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

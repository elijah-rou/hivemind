#!/usr/bin/env bash
# Offline stub fixture: gpu-test cleanup trap must run on terraform apply failure.
# Never touches live AWS/Terraform backends.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GPU_TEST="$REPO_ROOT/infra/gpu-test/run-tests.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="$TMP_DIR/bin"
STUB_STATE="$TMP_DIR/state"
mkdir -p "$STUB_BIN" "$STUB_STATE"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

if [[ ! -f "$GPU_TEST" ]]; then
  fail "missing $GPU_TEST"
  echo "FAIL: gpu_test_cleanup_trap_test ($FAIL)"
  exit 1
fi

# Source-order contract: trap cleanup EXIT must appear before terraform apply.
apply_line="$(grep -nE 'terraform[[:space:]]+apply' "$GPU_TEST" | head -n1 | cut -d: -f1)"
trap_line="$(grep -nE 'trap[[:space:]]+cleanup[[:space:]]+EXIT' "$GPU_TEST" | head -n1 | cut -d: -f1)"
if [[ -n "$apply_line" && -n "$trap_line" && "$trap_line" -lt "$apply_line" ]]; then
  pass "trap cleanup EXIT appears before terraform apply (lines $trap_line < $apply_line)"
else
  fail "trap cleanup EXIT must be installed before terraform apply (trap=$trap_line apply=$apply_line)"
fi

# KEEP_INFRA opt-out must remain supported.
if grep -qE 'KEEP_INFRA' "$GPU_TEST"; then
  pass "KEEP_INFRA opt-out present"
else
  fail "KEEP_INFRA opt-out missing"
fi

# Stub terraform: apply fails; destroy records cleanup.
cat > "$STUB_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_STATE:?}"
printf 'terraform:%s\n' "$*" >> "$STUB_STATE/calls.log"
cmd="${1:-}"
case "$cmd" in
  init) exit 0 ;;
  apply)
    echo "stub terraform apply failed" >&2
    exit 1
    ;;
  destroy)
    echo destroyed >> "$STUB_STATE/destroyed.log"
    exit 0
    ;;
  output)
    echo "i-stub"
    exit 0
    ;;
  *)
    echo "stub terraform: unexpected: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$STUB_BIN/terraform"

# Minimal aws stub (should not be reached if apply fails before SSM).
cat > "$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_STATE:?}"
printf 'aws:%s\n' "$*" >> "$STUB_STATE/aws.log"
exit 0
EOF
chmod +x "$STUB_BIN/aws"

export STUB_STATE
export PATH="$STUB_BIN:/usr/bin:/bin"

# Case 1: apply failure must still invoke destroy via EXIT trap.
rm -f "$STUB_STATE"/*
: > "$STUB_STATE/calls.log"
set +e
KEEP_INFRA=0 "$GPU_TEST" >"$TMP_DIR/out1.txt" 2>"$TMP_DIR/err1.txt"
rc1=$?
set -e
if [[ "$rc1" -ne 0 ]] && [[ -f "$STUB_STATE/destroyed.log" ]]; then
  pass "apply failure triggers terraform destroy cleanup (rc=$rc1)"
else
  fail "apply failure must trigger destroy cleanup (rc=$rc1 destroyed=$([[ -f $STUB_STATE/destroyed.log ]] && echo yes || echo no))"
  echo "--- stdout ---" >&2
  cat "$TMP_DIR/out1.txt" >&2 || true
  echo "--- stderr ---" >&2
  cat "$TMP_DIR/err1.txt" >&2 || true
  echo "--- terraform calls ---" >&2
  cat "$STUB_STATE/calls.log" >&2 || true
fi

# Case 2: KEEP_INFRA=1 must skip destroy on apply failure.
rm -f "$STUB_STATE"/*
: > "$STUB_STATE/calls.log"
set +e
KEEP_INFRA=1 "$GPU_TEST" >"$TMP_DIR/out2.txt" 2>"$TMP_DIR/err2.txt"
rc2=$?
set -e
if [[ "$rc2" -ne 0 ]] && [[ ! -f "$STUB_STATE/destroyed.log" ]]; then
  pass "KEEP_INFRA=1 skips destroy on apply failure (rc=$rc2)"
else
  fail "KEEP_INFRA=1 must skip destroy (rc=$rc2 destroyed=$([[ -f $STUB_STATE/destroyed.log ]] && echo yes || echo no))"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL: gpu_test_cleanup_trap_test ($FAIL assertion(s))"
  exit 1
fi
echo "PASS: gpu_test_cleanup_trap_test"
exit 0

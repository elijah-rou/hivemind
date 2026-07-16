#!/usr/bin/env bash
# Offline ownership fixture for infra/gpu-test/run-tests.sh.
# All Terraform, AWS, archive, and signal behavior is stubbed; no live infra is touched.
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
  echo "FAIL: missing $GPU_TEST" >&2
  exit 1
fi

apply_line="$(grep -nE 'terraform[[:space:]]+apply' "$GPU_TEST" | head -n1 | cut -d: -f1)"
trap_line="$(grep -nE 'trap[[:space:]]+cleanup[[:space:]]+EXIT' "$GPU_TEST" | head -n1 | cut -d: -f1)"
if [[ -n "$apply_line" && -n "$trap_line" && "$trap_line" -lt "$apply_line" ]]; then
  pass "cleanup trap precedes terraform apply"
else
  fail "cleanup trap must precede terraform apply (trap=$trap_line apply=$apply_line)"
fi

cat > "$STUB_BIN/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_STATE:?}"
printf 'terraform:%s\n' "$*" >> "$STUB_STATE/terraform.log"
case "${1:-}" in
  init) exit 0 ;;
  state)
    [[ "${2:-}" == "list" ]] || exit 2
    [[ "${STUB_INITIAL_STATE:-empty}" == "preexisting" ]] && echo "aws_instance.gpu_test"
    exit 0
    ;;
  apply)
    [[ "${STUB_APPLY:-failure}" == "success" ]] && exit 0
    echo "stub terraform apply failed" >&2
    exit 1
    ;;
  output) echo "i-stub" ;;
  destroy) echo destroyed >> "$STUB_STATE/destroyed.log" ;;
  *) echo "unexpected terraform call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$STUB_BIN/terraform"

cat > "$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_STATE:?}"
printf 'aws:%s\n' "$*" >> "$STUB_STATE/aws.log"
case "$*" in
  "ssm describe-instance-information"*)
    [[ "${STUB_SIGNAL:-0}" == "1" ]] && echo "None" || echo "Online"
    ;;
  "ssm send-command"*) echo "cmd-stub" ;;
  "ssm list-command-invocations"*"--details"*) echo "TESTS_COMPLETE" ;;
  "ssm list-command-invocations"*) echo "${STUB_REMOTE_STATUS:-Success}" ;;
  "s3 mb "*) echo bucket-created >> "$STUB_STATE/bucket-created.log" ;;
  "s3 rb "*) echo bucket-removed >> "$STUB_STATE/bucket-removed.log" ;;
  "s3 cp "*) : ;;
  *) echo "unexpected aws call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$STUB_BIN/aws"

cat > "$STUB_BIN/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$STUB_BIN/tar"

cat > "$STUB_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STUB_SIGNAL:-0}" == "1" ]]; then
  kill -TERM "$PPID"
fi
exit 0
EOF
chmod +x "$STUB_BIN/sleep"

export STUB_STATE
export PATH="$STUB_BIN:/usr/bin:/bin"

reset_state() {
  rm -f "$STUB_STATE"/*
  : > "$STUB_STATE/terraform.log"
  : > "$STUB_STATE/aws.log"
}

run_gpu_test() {
  local output_name="$1"
  shift
  set +e
  env "$@" "$GPU_TEST" >"$TMP_DIR/$output_name.out" 2>"$TMP_DIR/$output_name.err"
  RUN_RC=$?
  set -e
}

# Empty initial state is owned by this invocation, including partial apply resources.
reset_state
run_gpu_test empty-failure KEEP_INFRA=0 STUB_INITIAL_STATE=empty STUB_APPLY=failure
if [[ "$RUN_RC" -ne 0 && -f "$STUB_STATE/destroyed.log" ]]; then
  pass "empty-state apply failure destroys invocation-owned Terraform resources"
else
  fail "empty-state apply failure must destroy (rc=$RUN_RC)"
fi

# Required RED regression: pre-existing nonempty state must survive apply failure.
reset_state
run_gpu_test preexisting-failure KEEP_INFRA=0 STUB_INITIAL_STATE=preexisting STUB_APPLY=failure
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/destroyed.log" ]]; then
  pass "pre-existing state survives apply failure"
else
  fail "pre-existing state must not be destroyed (rc=$RUN_RC)"
fi

# Explicit retention wins even for empty state that this invocation could clean up.
reset_state
run_gpu_test keep KEEP_INFRA=1 STUB_INITIAL_STATE=empty STUB_APPLY=failure
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/destroyed.log" ]]; then
  pass "KEEP_INFRA=1 preserves invocation-owned Terraform resources"
else
  fail "KEEP_INFRA=1 must skip destroy (rc=$RUN_RC)"
fi

# Bucket ownership is independent: clean this run's bucket but preserve pre-existing Terraform state.
reset_state
run_gpu_test preexisting-remote-failure KEEP_INFRA=0 STUB_INITIAL_STATE=preexisting STUB_APPLY=success STUB_REMOTE_STATUS=Failed
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/destroyed.log" && -f "$STUB_STATE/bucket-created.log" && -f "$STUB_STATE/bucket-removed.log" ]]; then
  pass "remote failure cleans current-run bucket and preserves pre-existing Terraform state"
else
  fail "independent bucket cleanup contract failed (rc=$RUN_RC)"
fi

# TERM must preserve signal failure and run ownership-aware cleanup.
reset_state
run_gpu_test signal KEEP_INFRA=0 STUB_INITIAL_STATE=empty STUB_APPLY=success STUB_SIGNAL=1
if [[ "$RUN_RC" -eq 143 && -f "$STUB_STATE/destroyed.log" ]]; then
  pass "TERM exits 143 and destroys invocation-owned Terraform resources"
else
  fail "TERM cleanup contract failed (rc=$RUN_RC)"
fi

# Full success cleans both Terraform resources and only the bucket created by this run.
reset_state
run_gpu_test success KEEP_INFRA=0 STUB_INITIAL_STATE=empty STUB_APPLY=success STUB_REMOTE_STATUS=Success
if [[ "$RUN_RC" -eq 0 && -f "$STUB_STATE/destroyed.log" && -f "$STUB_STATE/bucket-created.log" && -f "$STUB_STATE/bucket-removed.log" ]]; then
  pass "success cleans invocation-owned Terraform resources and current-run bucket"
else
  fail "success cleanup contract failed (rc=$RUN_RC)"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL: gpu_test_cleanup_trap_test ($FAIL assertion(s))"
  exit 1
fi
echo "PASS: gpu_test_cleanup_trap_test"

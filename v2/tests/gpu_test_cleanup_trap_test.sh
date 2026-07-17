#!/usr/bin/env bash
# Offline lifecycle fixture for infra/gpu-test/run-tests.sh.
# Terraform, AWS, archive, signal, and concurrent-run behavior are stubbed.
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
workspace="${TF_WORKSPACE:-default}"
printf 'terraform:%s:workspace=%s\n' "$*" "$workspace" >> "$STUB_STATE/terraform.log"
case "${1:-}" in
  init) exit 0 ;;
  workspace) exit 0 ;;
  apply)
    if [[ "${STUB_BARRIER:-0}" == "1" ]]; then
      : > "$STUB_STATE/apply-$workspace"
      ready=0
      for _ in $(seq 1 200); do
        count=$(find "$STUB_STATE" -maxdepth 1 -name 'apply-hivemind-gpu-*' | wc -l)
        if [[ "$count" -ge 2 ]]; then ready=1; break; fi
        /bin/sleep 0.01
      done
      [[ "$ready" == "1" ]] || { echo "barrier timeout" >&2; exit 3; }
    fi
    [[ "${STUB_APPLY:-failure}" == "success" ]] && exit 0
    echo "stub terraform apply failed" >&2
    exit 1
    ;;
  output) echo "i-stub-${workspace}" ;;
  destroy)
    printf '%s\n' "$workspace" >> "$STUB_STATE/destroyed.log"
    [[ "${STUB_DESTROY:-success}" == "success" ]] || { echo "stub terraform destroy failed" >&2; exit 9; }
    ;;
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
  "ssm get-command-invocation"*"--query Status"*) echo "${STUB_REMOTE_STATUS:-Success}" ;;
  "ssm get-command-invocation"*"--query StandardOutputContent"*) echo "TESTS_COMPLETE" ;;
  "ssm get-command-invocation"*"--output json"*) echo '{"Status":"Failed"}' ;;
  "s3 mb "*) echo bucket-created >> "$STUB_STATE/bucket-created.log" ;;
  "s3 rb "*)
    [[ "${STUB_S3_RB:-success}" == "success" ]] || { echo "stub s3 remove failed" >&2; exit 8; }
    echo bucket-removed >> "$STUB_STATE/bucket-removed.log"
    ;;
  "s3 cp "*) : ;;
  *) echo "unexpected aws call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$STUB_BIN/aws"

cat > "$STUB_BIN/tar" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_STATE:?}"
printf '%s\n' "$*" >> "$STUB_STATE/tar.log"
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

reset_state
run_gpu_test apply-failure KEEP_INFRA=0 STUB_APPLY=failure
if [[ "$RUN_RC" -ne 0 && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "apply failure destroys only its workspace"
else
  fail "apply failure must destroy its workspace (rc=$RUN_RC)"
fi

reset_state
run_gpu_test keep KEEP_INFRA=1 STUB_APPLY=failure
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/destroyed.log" ]]; then
  pass "KEEP_INFRA=1 preserves the run workspace"
else
  fail "KEEP_INFRA=1 must skip destroy (rc=$RUN_RC)"
fi

reset_state
run_gpu_test signal KEEP_INFRA=0 STUB_APPLY=success STUB_SIGNAL=1
if [[ "$RUN_RC" -eq 143 && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "TERM exits 143 and destroys the run workspace"
else
  fail "TERM cleanup contract failed (rc=$RUN_RC)"
fi

reset_state
run_gpu_test success KEEP_INFRA=0 STUB_APPLY=success STUB_REMOTE_STATUS=Success
if [[ "$RUN_RC" -eq 0 && -s "$STUB_STATE/destroyed.log" && -f "$STUB_STATE/bucket-created.log" && -f "$STUB_STATE/bucket-removed.log" ]]; then
  pass "success cleans the run workspace and bucket"
else
  fail "success cleanup contract failed (rc=$RUN_RC)"
fi

reset_state
run_gpu_test success-destroy-failure KEEP_INFRA=0 STUB_APPLY=success STUB_REMOTE_STATUS=Success STUB_DESTROY=failure
if [[ "$RUN_RC" -ne 0 ]] && grep -q 'CLEANUP ERROR: terraform destroy' "$TMP_DIR/success-destroy-failure.err"; then
  pass "terraform teardown failure turns successful tests nonzero and is recorded"
else
  fail "terraform teardown failure must be recorded and fail success (rc=$RUN_RC)"
fi

reset_state
run_gpu_test success-s3-failure KEEP_INFRA=0 STUB_APPLY=success STUB_REMOTE_STATUS=Success STUB_S3_RB=failure
if [[ "$RUN_RC" -ne 0 && -s "$STUB_STATE/destroyed.log" ]] && grep -q 'CLEANUP ERROR: s3 bucket removal' "$TMP_DIR/success-s3-failure.err"; then
  pass "S3 teardown failure is recorded, fails success, and does not skip Terraform"
else
  fail "S3 teardown failure contract failed (rc=$RUN_RC)"
fi

reset_state
run_gpu_test failed-test-cleanup-failure KEEP_INFRA=0 STUB_APPLY=success STUB_REMOTE_STATUS=Failed STUB_DESTROY=failure
if [[ "$RUN_RC" -eq 1 ]] && grep -q 'CLEANUP ERROR: terraform destroy' "$TMP_DIR/failed-test-cleanup-failure.err"; then
  pass "cleanup failure preserves original test failure status"
else
  fail "cleanup must preserve original test failure status (rc=$RUN_RC)"
fi

# Two invocations synchronize inside apply. Distinct TF_WORKSPACE values prove
# neither can observe or destroy the other's state even when lifecycle overlaps.
reset_state
set +e
env KEEP_INFRA=0 STUB_APPLY=success STUB_BARRIER=1 STUB_REMOTE_STATUS=Success \
  "$GPU_TEST" >"$TMP_DIR/concurrent-a.out" 2>"$TMP_DIR/concurrent-a.err" &
pid_a=$!
env KEEP_INFRA=0 STUB_APPLY=success STUB_BARRIER=1 STUB_REMOTE_STATUS=Success \
  "$GPU_TEST" >"$TMP_DIR/concurrent-b.out" 2>"$TMP_DIR/concurrent-b.err" &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
set -e
mapfile -t applied < <(sed -n 's/^terraform:apply -auto-approve:workspace=//p' "$STUB_STATE/terraform.log" | sort -u)
mapfile -t destroyed < <(sort -u "$STUB_STATE/destroyed.log")
mapfile -t archives < <(sed -n 's/^czf \([^ ]*\).*/\1/p' "$STUB_STATE/tar.log" | sort -u)
if [[ "$rc_a" -eq 0 && "$rc_b" -eq 0 && "${#applied[@]}" -eq 2 && "${#destroyed[@]}" -eq 2 && "${applied[*]}" == "${destroyed[*]}" ]]; then
  pass "concurrent barrier runs apply and destroy two isolated workspaces"
else
  fail "concurrent workspace isolation failed (rc_a=$rc_a rc_b=$rc_b applied=${applied[*]-} destroyed=${destroyed[*]-})"
fi
if [[ "${#archives[@]}" -eq 2 && "${archives[0]}" != "${archives[1]}" && "${archives[*]}" != *"/tmp/worker-src.tar.gz"* ]]; then
  pass "concurrent runs use distinct workspace-owned worker archives"
else
  fail "concurrent archive isolation failed (archives=${archives[*]-})"
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL: gpu_test_cleanup_trap_test ($FAIL assertion(s))"
  exit 1
fi
echo "PASS: gpu_test_cleanup_trap_test"

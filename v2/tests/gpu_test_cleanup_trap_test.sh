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
  init)
    if [[ "${STUB_HANG_COMMAND:-}" == init ]]; then /bin/sleep 10; fi
    exit 0
    ;;
  workspace)
    if [[ "${STUB_HANG_COMMAND:-}" == workspace ]]; then /bin/sleep 10; fi
    exit 0
    ;;
  apply)
    if [[ "${STUB_HANG_COMMAND:-}" == apply ]]; then /bin/sleep 10; fi
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
    if [[ "${STUB_HANG_COMMAND:-}" == destroy ]]; then /bin/sleep 10; fi
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
service="${1:-}"
operation="${2:-}"
bucket=""
metadata=""
name=""
value=""
for ((i = 1; i <= $#; i++)); do
  arg="${!i}"
  if [[ "$arg" == --bucket ]]; then
    next=$((i + 1)); bucket="${!next}"
  elif [[ "$arg" == --metadata ]]; then
    next=$((i + 1)); metadata="${!next}"
  elif [[ "$arg" == --name ]]; then
    next=$((i + 1)); name="${!next}"
  elif [[ "$arg" == --value ]]; then
    next=$((i + 1)); value="${!next}"
  elif [[ "$arg" == s3://* ]]; then
    bucket="${arg#s3://}"; bucket="${bucket%%/*}"
  fi
done
bucket_state="$STUB_STATE/buckets/$bucket"
case "$service:$operation" in
  sts:get-caller-identity) echo "123456789012" ;;
  ssm:put-parameter)
    lease="$STUB_STATE/leases/${name##*/}"
    mkdir -p "$STUB_STATE/leases"
    [[ ! -e "$lease" ]] || exit 1
    if [[ "${STUB_LEASE_MODE:-}" == foreign ]]; then value='123456789012:foreign:foreign'; fi
    printf '%s' "$value" >"$lease"
    [[ "${STUB_LEASE_MODE:-}" != timeout-committed ]] || /bin/sleep 10
    ;;
  ssm:get-parameter)
    lease="$STUB_STATE/leases/${name##*/}"
    [[ -f "$lease" ]] || exit 1
    if [[ "${STUB_LEASE_MODE:-}" == read-failure-once ]]; then
      count_file="$lease.read-count"; count=0
      [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
      count=$((count + 1)); printf '%s' "$count" >"$count_file"
      (( count > 1 )) || exit 1
    fi
    [[ "${STUB_HANG_COMMAND:-}" != ssm-head ]] || /bin/sleep 10
    cat "$lease"
    ;;
  ssm:delete-parameter) rm -f "$STUB_STATE/leases/${name##*/}" ;;
  ssm:describe-instance-information)
    [[ "${STUB_SIGNAL:-0}" == "1" ]] && echo "None" || echo "Online"
    ;;
  ssm:send-command) echo "cmd-stub" ;;
  ssm:get-command-invocation)
    case "$*" in
      *"--query Status"*) echo "${STUB_REMOTE_STATUS:-Success}" ;;
      *"--query StandardOutputContent"*) echo "TESTS_COMPLETE" ;;
      *"--output json"*) echo '{"Status":"Failed"}' ;;
      *) exit 2 ;;
    esac
    ;;
  s3api:head-bucket)
    if [[ "${STUB_BUCKET_PREEXISTS:-0}" == 1 || -d "$bucket_state" ]]; then exit 0; fi
    if [[ "${STUB_HEAD_AMBIGUOUS:-0}" == 1 ]]; then
      echo 'An error occurred (403) when calling the HeadBucket operation: Forbidden' >&2
    else
      echo 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
    fi
    exit 254
    ;;
  s3api:wait) [[ ! -d "$bucket_state" ]] ;;
  s3api:create-bucket)
    mkdir -p "$bucket_state"
    echo "$bucket" >> "$STUB_STATE/bucket-created.log"
    if [[ "${STUB_HANG_COMMAND:-}" == s3-create ]]; then /bin/sleep 10; fi
    ;;
  s3api:put-object)
    [[ -d "$bucket_state" ]] || exit 1
    if [[ "${STUB_MARKER_MODE:-}" == foreign ]]; then
      printf '123456789012:foreign:foreign\n' > "$bucket_state/marker"
    fi
    [[ ! -f "$bucket_state/marker" ]] || exit 1
    account="$(sed -n 's/.*account=\([^,]*\).*/\1/p' <<<"$metadata")"
    token="$(sed -n 's/.*token=\([^,]*\).*/\1/p' <<<"$metadata")"
    claim="$(sed -n 's/.*claim=\([^,]*\).*/\1/p' <<<"$metadata")"
    case "${STUB_MARKER_MODE:-}" in
      account-mismatch) account=999999999999 ;;
      token-mismatch) token=00000000000000000000000000000000 ;;
    esac
    printf '%s:%s:%s\n' "$account" "$token" "$claim" > "$bucket_state/marker"
    if [[ "${STUB_MARKER_MODE:-}" == timeout-committed ||
          "${STUB_MARKER_MODE:-}" == account-mismatch ||
          "${STUB_MARKER_MODE:-}" == token-mismatch ]]; then
      /bin/sleep 10
    fi
    ;;
  s3api:head-object)
    [[ -f "$bucket_state/marker" ]] || exit 1
    if [[ "${STUB_HANG_COMMAND:-}" == s3-head-cleanup ]]; then
      head_count_file="$bucket_state/head-count"
      head_count=0; [[ ! -f "$head_count_file" ]] || head_count="$(cat "$head_count_file")"
      head_count=$((head_count + 1)); printf '%s
' "$head_count" >"$head_count_file"
      (( head_count == 1 )) || /bin/sleep 10
    fi
    if [[ "${STUB_MARKER_MODE:-}" == read-failure-once ]]; then
      count_file="$bucket_state/read-count"
      count=0; [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
      count=$((count + 1)); printf '%s\n' "$count" > "$count_file"
      (( count > 1 )) || exit 1
    fi
    cat "$bucket_state/marker"
    ;;
  s3:rb)
    if [[ "${STUB_HANG_COMMAND:-}" == s3-rb ]]; then /bin/sleep 10; fi
    [[ "${STUB_S3_RB:-success}" == "success" ]] || { echo "stub s3 remove failed" >&2; exit 8; }
    rm -rf "$bucket_state"
    echo "$bucket" >> "$STUB_STATE/bucket-removed.log"
    ;;
  s3:cp) : ;;
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
  rm -rf "${STUB_STATE:?}"/*
  : > "$STUB_STATE/terraform.log"
  : > "$STUB_STATE/aws.log"
}

run_gpu_test() {
  local output_name="$1"
  shift
  set +e
  env GPU_COMMAND_TIMEOUT_SEC=1 GPU_CLEANUP_TIMEOUT_SEC=4 GPU_KILL_AFTER_SEC=1 \
    "$@" "$GPU_TEST" >"$TMP_DIR/$output_name.out" 2>"$TMP_DIR/$output_name.err"
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
if [[ "$RUN_RC" -eq 0 && -s "$STUB_STATE/destroyed.log" && -f "$STUB_STATE/bucket-created.log" && -f "$STUB_STATE/bucket-removed.log" ]] &&
   grep -Eq 's3api put-object .*--if-none-match \* .*--metadata account=123456789012,token=[0-9a-f]{32},claim=[0-9a-f]{32}' "$STUB_STATE/aws.log"; then
  pass "success cleans only the account/token bucket with its conditional marker"
else
  fail "success cleanup contract failed (rc=$RUN_RC)"
fi

reset_state
run_gpu_test strict-gpu KEEP_INFRA=0 REQUIRE_GPU=1 STUB_APPLY=success STUB_REMOTE_STATUS=Success
if [[ "$RUN_RC" -eq 0 ]] && grep -q -- '--device nvidia.com/gpu=0' "$STUB_STATE/aws.log" && grep -q 'nvidia-smi' "$STUB_STATE/aws.log"; then
  pass "REQUIRE_GPU=1 sends CDI-selected in-container nvidia-smi proof"
else
  fail "REQUIRE_GPU=1 must send CDI/in-container proof (rc=$RUN_RC)"
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

reset_state
run_gpu_test hung-apply KEEP_INFRA=0 STUB_HANG_COMMAND=apply
if [[ "$RUN_RC" -ne 0 && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "hung Terraform apply is bounded and still reaches teardown"
else
  fail "hung Terraform apply must be bounded and torn down (rc=$RUN_RC)"
fi

reset_state
run_gpu_test ambiguous-s3-create KEEP_INFRA=0 STUB_APPLY=success STUB_HANG_COMMAND=s3-create
if [[ "$RUN_RC" -eq 0 && -f "$STUB_STATE/bucket-created.log" && -f "$STUB_STATE/bucket-removed.log" && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "ambiguous S3 creation is reconciled through the exact conditional marker"
else
  fail "ambiguous S3 creation must reconcile exact cleanup ownership (rc=$RUN_RC)"
fi

reset_state
run_gpu_test ambiguous-marker-write KEEP_INFRA=0 STUB_APPLY=success STUB_MARKER_MODE=timeout-committed
if [[ "$RUN_RC" -eq 0 && -f "$STUB_STATE/bucket-removed.log" && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "timed-out conditional marker write reconciles exact account/token ownership"
else
  fail "ambiguous conditional marker write must reconcile exact ownership (rc=$RUN_RC)"
fi

reset_state
run_gpu_test marker-read-transient KEEP_INFRA=0 STUB_APPLY=success STUB_MARKER_MODE=read-failure-once
if [[ "$RUN_RC" -ne 0 && -f "$STUB_STATE/bucket-removed.log" && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "conditional marker success retains provisional cleanup authority"
else
  fail "confirmed conditional marker must remain cleanup-owned after transient read failure (rc=$RUN_RC)"
fi

for mismatch in account-mismatch token-mismatch; do
  reset_state
  run_gpu_test "marker-$mismatch" KEEP_INFRA=0 STUB_APPLY=success STUB_MARKER_MODE="$mismatch"
  if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/bucket-removed.log" ]] && ! grep -q 's3 rb' "$STUB_STATE/aws.log"; then
    pass "$mismatch marker never grants GPU bucket deletion authority"
  else
    fail "$mismatch marker must prevent GPU bucket deletion (rc=$RUN_RC)"
  fi
done

reset_state
run_gpu_test ambiguous-head KEEP_INFRA=0 STUB_APPLY=success STUB_HEAD_AMBIGUOUS=1
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/bucket-created.log" && ! -f "$STUB_STATE/bucket-removed.log" ]]; then
  pass "ambiguous bucket absence fails before creation"
else
  fail "ambiguous bucket absence must not mutate S3 (rc=$RUN_RC)"
fi

reset_state
run_gpu_test preexisting-s3 KEEP_INFRA=0 STUB_APPLY=success STUB_BUCKET_PREEXISTS=1
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/bucket-removed.log" ]] && ! grep -q 's3 rb' "$STUB_STATE/aws.log"; then
  pass "pre-existing S3 bucket is never adopted or deleted"
else
  fail "pre-existing S3 bucket must remain untouched (rc=$RUN_RC)"
fi

reset_state
run_gpu_test lease-read-failure KEEP_INFRA=0 STUB_APPLY=success STUB_LEASE_MODE=read-failure-once
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/bucket-created.log" ]] && \
    ! find "$STUB_STATE/leases" -type f ! -name '*.read-count' -print -quit 2>/dev/null | grep -q .; then
  pass "definitive lease creation survives transient read and is cleaned safely"
else
  fail "transient lease read must retain provisional cleanup authority (rc=$RUN_RC)"
fi

reset_state
run_gpu_test lease-race KEEP_INFRA=0 STUB_APPLY=success STUB_LEASE_MODE=foreign
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/bucket-created.log" ]] && ! grep -q 's3api create-bucket' "$STUB_STATE/aws.log"; then
  pass "account-scoped bucket lease rejects a racing claimant"
else
  fail "foreign bucket lease must prevent S3 creation (rc=$RUN_RC)"
fi

reset_state
run_gpu_test marker-race KEEP_INFRA=0 STUB_APPLY=success STUB_MARKER_MODE=foreign
if [[ "$RUN_RC" -ne 0 && ! -f "$STUB_STATE/bucket-removed.log" ]] && ! grep -q 's3 rb' "$STUB_STATE/aws.log"; then
  pass "conditional ownership marker rejects a racing claimant"
else
  fail "foreign ownership marker must prevent deletion (rc=$RUN_RC)"
fi

reset_state
run_gpu_test hung-s3-cleanup KEEP_INFRA=0 STUB_APPLY=success STUB_REMOTE_STATUS=Success STUB_HANG_COMMAND=s3-rb
if [[ "$RUN_RC" -ne 0 && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "hung S3 cleanup is bounded and does not skip Terraform teardown"
else
  fail "hung S3 cleanup must not block Terraform teardown (rc=$RUN_RC)"
fi

reset_state
start_seconds="$SECONDS"
run_gpu_test hung-marker-read KEEP_INFRA=0 STUB_APPLY=success STUB_REMOTE_STATUS=Success STUB_HANG_COMMAND=s3-head-cleanup GPU_COMMAND_TIMEOUT_SEC=900
elapsed=$((SECONDS - start_seconds))
if [[ "$RUN_RC" -ne 0 && "$elapsed" -lt 10 && -s "$STUB_STATE/destroyed.log" ]]; then
  pass "hung marker verification obeys the aggregate cleanup deadline"
else
  fail "hung marker verification must be bounded by cleanup deadline (rc=$RUN_RC elapsed=$elapsed)"
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

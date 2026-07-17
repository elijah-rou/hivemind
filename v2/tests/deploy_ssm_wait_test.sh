#!/usr/bin/env bash
# shellcheck disable=SC2329 # Fixture callbacks are invoked indirectly by run_case and sourced helpers.
# Deterministic offline fixtures for infra/bench SSM wait + deploy contract.
# Uses a stub aws CLI; never touches live AWS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WAIT_LIB="$REPO_ROOT/infra/bench/ssm_wait.sh"
DEPLOY="$REPO_ROOT/infra/bench/deploy.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

STUB_BIN="$TMP_DIR/bin"
STUB_STATE="$TMP_DIR/state"
mkdir -p "$STUB_BIN" "$STUB_STATE"

FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

# Stub aws: scripted get-command-invocation Status and API-error sequences per command_id.
# State files:
#   $STUB_STATE/<command_id>.seq — newline-separated Status values consumed FIFO
#   $STUB_STATE/<command_id>.api_errors — newline-separated AWS error codes consumed FIFO
#   $STUB_STATE/<command_id>.fail_api — if present, every invocation fails with its error code
#   $STUB_STATE/calls.log — append-only call log
cat > "$STUB_BIN/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${STUB_STATE:?}"
printf 'aws:%s\n' "$*" >> "$STUB_STATE/calls.log"

if [[ "${1:-}" != "ssm" ]]; then
  echo "stub aws: unexpected service: ${1:-}" >&2
  exit 2
fi
shift

cmd="${1:-}"
shift || true

region=""
command_id=""
instance_id=""
query=""
output="text"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) region="$2"; shift 2 ;;
    --command-id) command_id="$2"; shift 2 ;;
    --instance-id) instance_id="$2"; shift 2 ;;
    --instance-ids) instance_id="$2"; shift 2 ;;
    --document-name) shift 2 ;;
    --parameters|--filters) shift 2 ;;
    --query) query="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$cmd" in
  describe-instance-information)
    if [[ -f "$STUB_STATE/hang_describe" ]]; then /bin/sleep 5; fi
    status_file="$STUB_STATE/ping.seq"
    status="None"
    if [[ -s "$status_file" ]]; then
      status="$(head -n1 "$status_file")"
      tail -n +2 "$status_file" > "$status_file.tmp"
      mv "$status_file.tmp" "$status_file"
    fi
    printf '%s\n' "$status"
    ;;
  send-command)
    cid="cmd-${instance_id:-unknown}"
    printf '%s\n' "$cid" >> "$STUB_STATE/send_command.log"
    if [[ -f "$STUB_STATE/dead_start" ]]; then
      printf '%s\n' Failed > "$STUB_STATE/${cid}.seq"
      printf '%s\n' "FAILED TO START" > "$STUB_STATE/${cid}.stdout"
    else
      printf '%s\n' Success > "$STUB_STATE/${cid}.seq"
    fi
    printf '%s\n' "$cid"
    exit 0
    ;;
  get-command-invocation)
    [[ -n "$command_id" ]] || { echo "missing command-id" >&2; exit 2; }
    [[ -n "$instance_id" ]] || { echo "missing instance-id" >&2; exit 2; }
    printf '%s\n' "$command_id|$instance_id" >> "$STUB_STATE/seen_pairs.log"
    if [[ -f "$STUB_STATE/${command_id}.fail_api" ]]; then
      error_code="$(cat "$STUB_STATE/${command_id}.fail_api")"
      echo "An error occurred (${error_code:-InternalError}) when calling the GetCommandInvocation operation: simulated API error" >&2
      exit 1
    fi
    error_file="$STUB_STATE/${command_id}.api_errors"
    if [[ -s "$error_file" ]]; then
      error_code="$(head -n1 "$error_file")"
      tail -n +2 "$error_file" > "$error_file.tmp"
      mv "$error_file.tmp" "$error_file"
      echo "An error occurred ($error_code) when calling the GetCommandInvocation operation: simulated API error" >&2
      exit 1
    fi
    seq_file="$STUB_STATE/${command_id}.seq"
    if [[ ! -f "$seq_file" ]]; then
      echo "no sequence for $command_id" >&2
      exit 1
    fi
    status="$(head -n1 "$seq_file")"
    if [[ -z "$status" ]]; then
      echo "sequence exhausted for $command_id" >&2
      exit 1
    fi
    # Drop consumed status line (keep remainder).
    tail -n +2 "$seq_file" > "$seq_file.tmp"
    mv "$seq_file.tmp" "$seq_file"

    if [[ "$query" == "Status" || "$query" == "Status"* ]]; then
      if [[ "$output" == "json" ]]; then
        printf '"%s"\n' "$status"
      else
        printf '%s\n' "$status"
      fi
      exit 0
    fi
    # Diagnostics dump path (--output json, no Status-only query).
    printf '{"Status":"%s","StatusDetails":"stub","StandardOutputContent":"out-%s","StandardErrorContent":"err-%s","CommandId":"%s","InstanceId":"%s"}\n' \
      "$status" "$command_id" "$command_id" "$command_id" "$instance_id"
    exit 0
    ;;
  *)
    echo "stub aws: unexpected ssm command: $cmd" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$STUB_BIN/aws"

export STUB_STATE
export PATH="$STUB_BIN:/usr/bin:/bin"

# Deterministic wall clock for ssm_wait.sh deadline accounting.
FAKE_NOW=1000000
export FAKE_NOW

# Advance fake clock on sleep (waiter uses hivemind_ssm_now).
sleep() {
  local n="${1:-1}"
  FAKE_NOW=$((FAKE_NOW + n))
}
export -f sleep

if [[ ! -f "$WAIT_LIB" ]]; then
  fail "missing wait library: $WAIT_LIB"
  echo "FAIL: deploy_ssm_wait_test ($FAIL)"
  exit 1
fi

# shellcheck source=/dev/null
source "$WAIT_LIB"

# Override after source so wall-clock deadline is deterministic.
hivemind_ssm_now() { echo "$FAKE_NOW"; }

reset_state() {
  rm -f "$STUB_STATE"/*
  : > "$STUB_STATE/calls.log"
  : > "$STUB_STATE/seen_pairs.log"
  FAKE_NOW=1000000
}

run_case() {
  local name="$1"
  shift
  reset_state
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

# Case helpers are invoked indirectly via run_case "$@".
case_pending_inprogress_success() {
  printf '%s\n' Pending InProgress Success > "$STUB_STATE/cmd-a.seq"
  SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-a" "i-aaa"
}

case_failed() {
  printf '%s\n' Pending Failed > "$STUB_STATE/cmd-b.seq"
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-b" "i-bbb" 2>"$TMP_DIR/failed.err"; then
    echo "expected failure for Failed status" >&2
    return 1
  fi
  grep -q 'terminal status=Failed' "$TMP_DIR/failed.err"
}

case_timedout() {
  printf '%s\n' InProgress TimedOut > "$STUB_STATE/cmd-c.seq"
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-c" "i-ccc" 2>"$TMP_DIR/timedout.err"; then
    echo "expected failure for TimedOut" >&2
    return 1
  fi
  grep -q 'terminal status=TimedOut' "$TMP_DIR/timedout.err"
}

case_cancelled() {
  printf '%s\n' Pending Cancelled > "$STUB_STATE/cmd-d.seq"
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-d" "i-ddd" 2>"$TMP_DIR/cancelled.err"; then
    echo "expected failure for Cancelled" >&2
    return 1
  fi
  grep -q 'terminal status=Cancelled' "$TMP_DIR/cancelled.err"
}

case_eventual_visibility_then_success() {
  printf '%s\n' InvocationDoesNotExist InvocationDoesNotExist > "$STUB_STATE/cmd-visible.api_errors"
  printf '%s\n' Pending Success > "$STUB_STATE/cmd-visible.seq"
  SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-visible" "i-visible"
  local status_calls
  status_calls=$(grep -c 'get-command-invocation.*--query Status' "$STUB_STATE/calls.log" || true)
  (( status_calls == 4 ))
}

case_persistent_eventual_visibility_timeout() {
  yes InvocationDoesNotExist | head -n 50 > "$STUB_STATE/cmd-not-visible.api_errors"
  printf '%s\n' Success > "$STUB_STATE/cmd-not-visible.seq"
  local start_now=$FAKE_NOW
  local timeout_sec=5
  if SSM_POLL_INTERVAL_SEC=2 SSM_POLL_TIMEOUT_SEC=$timeout_sec \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-not-visible" "i-not-visible" 2>"$TMP_DIR/not-visible.err"; then
    echo "expected eventual-visibility timeout" >&2
    return 1
  fi
  grep -q 'SSM poll timeout after 5s' "$TMP_DIR/not-visible.err" || {
    echo "missing eventual-visibility timeout" >&2
    return 1
  }
  grep -q 'status=InvocationDoesNotExist' "$TMP_DIR/not-visible.err" || {
    echo "missing eventual-visibility timeout status" >&2
    return 1
  }
  if (( FAKE_NOW > start_now + timeout_sec )); then
    echo "eventual-visibility deadline overrun" >&2
    return 1
  fi
}

case_permanent_api_error_fails_fast() {
  printf '%s\n' Pending > "$STUB_STATE/cmd-e.seq"
  printf '%s\n' AccessDeniedException > "$STUB_STATE/cmd-e.fail_api"
  local start_now=$FAKE_NOW
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-e" "i-eee" 2>"$TMP_DIR/api.err"; then
    echo "expected failure for permanent API error" >&2
    return 1
  fi
  grep -q 'API error' "$TMP_DIR/api.err"
  grep -q 'AccessDeniedException' "$TMP_DIR/api.err"
  local status_calls
  status_calls=$(grep -c 'get-command-invocation.*--query Status' "$STUB_STATE/calls.log" || true)
  (( status_calls == 1 && FAKE_NOW == start_now ))
}

case_bounded_timeout() {
  # Stay Pending forever within the stub sequence refill: keep rewriting Pending.
  # Use a short timeout and count Status polls via calls.log.
  : > "$STUB_STATE/cmd-f.seq"
  # Pre-fill enough Pending lines for several polls.
  yes Pending | head -n 50 > "$STUB_STATE/cmd-f.seq"
  if SSM_POLL_INTERVAL_SEC=2 SSM_POLL_TIMEOUT_SEC=5 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-f" "i-fff" 2>"$TMP_DIR/timeout.err"; then
    echo "expected poll timeout" >&2
    return 1
  fi
  grep -q 'SSM poll timeout after 5s' "$TMP_DIR/timeout.err"
  # With sleep stubbed to no-op, elapsed still advances by interval each loop.
  # Timeout at 5 with interval 2 => polls at t=0,2,4 then exit (3+ Status queries).
  local status_calls
  status_calls=$(grep -c 'get-command-invocation.*--query Status' "$STUB_STATE/calls.log" || true)
  (( status_calls >= 2 && status_calls <= 5 ))
}


case_timeout_diagnostics_no_deadline_overrun() {
  # After wall-clock timeout, diagnostics must not spend extra AWS budget past deadline,
  # but must still emit useful terminal identity/status lines.
  yes Pending | head -n 50 > "$STUB_STATE/cmd-overrun.seq"
  FAKE_NOW=1000000
  local start_now=$FAKE_NOW
  local timeout_sec=5
  if SSM_POLL_INTERVAL_SEC=2 SSM_POLL_TIMEOUT_SEC=$timeout_sec \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-overrun" "i-overrun" 2>"$TMP_DIR/overrun.err"; then
    echo "expected poll timeout" >&2
    return 1
  fi
  grep -q 'SSM poll timeout after 5s' "$TMP_DIR/overrun.err" || {
    echo "missing poll timeout message" >&2
    return 1
  }
  # Useful terminal diagnostics without requiring a post-deadline AWS dump.
  grep -q 'command_id=cmd-overrun' "$TMP_DIR/overrun.err" || {
    echo "missing command_id diagnostic" >&2
    return 1
  }
  grep -q 'instance_id=i-overrun' "$TMP_DIR/overrun.err" || {
    echo "missing instance_id diagnostic" >&2
    return 1
  }
  # No diagnostic dump AWS call after deadline: dump uses --output json without Status query.
  local dump_calls
  dump_calls=$(grep -cE 'get-command-invocation.*--output json' "$STUB_STATE/calls.log" || true)
  if (( dump_calls != 0 )); then
    echo "deadline-exhausted path must not call diagnostic AWS dump (got $dump_calls)" >&2
    return 1
  fi
  # Wall clock must not advance past start+timeout due to post-deadline dump work.
  local deadline=$((start_now + timeout_sec))
  if (( FAKE_NOW > deadline )); then
    echo "deadline overrun: FAKE_NOW=$FAKE_NOW deadline=$deadline" >&2
    return 1
  fi
  return 0
}

case_per_node_command_ids() {
  printf '%s\n' Success > "$STUB_STATE/cmd-node0.seq"
  printf '%s\n' Pending Success > "$STUB_STATE/cmd-node1.seq"
  SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-node0" "i-n0"
  SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-node1" "i-n1"
  grep -qx 'cmd-node0|i-n0' "$STUB_STATE/seen_pairs.log"
  grep -qx 'cmd-node1|i-n1' "$STUB_STATE/seen_pairs.log"
  # Ensure both distinct command IDs were queried.
  grep -q -- '--command-id cmd-node0' "$STUB_STATE/calls.log"
  grep -q -- '--command-id cmd-node1' "$STUB_STATE/calls.log"
}

case_invalid_bounds() {
  if SSM_POLL_INTERVAL_SEC=0 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-x" "i-x" 2>"$TMP_DIR/bounds.err"; then
    echo "expected bounds failure" >&2
    return 1
  fi
  grep -q 'SSM_POLL_INTERVAL_SEC' "$TMP_DIR/bounds.err"
}

case_missing_timeout_fails_before_aws() {
  local empty_path="$TMP_DIR/no-timeout"
  mkdir -p "$empty_path"
  local calls_before calls_after
  calls_before="$(wc -l < "$STUB_STATE/calls.log")"
  if PATH="$empty_path" SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-no-timeout" "i-no-timeout" 2>"$TMP_DIR/no-timeout.err"; then
    echo "expected missing timeout failure" >&2
    return 1
  fi
  calls_after="$(wc -l < "$STUB_STATE/calls.log")"
  [[ "$calls_after" -eq "$calls_before" ]]
  grep -q 'timeout(1) is required' "$TMP_DIR/no-timeout.err"
}


case_deploy_dead_process_fail_closed() {
  touch "$STUB_STATE/dead_start"
  cid=$(aws ssm send-command --region us-east-1 --instance-ids i-dead \
    --document-name AWS-RunShellScript --parameters commands="[]" \
    --output text --query 'Command.CommandId')
  [[ "$cid" == "cmd-i-dead" ]] || { echo "bad command id: $cid" >&2; return 1; }
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "$cid" "i-dead" 2>"$TMP_DIR/dead.err"; then
    echo "expected dead-process wait failure" >&2
    return 1
  fi
  grep -q 'terminal status=Failed' "$TMP_DIR/dead.err"
  # Managed service start must verify active state and propagate failure.
  grep -q 'hivemind_unit_start_verified' "$DEPLOY"
  grep -q 'systemctl is-active --quiet' "$(dirname "$DEPLOY")/systemd_lifecycle.sh"
  grep -q 'return 1' "$(dirname "$DEPLOY")/systemd_lifecycle.sh"
}

case_online_eventual_success() {
  printf '%s\n' None Offline Online > "$STUB_STATE/ping.seq"
  SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=5 \
    hivemind_ssm_wait_online us-east-1 i-online
  [[ "$(grep -c 'describe-instance-information' "$STUB_STATE/calls.log")" -eq 3 ]]
}

case_online_deadline_exhaustion() {
  yes Offline | head -n 20 > "$STUB_STATE/ping.seq"
  if SSM_POLL_INTERVAL_SEC=2 SSM_POLL_TIMEOUT_SEC=5 \
    hivemind_ssm_wait_online us-east-1 i-offline 2>"$TMP_DIR/offline.err"; then
    return 1
  fi
  grep -q 'never Online' "$TMP_DIR/offline.err"
}

case_hung_cli_is_bounded() {
  touch "$STUB_STATE/hang_describe"
  local start=$SECONDS
  if hivemind_ssm_aws 1 ssm describe-instance-information --region us-east-1 >/dev/null 2>&1; then
    return 1
  fi
  (( SECONDS - start <= 2 ))
}

run_case "readiness eventual success" case_online_eventual_success
run_case "readiness deadline exhaustion" case_online_deadline_exhaustion
run_case "hung AWS CLI bounded" case_hung_cli_is_bounded
run_case "Pending/InProgress/Success" case_pending_inprogress_success
run_case "terminal Failed" case_failed
run_case "terminal TimedOut" case_timedout
run_case "terminal Cancelled" case_cancelled
run_case "eventual visibility then Pending/Success" case_eventual_visibility_then_success
run_case "persistent eventual visibility reaches deadline" case_persistent_eventual_visibility_timeout
run_case "permanent API error fails fast" case_permanent_api_error_fails_fast
run_case "bounded timeout" case_bounded_timeout
run_case "timeout diagnostics no deadline overrun" case_timeout_diagnostics_no_deadline_overrun
run_case "per-node command IDs" case_per_node_command_ids
run_case "invalid poll bounds" case_invalid_bounds
run_case "missing timeout fails before AWS" case_missing_timeout_fails_before_aws
run_case "deploy dead-process fail-closed" case_deploy_dead_process_fail_closed

# Deploy script must source the waiter and poll captured CommandIds (not fire-and-forget).
if [[ ! -f "$DEPLOY" ]]; then
  fail "missing deploy.sh"
else
  if grep -qE 'hivemind_ssm_wait_invocation|source[[:space:]].*ssm_wait\.sh' "$DEPLOY"; then
    pass "deploy.sh sources/uses ssm wait"
  else
    fail "deploy.sh must source ssm_wait.sh and wait on invocations"
  fi
  if grep -qE 'Command\.CommandId.*&[[:space:]]*$' "$DEPLOY"; then
    fail "deploy.sh still backgrounds send-command without capturing CommandId"
  else
    pass "deploy.sh does not background send-command CommandId capture"
  fi
  if grep -q 'mapfile[[:space:]]\+-t[[:space:]]\+START_ARGS' "$DEPLOY"; then
    pass "deploy.sh preserves mapfile START_ARGS"
  else
    fail "deploy.sh must keep mapfile START_ARGS"
  fi
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL: deploy_ssm_wait_test ($FAIL assertion(s))"
  exit 1
fi
echo "PASS: deploy_ssm_wait_test"
exit 0

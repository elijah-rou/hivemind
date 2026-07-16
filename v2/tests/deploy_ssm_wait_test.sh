#!/usr/bin/env bash
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

# Stub aws: scripted get-command-invocation Status sequences per command_id.
# State files:
#   $STUB_STATE/<command_id>.seq  — newline-separated Status values consumed FIFO
#   $STUB_STATE/<command_id>.fail_api — if present, get-command-invocation exits 1
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
    --query) query="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "$cmd" in
  get-command-invocation)
    [[ -n "$command_id" ]] || { echo "missing command-id" >&2; exit 2; }
    [[ -n "$instance_id" ]] || { echo "missing instance-id" >&2; exit 2; }
    printf '%s\n' "$command_id|$instance_id" >> "$STUB_STATE/seen_pairs.log"
    if [[ -f "$STUB_STATE/${command_id}.fail_api" ]]; then
      echo "simulated API error" >&2
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

# Override sleep to advance instantly while still counting intervals.
# Invoked from sourced ssm_wait.sh during polls (export -f).
# shellcheck disable=SC2329
sleep() { :; }
export -f sleep

if [[ ! -f "$WAIT_LIB" ]]; then
  fail "missing wait library: $WAIT_LIB"
  echo "FAIL: deploy_ssm_wait_test ($FAIL)"
  exit 1
fi

# shellcheck source=/dev/null
source "$WAIT_LIB"

reset_state() {
  rm -f "$STUB_STATE"/*
  : > "$STUB_STATE/calls.log"
  : > "$STUB_STATE/seen_pairs.log"
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
# shellcheck disable=SC2329
case_pending_inprogress_success() {
  printf '%s\n' Pending InProgress Success > "$STUB_STATE/cmd-a.seq"
  SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-a" "i-aaa"
}

# shellcheck disable=SC2329
case_failed() {
  printf '%s\n' Pending Failed > "$STUB_STATE/cmd-b.seq"
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-b" "i-bbb" 2>"$TMP_DIR/failed.err"; then
    echo "expected failure for Failed status" >&2
    return 1
  fi
  grep -q 'terminal status=Failed' "$TMP_DIR/failed.err"
}

# shellcheck disable=SC2329
case_timedout() {
  printf '%s\n' InProgress TimedOut > "$STUB_STATE/cmd-c.seq"
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-c" "i-ccc" 2>"$TMP_DIR/timedout.err"; then
    echo "expected failure for TimedOut" >&2
    return 1
  fi
  grep -q 'terminal status=TimedOut' "$TMP_DIR/timedout.err"
}

# shellcheck disable=SC2329
case_cancelled() {
  printf '%s\n' Pending Cancelled > "$STUB_STATE/cmd-d.seq"
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-d" "i-ddd" 2>"$TMP_DIR/cancelled.err"; then
    echo "expected failure for Cancelled" >&2
    return 1
  fi
  grep -q 'terminal status=Cancelled' "$TMP_DIR/cancelled.err"
}

# shellcheck disable=SC2329
case_api_error() {
  printf '%s\n' Pending > "$STUB_STATE/cmd-e.seq"
  touch "$STUB_STATE/cmd-e.fail_api"
  if SSM_POLL_INTERVAL_SEC=1 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-e" "i-eee" 2>"$TMP_DIR/api.err"; then
    echo "expected failure for API error" >&2
    return 1
  fi
  grep -q 'API error' "$TMP_DIR/api.err"
}

# shellcheck disable=SC2329
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

# shellcheck disable=SC2329
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

# shellcheck disable=SC2329
case_invalid_bounds() {
  if SSM_POLL_INTERVAL_SEC=0 SSM_POLL_TIMEOUT_SEC=10 \
    hivemind_ssm_wait_invocation "us-east-1" "cmd-x" "i-x" 2>"$TMP_DIR/bounds.err"; then
    echo "expected bounds failure" >&2
    return 1
  fi
  grep -q 'SSM_POLL_INTERVAL_SEC' "$TMP_DIR/bounds.err"
}

run_case "Pending/InProgress/Success" case_pending_inprogress_success
run_case "terminal Failed" case_failed
run_case "terminal TimedOut" case_timedout
run_case "terminal Cancelled" case_cancelled
run_case "API error" case_api_error
run_case "bounded timeout" case_bounded_timeout
run_case "per-node command IDs" case_per_node_command_ids
run_case "invalid poll bounds" case_invalid_bounds

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
  if grep -q 'mapfile[[:space:]]\+-t[[:space:]]\+START_COMMANDS' "$DEPLOY"; then
    pass "deploy.sh preserves mapfile START_COMMANDS"
  else
    fail "deploy.sh must keep mapfile START_COMMANDS"
  fi
fi

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL: deploy_ssm_wait_test ($FAIL assertion(s))"
  exit 1
fi
echo "PASS: deploy_ssm_wait_test"
exit 0

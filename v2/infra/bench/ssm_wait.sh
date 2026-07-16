#!/usr/bin/env bash
# Bounded SSM get-command-invocation waiter for bench deploy.
# Sourced by deploy.sh; also exercisable offline via stub aws fixtures.

# Defaults are intentionally conservative for remote install/start.
: "${SSM_POLL_INTERVAL_SEC:=5}"
: "${SSM_POLL_TIMEOUT_SEC:=300}"

hivemind_ssm_assert_poll_bounds() {
  # shellcheck disable=SC2015
  [[ "$SSM_POLL_INTERVAL_SEC" =~ ^[1-9][0-9]*$ ]] \
    || { echo "FAIL: SSM_POLL_INTERVAL_SEC must be a positive integer (got: ${SSM_POLL_INTERVAL_SEC})" >&2; return 1; }
  [[ "$SSM_POLL_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] \
    || { echo "FAIL: SSM_POLL_TIMEOUT_SEC must be a positive integer (got: ${SSM_POLL_TIMEOUT_SEC})" >&2; return 1; }
  (( SSM_POLL_TIMEOUT_SEC >= SSM_POLL_INTERVAL_SEC )) \
    || { echo "FAIL: SSM_POLL_TIMEOUT_SEC ($SSM_POLL_TIMEOUT_SEC) < SSM_POLL_INTERVAL_SEC ($SSM_POLL_INTERVAL_SEC)" >&2; return 1; }
}

hivemind_ssm_dump_invocation() {
  local region="$1" command_id="$2" instance_id="$3"
  echo "--- SSM invocation diagnostics ---" >&2
  echo "region=$region command_id=$command_id instance_id=$instance_id" >&2
  aws ssm get-command-invocation \
    --region "$region" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --output json >&2 || true
}

# Wait until one command/instance reaches Success.
# Fail-fast on Failed/TimedOut/Cancelled and on AWS API errors.
# Returns 0 on Success; non-zero on terminal failure or bounded timeout.
hivemind_ssm_wait_invocation() {
  local region="$1" command_id="$2" instance_id="$3"
  local elapsed=0 status="" sleep_for=0

  [[ -n "$region" ]] || { echo "FAIL: empty region" >&2; return 1; }
  [[ -n "$command_id" && "$command_id" != "None" ]] \
    || { echo "FAIL: empty command_id" >&2; return 1; }
  [[ -n "$instance_id" && "$instance_id" != "None" ]] \
    || { echo "FAIL: empty instance_id" >&2; return 1; }

  hivemind_ssm_assert_poll_bounds || return 1

  while (( elapsed <= SSM_POLL_TIMEOUT_SEC )); do
    if ! status=$(aws ssm get-command-invocation \
      --region "$region" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' \
      --output text 2>/dev/null); then
      echo "FAIL: aws ssm get-command-invocation API error for command_id=$command_id instance_id=$instance_id" >&2
      hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id"
      return 1
    fi

    case "$status" in
      Success)
        echo "  $instance_id: Success ($command_id)"
        return 0
        ;;
      Failed|TimedOut|Cancelled|Cancelling|DeliveryTimedOut|Undeliverable|Terminated)
        echo "FAIL: SSM command terminal status=$status command_id=$command_id instance_id=$instance_id" >&2
        hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id"
        return 1
        ;;
      Pending|InProgress|Delayed|""|None)
        ;;
      *)
        echo "FAIL: unknown SSM status='$status' command_id=$command_id instance_id=$instance_id" >&2
        hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id"
        return 1
        ;;
    esac

    sleep_for=$SSM_POLL_INTERVAL_SEC
    if (( elapsed + sleep_for > SSM_POLL_TIMEOUT_SEC )); then
      sleep_for=$((SSM_POLL_TIMEOUT_SEC - elapsed))
    fi
    if (( sleep_for <= 0 )); then
      break
    fi
    sleep "$sleep_for"
    elapsed=$((elapsed + sleep_for))
  done

  echo "FAIL: SSM poll timeout after ${SSM_POLL_TIMEOUT_SEC}s status=${status:-unknown} command_id=$command_id instance_id=$instance_id" >&2
  hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id"
  return 1
}

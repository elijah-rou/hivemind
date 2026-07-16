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

hivemind_ssm_now() {
  date +%s
}

hivemind_ssm_remaining() {
  local deadline="$1"
  local now
  now="$(hivemind_ssm_now)"
  echo $((deadline - now))
}

# Run aws with a hard wall-clock bound of remaining seconds (minimum 1).
hivemind_ssm_aws() {
  local remaining="$1"
  shift
  if (( remaining < 1 )); then
    return 124
  fi
  # Bound connect/read via AWS CLI knobs and an outer timeout(1) when available.
  if command -v timeout >/dev/null 2>&1; then
    AWS_CLI_CONNECT_TIMEOUT="$remaining" AWS_CLI_READ_TIMEOUT="$remaining" \
      timeout --signal=KILL "$remaining" aws "$@"
  else
    AWS_CLI_CONNECT_TIMEOUT="$remaining" AWS_CLI_READ_TIMEOUT="$remaining" \
      aws "$@"
  fi
}

hivemind_ssm_dump_invocation() {
  local region="$1" command_id="$2" instance_id="$3" remaining="${4:-5}"
  echo "--- SSM invocation diagnostics ---" >&2
  echo "region=$region command_id=$command_id instance_id=$instance_id" >&2
  hivemind_ssm_aws "$remaining" ssm get-command-invocation \
    --region "$region" \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --output json >&2 || true
}

# Wait until one command/instance reaches Success.
# Fail-fast on Failed/TimedOut/Cancelled and on AWS API errors.
# Returns 0 on Success; non-zero on terminal failure or wall-clock timeout.
hivemind_ssm_wait_invocation() {
  local region="$1" command_id="$2" instance_id="$3"
  local status="" sleep_for=0 remaining=0
  local start deadline now

  [[ -n "$region" ]] || { echo "FAIL: empty region" >&2; return 1; }
  [[ -n "$command_id" && "$command_id" != "None" ]] \
    || { echo "FAIL: empty command_id" >&2; return 1; }
  [[ -n "$instance_id" && "$instance_id" != "None" ]] \
    || { echo "FAIL: empty instance_id" >&2; return 1; }

  hivemind_ssm_assert_poll_bounds || return 1

  start="$(hivemind_ssm_now)"
  deadline=$((start + SSM_POLL_TIMEOUT_SEC))

  while true; do
    now="$(hivemind_ssm_now)"
    remaining=$((deadline - now))
    if (( remaining <= 0 )); then
      break
    fi

    if ! status=$(hivemind_ssm_aws "$remaining" ssm get-command-invocation \
      --region "$region" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' \
      --output text 2>/dev/null); then
      echo "FAIL: aws ssm get-command-invocation API error for command_id=$command_id instance_id=$instance_id" >&2
      remaining="$(hivemind_ssm_remaining "$deadline")"
      hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id" "$remaining"
      return 1
    fi

    case "$status" in
      Success)
        echo "  $instance_id: Success ($command_id)"
        return 0
        ;;
      Failed|TimedOut|Cancelled|Cancelling|DeliveryTimedOut|Undeliverable|Terminated)
        echo "FAIL: SSM command terminal status=$status command_id=$command_id instance_id=$instance_id" >&2
        remaining="$(hivemind_ssm_remaining "$deadline")"
        hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id" "$remaining"
        return 1
        ;;
      Pending|InProgress|Delayed|""|None)
        ;;
      *)
        echo "FAIL: unknown SSM status='$status' command_id=$command_id instance_id=$instance_id" >&2
        remaining="$(hivemind_ssm_remaining "$deadline")"
        hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id" "$remaining"
        return 1
        ;;
    esac

    now="$(hivemind_ssm_now)"
    remaining=$((deadline - now))
    if (( remaining <= 0 )); then
      break
    fi
    sleep_for=$SSM_POLL_INTERVAL_SEC
    if (( sleep_for > remaining )); then
      sleep_for=$remaining
    fi
    sleep "$sleep_for"
  done

  echo "FAIL: SSM poll timeout after ${SSM_POLL_TIMEOUT_SEC}s status=${status:-unknown} command_id=$command_id instance_id=$instance_id" >&2
  remaining="$(hivemind_ssm_remaining "$deadline")"
  if (( remaining < 1 )); then remaining=1; fi
  hivemind_ssm_dump_invocation "$region" "$command_id" "$instance_id" "$remaining"
  return 1
}

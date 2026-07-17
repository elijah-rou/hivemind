#!/usr/bin/env bash
# Safe PID-state primitives for bench deploy. Source on the target node.

hivemind_stop_verified() {
    local state_file="$1" runs_root="$2" proc_root="${3:-/proc}" kill_bin="${4:-kill}"
    local timeout_sec="${HIVEMIND_STOP_TIMEOUT_SEC:-10}" poll_sec="${HIVEMIND_STOP_POLL_SEC:-0.1}"
    local pid token recorded_exe expected_exe actual_exe current_state deadline

    [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid stop timeout: $timeout_sec" >&2; return 1; }
    [[ "$poll_sec" =~ ^(0\.[0-9]+|[1-9][0-9]*(\.[0-9]+)?)$ ]] || { echo "FAIL: invalid stop poll interval: $poll_sec" >&2; return 1; }
    [[ -f "$state_file" ]] || return 0
    if ! read -r pid token recorded_exe < "$state_file"; then
        echo "WARN: malformed Hivemind PID state; refusing kill" >&2
        return 0
    fi
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "WARN: invalid Hivemind PID; refusing kill" >&2; return 0; }
    [[ "$token" =~ ^[A-Za-z0-9._-]{1,96}$ ]] || { echo "WARN: invalid Hivemind run token; refusing kill" >&2; return 0; }
    expected_exe="$runs_root/$token/hivemind"
    [[ "$recorded_exe" == "$expected_exe" ]] || { echo "WARN: Hivemind state token/exe mismatch; refusing kill pid=$pid" >&2; return 0; }
    actual_exe="$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)"
    [[ "$actual_exe" == "$expected_exe" ]] || { echo "WARN: stale/reused Hivemind PID; refusing kill pid=$pid exe=${actual_exe:-missing}" >&2; return 0; }

    "$kill_bin" -TERM "$pid" || { echo "FAIL: SIGTERM failed for pid=$pid" >&2; return 1; }
    deadline=$((SECONDS + timeout_sec))
    while (( SECONDS < deadline )); do
        current_state="$(cat "$state_file" 2>/dev/null || true)"
        [[ "$current_state" == "$pid $token $recorded_exe" ]] || { echo "FAIL: PID state changed while stopping pid=$pid" >&2; return 1; }
        actual_exe="$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)"
        [[ "$actual_exe" == "$expected_exe" ]] || return 0
        sleep "$poll_sec"
    done

    actual_exe="$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)"
    [[ "$actual_exe" == "$expected_exe" ]] || return 0
    current_state="$(cat "$state_file" 2>/dev/null || true)"
    [[ "$current_state" == "$pid $token $recorded_exe" ]] || { echo "FAIL: PID state changed before SIGKILL pid=$pid" >&2; return 1; }
    "$kill_bin" -KILL "$pid" || { echo "FAIL: SIGKILL failed for pid=$pid" >&2; return 1; }

    deadline=$((SECONDS + timeout_sec))
    while (( SECONDS < deadline )); do
        current_state="$(cat "$state_file" 2>/dev/null || true)"
        [[ "$current_state" == "$pid $token $recorded_exe" ]] || { echo "FAIL: PID state changed after SIGKILL pid=$pid" >&2; return 1; }
        actual_exe="$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)"
        [[ "$actual_exe" == "$expected_exe" ]] || return 0
        sleep "$poll_sec"
    done
    echo "FAIL: pid=$pid did not disappear after identity-validated SIGKILL" >&2
    return 1
}

hivemind_write_pid_state() {
    local state_file="$1" pid="$2" token="$3" expected_exe="$4" tmp_file
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9._-]{1,96}$ ]] || return 1
    [[ "$expected_exe" == */"$token"/hivemind ]] || return 1
    tmp_file="$state_file.tmp.$$"
    printf '%s %s %s\n' "$pid" "$token" "$expected_exe" > "$tmp_file"
    mv "$tmp_file" "$state_file"
}

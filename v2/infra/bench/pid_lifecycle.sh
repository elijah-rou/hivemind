#!/usr/bin/env bash
# Safe PID-state primitives for bench deploy. Source on the target node.

hivemind_proc_start_time() {
    local pid="$1" proc_root="$2" stat_line suffix start_time
    stat_line="$(cat "$proc_root/$pid/stat" 2>/dev/null)" || return 1
    [[ "$stat_line" == *") "* ]] || return 1
    suffix="${stat_line##*) }"
    start_time="$(awk '{print $20}' <<< "$suffix")"
    [[ "$start_time" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$start_time"
}

hivemind_identity_matches() {
    local state_file="$1" proc_root="$2" expected_state="$3" pid="$4" start_time="$5" expected_exe="$6"
    local current_state actual_exe actual_start_time

    current_state="$(cat "$state_file" 2>/dev/null || true)"
    if [[ "$current_state" != "$expected_state" ]]; then
        echo "FAIL: PID state changed while stopping pid=$pid" >&2
        return 2
    fi
    actual_exe="$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)"
    actual_start_time="$(hivemind_proc_start_time "$pid" "$proc_root" 2>/dev/null || true)"
    if [[ "$actual_exe" != "$expected_exe" || "$actual_start_time" != "$start_time" ]]; then
        echo "WARN: stale/reused Hivemind PID; refusing kill pid=$pid exe=${actual_exe:-missing} start=${actual_start_time:-missing}" >&2
        return 1
    fi
    return 0
}

hivemind_stop_verified() {
    local state_file="$1" runs_root="$2" proc_root="${3:-/proc}" kill_bin="${4:-kill}"
    local timeout_sec="${HIVEMIND_STOP_TIMEOUT_SEC:-10}" poll_sec="${HIVEMIND_STOP_POLL_SEC:-0.1}"
    local pid start_time recorded_exe token expected_exe expected_state deadline identity_status

    [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid stop timeout: $timeout_sec" >&2; return 1; }
    [[ "$poll_sec" =~ ^(0\.[0-9]+|[1-9][0-9]*(\.[0-9]+)?)$ ]] || { echo "FAIL: invalid stop poll interval: $poll_sec" >&2; return 1; }
    [[ -f "$state_file" ]] || return 0
    if ! read -r pid start_time recorded_exe token < "$state_file"; then
        echo "WARN: malformed Hivemind PID state; refusing kill" >&2
        return 0
    fi
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || { echo "WARN: invalid Hivemind PID; refusing kill" >&2; return 0; }
    [[ "$start_time" =~ ^[1-9][0-9]*$ ]] || { echo "WARN: invalid Hivemind process start-time; refusing kill" >&2; return 0; }
    [[ "$token" =~ ^[A-Za-z0-9._-]{1,96}$ ]] || { echo "WARN: invalid Hivemind run token; refusing kill" >&2; return 0; }
    expected_exe="$runs_root/$token/hivemind"
    [[ "$recorded_exe" == "$expected_exe" ]] || { echo "WARN: Hivemind state token/exe mismatch; refusing kill pid=$pid" >&2; return 0; }
    expected_state="$pid $start_time $recorded_exe $token"

    if hivemind_identity_matches "$state_file" "$proc_root" "$expected_state" "$pid" "$start_time" "$expected_exe"; then
        :
    else
        identity_status=$?
        [[ "$identity_status" -eq 1 ]] && return 0
        return 1
    fi
    "$kill_bin" -TERM "$pid" || { echo "FAIL: SIGTERM failed for pid=$pid" >&2; return 1; }

    deadline=$((SECONDS + timeout_sec))
    while (( SECONDS < deadline )); do
        if hivemind_identity_matches "$state_file" "$proc_root" "$expected_state" "$pid" "$start_time" "$expected_exe"; then
            :
        else
            identity_status=$?
            [[ "$identity_status" -eq 1 ]] && return 0
            return 1
        fi
        sleep "$poll_sec"
    done

    if hivemind_identity_matches "$state_file" "$proc_root" "$expected_state" "$pid" "$start_time" "$expected_exe"; then
        :
    else
        identity_status=$?
        [[ "$identity_status" -eq 1 ]] && return 0
        return 1
    fi
    "$kill_bin" -KILL "$pid" || { echo "FAIL: SIGKILL failed for pid=$pid" >&2; return 1; }

    deadline=$((SECONDS + timeout_sec))
    while (( SECONDS < deadline )); do
        if hivemind_identity_matches "$state_file" "$proc_root" "$expected_state" "$pid" "$start_time" "$expected_exe"; then
            :
        else
            identity_status=$?
            [[ "$identity_status" -eq 1 ]] && return 0
            return 1
        fi
        sleep "$poll_sec"
    done
    echo "FAIL: pid=$pid did not disappear after identity-validated SIGKILL" >&2
    return 1
}

hivemind_write_pid_state() {
    local state_file="$1" pid="$2" token="$3" expected_exe="$4" proc_root="${5:-/proc}"
    local tmp_file actual_exe start_time confirmed_start_time
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$token" =~ ^[A-Za-z0-9._-]{1,96}$ ]] || return 1
    [[ "$expected_exe" == */"$token"/hivemind ]] || return 1
    actual_exe="$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)"
    [[ "$actual_exe" == "$expected_exe" ]] || return 1
    start_time="$(hivemind_proc_start_time "$pid" "$proc_root")" || return 1
    confirmed_start_time="$(hivemind_proc_start_time "$pid" "$proc_root")" || return 1
    [[ "$confirmed_start_time" == "$start_time" ]] || return 1
    [[ "$(readlink "$proc_root/$pid/exe" 2>/dev/null || true)" == "$expected_exe" ]] || return 1
    tmp_file="$state_file.tmp.$$.$RANDOM"
    (umask 077; printf '%s %s %s %s\n' "$pid" "$start_time" "$expected_exe" "$token" > "$tmp_file") || { rm -f "$tmp_file"; return 1; }
    mv -f "$tmp_file" "$state_file"
}

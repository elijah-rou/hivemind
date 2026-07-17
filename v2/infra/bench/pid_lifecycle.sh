#!/usr/bin/env bash
# Safe PID-state primitives for bench deploy. Source on the target node.

hivemind_stop_verified() {
    local state_file="$1" runs_root="$2" proc_root="${3:-/proc}" kill_bin="${4:-kill}"
    local pid token recorded_exe expected_exe actual_exe

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

    "$kill_bin" "$pid"
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

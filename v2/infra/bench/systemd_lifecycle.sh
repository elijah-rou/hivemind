#!/usr/bin/env bash
# Managed transient-unit primitives for bench deploy. Source on the target node.

hivemind_transaction_begin() {
    local timeout_sec="${HIVEMIND_SYSTEMD_TIMEOUT_SEC:-15}" now
    [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid systemd timeout: $timeout_sec" >&2; return 1; }
    now="$(date +%s)" || { echo "FAIL: cannot read wall clock" >&2; return 1; }
    export HIVEMIND_TRANSACTION_DEADLINE_EPOCH=$((now + timeout_sec))
}

hivemind_deadline_remaining() {
    local deadline="${HIVEMIND_TRANSACTION_DEADLINE_EPOCH:-}" now remaining
    [[ "$deadline" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: transaction deadline is not initialized" >&2; return 1; }
    now="$(date +%s)" || { echo "FAIL: cannot read wall clock" >&2; return 1; }
    remaining=$((deadline - now))
    if (( remaining <= 0 )); then
        echo "FAIL: transaction deadline exhausted" >&2
        return 1
    fi
    printf '%s\n' "$remaining"
}

hivemind_transaction_ensure() {
    if [[ -z "${HIVEMIND_TRANSACTION_DEADLINE_EPOCH:-}" ]]; then
        hivemind_transaction_begin
    fi
    hivemind_deadline_remaining >/dev/null
}

hivemind_run_bounded() {
    local remaining
    remaining="$(hivemind_deadline_remaining)" || return 1
    timeout "${remaining}s" "$@"
}

hivemind_unit_diagnostics() {
    local unit="$1"
    hivemind_run_bounded systemctl --no-pager --full status "$unit" >&2 || true
    hivemind_run_bounded journalctl --no-pager -u "$unit" -n 100 >&2 || true
}

hivemind_unit_stop_verified() {
    local unit="$1" load_state active_state
    [[ "$unit" =~ ^hivemind-bench-[A-Za-z0-9_.-]+\.service$ ]] || { echo "FAIL: invalid unit: $unit" >&2; return 1; }
    hivemind_transaction_ensure || return 1

    if ! load_state="$(hivemind_run_bounded systemctl show "$unit" --property=LoadState --value 2>/dev/null)"; then
        echo "FAIL: LoadState query failed for $unit" >&2
        return 1
    fi
    if [[ "$load_state" == "not-found" ]]; then
        return 0
    fi
    if [[ -z "$load_state" ]]; then
        echo "FAIL: LoadState query returned empty state for $unit" >&2
        return 1
    fi
    if ! hivemind_run_bounded systemctl stop "$unit"; then
        echo "FAIL: bounded systemd stop failed for $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if ! active_state="$(hivemind_run_bounded systemctl show "$unit" --property=ActiveState --value 2>/dev/null)"; then
        echo "FAIL: ActiveState query failed for $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if [[ "$active_state" != "inactive" && "$active_state" != "failed" ]]; then
        echo "FAIL: old unit $unit remains ${active_state:-unknown}" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if ! hivemind_run_bounded systemctl reset-failed "$unit" >/dev/null 2>&1; then
        echo "FAIL: reset-failed failed for $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
}

hivemind_unit_start_verified() {
    local unit="$1" executable="$2" stabilize_sec="${HIVEMIND_SYSTEMD_STABILIZE_SEC:-2}"
    local initial_pid stable_pid
    shift 2
    [[ "$unit" =~ ^hivemind-bench-[A-Za-z0-9_.-]+\.service$ ]] || { echo "FAIL: invalid unit: $unit" >&2; return 1; }
    [[ -x "$executable" ]] || { echo "FAIL: executable is not runnable: $executable" >&2; return 1; }
    (( $# > 0 )) || { echo "FAIL: missing Hivemind arguments" >&2; return 1; }
    [[ "$stabilize_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid stabilization timeout: $stabilize_sec" >&2; return 1; }
    hivemind_transaction_ensure || return 1

    if ! hivemind_run_bounded systemd-run --unit="$unit" --collect --service-type=exec \
        --property=Restart=no --property=TimeoutStopSec=10s \
        --property=StandardOutput=journal --property=StandardError=journal \
        -- "$executable" "$@"; then
        echo "FAIL: systemd-run failed for $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if ! hivemind_run_bounded systemctl is-active --quiet "$unit"; then
        echo "FAIL: unit did not become active: $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if ! initial_pid="$(hivemind_run_bounded systemctl show "$unit" --property=MainPID --value 2>/dev/null)" ||
        [[ ! "$initial_pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "FAIL: unit has invalid MainPID after start: $unit (${initial_pid:-unknown})" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi

    if ! hivemind_run_bounded sleep "$stabilize_sec"; then
        echo "FAIL: stabilization deadline expired for $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if ! hivemind_run_bounded systemctl is-active --quiet "$unit"; then
        echo "FAIL: unit did not remain active through stabilization: $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if ! stable_pid="$(hivemind_run_bounded systemctl show "$unit" --property=MainPID --value 2>/dev/null)" ||
        [[ "$stable_pid" != "$initial_pid" ]]; then
        echo "FAIL: unit MainPID changed during stabilization: $unit (${initial_pid:-unknown} -> ${stable_pid:-unknown})" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
}

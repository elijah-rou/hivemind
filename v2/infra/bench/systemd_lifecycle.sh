#!/usr/bin/env bash
# Managed transient-unit primitives for bench deploy. Source on the target node.

hivemind_unit_diagnostics() {
    local unit="$1"
    systemctl --no-pager --full status "$unit" >&2 || true
    journalctl --no-pager -u "$unit" -n 100 >&2 || true
}

hivemind_unit_stop_verified() {
    local unit="$1" timeout_sec="${HIVEMIND_SYSTEMD_TIMEOUT_SEC:-15}"
    local load_state active_state
    [[ "$unit" =~ ^hivemind-bench-[A-Za-z0-9_.-]+\.service$ ]] || { echo "FAIL: invalid unit: $unit" >&2; return 1; }
    [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid systemd timeout: $timeout_sec" >&2; return 1; }

    load_state="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null || true)"
    if [[ -z "$load_state" || "$load_state" == "not-found" ]]; then
        return 0
    fi
    if ! timeout --foreground "${timeout_sec}s" systemctl stop "$unit"; then
        echo "FAIL: bounded systemd stop failed for $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    active_state="$(systemctl show "$unit" --property=ActiveState --value 2>/dev/null || true)"
    if [[ "$active_state" != "inactive" && "$active_state" != "failed" ]]; then
        echo "FAIL: old unit $unit remains ${active_state:-unknown}" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
}

hivemind_unit_start_verified() {
    local unit="$1" executable="$2"
    shift 2
    [[ "$unit" =~ ^hivemind-bench-[A-Za-z0-9_.-]+\.service$ ]] || { echo "FAIL: invalid unit: $unit" >&2; return 1; }
    [[ -x "$executable" ]] || { echo "FAIL: executable is not runnable: $executable" >&2; return 1; }
    (( $# > 0 )) || { echo "FAIL: missing Hivemind arguments" >&2; return 1; }

    if ! systemd-run --unit="$unit" --collect --service-type=exec \
        --property=Restart=no --property=TimeoutStopSec=10s \
        --property=StandardOutput=journal --property=StandardError=journal \
        -- "$executable" "$@"; then
        echo "FAIL: systemd-run failed for $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
    if ! systemctl is-active --quiet "$unit"; then
        echo "FAIL: unit did not become active: $unit" >&2
        hivemind_unit_diagnostics "$unit"
        return 1
    fi
}

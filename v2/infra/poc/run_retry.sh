#!/usr/bin/env bash
# Shared fail-closed /run retry helper. Source this file; do not execute it.

hivemind_run_with_retry() {
    local name="$1" url="$2" payload_arg="$3" expected="$4"
    local attempts="${5:-12}" delay="${6:-5}" out_file="${7:-}"
    local max_time="${8:-30}"
    local work_dir body_file meta_file http_code time_total error_code

    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || { echo "abort: run $name invalid attempts=$attempts" >&2; return 1; }
    [[ "$delay" =~ ^[0-9]+$ ]] || { echo "abort: run $name invalid delay=$delay" >&2; return 1; }
    [[ "$max_time" =~ ^[1-9][0-9]*$ ]] || { echo "abort: run $name invalid max_time=$max_time" >&2; return 1; }

    work_dir="$(mktemp -d)" || return 1
    body_file="$work_dir/body"
    meta_file="$work_dir/meta"
    for i in $(seq 1 "$attempts"); do
        : > "$body_file"
        if ! curl -sS --max-time "$max_time" -o "$body_file" -w '%{http_code} %{time_total}\n' \
            -X POST "$url" -H 'Content-Type: application/json' --data-binary "$payload_arg" > "$meta_file"; then
            echo "abort: run $name transport error; request will not be replayed" >&2
            rm -rf "$work_dir"
            return 1
        fi
        if ! read -r http_code time_total < "$meta_file" || [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
            echo "abort: run $name malformed curl metadata" >&2
            rm -rf "$work_dir"
            return 1
        fi

        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            if [[ -n "$expected" ]] && ! grep -Eq "$expected" "$body_file"; then
                echo "abort: run $name successful response missing expected pattern" >&2
                return 1
            fi
            if [[ -n "$out_file" ]]; then
                cp "$body_file" "$out_file"
            fi
            HIVEMIND_RUN_BODY="$(cat "$body_file")"
            HIVEMIND_RUN_TIME="$time_total"
            HIVEMIND_RUN_HTTP_STATUS="$http_code"
            echo "run ready: $name attempt=$i"
            rm -rf "$work_dir"
            return 0
        fi

        if ! error_code="$(python3 - "$body_file" <<'PY'
import json, sys
try:
    value = json.load(open(sys.argv[1], encoding="utf-8")).get("error")
except (OSError, ValueError, AttributeError):
    raise SystemExit(1)
if not isinstance(value, str):
    raise SystemExit(1)
print(value)
PY
        )"; then
            echo "abort: run $name malformed non-success response http_status=$http_code" >&2
            rm -rf "$work_dir"
            return 1
        fi

        case "$error_code" in
            unavailable|queue_full|no_running_pod)
                if (( i < attempts )); then
                    sleep "$delay"
                fi
                ;;
            *)
                echo "abort: run $name non-retryable status=$error_code http_status=$http_code" >&2
                rm -rf "$work_dir"
                return 1
                ;;
        esac
    done

    echo "timeout: run $name after $attempts safe retries" >&2
    rm -rf "$work_dir"
    return 1
}

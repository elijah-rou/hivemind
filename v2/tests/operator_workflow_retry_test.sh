#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count_file="$CURL_STUB_DIR/count"
count=0
[[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
case "$CURL_STUB_SCENARIO:$count" in
    ambiguous:1) printf '{"error":"outcome_ambiguous","status":5}\n\n502' ;;
    unavailable_then_success:1) printf '{"error":"unavailable"}\n\n503' ;;
    unavailable_then_success:2) printf 'served\n200' ;;
    permanent:1) printf '{"error":"worker_error","status":99}\n\n502' ;;
    *) echo "unexpected curl call scenario=$CURL_STUB_SCENARIO count=$count" >&2; exit 97 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/curl"

run_case() {
    local scenario="$1" expected_status="$2" expected_calls="$3" expected_text="$4"
    local case_dir="$TMP_DIR/$scenario"
    mkdir -p "$case_dir"
    printf '{}' > "$case_dir/request.json"
    set +e
    output="$(
        PATH="$TMP_DIR/bin:$PATH" \
        CURL_STUB_DIR="$case_dir" \
        CURL_STUB_SCENARIO="$scenario" \
        CPU_IMAGE=test GPU_IMAGE=test OUT_DIR="$case_dir/out" \
        OPERATOR_WORKFLOW_RETRY_FIXTURE=true \
        OPERATOR_WORKFLOW_RETRY_PAYLOAD="$case_dir/request.json" \
        OPERATOR_WORKFLOW_RETRY_OUTPUT="$case_dir/response" \
        bash "$ROOT_DIR/infra/poc/operator-workflow.sh" http://fixture 2>&1
    )"
    status=$?
    set -e
    [[ "$status" -eq "$expected_status" ]] || {
        echo "$scenario status=$status want=$expected_status output=$output" >&2
        return 1
    }
    [[ "$(cat "$case_dir/count")" -eq "$expected_calls" ]] || {
        echo "$scenario calls=$(cat "$case_dir/count") want=$expected_calls" >&2
        return 1
    }
    grep -Fq "$expected_text" <<<"$output" || {
        echo "$scenario missing output '$expected_text': $output" >&2
        return 1
    }
}

run_case ambiguous 1 1 outcome_ambiguous
run_case unavailable_then_success 0 2 'pass: run fixture attempt=2'
run_case permanent 1 1 worker_error

echo "operator workflow retry fixtures: PASS"

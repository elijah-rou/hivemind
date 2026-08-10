#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count_file="$RUN_RETRY_STATE/count"
count=0
[[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -w|--max-time|-X|-H|--data-binary) shift 2 ;;
        *) shift ;;
    esac
done
case "$RUN_RETRY_SCENARIO:$count" in
    unavailable_then_success:1) printf '%s' '{"error":"unavailable","status":8}' > "$out"; printf '503 0.01\n' ;;
    unavailable_then_success:2) printf '%s' '{"model":"ok"}' > "$out"; printf '200 0.02\n' ;;
    queue_full_then_success:1) printf '%s' '{"error":"queue_full","status":2}' > "$out"; printf '503 0.01\n' ;;
    queue_full_then_success:2) printf '%s' '{"model":"ok"}' > "$out"; printf '200 0.02\n' ;;
    transport:1) exit 7 ;;
    ambiguous:1) printf '%s' '{"error":"outcome_ambiguous","status":5}' > "$out"; printf '502 0.01\n' ;;
    forwarding:1) printf '%s' '{"error":"forwarding_failed","status":6}' > "$out"; printf '502 0.01\n' ;;
    no_pod_then_success:1) printf '%s' '{"error":"no_running_pod","status":7}' > "$out"; printf '503 0.01\n' ;;
    no_pod_then_success:2) printf '%s' '{"model":"ok"}' > "$out"; printf '200 0.02\n' ;;
    invalid:1) printf '%s' '{"error":"invalid_payload","status":3}' > "$out"; printf '400 0.01\n' ;;
    overflow:1) printf '%s' '{"error":"response_too_large","status":4}' > "$out"; printf '502 0.01\n' ;;
    malformed:1) printf '%s' 'not-json' > "$out"; printf '503 0.01\n' ;;
    *) echo "unexpected scenario=$RUN_RETRY_SCENARIO count=$count" >&2; exit 98 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/curl"

# shellcheck disable=SC1091
source "$ROOT_DIR/infra/poc/run_retry.sh"

run_case() {
    local scenario="$1" expected_status="$2" expected_calls="$3"
    local state="$TMP_DIR/$scenario"
    mkdir -p "$state"
    set +e
    PATH="$TMP_DIR/bin:$PATH" RUN_RETRY_STATE="$state" RUN_RETRY_SCENARIO="$scenario" \
        hivemind_run_with_retry fixture http://fixture/run '{}' '"model"' 3 0 >"$state/out" 2>&1
    local status=$?
    set -e
    [[ "$status" -eq "$expected_status" ]] || { cat "$state/out" >&2; return 1; }
    [[ "$(cat "$state/count")" -eq "$expected_calls" ]] || return 1
}

run_case unavailable_then_success 0 2
run_case queue_full_then_success 0 2
run_case transport 1 1
run_case ambiguous 1 1
run_case forwarding 1 1
run_case no_pod_then_success 0 2
run_case invalid 1 1
run_case overflow 1 1
run_case malformed 1 1

# Every post-mktemp failure removes its workspace.
cleanup_tmp="$TMP_DIR/workspaces"
mkdir -p "$cleanup_tmp"
state="$TMP_DIR/missing-pattern"
mkdir -p "$state"
set +e
TMPDIR="$cleanup_tmp" PATH="$TMP_DIR/bin:$PATH" RUN_RETRY_STATE="$state" RUN_RETRY_SCENARIO=unavailable_then_success \
    hivemind_run_with_retry fixture http://fixture/run '{}' 'missing-pattern' 3 0 >"$state/out" 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]]
[[ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

# Artifact preservation failure is fatal and also cleans the workspace.
state="$TMP_DIR/missing-output"
mkdir -p "$state"
set +e
TMPDIR="$cleanup_tmp" PATH="$TMP_DIR/bin:$PATH" RUN_RETRY_STATE="$state" RUN_RETRY_SCENARIO=unavailable_then_success \
    hivemind_run_with_retry fixture http://fixture/run '{}' '"model"' 3 0 "$TMP_DIR/no-such-parent/result.json" >"$state/out" 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]]
[[ ! -e "$TMP_DIR/no-such-parent/result.json" ]]
[[ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -print -quit)" ]]

# Live operator scripts retry only statuses proven safe. The local D1 contract
# intentionally sends each case once so it can assert exact wire outcomes.
for caller in \
    infra/poc/operator-workflow.sh \
    infra/poc/workload-test.sh \
    infra/poc/smoke-test.sh \
    infra/poc/failure-drills.sh
do
    grep -q 'run_retry.sh' "$ROOT_DIR/$caller" || { echo "caller missing helper: $caller" >&2; exit 1; }
done

echo "run retry fixtures: PASS"

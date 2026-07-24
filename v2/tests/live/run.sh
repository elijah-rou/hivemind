#!/usr/bin/env bash
set -euo pipefail

# Guarded opt-in live acceptance wrapper. It owns authorization, evidence paths,
# cleanup ordering, and final zero-inventory semantics. The executor and cleanup
# hooks receive the validated environment and must use exact run-token ownership.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ALLOW_LIVE="${HIVEMIND_ALLOW_LIVE:-0}"
ACCOUNT_ALLOWLIST="${HIVEMIND_AWS_ACCOUNT_ALLOWLIST:-}"
REGION="${AWS_REGION:-}"
REGION_ALLOWLIST="${HIVEMIND_AWS_REGION_ALLOWLIST:-}"
RUN_TOKEN="${HIVEMIND_RUN_TOKEN:-}"
WORKSPACE="${TF_WORKSPACE:-}"
BUCKET="${HIVEMIND_LIVE_BUCKET:-}"
ECR_NAME="${HIVEMIND_LIVE_ECR:-}"
KEEP_INFRA="${KEEP_INFRA:-0}"
EXECUTOR="${HIVEMIND_LIVE_EXECUTOR:-$SCRIPT_DIR/execute-reviewed-plan.sh}"
CLEANUP="${HIVEMIND_LIVE_CLEANUP:-$SCRIPT_DIR/cleanup-owned.sh}"
INVENTORY="${HIVEMIND_LIVE_INVENTORY:-$SCRIPT_DIR/inventory-owned.sh}"
EVIDENCE_DIR="${HIVEMIND_LIVE_EVIDENCE_DIR:-$ROOT_DIR/artifacts/live-$RUN_TOKEN}"
PREFLIGHT_ONLY="${HIVEMIND_LIVE_PREFLIGHT_ONLY:-0}"
FIXTURE_MODE="${HIVEMIND_LIVE_FIXTURE_MODE:-0}"
OWNERSHIP_STARTED=0

fail() { echo "FAIL: $*" >&2; exit 1; }
contains_csv() {
    local list="$1" wanted="$2" item
    IFS=',' read -ra items <<<"$list"
    for item in "${items[@]}"; do [[ "$item" == "$wanted" ]] && return 0; done
    return 1
}
valid_owned_name() {
    local value="$1"
    [[ "$value" =~ ^[a-z0-9][a-z0-9-]{7,62}$ && "$value" == *"$RUN_TOKEN"* ]]
}

# Literal authorization is checked before even the read-only identity command.
[[ "$ALLOW_LIVE" == 1 ]] || fail "HIVEMIND_ALLOW_LIVE=1 is required"
[[ "$KEEP_INFRA" == 0 || "$KEEP_INFRA" == 1 ]] || fail "KEEP_INFRA must be 0 or 1"
[[ "$PREFLIGHT_ONLY" == 0 || "$PREFLIGHT_ONLY" == 1 ]] || fail "HIVEMIND_LIVE_PREFLIGHT_ONLY must be 0 or 1"
[[ "$FIXTURE_MODE" == 0 || "$FIXTURE_MODE" == 1 ]] || fail "HIVEMIND_LIVE_FIXTURE_MODE must be 0 or 1"
if [[ "$FIXTURE_MODE" == 1 ]]; then
    [[ "$REGION" == us-test-1 && "$EXECUTOR" != "$SCRIPT_DIR/execute-reviewed-plan.sh" && "$CLEANUP" != "$SCRIPT_DIR/cleanup-owned.sh" && "$INVENTORY" != "$SCRIPT_DIR/inventory-owned.sh" ]] ||
        fail "fixture mode requires the reserved test region and all custom hooks"
fi
[[ "${HIVEMIND_COST_APPROVED:-0}" == 1 ]] || fail "HIVEMIND_COST_APPROVED=1 is required"
[[ "${HIVEMIND_CLEANUP_APPROVED:-0}" == 1 ]] || fail "HIVEMIND_CLEANUP_APPROVED=1 is required"
[[ "$RUN_TOKEN" =~ ^[a-z][a-z0-9]{11,31}$ ]] || fail "run token must be 12..32 lowercase alphanumeric characters"
[[ -n "$REGION" && -n "$REGION_ALLOWLIST" ]] || fail "explicit AWS region and region allowlist are required"
contains_csv "$REGION_ALLOWLIST" "$REGION" || fail "AWS region is not allowlisted"
[[ -n "$ACCOUNT_ALLOWLIST" ]] || fail "explicit AWS account allowlist is required"
valid_owned_name "$WORKSPACE" || fail "workspace must be unique and contain the run token"
valid_owned_name "$BUCKET" || fail "bucket must be unique and contain the run token"
valid_owned_name "$ECR_NAME" || fail "ECR repository must be unique and contain the run token"
[[ "${HIVEMIND_APPROVED_PLAN_SHA256:-}" =~ ^[0-9a-f]{64}$ ]] || fail "approved Terraform plan SHA-256 is required"
[[ -f "${HIVEMIND_PLAN_REVIEW_RECORD:-}" && ! -L "${HIVEMIND_PLAN_REVIEW_RECORD:-}" ]] || fail "plan review record must be a regular file"
if [[ "$FIXTURE_MODE" == 0 ]]; then
    [[ -f "${HIVEMIND_TF_PLAN:-}" && ! -L "${HIVEMIND_TF_PLAN:-}" ]] || fail "reviewed saved Terraform plan must be a regular file"
    [[ "$(sha256sum "$HIVEMIND_TF_PLAN" | awk '{print $1}')" == "$HIVEMIND_APPROVED_PLAN_SHA256" ]] || fail "saved Terraform plan digest differs from approval"
fi
if [[ "$KEEP_INFRA" == 1 ]]; then
    [[ -n "${HIVEMIND_KEEP_OWNER:-}" && -n "${HIVEMIND_KEEP_REASON:-}" && -n "${HIVEMIND_KEEP_EXPIRY:-}" && -n "${HIVEMIND_KEEP_CLEANUP_PLAN:-}" ]] ||
        fail "KEEP_INFRA=1 requires owner, reason, expiry, and cleanup plan"
fi
command -v aws >/dev/null 2>&1 || fail "aws command unavailable"

CURRENT_ACCOUNT="$(timeout --foreground --kill-after=2s 15s aws sts get-caller-identity --query Account --output text --region "$REGION")" ||
    fail "AWS caller identity lookup failed"
[[ "$CURRENT_ACCOUNT" =~ ^[0-9]{12}$ ]] || fail "AWS caller identity returned an invalid account"
contains_csv "$ACCOUNT_ALLOWLIST" "$CURRENT_ACCOUNT" || fail "current AWS account does not match the allowlist"
unset CURRENT_ACCOUNT

umask 077
[[ ! -e "$EVIDENCE_DIR" ]] || fail "evidence directory already exists: $EVIDENCE_DIR"
mkdir -p "$EVIDENCE_DIR"
STATUS_FILE="$EVIDENCE_DIR/command-statuses.tsv"
export HIVEMIND_LIVE_STATUS_FILE="$STATUS_FILE"
PRE_INVENTORY_FILE="$EVIDENCE_DIR/pre-ownership-inventory.txt"
INVENTORY_FILE="$EVIDENCE_DIR/post-cleanup-inventory.txt"
: >"$STATUS_FILE"

validate_zero_inventory() {
    local file="$1" key value count=0
    declare -A seen=()
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^(instances|volumes|buckets|repositories|locks|units|processes)$ ]] || return 1
        [[ "$value" == 0 && -z "${seen[$key]:-}" ]] || return 1
        seen[$key]=1; count=$((count + 1))
    done <"$file"
    [[ "$count" == 7 ]]
}

# shellcheck disable=SC2329 # Invoked by EXIT trap.
finish() {
    local status=$? cleanup_status=0 inventory_status=0
    trap - EXIT INT TERM
    set +e
    if [[ "$OWNERSHIP_STARTED" == 1 ]]; then
        timeout --foreground --kill-after=10s "${HIVEMIND_CLEANUP_TIMEOUT_SECONDS:-1800}s" "$CLEANUP"
        cleanup_status=$?
        printf 'cleanup\t%s\n' "$cleanup_status" >>"$STATUS_FILE"
        timeout --foreground --kill-after=5s "${HIVEMIND_INVENTORY_TIMEOUT_SECONDS:-300}s" "$INVENTORY" post >"$INVENTORY_FILE"
        inventory_status=$?
        printf 'post_cleanup_inventory\t%s\n' "$inventory_status" >>"$STATUS_FILE"
        if [[ "$inventory_status" != 0 ]] || ! validate_zero_inventory "$INVENTORY_FILE"; then
            echo "FAIL: post-cleanup inventory is not zero for every owned category" >&2
            status=1
        fi
        [[ "$cleanup_status" == 0 ]] || status=1
        if [[ "$status" == 0 ]]; then
            commit_sha="$(git -C "$ROOT_DIR" rev-parse HEAD)"
            binary_sha="$(cat "$EVIDENCE_DIR/binary.sha256")"
            image_sha="$(cat "$EVIDENCE_DIR/image.sha256")"
            dirty_state="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no | sed -n '1p')"
            printf 'commit=%s\ndirty=%s\n' "$commit_sha" "$dirty_state" >"$EVIDENCE_DIR/source-state.txt"
            printf 'redaction_scan\t0\n' >>"$STATUS_FILE"
            "$SCRIPT_DIR/evidence-manifest.sh" --commit "$commit_sha" \
                --binary-sha "$binary_sha" --image-sha "$image_sha" \
                --plan-sha "${HIVEMIND_APPROVED_PLAN_SHA256}" \
                --command-statuses "$STATUS_FILE" --metrics "$EVIDENCE_DIR/metrics.txt" \
                --journals "$EVIDENCE_DIR/journals.txt" --cleanup "$INVENTORY_FILE" \
                --redaction-status 0 --output "$EVIDENCE_DIR/manifest.json" || status=1
            if [[ "$status" == 0 ]] && ! "$SCRIPT_DIR/redaction-scan.sh" "$EVIDENCE_DIR" >"$EVIDENCE_DIR/redaction-scan.txt" 2>&1; then
                rm -f "$EVIDENCE_DIR/manifest.json"
                echo "FAIL: evidence redaction scan failed" >&2
                status=1
            fi
        fi
    fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -x "$INVENTORY" ]] || fail "live inventory hook is not executable: $INVENTORY"
[[ "$FIXTURE_MODE" == 1 ]] || [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]] || fail "guarded live execution requires a clean tracked worktree"
set +e
timeout --foreground --kill-after=5s "${HIVEMIND_INVENTORY_TIMEOUT_SECONDS:-300}s" "$INVENTORY" pre >"$PRE_INVENTORY_FILE"
pre_inventory_status=$?
set -e
printf 'pre_ownership_inventory\t%s\n' "$pre_inventory_status" >>"$STATUS_FILE"
if [[ "$pre_inventory_status" != 0 ]] || ! validate_zero_inventory "$PRE_INVENTORY_FILE"; then
    fail "pre-ownership inventory is not zero for every owned category"
fi

printf 'guardrails=passed region=%s run_token=%s workspace=%s bucket=%s ecr=%s KEEP_INFRA=%s\n' \
    "$REGION" "$RUN_TOKEN" "$WORKSPACE" "$BUCKET" "$ECR_NAME" "$KEEP_INFRA"
if [[ "$PREFLIGHT_ONLY" == 1 ]]; then
    echo "PREPARED ONLY: no ownership or live executor invocation"
    exit 0
fi
[[ -x "$EXECUTOR" ]] || fail "live executor is not executable: $EXECUTOR"
[[ -x "$CLEANUP" ]] || fail "live cleanup hook is not executable: $CLEANUP"
# The trap is active before this boundary. Only the executor may acquire ownership.
OWNERSHIP_STARTED=1
set +e
timeout --foreground --kill-after=30s "${HIVEMIND_LIVE_TIMEOUT_SECONDS:-14400}s" "$EXECUTOR"
executor_status=$?
set -e
printf 'executor\t%s\n' "$executor_status" >>"$STATUS_FILE"
exit "$executor_status"

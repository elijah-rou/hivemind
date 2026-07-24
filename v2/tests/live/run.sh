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
RUN_TOKEN_HASH="$(printf '%s' "$RUN_TOKEN" | sha256sum | awk '{print $1}')"
EVIDENCE_DIR="${HIVEMIND_LIVE_EVIDENCE_DIR:-$ROOT_DIR/artifacts/live-${RUN_TOKEN_HASH:0:16}}"
PREFLIGHT_ONLY="${HIVEMIND_LIVE_PREFLIGHT_ONLY:-0}"
FIXTURE_MODE="${HIVEMIND_LIVE_FIXTURE_MODE:-0}"
OWNERSHIP_STARTED=0
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
else
    [[ "$(realpath -e -- "$EXECUTOR" 2>/dev/null || true)" == "$SCRIPT_DIR/execute-reviewed-plan.sh" &&
       "$(realpath -e -- "$CLEANUP" 2>/dev/null || true)" == "$SCRIPT_DIR/cleanup-owned.sh" &&
       "$(realpath -e -- "$INVENTORY" 2>/dev/null || true)" == "$SCRIPT_DIR/inventory-owned.sh" ]] ||
        fail "production mode requires canonical live hooks"
fi
[[ "${HIVEMIND_COST_APPROVED:-0}" == 1 ]] || fail "HIVEMIND_COST_APPROVED=1 is required"
[[ "${HIVEMIND_CLEANUP_APPROVED:-0}" == 1 ]] || fail "HIVEMIND_CLEANUP_APPROVED=1 is required"
[[ "${HIVEMIND_QUOTA_CONFIRMED:-0}" == 1 ]] || fail "HIVEMIND_QUOTA_CONFIRMED=1 is required"
for timeout_pair in \
    "HIVEMIND_LIVE_TIMEOUT_SECONDS:${HIVEMIND_LIVE_TIMEOUT_SECONDS:-14400}:60:14400" \
    "HIVEMIND_CLEANUP_TIMEOUT_SECONDS:${HIVEMIND_CLEANUP_TIMEOUT_SECONDS:-1800}:30:1800" \
    "HIVEMIND_INVENTORY_TIMEOUT_SECONDS:${HIVEMIND_INVENTORY_TIMEOUT_SECONDS:-300}:10:300"; do
    timeout_name="${timeout_pair%%:*}"; timeout_rest="${timeout_pair#*:}"
    timeout_value="${timeout_rest%%:*}"; timeout_bounds="${timeout_rest#*:}"
    timeout_min="${timeout_bounds%%:*}"; timeout_max="${timeout_bounds#*:}"
    [[ "$timeout_value" =~ ^[0-9]+$ && "$timeout_value" -ge "$timeout_min" && "$timeout_value" -le "$timeout_max" ]] ||
        fail "$timeout_name must be a bounded decimal integer in $timeout_min..$timeout_max"
done
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
    [[ -f "${HIVEMIND_WORKSPACE_CREATION_RECORD:-}" && ! -L "${HIVEMIND_WORKSPACE_CREATION_RECORD:-}" ]] || fail "workspace creation record must be a regular file"
    grep -Fqx "workspace=$WORKSPACE" "$HIVEMIND_WORKSPACE_CREATION_RECORD" || fail "workspace creation record does not bind the guarded workspace"
    grep -Fqx "plan_sha256=$HIVEMIND_APPROVED_PLAN_SHA256" "$HIVEMIND_WORKSPACE_CREATION_RECORD" || fail "workspace creation record does not bind the reviewed plan"
    for acceptance_pair in \
        "REQUIRE_CONTAINERD:${REQUIRE_CONTAINERD:-0}" "REQUIRE_GPU:${REQUIRE_GPU:-0}" \
        "REQUIRE_NYDUS:${REQUIRE_NYDUS:-0}" "REQUIRE_JUICEFS:${REQUIRE_JUICEFS:-0}" \
        "REQUIRE_ECR_COLD_PULL:${REQUIRE_ECR_COLD_PULL:-0}"; do
        [[ "${acceptance_pair#*:}" == 1 ]] || fail "live acceptance requires ${acceptance_pair%%:*}=1"
    done
    for skip_pair in \
        "SKIP_IMAGE_BUILD:${SKIP_IMAGE_BUILD:-false}" "SKIP_HIVEMIND_DEPLOY:${SKIP_HIVEMIND_DEPLOY:-false}" \
        "SKIP_FAILURE_DRILLS:${SKIP_FAILURE_DRILLS:-false}" "SKIP_OPERATOR_WORKFLOW:${SKIP_OPERATOR_WORKFLOW:-false}" \
        "SKIP_WORKLOAD_PRELOAD:${SKIP_WORKLOAD_PRELOAD:-false}"; do
        [[ "${skip_pair#*:}" == false ]] || fail "live acceptance requires ${skip_pair%%:*}=false"
    done
    fail "REQUIRE_JUICEFS=1: current API/AppSpec cannot request a required JuiceFS mount; refusing before ownership"
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
if [[ "$FIXTURE_MODE" == 0 ]]; then
    timeout --kill-after=5s 60s "$SCRIPT_DIR/quota-preflight.sh" >"${TMPDIR:-/tmp}/hivemind-quota-${RUN_TOKEN_HASH:0:16}.txt" ||
        fail "bounded quota/capability preflight failed"
    rm -f "${TMPDIR:-/tmp}/hivemind-quota-${RUN_TOKEN_HASH:0:16}.txt"
fi

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
        [[ "$key" =~ ^(instances|volumes|network_resources|buckets|repositories|locks|units|processes)$ ]] || return 1
        [[ "$value" == 0 && -z "${seen[$key]:-}" ]] || return 1
        seen[$key]=1; count=$((count + 1))
    done <"$file"
    [[ "$count" == 8 ]]
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
            redaction_log="$(mktemp)"
            if ! HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" "$SCRIPT_DIR/redaction-scan.sh" "$EVIDENCE_DIR" >"$redaction_log" 2>&1; then
                cat "$redaction_log" >&2
                rm -f "$redaction_log"
                echo "FAIL: evidence redaction scan failed" >&2
                status=1
            else
                printf 'redaction_scan\t0\n' >>"$STATUS_FILE"
                mv "$redaction_log" "$EVIDENCE_DIR/redaction-scan.txt"
                export HIVEMIND_EVIDENCE_STARTED_AT="$STARTED_AT"
                HIVEMIND_EVIDENCE_ENDED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                export HIVEMIND_EVIDENCE_ENDED_AT
                HIVEMIND_EVIDENCE_COMMAND="timeout --kill-after=30s ${HIVEMIND_LIVE_TIMEOUT_SECONDS:-14400}s ./tests/live/run.sh"
                export HIVEMIND_EVIDENCE_COMMAND
                export HIVEMIND_EVIDENCE_REGION="$REGION"
                export HIVEMIND_EVIDENCE_OWNERSHIP_HASH="$RUN_TOKEN_HASH"
                export HIVEMIND_EVIDENCE_WORKSPACE_HASH
                HIVEMIND_EVIDENCE_WORKSPACE_HASH="$(printf '%s' "$WORKSPACE" | sha256sum | awk '{print $1}')"
                export HIVEMIND_EVIDENCE_KEEP_INFRA="$KEEP_INFRA" HIVEMIND_EVIDENCE_FINAL_STATUS=0
                "$SCRIPT_DIR/evidence-manifest.sh" --commit "$commit_sha" \
                    --binary-sha "$binary_sha" --image-sha "$image_sha" \
                    --binary-list "$EVIDENCE_DIR/binary-list.sha256" \
                    --image-digests "$EVIDENCE_DIR/image-digests.txt" --plan-sha "${HIVEMIND_APPROVED_PLAN_SHA256}" \
                    --command-statuses "$STATUS_FILE" --metrics "$EVIDENCE_DIR/metrics.txt" \
                    --journals "$EVIDENCE_DIR/journals.txt" --source-state "$EVIDENCE_DIR/source-state.txt" \
                    --pre-inventory "$PRE_INVENTORY_FILE" --cleanup "$INVENTORY_FILE" \
                    --redaction-status 0 --output "$EVIDENCE_DIR/manifest.json" || status=1
                if [[ "$status" == 0 ]] && ! HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" \
                    "$SCRIPT_DIR/redaction-scan.sh" "$EVIDENCE_DIR" >/dev/null; then
                    rm -f "$EVIDENCE_DIR/manifest.json"
                    echo "FAIL: final evidence redaction scan failed" >&2
                    status=1
                fi
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

printf 'guardrails=passed region=%s ownership_hash=%s KEEP_INFRA=%s\n' \
    "$REGION" "${RUN_TOKEN_HASH:0:16}" "$KEEP_INFRA"
if [[ "$PREFLIGHT_ONLY" == 1 ]]; then
    echo "PREPARED ONLY: no ownership or live executor invocation"
    exit 0
fi
[[ -x "$EXECUTOR" ]] || fail "live executor is not executable: $EXECUTOR"
[[ -x "$CLEANUP" ]] || fail "live cleanup hook is not executable: $CLEANUP"
# The trap is active before this boundary. Only the executor may acquire ownership.
OWNERSHIP_STARTED=1
export HIVEMIND_LIVE_GUARD_NONCE HIVEMIND_GUARDRAILS_ACTIVE
HIVEMIND_LIVE_GUARD_NONCE="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
HIVEMIND_GUARDRAILS_ACTIVE=1
set +e
# GNU timeout without --foreground owns a process group and kills all executor descendants.
timeout --kill-after=30s "${HIVEMIND_LIVE_TIMEOUT_SECONDS:-14400}s" "$EXECUTOR"
executor_status=$?
set -e
printf 'executor\t%s\n' "$executor_status" >>"$STATUS_FILE"
exit "$executor_status"

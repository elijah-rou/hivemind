#!/usr/bin/env bash
set -euo pipefail
[[ "${HIVEMIND_ALLOW_LIVE:-0}" == 1 && "${HIVEMIND_GUARDRAILS_ACTIVE:-0}" == 1 && "${HIVEMIND_LIVE_GUARD_NONCE:-}" =~ ^[0-9a-f]{32}$ ]] || {
    echo "FAIL: private live helper requires guarded parent" >&2
    exit 1
}
guard_parent="$(awk '{print $4}' "/proc/$PPID/stat" 2>/dev/null || true)"
tr '\0' ' ' <"/proc/$guard_parent/cmdline" 2>/dev/null | grep -Fq '/tests/live/run.sh' || {
    echo "FAIL: private live helper requires guarded parent" >&2
    exit 1
}
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TF_ROOT="$ROOT_DIR/infra/poc"
RUN_TOKEN="${HIVEMIND_RUN_TOKEN:?}"
WORKSPACE="${TF_WORKSPACE:?}"
BUCKET="${HIVEMIND_LIVE_BUCKET:?}"
ECR_NAME="${HIVEMIND_LIVE_ECR:?}"
REGION="${AWS_REGION:?}"
EVIDENCE_DIR="${HIVEMIND_LIVE_EVIDENCE_DIR:?}"
PLAN="${HIVEMIND_TF_PLAN:?HIVEMIND_TF_PLAN is required}"
PLAN_SHA="${HIVEMIND_APPROVED_PLAN_SHA256:?}"
REVIEW_RECORD="${HIVEMIND_PLAN_REVIEW_RECORD:?}"
SSH_KEY="${SSH_KEY:?SSH_KEY is required}"
STATUS_FILE="${HIVEMIND_LIVE_STATUS_FILE:?}"
record_success() { printf '%s\t0\n' "$1" >>"$STATUS_FILE"; }
run_recorded() {
    local phase="$1" status
    shift
    set +e
    "$@"
    status=$?
    set -e
    printf '%s\t%s\n' "$phase" "$status" >>"$STATUS_FILE"
    return "$status"
}

[[ -f "$PLAN" && ! -L "$PLAN" && "$(stat -c %s "$PLAN")" -le 104857600 ]] || { echo "FAIL: saved plan must be a regular file no larger than 100 MiB" >&2; exit 1; }
PLAN="$(realpath -- "$PLAN")"
[[ "$(sha256sum "$PLAN" | awk '{print $1}')" == "$PLAN_SHA" ]] || { echo "FAIL: saved Terraform plan digest differs from approval" >&2; exit 1; }
grep -Fqx "$PLAN_SHA" "$REVIEW_RECORD" || { echo "FAIL: review record does not bind the approved plan digest" >&2; exit 1; }
[[ "$(terraform -chdir="$TF_ROOT" workspace show)" == "$WORKSPACE" ]] || { echo "FAIL: selected Terraform workspace differs from guarded workspace" >&2; exit 1; }
PLAN_JSON="$EVIDENCE_DIR/.reviewed-plan.json"
terraform -chdir="$TF_ROOT" show -json "$PLAN" >"$PLAN_JSON"
python3 - "$PLAN_JSON" "$RUN_TOKEN" "$ECR_NAME" <<'PY'
import json, sys
plan_path, token, ecr_name = sys.argv[1:]
plan = json.load(open(plan_path, encoding="utf-8"))
changes = plan.get("resource_changes", [])
if not changes or len(changes) > 128:
    raise SystemExit("reviewed plan resource count is empty or unbounded")
owned_types = {"aws_instance", "aws_ebs_volume", "aws_security_group", "aws_key_pair", "aws_ecr_repository"}
for change in changes:
    if change.get("mode") != "managed" or change.get("type") not in owned_types:
        continue
    values = change.get("change", {})
    before = values.get("before")
    after = values.get("after")
    if before is not None and before.get("tags", {}).get("HivemindRunToken") != token:
        raise SystemExit(f"plan would mutate unowned resource: {change.get('address')}")
    if after is not None and after.get("tags", {}).get("HivemindRunToken") != token:
        raise SystemExit(f"plan lacks ownership tag: {change.get('address')}")
    if change.get("type") == "aws_ecr_repository" and after is not None and after.get("name") != ecr_name:
        raise SystemExit("plan ECR repository differs from guarded name")
PY
rm -f "$PLAN_JSON"
install -m 600 "$REVIEW_RECORD" "$EVIDENCE_DIR/reviewed-plan-record.txt"
record_success reviewed_plan_validation

# Ownership starts only after the parent wrapper's cleanup trap and zero inventory.
aws s3 mb "s3://$BUCKET" --region "$REGION"
marker_file="$EVIDENCE_DIR/.ownership-marker"
printf '%s' "$RUN_TOKEN" >"$marker_file"
aws s3api put-object --bucket "$BUCKET" --key .hivemind-owner --body "$marker_file" --region "$REGION" >/dev/null
rm -f "$marker_file"
record_success bucket_ownership

set +e
timeout --foreground --kill-after=30s "${HIVEMIND_TERRAFORM_APPLY_TIMEOUT_SECONDS:-1800}s" \
    terraform -chdir="$TF_ROOT" apply "$PLAN" > >(tee "$EVIDENCE_DIR/terraform-apply.log") 2>&1
apply_status=$?
set -e
printf 'terraform_apply\t%s\n' "$apply_status" >>"$STATUS_FILE"
[[ "$apply_status" == 0 ]] || exit "$apply_status"
terraform -chdir="$TF_ROOT" output -json >"$EVIDENCE_DIR/terraform-outputs.json"

export TF_VAR_run_token="$RUN_TOKEN" TF_VAR_ecr_repository_name="$ECR_NAME" TF_VAR_region="$REGION"
export ECR_REPOSITORY="$ECR_NAME" TAG="live-${RUN_TOKEN:0:8}" SKIP_HIVEMIND_APPLY=true
export DESTROY_HIVEMIND_AFTER=false DESTROY_EKS_AFTER=false RUN_EKS=false
export ARTIFACT_ROOT="$EVIDENCE_DIR/runbook"
run_recorded poc_runbook bash "$ROOT_DIR/scripts/poc-runbook.sh"
[[ -d "$EVIDENCE_DIR/runbook" ]] || { echo "FAIL: runbook evidence directory missing" >&2; exit 1; }

replica_ips="$(terraform -chdir="$TF_ROOT" output -json replica_public_ips)"
worker_cpu="$(terraform -chdir="$TF_ROOT" output -raw worker_cpu_public_ip)"
python3 -c 'import json,sys; a=json.load(sys.stdin); assert 1 <= len(a) <= 5; assert all(isinstance(x,str) and len(x)<=45 for x in a)' <<<"$replica_ips"
[[ "$worker_cpu" =~ ^[0-9A-Fa-f:.]{3,45}$ ]]
mapfile -t replicas < <(python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))' <<<"$replica_ips")
ssh_opts=(-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i "$SSH_KEY")
: >"$EVIDENCE_DIR/metrics.txt"
: >"$EVIDENCE_DIR/journals.txt"
index=0
for ip in "${replicas[@]}"; do
    printf 'replica=%s\n' "$index" >>"$EVIDENCE_DIR/metrics.txt"
    timeout --foreground --kill-after=2s 15s ssh "${ssh_opts[@]}" "ec2-user@$ip" \
        'curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:9200/metrics' \
        | grep -E '^(hivemind_consensus_commit|hivemind_committed_state_digest|hivemind_replica_status|hivemind_queue_depth_total|hivemind_queue_in_flight) ' \
        >>"$EVIDENCE_DIR/metrics.txt"
    {
        printf 'replica=%s\n' "$index"
        timeout --foreground --kill-after=2s 30s ssh "${ssh_opts[@]}" "ec2-user@$ip" \
            "sudo journalctl -u hivemind -u hivemind-api --no-pager -n 100" |
            sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[REDACTED_IP]/g; s/[0-9]{12}\.dkr\.ecr\./[REDACTED_ACCOUNT].dkr.ecr./g; s/(arn:(aws|aws-us-gov|aws-cn):[^:]*:[^:]*:)[0-9]{12}:/\1[REDACTED_ACCOUNT]:/g' |
            head -c 180000
        printf '\n'
    } >>"$EVIDENCE_DIR/journals.txt"
    index=$((index + 1))
done

binary_list="$EVIDENCE_DIR/binary-list.sha256"
sha256sum "$ROOT_DIR/core/zig-out/bin/hivemind" "$ROOT_DIR/worker/target/release/hivemind-worker" \
    "$ROOT_DIR/api/hivemind-api" >"$binary_list"
sha256sum "$binary_list" | awk '{print $1}' >"$EVIDENCE_DIR/binary.sha256"
image_digests="$EVIDENCE_DIR/image-digests.txt"
aws ecr describe-images --region "$REGION" --repository-name "$ECR_NAME" \
    --query 'sort(imageDetails[].imageDigest)' --output text | tr '\t' '\n' | sed '/^$/d' >"$image_digests"
[[ -s "$image_digests" ]]
sha256sum "$image_digests" | awk '{print $1}' >"$EVIDENCE_DIR/image.sha256"
printf '%s\n' "$PLAN_SHA" >"$EVIDENCE_DIR/plan.sha256"
record_success evidence_capture

#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT_DIR/tests/live/run.sh"
[[ "${HIVEMIND_ALLOW_LIVE:-0}" == 1 && "${HIVEMIND_GUARDRAILS_ACTIVE:-0}" == 1 && -r /proc/self/fd/9 ]] || {
    echo "FAIL: private live helper requires guarded parent" >&2
    exit 1
}
python3 - "$PPID" "$RUNNER" <<'PY' || { echo "FAIL: private live helper requires guarded parent" >&2; exit 1; }
import os, sys
pid = int(sys.argv[1])
expected = os.path.realpath(sys.argv[2])
capability = os.stat("/proc/self/fd/9")
for _ in range(6):
    try:
        script = os.path.realpath(f"/proc/{pid}/fd/255")
        inherited = os.stat(f"/proc/{pid}/fd/9")
        argv = [os.fsdecode(value) for value in open(f"/proc/{pid}/cmdline", "rb").read().split(b"\0") if value]
        exact_script_arg = any("/" in value and os.path.realpath(value) == expected for value in argv)
        if script == expected and exact_script_arg and "-c" not in argv and (inherited.st_dev, inherited.st_ino) == (capability.st_dev, capability.st_ino):
            raise SystemExit(0)
        with open(f"/proc/{pid}/stat", encoding="ascii") as source:
            pid = int(source.read().split()[3])
    except (FileNotFoundError, PermissionError, ValueError):
        break
raise SystemExit(1)
PY
TF_ROOT="$ROOT_DIR/infra/poc"
RUN_TOKEN="${HIVEMIND_RUN_TOKEN:?}"
WORKSPACE="${TF_WORKSPACE:?}"
BUCKET="${HIVEMIND_LIVE_BUCKET:?}"
ECR_NAME="${HIVEMIND_LIVE_ECR:?}"
REGION="${AWS_REGION:?}"
EVIDENCE_DIR="${HIVEMIND_LIVE_EVIDENCE_DIR:?}"
RAW_DIR="${HIVEMIND_LIVE_RAW_DIR:?}"
INVENTORY="${HIVEMIND_LIVE_INVENTORY_HOOK:?}"
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
SEALED_PLAN="$RAW_DIR/terraform-plan-$PLAN_SHA.tfplan"
SEALED_REVIEW="$RAW_DIR/reviewed-plan-record.txt"
install -m 600 -- "$PLAN" "$SEALED_PLAN"
install -m 600 -- "$REVIEW_RECORD" "$SEALED_REVIEW"
[[ "$(sha256sum "$SEALED_PLAN" | awk '{print $1}')" == "$PLAN_SHA" ]] || { echo "FAIL: sealed Terraform plan digest differs from approval" >&2; exit 1; }
grep -Fqx "$PLAN_SHA" "$SEALED_REVIEW" || { echo "FAIL: sealed review record does not bind the approved plan digest" >&2; exit 1; }
PLAN="$SEALED_PLAN"
REVIEW_RECORD="$SEALED_REVIEW"
[[ "$(terraform -chdir="$TF_ROOT" workspace show)" == "$WORKSPACE" ]] || { echo "FAIL: selected Terraform workspace differs from guarded workspace" >&2; exit 1; }
PLAN_JSON="$EVIDENCE_DIR/.reviewed-plan.json"
terraform -chdir="$TF_ROOT" show -json "$PLAN" >"$PLAN_JSON"
python3 "$ROOT_DIR/tests/live/validate-reviewed-plan.py" "$PLAN_JSON" "$RUN_TOKEN" "$ECR_NAME"
rm -f "$PLAN_JSON"
HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" "$ROOT_DIR/tests/live/publish-redacted.sh" \
    "$REVIEW_RECORD" "$EVIDENCE_DIR/reviewed-plan-record.txt"
record_success reviewed_plan_validation

# Ownership starts only after the parent wrapper's cleanup trap and zero inventory.
claim_file="$RAW_DIR/s3-ownership-claim"
marker_file="$RAW_DIR/s3-ownership-marker"
install -m 600 /dev/null "$claim_file"
printf '%s' "$RUN_TOKEN" >"$claim_file"
install -m 600 /dev/null "$marker_file"
printf '%s' "$RUN_TOKEN" >"$marker_file"
precreate_check="$RAW_DIR/s3-precreate-check.log"
set +e
timeout --foreground --kill-after=2s 30s aws s3api head-bucket --bucket "$BUCKET" \
    >"$precreate_check" 2>&1
precreate_status=$?
set -e
if [[ "$precreate_status" == 0 ]]; then
    echo "FAIL: refusing to claim a bucket that existed before this run" >&2
    exit 1
fi
if ! grep -Eq '(404|Not Found|NoSuchBucket)' "$precreate_check"; then
    echo "FAIL: bucket absence could not be proven before creation" >&2
    exit 1
fi
set +e
timeout --foreground --kill-after=5s 120s aws s3 mb "s3://$BUCKET" --region "$REGION"
bucket_create_status=$?
set -e
# Reconcile an ambiguous create against the exact pre-recorded claim before any later side effect.
timeout --foreground --kill-after=2s 30s aws s3api head-bucket --bucket "$BUCKET" >/dev/null
timeout --foreground --kill-after=2s 30s aws s3api put-object --bucket "$BUCKET" --key .hivemind-owner \
    --body "$marker_file" --region "$REGION" >/dev/null
verified_marker="$RAW_DIR/s3-ownership-marker.verified"
timeout --foreground --kill-after=2s 30s aws s3api get-object --bucket "$BUCKET" \
    --key .hivemind-owner "$verified_marker" >/dev/null
[[ "$(cat "$verified_marker")" == "$RUN_TOKEN" ]] || {
    echo "FAIL: bucket ownership marker reconciliation failed" >&2
    exit 1
}
printf 'bucket_create\t%s\n' "$bucket_create_status" >>"$STATUS_FILE"
record_success bucket_ownership

set +e
timeout --foreground --kill-after=30s "${HIVEMIND_TERRAFORM_APPLY_TIMEOUT_SECONDS:-1800}s" \
    terraform -chdir="$TF_ROOT" apply "$PLAN" 2>&1 | python3 -c 'import sys; p=open(sys.argv[1], "xb"); n=0
for chunk in iter(lambda: sys.stdin.buffer.read(65536), b""):
 sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
 if n < 1048576: data=chunk[:1048576-n]; p.write(data); n += len(data)
p.close()' "$RAW_DIR/terraform-apply.log"
apply_status=${PIPESTATUS[0]}
set -e
printf 'terraform_apply\t%s\n' "$apply_status" >>"$STATUS_FILE"
[[ "$apply_status" == 0 ]] || exit "$apply_status"
terraform -chdir="$TF_ROOT" output -json >"$RAW_DIR/terraform-outputs.json"
HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" "$ROOT_DIR/tests/live/publish-redacted.sh" \
    "$RAW_DIR/terraform-apply.log" "$EVIDENCE_DIR/terraform-apply.log"
HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" "$ROOT_DIR/tests/live/publish-redacted.sh" \
    "$RAW_DIR/terraform-outputs.json" "$EVIDENCE_DIR/terraform-outputs.json"
timeout --foreground --kill-after=5s "${HIVEMIND_INVENTORY_TIMEOUT_SECONDS:-300}s" "$INVENTORY" post \
    >"$EVIDENCE_DIR/post-apply-inventory.txt"
record_success post_apply_inventory

export TF_VAR_run_token="$RUN_TOKEN" TF_VAR_ecr_repository_name="$ECR_NAME" TF_VAR_region="$REGION"
export ECR_REPOSITORY="$ECR_NAME" TAG="live-${RUN_TOKEN:0:8}" SKIP_HIVEMIND_APPLY=true
export DESTROY_HIVEMIND_AFTER=false DESTROY_EKS_AFTER=false RUN_EKS=false
export ARTIFACT_ROOT="$RAW_DIR/runbook"
run_recorded poc_runbook bash "$ROOT_DIR/scripts/poc-runbook.sh"
[[ -d "$RAW_DIR/runbook" ]] || { echo "FAIL: runbook evidence directory missing" >&2; exit 1; }
HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" "$ROOT_DIR/tests/live/publish-redacted.sh" \
    "$RAW_DIR/runbook" "$EVIDENCE_DIR/runbook"

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

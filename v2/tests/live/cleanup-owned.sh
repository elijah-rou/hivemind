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
REGION="${AWS_REGION:?}"
KEEP_INFRA="${KEEP_INFRA:-0}"
EVIDENCE_DIR="${HIVEMIND_LIVE_EVIDENCE_DIR:?}"
RAW_DIR="${HIVEMIND_LIVE_RAW_DIR:?}"
[[ "$WORKSPACE" == *"$RUN_TOKEN"* && "$BUCKET" == *"$RUN_TOKEN"* ]]

if [[ "$KEEP_INFRA" == 1 ]]; then
    echo "KEEP_INFRA=1: no destructive cleanup performed; acceptance will remain incomplete"
    exit 0
fi

overall_status=0
record_failure() {
    local phase="$1" status="$2"
    if [[ "$status" != 0 ]]; then
        echo "FAIL: $phase cleanup failed with status $status" >&2
        overall_status=1
    fi
}

set +e
timeout --foreground --kill-after=5s "${HIVEMIND_TERRAFORM_SELECT_TIMEOUT_SECONDS:-60}s" \
    terraform -chdir="$TF_ROOT" workspace select "$WORKSPACE" >/dev/null
select_status=$?
record_failure terraform_workspace_select "$select_status"
if [[ "$select_status" == 0 ]]; then
    timeout --foreground --kill-after=30s "${HIVEMIND_TERRAFORM_DESTROY_TIMEOUT_SECONDS:-1200}s" \
        terraform -chdir="$TF_ROOT" destroy -auto-approve \
        -var "run_token=$RUN_TOKEN" -var "ecr_repository_name=${HIVEMIND_LIVE_ECR:?}" -var "region=$REGION" 2>&1 | \
        python3 -c 'import sys; p=open(sys.argv[1], "xb"); n=0
for chunk in iter(lambda: sys.stdin.buffer.read(65536), b""):
 sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
 if n < 1048576: data=chunk[:1048576-n]; p.write(data); n += len(data)
p.close()' "$RAW_DIR/terraform-destroy.log"
    destroy_status=${PIPESTATUS[0]}
else
    printf 'workspace selection failed; destroy not attempted\n' >"$RAW_DIR/terraform-destroy.log"
    destroy_status=1
fi
record_failure terraform_destroy "$destroy_status"
HIVEMIND_REDACTION_TOKEN="$RUN_TOKEN" "$ROOT_DIR/tests/live/publish-redacted.sh" \
    "$RAW_DIR/terraform-destroy.log" "$EVIDENCE_DIR/terraform-destroy.log"
record_failure terraform_destroy_log "$?"

marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT
claim_file="$RAW_DIR/s3-ownership-claim"
bucket_check="$RAW_DIR/s3-cleanup-head.log"
timeout --foreground --kill-after=2s 30s aws s3api head-bucket --bucket "$BUCKET" \
    >"$bucket_check" 2>&1
bucket_status=$?
if [[ "$bucket_status" == 0 ]]; then
    timeout --foreground --kill-after=2s 30s aws s3api get-object --bucket "$BUCKET" \
        --key .hivemind-owner "$marker" >/dev/null 2>&1
    marker_status=$?
    if [[ "$marker_status" != 0 || "$(cat "$marker" 2>/dev/null)" != "$RUN_TOKEN" ]]; then
        if [[ -f "$claim_file" && "$(cat "$claim_file")" == "$RUN_TOKEN" ]]; then
            timeout --foreground --kill-after=2s 30s aws s3api put-object --bucket "$BUCKET" \
                --key .hivemind-owner --body "$claim_file" --region "$REGION" >/dev/null
            marker_status=$?
            : >"$marker"
            if [[ "$marker_status" == 0 ]]; then
                timeout --foreground --kill-after=2s 30s aws s3api get-object --bucket "$BUCKET" \
                    --key .hivemind-owner "$marker" >/dev/null
                marker_status=$?
            fi
        fi
    fi
    if [[ "$marker_status" == 0 && "$(cat "$marker")" == "$RUN_TOKEN" ]]; then
        timeout --foreground --kill-after=10s "${HIVEMIND_S3_EMPTY_TIMEOUT_SECONDS:-300}s" \
            aws s3 rm "s3://$BUCKET" --recursive --region "$REGION"
        record_failure s3_empty "$?"
        timeout --foreground --kill-after=2s "${HIVEMIND_S3_DELETE_TIMEOUT_SECONDS:-60}s" \
            aws s3 rb "s3://$BUCKET" --region "$REGION"
        record_failure s3_delete "$?"
    else
        echo "FAIL: refusing cleanup of bucket without exact ownership claim" >&2
        overall_status=1
    fi
elif ! grep -Eq '(404|Not Found|NoSuchBucket)' "$bucket_check"; then
    echo "FAIL: bucket cleanup inventory was ambiguous" >&2
    overall_status=1
fi

timeout --foreground --kill-after=5s "${HIVEMIND_TERRAFORM_SELECT_TIMEOUT_SECONDS:-60}s" \
    env -u TF_WORKSPACE terraform -chdir="$TF_ROOT" workspace select default >/dev/null
record_failure terraform_default_workspace "$?"
timeout --foreground --kill-after=5s "${HIVEMIND_TERRAFORM_WORKSPACE_DELETE_TIMEOUT_SECONDS:-60}s" \
    env -u TF_WORKSPACE terraform -chdir="$TF_ROOT" workspace delete "$WORKSPACE" >/dev/null
record_failure terraform_workspace_delete "$?"
set -e
exit "$overall_status"

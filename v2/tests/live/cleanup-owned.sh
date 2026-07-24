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
REGION="${AWS_REGION:?}"
KEEP_INFRA="${KEEP_INFRA:-0}"
EVIDENCE_DIR="${HIVEMIND_LIVE_EVIDENCE_DIR:?}"
[[ "$WORKSPACE" == *"$RUN_TOKEN"* && "$BUCKET" == *"$RUN_TOKEN"* ]]

if [[ "$KEEP_INFRA" == 1 ]]; then
    echo "KEEP_INFRA=1: no destructive cleanup performed; acceptance will remain incomplete"
    exit 0
fi

terraform -chdir="$TF_ROOT" workspace select "$WORKSPACE" >/dev/null
timeout --foreground --kill-after=30s "${HIVEMIND_TERRAFORM_DESTROY_TIMEOUT_SECONDS:-1800}s" \
    terraform -chdir="$TF_ROOT" destroy -auto-approve \
    -var "run_token=$RUN_TOKEN" -var "ecr_repository_name=${HIVEMIND_LIVE_ECR:?}" -var "region=$REGION" \
    > >(tee "$EVIDENCE_DIR/terraform-destroy.log") 2>&1

marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT
if timeout --foreground --kill-after=2s 30s aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
    timeout --foreground --kill-after=2s 30s aws s3api get-object --bucket "$BUCKET" --key .hivemind-owner "$marker" >/dev/null
    [[ "$(cat "$marker")" == "$RUN_TOKEN" ]] || { echo "FAIL: refusing cleanup of bucket without exact ownership marker" >&2; exit 1; }
    timeout --foreground --kill-after=10s 300s aws s3 rm "s3://$BUCKET" --recursive --region "$REGION"
    timeout --foreground --kill-after=2s 30s aws s3 rb "s3://$BUCKET" --region "$REGION"
fi

env -u TF_WORKSPACE terraform -chdir="$TF_ROOT" workspace select default >/dev/null
env -u TF_WORKSPACE terraform -chdir="$TF_ROOT" workspace delete "$WORKSPACE" >/dev/null

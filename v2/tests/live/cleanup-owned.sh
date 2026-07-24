#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TF_ROOT="$ROOT_DIR/infra/poc"
RUN_TOKEN="${HIVEMIND_RUN_TOKEN:?}"
WORKSPACE="${TF_WORKSPACE:?}"
BUCKET="${HIVEMIND_LIVE_BUCKET:?}"
REGION="${AWS_REGION:?}"
KEEP_INFRA="${KEEP_INFRA:-0}"
[[ "$WORKSPACE" == *"$RUN_TOKEN"* && "$BUCKET" == *"$RUN_TOKEN"* ]]

if [[ "$KEEP_INFRA" == 1 ]]; then
    echo "KEEP_INFRA=1: no destructive cleanup performed; acceptance will remain incomplete"
    exit 0
fi

terraform -chdir="$TF_ROOT" workspace select "$WORKSPACE" >/dev/null
timeout --foreground --kill-after=30s "${HIVEMIND_TERRAFORM_DESTROY_TIMEOUT_SECONDS:-1800}s" \
    terraform -chdir="$TF_ROOT" destroy -auto-approve \
    -var "run_token=$RUN_TOKEN" -var "ecr_repository_name=${HIVEMIND_LIVE_ECR:?}" -var "region=$REGION"

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

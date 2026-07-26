#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:?}"
RUN_TOKEN="${HIVEMIND_RUN_TOKEN:?}"
BUCKET="${HIVEMIND_LIVE_BUCKET:?}"
ECR_NAME="${HIVEMIND_LIVE_ECR:?}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PHASE="${1:-post}"
[[ "$PHASE" == pre || "$PHASE" == post ]] || { echo "usage: inventory-owned.sh [pre|post]" >&2; exit 2; }
[[ "$RUN_TOKEN" =~ ^[a-z][a-z0-9]{11,31}$ ]]
[[ "$BUCKET" =~ ^[a-z0-9][a-z0-9-]{7,62}$ && "$ECR_NAME" =~ ^[a-z0-9][a-z0-9-]{7,62}$ ]]
[[ "$BUCKET" == *"$RUN_TOKEN"* && "$ECR_NAME" == *"$RUN_TOKEN"* ]]

aws_count() {
    timeout --foreground --kill-after=2s 30s aws "$@"
}
instances="$(aws_count ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:HivemindRunToken,Values=$RUN_TOKEN" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
    --query 'length(Reservations[].Instances[])' --output text)"
volumes="$(aws_count ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:HivemindRunToken,Values=$RUN_TOKEN" \
    --query 'length(Volumes)' --output text)"
security_groups="$(aws_count ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:HivemindRunToken,Values=$RUN_TOKEN" --query 'length(SecurityGroups)' --output text)"
key_pairs="$(aws_count ec2 describe-key-pairs --region "$REGION" \
    --filters "Name=tag:HivemindRunToken,Values=$RUN_TOKEN" --query 'length(KeyPairs)' --output text)"
network_resources=$((security_groups + key_pairs))
buckets="$(aws_count s3api list-buckets --query "length(Buckets[?Name=='$BUCKET'])" --output text)"
ecr_error="$(mktemp)"
trap 'rm -f "$ecr_error"' EXIT
if aws_count ecr describe-repositories --region "$REGION" --repository-names "$ECR_NAME" >/dev/null 2>"$ecr_error"; then
    repositories=1
elif grep -q 'RepositoryNotFoundException' "$ecr_error"; then
    repositories=0
else
    cat "$ecr_error" >&2
    exit 1
fi
locks=0
[[ ! -e "$ROOT_DIR/infra/poc/.terraform.tfstate.lock.info" ]] || locks=1
selected_workspace="$(terraform -chdir="$ROOT_DIR/infra/poc" workspace show 2>/dev/null || true)"
workspace_count="$(terraform -chdir="$ROOT_DIR/infra/poc" workspace list 2>/dev/null | sed 's/^[* ]*//' | grep -Fxc "${TF_WORKSPACE:?}" || true)"
if [[ "$PHASE" == pre ]]; then
    state_count="$(terraform -chdir="$ROOT_DIR/infra/poc" state list 2>/dev/null | awk 'END {print NR + 0}')"
    [[ "$selected_workspace" == "$TF_WORKSPACE" && "$workspace_count" == 1 && "$state_count" == 0 ]] || locks=$((locks + 1))
else
    [[ "$workspace_count" == 0 ]] || locks=$((locks + 1))
fi
units="$({ systemctl list-units --all --no-legend "*$RUN_TOKEN*" 2>/dev/null || true; } | awk 'END {print NR + 0}')"
processes="$(ps -eo args= | awk -v token="$RUN_TOKEN" -v self="$0" 'index($0, token) && !index($0, self) {count++} END {print count + 0}')"
# Runtime-owned deployments, tasks, containers, and mounts cannot outlive their
# token-owned hosts. Count every remaining host conservatively until teardown
# proves that the host boundary itself is absent.
deployments="$instances"
containerd_tasks="$instances"
containerd_containers="$instances"
juicefs_mounts="$instances"
ssm_commands=0
for command_status in Pending InProgress Delayed Cancelling; do
    active_commands="$(aws_count ssm list-commands --region "$REGION" --filters \
        "key=Comment,value=$RUN_TOKEN" "key=Status,value=$command_status" \
        --query 'length(Commands)' --output text)"
    [[ "$active_commands" =~ ^[0-9]+$ ]] || { echo "invalid SSM inventory count" >&2; exit 1; }
    ssm_commands=$((ssm_commands + active_commands))
done
temporary_secret_files="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type f -name "*${RUN_TOKEN}*" -print 2>/dev/null | awk 'END {print NR + 0}')"
for value in "$instances" "$volumes" "$network_resources" "$buckets" "$repositories" "$locks" "$units" "$processes" \
    "$deployments" "$containerd_tasks" "$containerd_containers" "$juicefs_mounts" "$ssm_commands" "$temporary_secret_files"; do
    [[ "$value" =~ ^[0-9]+$ ]] || { echo "invalid inventory count" >&2; exit 1; }
done
printf 'instances=%s\nvolumes=%s\nnetwork_resources=%s\nbuckets=%s\nrepositories=%s\nlocks=%s\nunits=%s\nprocesses=%s\ndeployments=%s\ncontainerd_tasks=%s\ncontainerd_containers=%s\njuicefs_mounts=%s\nssm_commands=%s\ntemporary_secret_files=%s\n' \
    "$instances" "$volumes" "$network_resources" "$buckets" "$repositories" "$locks" "$units" "$processes" \
    "$deployments" "$containerd_tasks" "$containerd_containers" "$juicefs_mounts" "$ssm_commands" "$temporary_secret_files"

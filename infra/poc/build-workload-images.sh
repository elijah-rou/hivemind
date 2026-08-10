#!/usr/bin/env bash
set -euo pipefail

# Build and push the POC CPU/GPU inference images.
# Required:
#   REGISTRY=registry.example.com/repo-prefix
# Optional:
#   TAG=poc-YYYYMMDD
#   PUSH=false    # build only
#
# The runbook creates the POC ECR repository through Terraform before calling
# this script. This script never creates cloud resources; teardown is owned by
# Terraform.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY="${REGISTRY:?set REGISTRY, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/hivemind-poc}"
TAG="${TAG:-poc-$(date +%Y%m%d%H%M%S)}"
PUSH="${PUSH:-true}"

CPU_IMAGE="$REGISTRY:cpu-$TAG"
GPU_IMAGE="$REGISTRY:gpu-$TAG"

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required" >&2
    exit 1
fi

# Auto-login to ECR if registry looks like an ECR URL.
# The repository must already exist so `terraform destroy` can own cleanup.
if [[ "$REGISTRY" == *.dkr.ecr.*.amazonaws.com* && "$PUSH" == "true" ]]; then
    if ! command -v aws >/dev/null 2>&1; then
        echo "aws is required for ECR login" >&2
        exit 1
    fi
    ECR_HOST="${REGISTRY%%/*}"
    ECR_REGION="${ECR_HOST#*.dkr.ecr.}"
    ECR_REGION="${ECR_REGION%%.amazonaws.com}"
    ECR_REPO="${REGISTRY#*/}"
    echo "Logging into ECR in $ECR_REGION..."
    aws ecr describe-repositories --region "$ECR_REGION" --repository-names "$ECR_REPO" >/dev/null
    aws ecr get-login-password --region "$ECR_REGION" | docker login --username AWS --password-stdin "${REGISTRY%%/*}"
fi

docker build --platform linux/amd64 -t "$CPU_IMAGE" "$ROOT_DIR/workloads/poc/cpu"
docker build --platform linux/amd64 -t "$GPU_IMAGE" "$ROOT_DIR/workloads/poc/gpu"

if [[ "$PUSH" == "true" ]]; then
    docker push "$CPU_IMAGE"
    docker push "$GPU_IMAGE"
fi

cat <<EOF
CPU_IMAGE=$CPU_IMAGE
GPU_IMAGE=$GPU_IMAGE
EOF

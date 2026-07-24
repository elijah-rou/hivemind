#!/usr/bin/env bash
set -euo pipefail

# Destroy POC-owned cloud resources in reverse dependency order.
# Defaults destroy both isolated Terraform states:
#   - infra/poc-eks: dedicated EKS baseline VPC/cluster/node groups/IAM
#   - infra/poc: Hivemind EC2/SG/keypair + Terraform-managed ECR repo
#
# Usage:
#   bash scripts/poc-teardown.sh
#   DESTROY_EKS=false bash scripts/poc-teardown.sh
#   DESTROY_HIVEMIND=false bash scripts/poc-teardown.sh

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_REGION="${AWS_REGION:-us-east-1}"
DESTROY_EKS="${DESTROY_EKS:-true}"
DESTROY_HIVEMIND="${DESTROY_HIVEMIND:-true}"
export TF_VAR_region="$AWS_REGION"

need() {
    command -v "$1" >/dev/null 2>&1 || { echo "missing required command: $1" >&2; exit 1; }
}

section() {
    echo ""
    echo "=== $* ==="
}

confirm_path_safety() {
    local path="$1"
    case "$path" in
        "$ROOT_DIR/infra/poc"|"$ROOT_DIR/infra/poc-eks") ;;
        *) echo "refusing to run terraform outside isolated POC dirs: $path" >&2; exit 1 ;;
    esac
}

terraform_destroy_dir() {
    local dir="$1"
    confirm_path_safety "$dir"
    (cd "$dir" && terraform init -input=false && terraform destroy -auto-approve)
}

resolve_poc_run_token() {
    if [[ -n "${TF_VAR_run_token:-}" ]]; then
        return 0
    fi
    local token
    token="$(terraform -chdir="$ROOT_DIR/infra/poc" show -json 2>/dev/null | jq -r \
        '[.. | objects | .HivemindRunToken? // empty] | unique | if length == 1 then .[0] else empty end')"
    [[ "$token" =~ ^[a-z][a-z0-9]{11,31}$ ]] || {
        echo "unable to derive one exact run token from existing POC state; set TF_VAR_run_token" >&2
        exit 1
    }
    export TF_VAR_run_token="$token"
}

need terraform
need jq

if [[ "$DESTROY_EKS" == "true" ]]; then
    section "Destroy isolated EKS baseline"
    terraform_destroy_dir "$ROOT_DIR/infra/poc-eks"
else
    echo "skip EKS destroy"
fi

if [[ "$DESTROY_HIVEMIND" == "true" ]]; then
    section "Destroy isolated Hivemind POC infra"
    resolve_poc_run_token
    terraform_destroy_dir "$ROOT_DIR/infra/poc"
else
    echo "skip Hivemind destroy"
fi

section "Teardown complete"

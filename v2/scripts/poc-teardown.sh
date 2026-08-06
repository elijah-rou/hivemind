#!/usr/bin/env bash
set -euo pipefail

# Destroy POC-owned cloud resources in reverse dependency order.
# Defaults destroy both isolated Terraform states:
#   - infra/poc-eks: dedicated EKS baseline VPC/cluster/node groups/IAM
#   - infra/poc: Hivemind EC2/SG/keypair + Terraform-managed ECR repo
#
# Usage:
#   TF_VAR_run_token=<exact-run-token> bash scripts/poc-teardown.sh
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
    local supplied_token="${TF_VAR_run_token:-}" state_file state_token
    [[ "$supplied_token" =~ ^[a-z][a-z0-9]{11,31}$ ]] || {
        echo "TF_VAR_run_token must supply the exact token recorded on every managed POC resource" >&2
        exit 1
    }

    state_file="$(mktemp)" || { echo "unable to create POC state verification file" >&2; exit 1; }
    trap 'rm -f "$state_file"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! terraform -chdir="$ROOT_DIR/infra/poc" show -json >"$state_file" 2>/dev/null; then
        rm -f "$state_file"
        echo "unable to read existing POC Terraform state" >&2
        exit 1
    fi
    if ! state_token="$(jq -er '
        [
          .values.root_module
          | recurse(.child_modules[]?)
          | .resources[]?
          | select(.mode == "managed")
          | {
              address,
              token: (.values.tags_all.HivemindRunToken
                      // .values.tags.HivemindRunToken
                      // null)
            }
        ] as $resources
        | if ($resources | length) == 0 then
            error("POC state has no managed resources")
          elif all($resources[];
                   (.token | type) == "string"
                   and (.token | test("^[a-z][a-z0-9]{11,31}$"))) | not then
            error("managed POC resource is missing an exact ownership token")
          elif ([$resources[].token] | unique | length) != 1 then
            error("managed POC resources have inconsistent ownership tokens")
          else
            $resources[0].token
          end
    ' "$state_file")"; then
        rm -f "$state_file"
        echo "unable to derive one exact run token from all managed POC resources" >&2
        exit 1
    fi
    rm -f "$state_file"
    trap - EXIT INT TERM

    if [[ "$state_token" != "$supplied_token" ]]; then
        echo "supplied POC run token does not match managed resource ownership" >&2
        exit 1
    fi
    export TF_VAR_run_token="$state_token"
}

resolve_eks_run_token() {
    local supplied_token="${TF_VAR_run_token:-}" state_file
    [[ "$supplied_token" =~ ^[a-z][a-z0-9]{11,31}$ ]] || {
        echo "TF_VAR_run_token must supply the exact token recorded in the independent EKS state" >&2
        exit 1
    }

    state_file="$(mktemp)" || { echo "unable to create EKS state verification file" >&2; exit 1; }
    trap 'rm -f "$state_file"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if ! terraform -chdir="$ROOT_DIR/infra/poc-eks" show -json >"$state_file" 2>/dev/null; then
        rm -f "$state_file"
        echo "unable to read existing EKS Terraform state" >&2
        exit 1
    fi
    if ! jq -e --arg token "$supplied_token" '
        def managed:
          [.values.root_module
           | recurse(.child_modules[]?)
           | .resources[]?
           | select(.mode == "managed")];
        def resource($resources; $address):
          $resources[] | select(.address == $address);
        def token_of:
          .values.tags_all.HivemindRunToken
          // .values.tags.HivemindRunToken
          // null;
        [
          "aws_eks_cluster.main",
          "aws_eks_node_group.cpu",
          "aws_eks_node_group.gpu",
          "aws_iam_role.eks_cluster",
          "aws_iam_role.eks_nodes",
          "aws_iam_role_policy_attachment.eks_cluster",
          "aws_iam_role_policy_attachment.eks_node_cni",
          "aws_iam_role_policy_attachment.eks_node_ecr",
          "aws_iam_role_policy_attachment.eks_node_worker",
          "aws_internet_gateway.eks",
          "aws_route_table.eks",
          "aws_route_table_association.eks[0]",
          "aws_route_table_association.eks[1]",
          "aws_subnet.eks[0]",
          "aws_subnet.eks[1]",
          "aws_vpc.eks"
        ] as $expected_addresses
        | managed as $resources
        | (resource($resources; "aws_vpc.eks").values.id) as $vpc_id
        | ([resource($resources; "aws_subnet.eks[0]").values.id,
            resource($resources; "aws_subnet.eks[1]").values.id] | sort) as $subnet_ids
        | (resource($resources; "aws_route_table.eks").values.id) as $route_table_id
        | (resource($resources; "aws_iam_role.eks_cluster").values) as $cluster_role
        | (resource($resources; "aws_iam_role.eks_nodes").values) as $node_role
        | (resource($resources; "aws_eks_cluster.main").values) as $cluster
        | (.values.outputs.hivemind_run_token.value == $token)
        and (($resources | map(.address) | sort) == ($expected_addresses | sort))
        and ($resources | all(.[];
          if (.type == "aws_route_table_association"
              or .type == "aws_iam_role_policy_attachment")
          then true else token_of == $token end))
        and ([resource($resources; "aws_subnet.eks[0]"),
              resource($resources; "aws_subnet.eks[1]")] | all(.[]; .values.vpc_id == $vpc_id))
        and (resource($resources; "aws_internet_gateway.eks").values.vpc_id == $vpc_id)
        and (resource($resources; "aws_route_table.eks").values.vpc_id == $vpc_id)
        and ([resource($resources; "aws_route_table_association.eks[0]"),
              resource($resources; "aws_route_table_association.eks[1]")]
             | all(.[];
               . as $association
               | $association.values.route_table_id == $route_table_id
                 and ($subnet_ids | index($association.values.subnet_id)) != null))
        and (($cluster.vpc_config[0].subnet_ids | sort) == $subnet_ids)
        and ($cluster.role_arn == $cluster_role.arn)
        and ([resource($resources; "aws_eks_node_group.cpu"),
              resource($resources; "aws_eks_node_group.gpu")]
             | all(.[];
               .values.cluster_name == $cluster.name
               and .values.node_role_arn == $node_role.arn
               and ((.values.subnet_ids | sort) == $subnet_ids)))
        and (resource($resources; "aws_iam_role_policy_attachment.eks_cluster").values
             | .role == $cluster_role.name
               and .policy_arn == "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy")
        and ([resource($resources; "aws_iam_role_policy_attachment.eks_node_worker").values,
              resource($resources; "aws_iam_role_policy_attachment.eks_node_cni").values,
              resource($resources; "aws_iam_role_policy_attachment.eks_node_ecr").values]
             | map(.role) | all(.[]; . == $node_role.name))
        and ([resource($resources; "aws_iam_role_policy_attachment.eks_node_worker").values.policy_arn,
              resource($resources; "aws_iam_role_policy_attachment.eks_node_cni").values.policy_arn,
              resource($resources; "aws_iam_role_policy_attachment.eks_node_ecr").values.policy_arn]
             | sort == ([
                 "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
                 "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
                 "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
               ] | sort))
    ' "$state_file" >/dev/null; then
        rm -f "$state_file"
        echo "EKS state topology or exact ownership token validation failed" >&2
        exit 1
    fi
    rm -f "$state_file"
    trap - EXIT INT TERM
}

need terraform
need jq
for destroy_flag in "$DESTROY_EKS" "$DESTROY_HIVEMIND"; do
    [[ "$destroy_flag" == "true" || "$destroy_flag" == "false" ]] || {
        echo "DESTROY_EKS and DESTROY_HIVEMIND must be true or false" >&2
        exit 2
    }
done

# Each independent state must prove the supplied token and its expected topology
# before any destroy against that state, including EKS-only teardown.
if [[ "$DESTROY_EKS" == "true" ]]; then
    resolve_eks_run_token
fi
if [[ "$DESTROY_HIVEMIND" == "true" ]]; then
    resolve_poc_run_token
fi

if [[ "$DESTROY_EKS" == "true" ]]; then
    section "Destroy isolated EKS baseline"
    terraform_destroy_dir "$ROOT_DIR/infra/poc-eks"
else
    echo "skip EKS destroy"
fi

if [[ "$DESTROY_HIVEMIND" == "true" ]]; then
    section "Destroy isolated Hivemind POC infra"
    terraform_destroy_dir "$ROOT_DIR/infra/poc"
else
    echo "skip Hivemind destroy"
fi

section "Teardown complete"

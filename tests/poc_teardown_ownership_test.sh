#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEARDOWN="$ROOT_DIR/scripts/poc-teardown.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
: > "$TMP_DIR/terraform.log"

cat > "$TMP_DIR/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cwd=%s token=%s args=%s\n' "$PWD" "${TF_VAR_run_token:-}" "$*" >> "$TF_LOG"
if [[ "${1:-}" == -chdir=* && "${2:-}" == show && "${3:-}" == -json ]]; then
  chdir="${1#-chdir=}"
  if [[ "$chdir" == */infra/poc-eks ]]; then
    [[ "${TF_EKS_STATE_SCENARIO:-exact}" != show-failure ]] || exit 1
    eks_token="${TF_EKS_STATE_TOKEN:-${TF_STATE_TOKEN:-hivemindrun01}}"
    association_route=rt-owned
    [[ "${TF_EKS_STATE_SCENARIO:-exact}" != foreign-association ]] || association_route=rt-foreign
    case "${TF_EKS_STATE_SCENARIO:-exact}" in
      exact|foreign-association)
        cat <<JSON
{"values":{"outputs":{"hivemind_run_token":{"value":"$eks_token"}},"root_module":{"resources":[
 {"address":"aws_eks_cluster.main","mode":"managed","type":"aws_eks_cluster","values":{"name":"hivemind-poc-eks-baseline","role_arn":"arn:cluster-role","vpc_config":[{"subnet_ids":["subnet-b","subnet-a"]}],"tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_eks_node_group.cpu","mode":"managed","type":"aws_eks_node_group","values":{"cluster_name":"hivemind-poc-eks-baseline","node_role_arn":"arn:node-role","subnet_ids":["subnet-a","subnet-b"],"tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_eks_node_group.gpu","mode":"managed","type":"aws_eks_node_group","values":{"cluster_name":"hivemind-poc-eks-baseline","node_role_arn":"arn:node-role","subnet_ids":["subnet-b","subnet-a"],"tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_vpc.eks","mode":"managed","type":"aws_vpc","values":{"id":"vpc-owned","tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_subnet.eks[0]","mode":"managed","type":"aws_subnet","values":{"id":"subnet-a","vpc_id":"vpc-owned","tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_subnet.eks[1]","mode":"managed","type":"aws_subnet","values":{"id":"subnet-b","vpc_id":"vpc-owned","tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_internet_gateway.eks","mode":"managed","type":"aws_internet_gateway","values":{"vpc_id":"vpc-owned","tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_route_table.eks","mode":"managed","type":"aws_route_table","values":{"id":"rt-owned","vpc_id":"vpc-owned","tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_route_table_association.eks[0]","mode":"managed","type":"aws_route_table_association","values":{"subnet_id":"subnet-a","route_table_id":"$association_route"}},
 {"address":"aws_route_table_association.eks[1]","mode":"managed","type":"aws_route_table_association","values":{"subnet_id":"subnet-b","route_table_id":"$association_route"}},
 {"address":"aws_iam_role.eks_cluster","mode":"managed","type":"aws_iam_role","values":{"name":"cluster-role","arn":"arn:cluster-role","tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_iam_role.eks_nodes","mode":"managed","type":"aws_iam_role","values":{"name":"node-role","arn":"arn:node-role","tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_iam_role_policy_attachment.eks_cluster","mode":"managed","type":"aws_iam_role_policy_attachment","values":{"role":"cluster-role","policy_arn":"arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"}},
 {"address":"aws_iam_role_policy_attachment.eks_node_worker","mode":"managed","type":"aws_iam_role_policy_attachment","values":{"role":"node-role","policy_arn":"arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"}},
 {"address":"aws_iam_role_policy_attachment.eks_node_cni","mode":"managed","type":"aws_iam_role_policy_attachment","values":{"role":"node-role","policy_arn":"arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"}},
 {"address":"aws_iam_role_policy_attachment.eks_node_ecr","mode":"managed","type":"aws_iam_role_policy_attachment","values":{"role":"node-role","policy_arn":"arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"}}
]}}}
JSON
        ;;
      missing-tag)
        cat <<JSON
{"values":{"outputs":{"hivemind_run_token":{"value":"$eks_token"}},"root_module":{"resources":[
 {"address":"aws_eks_cluster.main","mode":"managed","type":"aws_eks_cluster","values":{"tags_all":{}}},
 {"address":"aws_eks_node_group.cpu","mode":"managed","type":"aws_eks_node_group","values":{"tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_eks_node_group.gpu","mode":"managed","type":"aws_eks_node_group","values":{"tags_all":{"HivemindRunToken":"$eks_token"}}}
]}}}
JSON
        ;;
      unexpected-resource)
        cat <<JSON
{"values":{"outputs":{"hivemind_run_token":{"value":"$eks_token"}},"root_module":{"resources":[
 {"address":"aws_eks_cluster.main","mode":"managed","type":"aws_eks_cluster","values":{"tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_eks_node_group.cpu","mode":"managed","type":"aws_eks_node_group","values":{"tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_eks_node_group.gpu","mode":"managed","type":"aws_eks_node_group","values":{"tags_all":{"HivemindRunToken":"$eks_token"}}},
 {"address":"aws_s3_bucket.foreign","mode":"managed","type":"aws_s3_bucket","values":{"tags_all":{"HivemindRunToken":"$eks_token"}}}
]}}}
JSON
        ;;
      *) exit 2 ;;
    esac
    exit 0
  fi
  [[ "${TF_STATE_SCENARIO:-exact}" != show-failure ]] || exit 1
  token="${TF_STATE_TOKEN:-hivemindrun01}"
  other="${TF_STATE_OTHER_TOKEN:-hivemindrun02}"
  case "${TF_STATE_SCENARIO:-exact}" in
    exact)
      cat <<JSON
{"values":{"root_module":{"resources":[
 {"address":"aws_instance.replica[0]","mode":"managed","values":{"tags_all":{"HivemindRunToken":"$token"}}},
 {"address":"data.aws_vpc.default","mode":"data","values":{}},
 {"address":"aws_ecr_repository.workloads","mode":"managed","values":{"tags":{"HivemindRunToken":"$token"}}}
],"child_modules":[{"resources":[
 {"address":"module.child.aws_security_group.poc","mode":"managed","values":{"tags_all":{"HivemindRunToken":"$token"}}}
]}]}}}
JSON
      ;;
    mixed)
      cat <<JSON
{"values":{"root_module":{"resources":[
 {"address":"aws_instance.replica[0]","mode":"managed","values":{"tags_all":{"HivemindRunToken":"$token"}}},
 {"address":"aws_instance.worker","mode":"managed","values":{"tags_all":{"HivemindRunToken":"$other"}}}
]}}}
JSON
      ;;
    missing)
      cat <<JSON
{"values":{"root_module":{"resources":[
 {"address":"aws_instance.replica[0]","mode":"managed","values":{"tags_all":{"HivemindRunToken":"$token"}}},
 {"address":"aws_key_pair.poc","mode":"managed","values":{"tags_all":{}}}
]}}}
JSON
      ;;
    empty) printf '%s\n' '{"values":{"root_module":{"resources":[]}}}' ;;
    *) exit 2 ;;
  esac
  exit 0
fi
case "${1:-}" in
  init) exit 0 ;;
  destroy) exit 0 ;;
  *) echo "unexpected terraform invocation: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/terraform"
export PATH="$TMP_DIR/bin:/usr/bin:/bin" TF_LOG="$TMP_DIR/terraform.log"

run_teardown() {
  local output_name="$1"
  shift
  : > "$TF_LOG"
  set +e
  env "$@" "$TEARDOWN" >"$TMP_DIR/$output_name.out" 2>"$TMP_DIR/$output_name.err"
  RUN_RC=$?
  set -e
}

assert_no_destroy() {
  if grep -q 'args=destroy ' "$TF_LOG"; then
    echo "destructive Terraform call occurred without exact ownership" >&2
    exit 1
  fi
}

run_teardown missing-supplied DESTROY_EKS=true DESTROY_HIVEMIND=true
[[ "$RUN_RC" -ne 0 ]]
assert_no_destroy
grep -q 'must supply the exact token' "$TMP_DIR/missing-supplied.err"

run_teardown supplied-mismatch DESTROY_EKS=true DESTROY_HIVEMIND=true \
  TF_VAR_run_token=hivemindrun09 TF_EKS_STATE_TOKEN=hivemindrun09 TF_STATE_TOKEN=hivemindrun01
[[ "$RUN_RC" -ne 0 ]]
assert_no_destroy
grep -q 'does not match managed resource ownership' "$TMP_DIR/supplied-mismatch.err"

for scenario in mixed missing empty show-failure; do
  run_teardown "$scenario" DESTROY_EKS=true DESTROY_HIVEMIND=true \
    TF_VAR_run_token=hivemindrun01 TF_STATE_SCENARIO="$scenario"
  [[ "$RUN_RC" -ne 0 ]]
  assert_no_destroy
done

run_teardown exact DESTROY_EKS=true DESTROY_HIVEMIND=true \
  TF_VAR_run_token=hivemindrun01 TF_STATE_SCENARIO=exact
[[ "$RUN_RC" -eq 0 ]]
[[ "$(grep -c 'args=destroy -auto-approve' "$TF_LOG")" -eq 2 ]]
if grep 'args=destroy -auto-approve' "$TF_LOG" | grep -vq 'token=hivemindrun01'; then
  echo "destroy did not retain the state-verified token" >&2
  exit 1
fi

run_teardown eks-only-missing-token DESTROY_EKS=true DESTROY_HIVEMIND=false
[[ "$RUN_RC" -ne 0 ]]
assert_no_destroy

for scenario in missing-tag unexpected-resource foreign-association show-failure; do
  run_teardown "eks-$scenario" DESTROY_EKS=true DESTROY_HIVEMIND=false \
    TF_VAR_run_token=hivemindrun01 TF_EKS_STATE_SCENARIO="$scenario"
  [[ "$RUN_RC" -ne 0 ]]
  assert_no_destroy
done

run_teardown eks-only-exact DESTROY_EKS=true DESTROY_HIVEMIND=false \
  TF_VAR_run_token=hivemindrun01 TF_EKS_STATE_SCENARIO=exact
[[ "$RUN_RC" -eq 0 ]]
[[ "$(grep -c 'args=destroy -auto-approve' "$TF_LOG")" -eq 1 ]]
grep -q -- '-chdir=.*/infra/poc-eks show -json' "$TF_LOG"
if grep -q -- '-chdir=.*/infra/poc show -json' "$TF_LOG"; then
  echo "EKS-only teardown unexpectedly read Hivemind state" >&2
  exit 1
fi

echo 'POC teardown ownership fixtures: PASS'

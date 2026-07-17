#!/usr/bin/env bash
set -euo pipefail

# Deploy hivemind binary to EC2 instances and start 5-node cluster.
# Usage: ./deploy.sh [path-to-hivemind-binary] [path-to-bench-binary]
#
# Defaults resolve relative to this script, not the caller CWD.
# SSM start commands are polled to terminal Success (see ssm_wait.sh).
# Override bounds with SSM_POLL_INTERVAL_SEC / SSM_POLL_TIMEOUT_SEC.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${1:-$SCRIPT_DIR/../../core/zig-out/bin/hivemind}"
BENCH="${2:-$SCRIPT_DIR/../../bench/hivemind-bench}"
REGION="us-east-1"
TF=(terraform -chdir="$SCRIPT_DIR")

# shellcheck source=ssm_wait.sh disable=SC1091
source "$SCRIPT_DIR/ssm_wait.sh"
# shellcheck source=artifact_lifecycle.sh disable=SC1091
source "$SCRIPT_DIR/artifact_lifecycle.sh"
hivemind_ssm_assert_poll_bounds

if [[ ! -f "$BINARY" ]]; then
  echo "binary not found: $BINARY"
  echo "build with: cd \"$SCRIPT_DIR/../../core\" && zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast"
  exit 1
fi

# Get terraform outputs (always scoped to SCRIPT_DIR, independent of caller CWD)
mapfile -t INSTANCE_IDS < <("${TF[@]}" output -json instance_ids | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))")
mapfile -t PRIVATE_IPS < <("${TF[@]}" output -json private_ips | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))")
BENCH_ADDRS=$("${TF[@]}" output -raw bench_addrs)
REMOTE_REPLACE_TIMEOUT_SEC="${HIVEMIND_REMOTE_REPLACE_TIMEOUT_SEC:-30}"
[[ "$REMOTE_REPLACE_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid remote replacement timeout" >&2; exit 1; }
SYSTEMD_LIBRARY_B64="$(base64 < "$SCRIPT_DIR/systemd_lifecycle.sh" | tr -d '\n')"

NODE_COUNT=${#INSTANCE_IDS[@]}
echo "deploying to $NODE_COUNT nodes: ${INSTANCE_IDS[*]}"

# Wait for SSM to be ready on all instances
echo "waiting for SSM..."
for id in "${INSTANCE_IDS[@]}"; do
  hivemind_ssm_wait_online "$REGION" "$id"
done

hivemind_deploy_cleanup() {
  local prior_status=$?
  trap - EXIT
  hivemind_artifact_cleanup "$prior_status"
  exit $?
}

# Install cleanup as the immediate next operation after ownership succeeds.
hivemind_artifact_prepare "$REGION"
trap hivemind_deploy_cleanup EXIT

RUN_ID="$HIVEMIND_ARTIFACT_ACCOUNT-$HIVEMIND_ARTIFACT_TOKEN"
hivemind_artifact_upload "$BINARY" hivemind
HIVEMIND_BINARY_URI="$HIVEMIND_ARTIFACT_URI"
HIVEMIND_BENCH_URI=""
if [[ -f "$BENCH" ]]; then
  hivemind_artifact_upload "$BENCH" bench
  HIVEMIND_BENCH_URI="$HIVEMIND_ARTIFACT_URI"
fi

echo "uploaded immutable artifacts under s3://$HIVEMIND_ARTIFACT_BUCKET/$HIVEMIND_ARTIFACT_PREFIX"

# Preserve each argument vector as a single line. Terraform values contain no whitespace-bearing arguments.
mapfile -t START_ARGS < <("${TF[@]}" output -json start_args | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))")

if [[ ${#START_ARGS[@]} -ne $NODE_COUNT ]]; then
  echo "FAIL: start_args count (${#START_ARGS[@]}) != node count ($NODE_COUNT)" >&2
  exit 1
fi

declare -a COMMAND_IDS=()
for i in $(seq 0 $((NODE_COUNT - 1))); do
  id="${INSTANCE_IDS[$i]}"
  args="${START_ARGS[$i]}"

  echo "starting node $i on $id (${PRIVATE_IPS[$i]})"

  run_dir="/tmp/hivemind-runs/$RUN_ID"
  run_binary="$run_dir/hivemind"
  unit="hivemind-bench-node-$i.service"
  remote_script=$(cat <<EOF
set -euo pipefail
source /tmp/hivemind-systemd-lifecycle.sh
mkdir -m 700 -p '$run_dir' '/var/lib/hivemind/node-$i'
aws s3 cp '$HIVEMIND_BINARY_URI' '$run_binary' --region '$REGION'
chmod 700 '$run_binary'
export HIVEMIND_SYSTEMD_TIMEOUT_SEC='$REMOTE_REPLACE_TIMEOUT_SEC'
hivemind_transaction_begin
exec 9>/tmp/hivemind-launch.lock
lock_wait="\$(hivemind_deadline_remaining)"
if ! flock -x -w "\$lock_wait" 9; then
  echo 'FAIL: timed out waiting for Hivemind replacement lock' >&2
  exit 1
fi
hivemind_unit_stop_verified '$unit'
read -r -a node_args <<< '$args'
hivemind_unit_start_verified '$unit' '$run_binary' "\${node_args[@]}"
echo 'hivemind running as $unit'
EOF
)
  remote_script_b64="$(printf '%s' "$remote_script" | base64 | tr -d '\n')"
  bench_copy_command=":"
  if [[ -n "$HIVEMIND_BENCH_URI" ]]; then
    bench_copy_command="aws s3 cp '$HIVEMIND_BENCH_URI' /tmp/bench --region '$REGION' && chmod 700 /tmp/bench"
  fi

  cmd_id=$(hivemind_ssm_send_command "$SSM_POLL_TIMEOUT_SEC" --region "$REGION" \
    --instance-ids "$id" \
    --document-name "AWS-RunShellScript" \
    --parameters commands="[
      \"printf '%s' '$SYSTEMD_LIBRARY_B64' | base64 -d > /tmp/hivemind-systemd-lifecycle.sh\",
      \"chmod 700 /tmp/hivemind-systemd-lifecycle.sh\",
      \"printf '%s' '$remote_script_b64' | base64 -d | bash\",
      \"$bench_copy_command\"
    ]" \
    --output text --query 'Command.CommandId')
  if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
    echo "FAIL: empty CommandId from send-command for instance $id" >&2
    exit 1
  fi
  COMMAND_IDS+=("$cmd_id")
  echo "  submitted command: $cmd_id"
done

if [[ ${#COMMAND_IDS[@]} -ne $NODE_COUNT ]]; then
  echo "FAIL: command id count (${#COMMAND_IDS[@]}) != node count ($NODE_COUNT)" >&2
  exit 1
fi

echo "waiting for SSM start commands..."
for i in $(seq 0 $((NODE_COUNT - 1))); do
  echo "waiting for node $i (${INSTANCE_IDS[$i]}) command ${COMMAND_IDS[$i]}"
  hivemind_ssm_wait_invocation "$REGION" "${COMMAND_IDS[$i]}" "${INSTANCE_IDS[$i]}"
done

echo ""
echo "cluster started on all $NODE_COUNT nodes."
echo "wait ~10s for peers to connect."
echo ""
echo "bench command (run from any instance or a box in the VPC):"
echo "  ./bench -addrs $BENCH_ADDRS -n 100"
echo ""
echo "to run bench from instance 0:"
echo "  aws ssm start-session --target ${INSTANCE_IDS[0]} --region $REGION"
echo "  /tmp/bench -addrs $BENCH_ADDRS -n 100"
echo ""
echo "artifacts are removed automatically on exit unless HIVEMIND_KEEP_ARTIFACTS=1."
echo "terraform cleanup: terraform -chdir=\"$SCRIPT_DIR\" destroy -auto-approve"

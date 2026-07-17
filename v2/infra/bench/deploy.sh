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
RUN_TOKEN="${HIVEMIND_BENCH_RUN_TOKEN:-$(date +%s)-$$-$RANDOM}"
[[ "$RUN_TOKEN" =~ ^[A-Za-z0-9._-]{1,96}$ ]] || { echo "FAIL: invalid run token" >&2; exit 1; }
PID_LIBRARY_B64="$(base64 < "$SCRIPT_DIR/pid_lifecycle.sh" | tr -d '\n')"

NODE_COUNT=${#INSTANCE_IDS[@]}
echo "deploying to $NODE_COUNT nodes: ${INSTANCE_IDS[*]}"

# Wait for SSM to be ready on all instances
echo "waiting for SSM..."
for id in "${INSTANCE_IDS[@]}"; do
  hivemind_ssm_wait_online "$REGION" "$id"
done

# Upload binary to each instance via S3 (SSM can't do direct file transfer easily)
BUCKET="hivemind-bench-$(date +%s)"
aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null || true
aws s3 cp "$BINARY" "s3://$BUCKET/hivemind" --region "$REGION"
if [[ -f "$BENCH" ]]; then
  aws s3 cp "$BENCH" "s3://$BUCKET/bench" --region "$REGION"
fi

echo "uploaded binary to s3://$BUCKET"

# Preserve each start command as a single line (commands contain spaces).
mapfile -t START_COMMANDS < <("${TF[@]}" output -json start_commands | python3 -c "import sys,json; print('\n'.join(json.load(sys.stdin)))")

if [[ ${#START_COMMANDS[@]} -ne $NODE_COUNT ]]; then
  echo "FAIL: start_commands count (${#START_COMMANDS[@]}) != node count ($NODE_COUNT)" >&2
  exit 1
fi

declare -a COMMAND_IDS=()
for i in $(seq 0 $((NODE_COUNT - 1))); do
  id="${INSTANCE_IDS[$i]}"
  cmd="${START_COMMANDS[$i]}"

  echo "starting node $i on $id (${PRIVATE_IPS[$i]})"

  run_dir="/tmp/hivemind-runs/$RUN_TOKEN"
  run_binary="$run_dir/hivemind"
  cmd="${cmd/\.\/hivemind/$run_binary}"
  remote_script=$(cat <<EOF
set -euo pipefail
source /tmp/hivemind-pid-lifecycle.sh
mkdir -p '$run_dir'
aws s3 cp 's3://$BUCKET/hivemind' '$run_binary' --region '$REGION'
chmod 700 '$run_binary'
exec 9>/tmp/hivemind-launch.lock
flock -x 9
hivemind_stop_verified /tmp/hivemind-current.pid /tmp/hivemind-runs
cd /tmp
nohup $cmd > '$run_dir/hivemind.log' 2>&1 &
pid=\$!
sleep 3
actual=\$(readlink "/proc/\$pid/exe" 2>/dev/null || true)
[[ "\$actual" == '$run_binary' ]] || { echo 'FAILED TO START'; exit 1; }
hivemind_write_pid_state /tmp/hivemind-current.pid "\$pid" '$RUN_TOKEN' '$run_binary'
echo 'hivemind running'
EOF
)
  remote_script_b64="$(printf '%s' "$remote_script" | base64 | tr -d '\n')"

  cmd_id=$(hivemind_ssm_send_command "$SSM_POLL_TIMEOUT_SEC" --region "$REGION" \
    --instance-ids "$id" \
    --document-name "AWS-RunShellScript" \
    --parameters commands="[
      \"printf '%s' '$PID_LIBRARY_B64' | base64 -d > /tmp/hivemind-pid-lifecycle.sh\",
      \"chmod 700 /tmp/hivemind-pid-lifecycle.sh\",
      \"printf '%s' '$remote_script_b64' | base64 -d | bash\",
      \"aws s3 cp s3://$BUCKET/bench /tmp/bench --region $REGION 2>/dev/null || true\",
      \"chmod +x /tmp/bench 2>/dev/null || true\"
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
echo "cleanup:"
echo "  aws s3 rb s3://$BUCKET --force --region $REGION"
echo "  terraform -chdir=\"$SCRIPT_DIR\" destroy -auto-approve"

#!/usr/bin/env bash
set -euo pipefail

# Deploy hivemind binary to EC2 instances and start 5-node cluster.
# Usage: ./deploy.sh [path-to-hivemind-binary]

BINARY="${1:-../../core/zig-out/bin/hivemind}"
BENCH="${2:-../../bench/bench-linux}"
REGION="us-east-1"

if [[ ! -f "$BINARY" ]]; then
  echo "binary not found: $BINARY"
  echo "build with: cd core && zig build -Dtarget=x86_64-linux -Doptimize=ReleaseFast"
  exit 1
fi

# Get terraform outputs
INSTANCE_IDS=($(terraform output -json instance_ids | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)]"))
PRIVATE_IPS=($(terraform output -json private_ips | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)]"))
BENCH_ADDRS=$(terraform output -raw bench_addrs)

NODE_COUNT=${#INSTANCE_IDS[@]}
echo "deploying to $NODE_COUNT nodes: ${INSTANCE_IDS[*]}"

# Wait for SSM to be ready on all instances
echo "waiting for SSM..."
for id in "${INSTANCE_IDS[@]}"; do
  for i in $(seq 1 30); do
    status=$(aws ssm describe-instance-information --region "$REGION" \
      --filters "Key=InstanceIds,Values=$id" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
    if [[ "$status" == "Online" ]]; then
      echo "  $id: online"
      break
    fi
    sleep 5
  done
done

# Upload binary to each instance via S3 (SSM can't do direct file transfer easily)
BUCKET="hivemind-bench-$(date +%s)"
aws s3 mb "s3://$BUCKET" --region "$REGION" 2>/dev/null || true
aws s3 cp "$BINARY" "s3://$BUCKET/hivemind" --region "$REGION"
if [[ -f "$BENCH" ]]; then
  aws s3 cp "$BENCH" "s3://$BUCKET/bench" --region "$REGION"
fi

echo "uploaded binary to s3://$BUCKET"

# Download binary on each instance and start hivemind
START_COMMANDS=($(terraform output -json start_commands | python3 -c "import sys,json; [print(x) for x in json.load(sys.stdin)]"))

for i in $(seq 0 $((NODE_COUNT - 1))); do
  id="${INSTANCE_IDS[$i]}"
  cmd="${START_COMMANDS[$i]}"

  echo "starting node $i on $id (${PRIVATE_IPS[$i]})"

  aws ssm send-command --region "$REGION" \
    --instance-ids "$id" \
    --document-name "AWS-RunShellScript" \
    --parameters commands="[
      \"aws s3 cp s3://$BUCKET/hivemind /tmp/hivemind --region $REGION\",
      \"chmod +x /tmp/hivemind\",
      \"aws s3 cp s3://$BUCKET/bench /tmp/bench --region $REGION 2>/dev/null || true\",
      \"chmod +x /tmp/bench 2>/dev/null || true\",
      \"pkill -f hivemind || true\",
      \"cd /tmp && nohup $cmd > /tmp/hivemind.log 2>&1 &\",
      \"sleep 3\",
      \"pgrep -f hivemind && echo 'hivemind running' || echo 'FAILED TO START'\"
    ]" \
    --output text --query 'Command.CommandId' &
done

wait
echo ""
echo "cluster starting. wait ~10s for peers to connect."
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
echo "  terraform destroy -auto-approve"

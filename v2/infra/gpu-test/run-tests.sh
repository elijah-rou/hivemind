#!/usr/bin/env bash
set -euo pipefail

# Spin up a g4dn.xlarge, run containerd integration tests, tear down.
# Usage: ./run-tests.sh
#
# Prerequisites:
#   - Rust agent built for Linux: cd agent && cross build --release --target x86_64-unknown-linux-gnu --features containerd-integration
#   - Or use cargo-zigbuild: cargo zigbuild --release --target x86_64-unknown-linux-gnu --features containerd-integration
#   - Terraform initialized: terraform init

REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT_DIR="$SCRIPT_DIR/../../agent"

echo "=== Step 1: Build agent + test binary for Linux ==="
cd "$AGENT_DIR"

# Build the integration test binary
# Note: cross-compilation of test binaries is tricky. We'll compile ON the instance instead.
echo "will compile on-instance (cross-compiling test binaries is unreliable)"

echo ""
echo "=== Step 2: Terraform apply ==="
cd "$SCRIPT_DIR"
terraform init -input=false 2>/dev/null
terraform apply -auto-approve

INSTANCE_ID=$(terraform output -raw instance_id)
echo "instance: $INSTANCE_ID"

echo ""
echo "=== Step 3: Wait for SSM ==="
for i in $(seq 1 60); do
  status=$(aws ssm describe-instance-information --region "$REGION" \
    --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo "None")
  if [[ "$status" == "Online" ]]; then
    echo "SSM online"
    break
  fi
  sleep 5
done

echo ""
echo "=== Step 4: Setup instance ==="
# Upload agent source and build on-instance (avoids cross-compilation issues)
BUCKET="hivemind-gpu-test-$(date +%s)"
aws s3 mb "s3://$BUCKET" --region "$REGION"

# Package the agent source
cd "$AGENT_DIR"
tar czf /tmp/agent-src.tar.gz --exclude target --exclude .git -C .. agent/
aws s3 cp /tmp/agent-src.tar.gz "s3://$BUCKET/agent-src.tar.gz" --region "$REGION"

CMD_ID=$(aws ssm send-command --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 600 \
  --parameters commands="[
    \"set -ex\",
    \"apt-get update -qq && apt-get install -y -qq build-essential pkg-config libssl-dev gvisor 2>/dev/null\",
    \"curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y\",
    \"source /root/.cargo/env\",
    \"aws s3 cp s3://$BUCKET/agent-src.tar.gz /tmp/agent-src.tar.gz --region $REGION\",
    \"cd /tmp && tar xzf agent-src.tar.gz\",
    \"cd /tmp/agent && cargo test --test containerd_integration --features containerd-integration -- --test-threads=1 2>&1 || true\",
    \"echo TESTS_COMPLETE\"
  ]" \
  --query 'Command.CommandId' --output text)

echo "command: $CMD_ID"
echo ""
echo "=== Step 5: Wait for tests ==="
echo "(this may take 5-10 minutes for first build)"

for i in $(seq 1 120); do
  status=$(aws ssm list-command-invocations --region "$REGION" \
    --command-id "$CMD_ID" \
    --query 'CommandInvocations[0].Status' --output text 2>/dev/null || echo "Pending")
  if [[ "$status" == "Success" || "$status" == "Failed" ]]; then
    echo "status: $status"
    break
  fi
  sleep 5
done

echo ""
echo "=== Test Output ==="
aws ssm list-command-invocations --region "$REGION" \
  --command-id "$CMD_ID" --details \
  --query 'CommandInvocations[0].CommandPlugins[0].Output' --output text

echo ""
echo "=== Step 6: Cleanup ==="
read -p "Destroy instance? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  aws s3 rb "s3://$BUCKET" --force --region "$REGION"
  terraform destroy -auto-approve
  echo "cleaned up"
else
  echo "instance still running: $INSTANCE_ID"
  echo "connect: aws ssm start-session --target $INSTANCE_ID --region $REGION"
  echo "destroy: cd $SCRIPT_DIR && terraform destroy -auto-approve"
  echo "s3 cleanup: aws s3 rb s3://$BUCKET --force --region $REGION"
fi

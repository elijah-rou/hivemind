#!/usr/bin/env bash
set -euo pipefail

# Spin up a g4dn.xlarge, run containerd integration tests, tear down.
# Usage: ./run-tests.sh
# Set KEEP_INFRA=1 to skip destroy after success/failure (debug retention).
#
# Prerequisites:
#   - Rust worker built for Linux: cd worker && cross build --release --target x86_64-unknown-linux-gnu --features containerd-integration
#   - Or use cargo-zigbuild: cargo zigbuild --release --target x86_64-unknown-linux-gnu --features containerd-integration
#   - Terraform initialized: terraform init

REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKER_DIR="$SCRIPT_DIR/../../worker"
KEEP_INFRA="${KEEP_INFRA:-0}"
REQUIRE_GPU="${REQUIRE_GPU:-0}"
BUCKET=""
BUCKET_OWNED=0
BUCKET_ACCOUNT=""
BUCKET_TOKEN=""
BUCKET_CLAIM=""
BUCKET_MARKER_KEY=".hivemind-owner"
BUCKET_LEASE_PARAMETER=""
BUCKET_LEASE_OWNED=0
INSTANCE_ID=""
CLEANUP_INSTALLED=0
RUN_IDENTITY=""
RUN_WORKSPACE=""
TF_DATA_DIR=""
WORKER_ARCHIVE=""
SSM_POLL_INTERVAL_SEC="${SSM_POLL_INTERVAL_SEC:-5}"
SSM_POLL_TIMEOUT_SEC="${SSM_POLL_TIMEOUT_SEC:-600}"
GPU_COMMAND_TIMEOUT_SEC="${GPU_COMMAND_TIMEOUT_SEC:-900}"
GPU_CLEANUP_TIMEOUT_SEC="${GPU_CLEANUP_TIMEOUT_SEC:-1200}"
GPU_KILL_AFTER_SEC="${GPU_KILL_AFTER_SEC:-10}"
# shellcheck source=../bench/ssm_wait.sh disable=SC1091
source "$SCRIPT_DIR/../bench/ssm_wait.sh"
hivemind_ssm_assert_poll_bounds

if [[ "$KEEP_INFRA" != "0" && "$KEEP_INFRA" != "1" ]]; then
  echo "FAIL: KEEP_INFRA must be 0 or 1" >&2
  exit 2
fi
if [[ "$REQUIRE_GPU" != "0" && "$REQUIRE_GPU" != "1" ]]; then
  echo "FAIL: REQUIRE_GPU must be 0 or 1" >&2
  exit 2
fi
for timeout_value in "$GPU_COMMAND_TIMEOUT_SEC" "$GPU_CLEANUP_TIMEOUT_SEC" "$GPU_KILL_AFTER_SEC"; do
  [[ "$timeout_value" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: GPU timeout values must be positive integers" >&2; exit 2; }
done
(( GPU_CLEANUP_TIMEOUT_SEC >= 4 )) || { echo "FAIL: GPU_CLEANUP_TIMEOUT_SEC must be at least 4" >&2; exit 2; }
run_bounded() {
  local seconds="$1"
  shift
  timeout --signal=TERM --kill-after="${GPU_KILL_AFTER_SEC}s" "${seconds}s" "$@"
}
command -v openssl >/dev/null 2>&1 || { echo "FAIL: openssl is required for the GPU run identity" >&2; exit 1; }
RUN_IDENTITY="$(openssl rand -hex 32)"
[[ "$RUN_IDENTITY" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: invalid GPU run identity" >&2; exit 1; }
BUCKET_TOKEN="${RUN_IDENTITY:0:32}"
BUCKET_CLAIM="${RUN_IDENTITY:32:32}"
RUN_WORKSPACE="hivemind-gpu-$BUCKET_TOKEN"

bucket_identity_valid() {
  [[ "$BUCKET_ACCOUNT" =~ ^[0-9]{12}$ ]] || return 1
  [[ "$BUCKET_TOKEN" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "$BUCKET_CLAIM" =~ ^[0-9a-f]{32}$ ]] || return 1
  [[ "$BUCKET" == "hivemind-gpu-test-$BUCKET_ACCOUNT-$BUCKET_TOKEN" ]] || return 1
  [[ "$BUCKET_MARKER_KEY" == ".hivemind-owner" ]] || return 1
}

bucket_marker_read() {
  local timeout_sec="${1:-$GPU_COMMAND_TIMEOUT_SEC}" marker
  [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || return 1
  bucket_identity_valid || return 1
  marker="$(run_bounded "$timeout_sec" aws s3api head-object \
    --bucket "$BUCKET" \
    --key "$BUCKET_MARKER_KEY" \
    --query "join(':', [Metadata.account,Metadata.token,Metadata.claim])" \
    --output text \
    --region "$REGION")" || return 1
  [[ "$marker" == "$BUCKET_ACCOUNT:$BUCKET_TOKEN:$BUCKET_CLAIM" ]]
}

bucket_lease_read() {
  local timeout_sec="${1:-$GPU_COMMAND_TIMEOUT_SEC}" value
  [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || return 1
  value="$(run_bounded "$timeout_sec" aws ssm get-parameter \
    --name "$BUCKET_LEASE_PARAMETER" --query Parameter.Value --output text \
    --region "$REGION")" || return 1
  [[ "$value" == "$BUCKET_ACCOUNT:$BUCKET_TOKEN:$BUCKET_CLAIM" ]]
}

bucket_lease_acquire() {
  local status=0 value="$BUCKET_ACCOUNT:$BUCKET_TOKEN:$BUCKET_CLAIM"
  BUCKET_LEASE_PARAMETER="/hivemind/s3-ownership/$BUCKET_TOKEN"
  run_bounded "$GPU_COMMAND_TIMEOUT_SEC" aws ssm put-parameter \
    --name "$BUCKET_LEASE_PARAMETER" --type String --value "$value" \
    --no-overwrite --region "$REGION" >/dev/null || status=$?
  if [[ "$status" -eq 0 ]]; then BUCKET_LEASE_OWNED=1; fi
  if ! bucket_lease_read; then
    echo "FAIL: GPU artifact ownership lease was not acquired (status $status)" >&2
    return 1
  fi
  BUCKET_LEASE_OWNED=1
}

prepare_bucket() {
  local head_error create_status=0 marker_status=0
  head_error="$(mktemp "$TF_DATA_DIR/bucket-head.XXXXXX")"
  BUCKET_ACCOUNT="$(run_bounded "$GPU_COMMAND_TIMEOUT_SEC" aws sts get-caller-identity \
    --query Account --output text --region "$REGION")" || {
    echo "FAIL: unable to determine AWS account for GPU bucket ownership" >&2
    return 1
  }
  [[ "$BUCKET_ACCOUNT" =~ ^[0-9]{12}$ ]] || {
    echo "FAIL: invalid AWS account for GPU bucket ownership" >&2
    return 1
  }
  BUCKET="hivemind-gpu-test-$BUCKET_ACCOUNT-$BUCKET_TOKEN"
  bucket_identity_valid || {
    echo "FAIL: invalid GPU bucket ownership identity" >&2
    return 1
  }

  if run_bounded "$GPU_COMMAND_TIMEOUT_SEC" aws s3api head-bucket \
    --bucket "$BUCKET" --region "$REGION" >/dev/null 2>"$head_error"; then
    echo "FAIL: refusing pre-existing GPU artifact bucket: $BUCKET" >&2
    return 1
  fi
  grep -Eq '(404|Not Found|NoSuchBucket)' "$head_error" || {
    echo "FAIL: GPU artifact bucket absence is ambiguous: $BUCKET" >&2
    return 1
  }
  bucket_lease_acquire || return 1

  local -a create_args=(s3api create-bucket --bucket "$BUCKET" --region "$REGION")
  if [[ "$REGION" != us-east-1 ]]; then
    create_args+=(--create-bucket-configuration "LocationConstraint=$REGION")
  fi
  run_bounded "$GPU_COMMAND_TIMEOUT_SEC" aws "${create_args[@]}" >/dev/null || create_status=$?
  run_bounded "$GPU_COMMAND_TIMEOUT_SEC" aws s3api put-object \
    --bucket "$BUCKET" \
    --key "$BUCKET_MARKER_KEY" \
    --body /dev/null \
    --if-none-match '*' \
    --metadata "account=$BUCKET_ACCOUNT,token=$BUCKET_TOKEN,claim=$BUCKET_CLAIM" \
    --region "$REGION" >/dev/null || marker_status=$?

  # The SSM no-overwrite lease serializes cooperative bucket creators. The
  # conditional marker binds the bucket to that exact account/token/claim;
  # ambiguous replies require both remote proofs to read back exactly.
  if [[ "$marker_status" -eq 0 ]]; then
    BUCKET_OWNED=1
  fi
  if ! bucket_marker_read; then
    echo "FAIL: GPU artifact bucket ownership was not proven (create=$create_status marker=$marker_status): $BUCKET" >&2
    return 1
  fi
  BUCKET_OWNED=1
  if [[ "$create_status" -ne 0 || "$marker_status" -ne 0 ]]; then
    echo "reconciled ambiguous GPU artifact bucket ownership: $BUCKET" >&2
  fi
}

if [[ ! -d "$WORKER_DIR" ]]; then
  echo "FAIL: worker source not found at $WORKER_DIR" >&2
  exit 1
fi
TF_DATA_DIR="$(mktemp -d)"
WORKER_ARCHIVE="$(mktemp "$TF_DATA_DIR/worker-src.XXXXXX.tar.gz")"
export TF_DATA_DIR
export TF_WORKSPACE="$RUN_WORKSPACE"

cleanup() {
  local status=$?
  local cleanup_failed=0 cleanup_deadline=$((SECONDS + GPU_CLEANUP_TIMEOUT_SEC)) remaining command_budget=$((GPU_CLEANUP_TIMEOUT_SEC / 4))
  trap - EXIT INT TERM
  set +e
  if [[ "$KEEP_INFRA" == "1" ]]; then
    echo "KEEP_INFRA=1: leaving resources for debugging"
    echo "terraform workspace: $RUN_WORKSPACE"
    [[ -n "$INSTANCE_ID" ]] && echo "instance: $INSTANCE_ID"
    [[ -n "$BUCKET" ]] && echo "s3: s3://$BUCKET"
    rm -rf "$TF_DATA_DIR"
    exit "$status"
  fi
  if [[ -n "$BUCKET" ]]; then
    remaining=$((cleanup_deadline - SECONDS))
    (( remaining <= command_budget )) || remaining=$command_budget
    if [[ "$BUCKET_OWNED" != 1 ]]; then
      if [[ "$BUCKET_LEASE_OWNED" == 1 ]] && (( remaining >= 1 )) && bucket_lease_read "$remaining"; then
        remaining=$((cleanup_deadline - SECONDS))
        (( remaining <= command_budget )) || remaining=$command_budget
        if (( remaining >= 1 )) && run_bounded "$remaining" aws s3api wait bucket-not-exists \
            --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1; then
          remaining=$((cleanup_deadline - SECONDS))
          (( remaining <= command_budget )) || remaining=$command_budget
          if (( remaining >= 1 )) && run_bounded "$remaining" aws ssm delete-parameter \
              --name "$BUCKET_LEASE_PARAMETER" --region "$REGION" >/dev/null; then
            BUCKET_LEASE_OWNED=0
          else
            echo "CLEANUP ERROR: GPU bucket lease removal failed: $BUCKET_LEASE_PARAMETER" >&2
            cleanup_failed=1
          fi
        else
          echo "CLEANUP ERROR: refusing lease release while GPU bucket absence is unproven: s3://$BUCKET" >&2
          cleanup_failed=1
        fi
      elif [[ "$BUCKET_LEASE_OWNED" == 1 ]]; then
        echo "CLEANUP ERROR: GPU bucket lease verification failed: $BUCKET_LEASE_PARAMETER" >&2
        cleanup_failed=1
      fi
    elif [[ "$BUCKET_LEASE_OWNED" != 1 ]] || (( remaining < 1 )) || ! bucket_marker_read "$remaining"; then
      echo "CLEANUP ERROR: refusing S3 removal without the exact GPU marker and account lease: s3://$BUCKET" >&2
      cleanup_failed=1
    else
      remaining=$((cleanup_deadline - SECONDS))
      (( remaining <= command_budget )) || remaining=$command_budget
      if (( remaining < 1 )) || ! bucket_lease_read "$remaining"; then
        echo "CLEANUP ERROR: GPU bucket lease verification failed: $BUCKET_LEASE_PARAMETER" >&2
        cleanup_failed=1
      else
        remaining=$((cleanup_deadline - SECONDS))
        (( remaining <= command_budget )) || remaining=$command_budget
        if (( remaining < 1 )) || ! run_bounded "$remaining" aws s3 rb "s3://$BUCKET" --force --region "$REGION"; then
          echo "CLEANUP ERROR: s3 bucket removal failed: s3://$BUCKET" >&2
          cleanup_failed=1
        else
          BUCKET_OWNED=0
          remaining=$((cleanup_deadline - SECONDS))
          (( remaining <= command_budget )) || remaining=$command_budget
          if (( remaining < 1 )) || ! run_bounded "$remaining" aws ssm delete-parameter \
              --name "$BUCKET_LEASE_PARAMETER" --region "$REGION" >/dev/null; then
            echo "CLEANUP ERROR: GPU bucket lease removal failed: $BUCKET_LEASE_PARAMETER" >&2
            cleanup_failed=1
          else
            BUCKET_LEASE_OWNED=0
          fi
        fi
      fi
    fi
  fi
  cd "$SCRIPT_DIR"
  remaining=$((cleanup_deadline - SECONDS))
  (( remaining <= command_budget )) || remaining=$command_budget
  if (( remaining < 1 )) || ! run_bounded "$remaining" terraform destroy -auto-approve; then
    echo "CLEANUP ERROR: terraform destroy failed for workspace $RUN_WORKSPACE" >&2
    cleanup_failed=1
  fi
  remaining=$((cleanup_deadline - SECONDS))
  (( remaining <= command_budget )) || remaining=$command_budget
  if (( remaining < 1 )) || ! run_bounded "$remaining" env -u TF_WORKSPACE terraform workspace select default >/dev/null; then
    echo "CLEANUP ERROR: terraform workspace select default failed in isolated state $TF_DATA_DIR" >&2
    cleanup_failed=1
  fi
  remaining=$((cleanup_deadline - SECONDS))
  (( remaining <= command_budget )) || remaining=$command_budget
  if (( remaining < 1 )) || ! run_bounded "$remaining" env -u TF_WORKSPACE terraform workspace delete "$RUN_WORKSPACE" >/dev/null; then
    echo "CLEANUP ERROR: terraform workspace delete failed: $RUN_WORKSPACE" >&2
    cleanup_failed=1
  fi
  rm -rf "$TF_DATA_DIR"
  if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
    status=1
  fi
  exit "$status"
}

echo "=== Step 1: Build worker + test binary for Linux ==="
cd "$WORKER_DIR"

# Build the integration test binary
# Note: cross-compilation of test binaries is tricky. We'll compile ON the instance instead.
echo "will compile on-instance (cross-compiling test binaries is unreliable)"

echo ""
echo "=== Step 2: Terraform apply ==="
cd "$SCRIPT_DIR"
run_bounded "$GPU_COMMAND_TIMEOUT_SEC" terraform init -input=false 2>/dev/null
# Each invocation owns a unique Terraform workspace and local metadata directory.
# Concurrent runs therefore cannot observe, mutate, or destroy each other's state.
run_bounded "$GPU_COMMAND_TIMEOUT_SEC" env -u TF_WORKSPACE terraform workspace new "$RUN_WORKSPACE" >/dev/null
if [[ "$CLEANUP_INSTALLED" -eq 0 ]]; then
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  CLEANUP_INSTALLED=1
fi
run_bounded "$GPU_COMMAND_TIMEOUT_SEC" terraform apply -auto-approve

INSTANCE_ID="$(run_bounded "$GPU_COMMAND_TIMEOUT_SEC" terraform output -raw instance_id)"
echo "instance: $INSTANCE_ID"

echo ""
echo "=== Step 3: Wait for SSM ==="
hivemind_ssm_wait_online "$REGION" "$INSTANCE_ID"

echo ""
echo "=== Step 4: Setup instance ==="
if [[ "$REQUIRE_GPU" == "1" ]]; then
  STRICT_GPU_REMOTE='sudo ctr -n hivemind images pull docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04; sudo ctr -n hivemind run --rm --runtime io.containerd.runc.v2 --device nvidia.com/gpu=0 docker.io/nvidia/cuda:12.2.0-base-ubuntu22.04 hivemind-strict-gpu nvidia-smi | tee /tmp/hivemind-strict-gpu.txt; grep -E "NVIDIA-SMI|Driver Version" /tmp/hivemind-strict-gpu.txt'
else
  STRICT_GPU_REMOTE='echo "SKIP: REQUIRE_GPU=0; CDI-selected in-container nvidia-smi acceptance unavailable"'
fi
# Upload worker source and build on-instance (avoids cross-compilation issues)
# A random account-scoped name plus a conditional per-invocation marker forms
# the cleanup ownership boundary. Ambiguous creates are reconciled only through
# that exact marker; cleanup never adopts a name by itself.
prepare_bucket

# Package the worker source
cd "$WORKER_DIR"
tar czf "$WORKER_ARCHIVE" --exclude target --exclude .git -C .. worker/
run_bounded "$GPU_COMMAND_TIMEOUT_SEC" aws s3 cp "$WORKER_ARCHIVE" "s3://$BUCKET/worker-src.tar.gz" --region "$REGION"

CMD_ID=$(hivemind_ssm_send_command "$SSM_POLL_TIMEOUT_SEC" --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --timeout-seconds 600 \
  --parameters commands="[
    \"set -ex\",
    \"apt-get update -qq && apt-get install -y -qq build-essential pkg-config libssl-dev gvisor 2>/dev/null\",
    \"curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y\",
    \"source /root/.cargo/env\",
    \"aws s3 cp s3://$BUCKET/worker-src.tar.gz /tmp/worker-src.tar.gz --region $REGION\",
    \"cd /tmp && tar xzf worker-src.tar.gz\",
    \"cd /tmp/worker && cargo test --test containerd_integration --features containerd-integration -- --test-threads=1\",
    \"$STRICT_GPU_REMOTE\",
    \"echo TESTS_COMPLETE\"
  ]" \
  --query 'Command.CommandId' --output text)

echo "command: $CMD_ID"
echo ""
echo "=== Step 5: Wait for tests ==="
echo "(this may take 5-10 minutes for first build)"

if ! hivemind_ssm_wait_invocation "$REGION" "$CMD_ID" "$INSTANCE_ID"; then
  echo "FAIL: remote tests did not reach terminal Success" >&2
  exit 1
fi

echo ""
echo "=== Test Output ==="
# Diagnostic retrieval is independently bounded and cannot hang cleanup.
if ! hivemind_ssm_aws "$SSM_POLL_TIMEOUT_SEC" ssm get-command-invocation --region "$REGION" \
  --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query 'StandardOutputContent' --output text; then
  echo "FAIL: bounded remote test output retrieval failed" >&2
  exit 1
fi

echo ""
echo "=== Step 6: Cleanup ==="
# cleanup trap handles destroy unless KEEP_INFRA=1

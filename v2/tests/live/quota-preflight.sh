#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:?AWS_REGION is required}"
[[ "${HIVEMIND_QUOTA_CONFIRMED:-0}" == 1 ]] || { echo "FAIL: quota confirmation is required" >&2; exit 1; }
[[ "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]$ ]] || { echo "FAIL: invalid AWS region" >&2; exit 2; }
command -v aws >/dev/null 2>&1 || { echo "FAIL: aws command unavailable" >&2; exit 1; }

aws_bounded() {
    timeout --kill-after=2s 20s aws "$@"
}

for instance_type in c5.xlarge g4dn.xlarge; do
    count="$(aws_bounded ec2 describe-instance-type-offerings --region "$REGION" \
        --location-type region --filters "Name=instance-type,Values=$instance_type" \
        --query 'length(InstanceTypeOfferings)' --output text)"
    [[ "$count" =~ ^[0-9]+$ && "$count" -ge 1 ]] || {
        echo "FAIL: $instance_type is unavailable in the selected region" >&2
        exit 1
    }
done

check_quota() {
    local service="$1" code="$2" required="$3" label="$4" value
    value="$(aws_bounded service-quotas get-service-quota --region "$REGION" \
        --service-code "$service" --quota-code "$code" --query 'Quota.Value' --output text)"
    python3 - "$value" "$required" "$label" <<'PY'
import math, sys
value = float(sys.argv[1])
required = float(sys.argv[2])
if not math.isfinite(value) or value < required:
    raise SystemExit(f"FAIL: insufficient {sys.argv[3]} quota: {value} < {required}")
PY
}

# Five c5 replicas plus one c5 worker need 24 standard vCPUs; one g4dn.xlarge needs 4 G-family vCPUs.
check_quota ec2 L-1216C47A 24 standard-vcpu
check_quota ec2 L-DB2E81BA 4 gpu-vcpu
# The reviewed topology uses seven subnet addresses and 450 GiB of gp3 root storage,
# plus one isolated repository and one ownership-marker bucket.
if [[ -n "${TF_VAR_subnet_id:-}" ]]; then
    address_count="$(aws_bounded ec2 describe-subnets --region "$REGION" --subnet-ids "$TF_VAR_subnet_id" \
        --query 'sum(Subnets[].AvailableIpAddressCount)' --output text)"
else
    address_count="$(aws_bounded ec2 describe-subnets --region "$REGION" \
        --filters Name=default-for-az,Values=true --query 'sum(Subnets[].AvailableIpAddressCount)' --output text)"
fi
[[ "$address_count" =~ ^[0-9]+$ && "$address_count" -ge 7 ]] || { echo "FAIL: fewer than seven subnet addresses are available" >&2; exit 1; }
check_quota ebs L-7A658B76 0.44 gp3-storage-tib
check_quota ecr L-03A36CE1 1 ecr-repository
check_quota s3 L-DC2B2D3D 1 s3-bucket
echo "PASS: bounded regional offerings and EC2/address/EBS/ECR/S3 quota preflight; max duration and cost require the bound approval record"

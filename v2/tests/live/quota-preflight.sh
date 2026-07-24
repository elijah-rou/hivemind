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
    local code="$1" required="$2" label="$3" value
    value="$(aws_bounded service-quotas get-service-quota --region "$REGION" \
        --service-code ec2 --quota-code "$code" --query 'Quota.Value' --output text)"
    python3 - "$value" "$required" "$label" <<'PY'
import math, sys
value = float(sys.argv[1])
required = float(sys.argv[2])
if not math.isfinite(value) or value < required:
    raise SystemExit(f"FAIL: insufficient {sys.argv[3]} quota: {value} < {required}")
PY
}

# Five c5 replicas plus one c5 worker need 24 standard vCPUs; one g4dn.xlarge needs 4 G-family vCPUs.
check_quota L-1216C47A 24 standard-vcpu
check_quota L-DB2E81BA 4 gpu-vcpu
echo "PASS: bounded regional instance-offering and EC2 quota preflight"

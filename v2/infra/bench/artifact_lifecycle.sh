#!/usr/bin/env bash
# Ownership-scoped immutable S3 artifacts for bench deploy. Source this file.

hivemind_artifact_aws() {
    local timeout_sec="${HIVEMIND_ARTIFACT_AWS_TIMEOUT_SEC:-120}"
    [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid artifact AWS timeout: $timeout_sec" >&2; return 1; }
    timeout --foreground "${timeout_sec}s" aws "$@"
}

hivemind_artifact_prepare() {
    local region="$1" account token
    HIVEMIND_ARTIFACT_OWNED=0
    account="$(hivemind_artifact_aws sts get-caller-identity --query Account --output text)" || {
        echo 'FAIL: unable to determine AWS account for artifact ownership' >&2
        return 1
    }
    [[ "$account" =~ ^[0-9]{12}$ ]] || { echo "FAIL: invalid AWS account: $account" >&2; return 1; }

    token="${HIVEMIND_RUN_TOKEN:-}"
    if [[ -z "$token" ]]; then
        token="$(openssl rand -hex 16)" || { echo 'FAIL: unable to generate run token' >&2; return 1; }
    fi
    token="${token,,}"
    [[ "$token" =~ ^[0-9a-f]{32}$ ]] || { echo 'FAIL: run token must be 128-bit lowercase hex' >&2; return 1; }

    export HIVEMIND_ARTIFACT_ACCOUNT="$account"
    export HIVEMIND_ARTIFACT_TOKEN="$token"
    export HIVEMIND_ARTIFACT_BUCKET="hivemind-bench-${account}-${token}"
    export HIVEMIND_ARTIFACT_PREFIX="runs/${account}/${token}"
    export HIVEMIND_ARTIFACT_REGION="$region"

    if ! hivemind_artifact_aws s3api create-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$region" >/dev/null; then
        echo "FAIL: unable to create owned artifact bucket: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return 1
    fi
    HIVEMIND_ARTIFACT_OWNED=1
}

hivemind_artifact_upload() {
    local source_file="$1" artifact_name="$2" digest key
    [[ "${HIVEMIND_ARTIFACT_OWNED:-0}" == 1 ]] || { echo 'FAIL: artifact bucket is not owned' >&2; return 1; }
    [[ -f "$source_file" ]] || { echo "FAIL: artifact missing: $source_file" >&2; return 1; }
    [[ "$artifact_name" =~ ^[a-z0-9-]+$ ]] || { echo "FAIL: invalid artifact name: $artifact_name" >&2; return 1; }
    digest="$(python3 - "$source_file" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as source:
    print(hashlib.file_digest(source, "sha256").hexdigest())
PY
    )" || { echo "FAIL: unable to hash artifact: $source_file" >&2; return 1; }
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'FAIL: invalid artifact digest' >&2; return 1; }
    key="$HIVEMIND_ARTIFACT_PREFIX/${artifact_name}-${digest}"
    export HIVEMIND_ARTIFACT_URI="s3://$HIVEMIND_ARTIFACT_BUCKET/$key"
    if ! hivemind_artifact_aws s3 cp "$source_file" "$HIVEMIND_ARTIFACT_URI" --region "$HIVEMIND_ARTIFACT_REGION"; then
        echo "FAIL: artifact upload failed: $HIVEMIND_ARTIFACT_URI" >&2
        return 1
    fi
}

hivemind_artifact_cleanup() {
    local prior_status="$1" cleanup_status=0
    [[ "${HIVEMIND_ARTIFACT_OWNED:-0}" == 1 ]] || return "$prior_status"
    if [[ "${HIVEMIND_KEEP_ARTIFACTS:-0}" == 1 ]]; then
        echo "keeping owned artifact bucket: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return "$prior_status"
    fi
    hivemind_artifact_aws s3 rm "s3://$HIVEMIND_ARTIFACT_BUCKET/$HIVEMIND_ARTIFACT_PREFIX" \
        --recursive --region "$HIVEMIND_ARTIFACT_REGION" || cleanup_status=1
    hivemind_artifact_aws s3api delete-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" \
        --region "$HIVEMIND_ARTIFACT_REGION" || cleanup_status=1
    HIVEMIND_ARTIFACT_OWNED=0
    if [[ "$prior_status" -ne 0 ]]; then
        return "$prior_status"
    fi
    return "$cleanup_status"
}

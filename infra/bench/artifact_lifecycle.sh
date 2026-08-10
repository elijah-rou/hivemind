#!/usr/bin/env bash
# Ownership-scoped immutable S3 artifacts for bench deploy. Source this file.

hivemind_artifact_require_timeout() {
    command -v timeout >/dev/null 2>&1 || { echo 'FAIL: GNU timeout is required for artifact AWS calls' >&2; return 1; }
    timeout --version 2>/dev/null | grep -q 'GNU coreutils' || {
        echo 'FAIL: artifact AWS calls require GNU coreutils timeout' >&2
        return 1
    }
}

hivemind_artifact_aws() {
    local timeout_sec="${HIVEMIND_ARTIFACT_AWS_TIMEOUT_SEC:-120}"
    local kill_after_sec="${HIVEMIND_ARTIFACT_KILL_AFTER_SEC:-2}"
    [[ "$timeout_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid artifact AWS timeout: $timeout_sec" >&2; return 1; }
    [[ "$kill_after_sec" =~ ^[1-9][0-9]*$ ]] || { echo "FAIL: invalid artifact kill-after: $kill_after_sec" >&2; return 1; }
    hivemind_artifact_require_timeout || return 1
    timeout --signal=TERM --kill-after="${kill_after_sec}s" "${timeout_sec}s" aws "$@"
}

hivemind_artifact_random_identity() {
    local identity
    command -v openssl >/dev/null 2>&1 || { echo 'FAIL: openssl is required for artifact run identity' >&2; return 1; }
    identity="$(openssl rand -hex 32)" || { echo 'FAIL: unable to generate artifact run identity' >&2; return 1; }
    identity="${identity,,}"
    [[ "$identity" =~ ^[0-9a-f]{64}$ ]] || { echo 'FAIL: invalid artifact run identity and claim' >&2; return 1; }
    printf '%s\n' "$identity"
}

hivemind_artifact_lease_read() {
    local value
    value="$(hivemind_artifact_aws ssm get-parameter \
        --name "$HIVEMIND_ARTIFACT_LEASE_PARAMETER" \
        --query Parameter.Value --output text \
        --region "$HIVEMIND_ARTIFACT_REGION")" || return 1
    [[ "$value" == "$HIVEMIND_ARTIFACT_ACCOUNT:$HIVEMIND_ARTIFACT_TOKEN:$HIVEMIND_ARTIFACT_CLAIM" ]]
}

hivemind_artifact_lease_acquire() {
    local status=0 value
    value="$HIVEMIND_ARTIFACT_ACCOUNT:$HIVEMIND_ARTIFACT_TOKEN:$HIVEMIND_ARTIFACT_CLAIM"
    hivemind_artifact_aws ssm put-parameter \
        --name "$HIVEMIND_ARTIFACT_LEASE_PARAMETER" \
        --type String --value "$value" --no-overwrite \
        --region "$HIVEMIND_ARTIFACT_REGION" >/dev/null || status=$?
    # Status zero is definitive provisional authority to remove this exact lease.
    # A nonzero result is ambiguous and requires exact remote reconciliation.
    if [[ "$status" -eq 0 ]]; then HIVEMIND_ARTIFACT_LEASE_OWNED=1; fi
    if ! hivemind_artifact_lease_read; then
        echo "FAIL: artifact ownership lease was not acquired (status $status)" >&2
        return 1
    fi
    HIVEMIND_ARTIFACT_LEASE_OWNED=1
}

hivemind_artifact_marker_read() {
    local marker
    HIVEMIND_ARTIFACT_OBSERVED_ACCOUNT=""
    HIVEMIND_ARTIFACT_OBSERVED_TOKEN=""
    HIVEMIND_ARTIFACT_OBSERVED_CLAIM=""
    marker="$(hivemind_artifact_aws s3api head-object \
        --bucket "$HIVEMIND_ARTIFACT_BUCKET" \
        --key "$HIVEMIND_ARTIFACT_MARKER_KEY" \
        --query "join(':', [Metadata.account,Metadata.token,Metadata.claim])" --output text \
        --region "$HIVEMIND_ARTIFACT_REGION")" || return 1
    HIVEMIND_ARTIFACT_OBSERVED_ACCOUNT="${marker%%:*}"
    marker="${marker#*:}"
    HIVEMIND_ARTIFACT_OBSERVED_TOKEN="${marker%%:*}"
    HIVEMIND_ARTIFACT_OBSERVED_CLAIM="${marker#*:}"
    if [[ -z "$HIVEMIND_ARTIFACT_OBSERVED_ACCOUNT" ]]; then
        return 1
    fi
    if [[ -z "$HIVEMIND_ARTIFACT_OBSERVED_TOKEN" ]]; then
        return 1
    fi
    if [[ -z "$HIVEMIND_ARTIFACT_OBSERVED_CLAIM" ]]; then
        return 1
    fi
    return 0
}

hivemind_artifact_marker_matches() {
    if [[ "${HIVEMIND_ARTIFACT_OBSERVED_ACCOUNT:-}" != "$HIVEMIND_ARTIFACT_ACCOUNT" ]]; then
        return 1
    fi
    if [[ "${HIVEMIND_ARTIFACT_OBSERVED_TOKEN:-}" != "$HIVEMIND_ARTIFACT_TOKEN" ]]; then
        return 1
    fi
    if [[ "${HIVEMIND_ARTIFACT_OBSERVED_CLAIM:-}" != "$HIVEMIND_ARTIFACT_CLAIM" ]]; then
        return 1
    fi
    return 0
}

hivemind_artifact_prepare() {
    local region="$1" account identity token claim marker_key marker_write_ok=0
    HIVEMIND_ARTIFACT_OWNED=0
    HIVEMIND_ARTIFACT_LEASE_OWNED=0
    account="$(hivemind_artifact_aws sts get-caller-identity --query Account --output text)" || {
        echo 'FAIL: unable to determine AWS account for artifact ownership' >&2
        return 1
    }
    [[ "$account" =~ ^[0-9]{12}$ ]] || { echo "FAIL: invalid AWS account: $account" >&2; return 1; }
    identity="$(hivemind_artifact_random_identity)" || return 1
    token="${identity:0:32}"
    claim="${identity:32:32}"

    export HIVEMIND_ARTIFACT_ACCOUNT="$account"
    export HIVEMIND_ARTIFACT_TOKEN="$token"
    export HIVEMIND_ARTIFACT_CLAIM="$claim"
    export HIVEMIND_ARTIFACT_BUCKET="hivemind-bench-${account}-${token}"
    export HIVEMIND_ARTIFACT_PREFIX="runs/${account}/${token}"
    export HIVEMIND_ARTIFACT_REGION="$region"
    marker_key="$HIVEMIND_ARTIFACT_PREFIX/.owner"
    export HIVEMIND_ARTIFACT_MARKER_KEY="$marker_key"
    export HIVEMIND_ARTIFACT_LEASE_PARAMETER="/hivemind/s3-ownership/$token"

    if hivemind_artifact_aws s3api head-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$region" >/dev/null 2>&1; then
        echo "FAIL: artifact bucket identity collision: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return 1
    fi
    if ! hivemind_artifact_aws s3api wait bucket-not-exists \
        --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$region"; then
        echo "FAIL: artifact bucket absence could not be verified: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return 1
    fi
    hivemind_artifact_lease_acquire || return 1
    local create_status=0
    local -a create_args=(s3api create-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$region")
    if [[ "$region" != us-east-1 ]]; then
        create_args+=(--create-bucket-configuration "LocationConstraint=$region")
    fi
    hivemind_artifact_aws "${create_args[@]}" >/dev/null || create_status=$?

    # The account-scoped SSM no-overwrite lease serializes cooperative creators.
    # The conditional S3 marker then binds the bucket to the exact lease value;
    # ambiguous AWS replies are accepted only when both remote proofs read back.
    if hivemind_artifact_aws s3api put-object \
        --bucket "$HIVEMIND_ARTIFACT_BUCKET" \
        --key "$marker_key" \
        --body /dev/null \
        --if-none-match '*' \
        --metadata "account=$account,token=$token,claim=$claim" \
        --region "$region" >/dev/null; then
        marker_write_ok=1
        # Conditional success proves this exact invocation created the marker.
        HIVEMIND_ARTIFACT_OWNED=1
    fi

    if ! hivemind_artifact_marker_read; then
        if [[ "$marker_write_ok" -eq 0 ]]; then
            echo "FAIL: artifact bucket create/marker was not confirmed (create status $create_status): $HIVEMIND_ARTIFACT_BUCKET" >&2
        else
            echo 'FAIL: unable to verify artifact ownership marker' >&2
        fi
        return 1
    fi
    if ! hivemind_artifact_marker_matches; then
        echo 'FAIL: artifact ownership marker verification mismatch' >&2
        return 1
    fi
    # A timed-out/failed write may still have committed. Exact token + claim
    # reconciliation is sufficient to establish provisional cleanup ownership.
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
    local prior_status="$1" cleanup_status=0 lease_verified=0
    if [[ "${HIVEMIND_ARTIFACT_OWNED:-0}" != 1 && "${HIVEMIND_ARTIFACT_LEASE_OWNED:-0}" != 1 ]]; then
        return "$prior_status"
    fi
    if [[ "${HIVEMIND_KEEP_ARTIFACTS:-0}" == 1 ]]; then
        echo "keeping owned artifact bucket: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return "$prior_status"
    fi

    if [[ "${HIVEMIND_ARTIFACT_OWNED:-0}" != 1 ]]; then
        if hivemind_artifact_lease_read && hivemind_artifact_aws s3api wait bucket-not-exists \
            --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$HIVEMIND_ARTIFACT_REGION" >/dev/null 2>&1; then
            hivemind_artifact_aws ssm delete-parameter \
                --name "$HIVEMIND_ARTIFACT_LEASE_PARAMETER" \
                --region "$HIVEMIND_ARTIFACT_REGION" >/dev/null || cleanup_status=1
            [[ "$cleanup_status" -ne 0 ]] || HIVEMIND_ARTIFACT_LEASE_OWNED=0
        else
            echo 'FAIL: refusing lease release while bucket ownership is ambiguous' >&2
            cleanup_status=1
        fi
        if [[ "$prior_status" -ne 0 ]]; then return "$prior_status"; fi
        return "$cleanup_status"
    fi

    hivemind_artifact_marker_read || cleanup_status=1
    if hivemind_artifact_lease_read; then lease_verified=1; else cleanup_status=1; fi
    if ! hivemind_artifact_marker_matches || [[ "$lease_verified" != 1 || "${HIVEMIND_ARTIFACT_LEASE_OWNED:-0}" != 1 ]]; then
        echo 'FAIL: refusing cleanup without exact artifact marker and account lease' >&2
        cleanup_status=1
    else
        hivemind_artifact_aws s3 rm "s3://$HIVEMIND_ARTIFACT_BUCKET/$HIVEMIND_ARTIFACT_PREFIX" \
            --recursive --region "$HIVEMIND_ARTIFACT_REGION" || cleanup_status=1
        hivemind_artifact_aws s3api delete-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" \
            --region "$HIVEMIND_ARTIFACT_REGION" || cleanup_status=1
        if [[ "$cleanup_status" -eq 0 ]]; then
            hivemind_artifact_aws ssm delete-parameter \
                --name "$HIVEMIND_ARTIFACT_LEASE_PARAMETER" \
                --region "$HIVEMIND_ARTIFACT_REGION" >/dev/null || cleanup_status=1
        fi
        if [[ "$cleanup_status" -eq 0 ]]; then
            HIVEMIND_ARTIFACT_OWNED=0
            HIVEMIND_ARTIFACT_LEASE_OWNED=0
        fi
    fi
    if [[ "$prior_status" -ne 0 ]]; then
        return "$prior_status"
    fi
    return "$cleanup_status"
}

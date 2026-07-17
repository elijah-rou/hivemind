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

hivemind_artifact_marker_read() {
    local marker
    HIVEMIND_ARTIFACT_OBSERVED_TOKEN=""
    HIVEMIND_ARTIFACT_OBSERVED_CLAIM=""
    marker="$(hivemind_artifact_aws s3api head-object \
        --bucket "$HIVEMIND_ARTIFACT_BUCKET" \
        --key "$HIVEMIND_ARTIFACT_MARKER_KEY" \
        --query '[Metadata.token,Metadata.claim]' --output text \
        --region "$HIVEMIND_ARTIFACT_REGION")" || return 1
    read -r HIVEMIND_ARTIFACT_OBSERVED_TOKEN HIVEMIND_ARTIFACT_OBSERVED_CLAIM <<< "$marker"
    [[ -n "$HIVEMIND_ARTIFACT_OBSERVED_TOKEN" ]]
    [[ -n "$HIVEMIND_ARTIFACT_OBSERVED_CLAIM" ]]
}

hivemind_artifact_marker_matches() {
    [[ "${HIVEMIND_ARTIFACT_OBSERVED_TOKEN:-}" == "$HIVEMIND_ARTIFACT_TOKEN" ]]
    [[ "${HIVEMIND_ARTIFACT_OBSERVED_CLAIM:-}" == "$HIVEMIND_ARTIFACT_CLAIM" ]]
}

hivemind_artifact_prepare() {
    local region="$1" account identity token claim marker_key marker_write_ok=0
    HIVEMIND_ARTIFACT_OWNED=0
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

    if hivemind_artifact_aws s3api head-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$region" >/dev/null 2>&1; then
        echo "FAIL: artifact bucket identity collision: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return 1
    fi
    if ! hivemind_artifact_aws s3api wait bucket-not-exists \
        --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$region"; then
        echo "FAIL: artifact bucket absence could not be verified: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return 1
    fi
    if ! hivemind_artifact_aws s3api create-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" --region "$region" >/dev/null; then
        echo "FAIL: unable to create owned artifact bucket: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return 1
    fi

    # S3 us-east-1 may report success for an already-owned bucket. The
    # conditional marker is the atomic ownership boundary for same-token races.
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
            echo "FAIL: artifact ownership marker write was not confirmed: $HIVEMIND_ARTIFACT_BUCKET" >&2
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
    local prior_status="$1" cleanup_status=0
    [[ "${HIVEMIND_ARTIFACT_OWNED:-0}" == 1 ]] || return "$prior_status"
    if [[ "${HIVEMIND_KEEP_ARTIFACTS:-0}" == 1 ]]; then
        echo "keeping owned artifact bucket: $HIVEMIND_ARTIFACT_BUCKET" >&2
        return "$prior_status"
    fi

    hivemind_artifact_marker_read || cleanup_status=1
    if ! hivemind_artifact_marker_matches; then
        echo 'FAIL: refusing cleanup without exact artifact ownership marker' >&2
        cleanup_status=1
    else
        hivemind_artifact_aws s3 rm "s3://$HIVEMIND_ARTIFACT_BUCKET/$HIVEMIND_ARTIFACT_PREFIX" \
            --recursive --region "$HIVEMIND_ARTIFACT_REGION" || cleanup_status=1
        hivemind_artifact_aws s3api delete-bucket --bucket "$HIVEMIND_ARTIFACT_BUCKET" \
            --region "$HIVEMIND_ARTIFACT_REGION" || cleanup_status=1
        if [[ "$cleanup_status" -eq 0 ]]; then
            HIVEMIND_ARTIFACT_OWNED=0
        fi
    fi
    if [[ "$prior_status" -ne 0 ]]; then
        return "$prior_status"
    fi
    return "$cleanup_status"
}

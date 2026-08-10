#!/usr/bin/env bash
# Sourced by guarded live helpers. Ownership requires both a successful bucket
# create and an atomic, exact remote marker. Ambiguous or racing creates fail
# closed and are never adopted from local state.

hivemind_live_bucket_preflight() {
    local bucket="$1" region="$2" output="$3" status
    if [[ "$region" == us-east-1 ]]; then
        echo "FAIL: guarded bucket acquisition does not support us-east-1 legacy create semantics" >&2
        return 1
    fi
    rm -f -- "$output"
    set +e
    timeout --foreground --kill-after=2s 30s aws s3api head-bucket \
        --bucket "$bucket" --region "$region" >"$output" 2>&1
    status=$?
    set -e
    if [[ "$status" == 0 ]]; then
        echo "FAIL: refusing a bucket that exists before this run" >&2
        return 1
    fi
    if ! grep -Eq '(404|Not Found|NoSuchBucket)' "$output"; then
        echo "FAIL: bucket absence could not be proven" >&2
        return 1
    fi
}

hivemind_live_bucket_acquire() {
    local bucket="$1" region="$2" run_token="$3" raw_dir="$4"
    local claim_file="$raw_dir/s3-ownership-claim"
    local marker_file="$raw_dir/s3-ownership-marker"
    local verified_marker="$raw_dir/s3-ownership-marker.verified"
    local precreate_check="$raw_dir/s3-precreate-check.log"
    local create_status marker_status

    hivemind_live_bucket_preflight "$bucket" "$region" "$precreate_check" || return 1
    install -m 600 /dev/null "$marker_file" || return 1
    printf '%s' "$run_token" >"$marker_file" || return 1

    set +e
    timeout --foreground --kill-after=5s 120s aws s3api create-bucket \
        --bucket "$bucket" --region "$region" \
        --create-bucket-configuration "LocationConstraint=$region" >/dev/null
    create_status=$?
    set -e
    if [[ "$create_status" != 0 ]]; then
        echo "FAIL: bucket creation failed or was ambiguous; refusing ownership" >&2
        return "$create_status"
    fi

    set +e
    timeout --foreground --kill-after=2s 30s aws s3api put-object --bucket "$bucket"         --key .hivemind-owner --body "$marker_file" --if-none-match '*'         --region "$region" >/dev/null
    marker_status=$?
    set -e
    if [[ "$marker_status" != 0 ]]; then
        echo "FAIL: atomic bucket ownership marker was not created" >&2
        return "$marker_status"
    fi

    rm -f -- "$verified_marker"
    timeout --foreground --kill-after=2s 30s aws s3api get-object --bucket "$bucket"         --key .hivemind-owner "$verified_marker" >/dev/null || return 1
    if [[ ! -f "$verified_marker" || "$(cat "$verified_marker")" != "$run_token" ]]; then
        echo "FAIL: bucket ownership marker verification failed" >&2
        return 1
    fi

    # The local claim is evidence of completed remote acquisition, never
    # authority to create or repair the remote marker.
    install -m 600 /dev/null "$claim_file" || return 1
    printf '%s' "$run_token" >"$claim_file" || return 1
    printf 'bucket_create	0
' >>"${HIVEMIND_LIVE_STATUS_FILE:?}"
}

hivemind_live_bucket_verify_owned() {
    local bucket="$1" region="$2" run_token="$3" raw_dir="$4" output="$5"
    local claim_file="$raw_dir/s3-ownership-claim"
    [[ -f "$claim_file" && ! -L "$claim_file" ]] || return 1
    [[ "$(cat "$claim_file")" == "$run_token" ]] || return 1
    rm -f -- "$output"
    timeout --foreground --kill-after=2s 30s aws s3api get-object --bucket "$bucket"         --key .hivemind-owner "$output" --region "$region" >/dev/null 2>&1 || return 1
    [[ -f "$output" && ! -L "$output" ]] || return 1
    [[ "$(cat "$output")" == "$run_token" ]]
}

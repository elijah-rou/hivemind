#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/infra/bench/artifact_lifecycle.sh"
DEPLOY="$ROOT_DIR/infra/bench/deploy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin" "$TMP_DIR/state/buckets" "$TMP_DIR/state/random"
: > "$TMP_DIR/calls"

cat > "$TMP_DIR/bin/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "rand -hex 32" ]]
printf '%s%s\n' "$TEST_RANDOM_TOKEN" "$TEST_RANDOM_CLAIM"
EOF

cat > "$TMP_DIR/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$AWS_CALLS"; echo >> "$AWS_CALLS"
service="${1:-}" operation="${2:-}"
shift 2 || true
first_arg="${1:-}"
bucket="" key="" metadata=""
while (( $# > 0 )); do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --metadata) metadata="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$service" == s3 && "$first_arg" == s3://* ]]; then
  bucket="${first_arg#s3://}"; bucket="${bucket%%/*}"
fi
bucket_dir="$AWS_STUB_STATE/buckets/$bucket"
exec 7>"$AWS_STUB_STATE/aws.lock"; flock -x 7
case "$service:$operation" in
  sts:get-caller-identity) printf '%s\n' "${AWS_ACCOUNT:-123456789012}" ;;
  s3api:head-bucket) [[ -d "$bucket_dir" ]] ;;
  s3api:wait) [[ "$operation" == wait && ! -d "$bucket_dir" ]] ;;
  s3api:create-bucket)
    [[ "${AWS_SCENARIO:-success}" != creation-failure ]] || exit 1
    mkdir -p "$bucket_dir"
    ;;
  s3api:put-object)
    exec 8>"$AWS_STUB_STATE/marker.lock"; flock -x 8
    [[ ! -f "$bucket_dir/marker" ]] || exit 1
    case "${AWS_SCENARIO:-success}" in
      put-timeout-token-mismatch) metadata="${metadata/token=*/token=00000000000000000000000000000000,claim=${metadata##*claim=}}" ;;
      put-timeout-claim-mismatch) metadata="${metadata/claim=*/claim=00000000000000000000000000000000}" ;;
      put-timeout-empty-token) metadata="${metadata/token=*/token=,claim=${metadata##*claim=}}" ;;
      put-timeout-empty-claim) metadata="${metadata/claim=*/claim=}" ;;
      put-timeout-committed|success) ;;
      *) ;;
    esac
    printf '%s\n' "$metadata" > "$bucket_dir/marker"
    case "${AWS_SCENARIO:-success}" in put-timeout-*) exit 124 ;; esac
    ;;
  s3api:head-object)
    [[ -f "$bucket_dir/marker" ]] || exit 1
    [[ "${AWS_SCENARIO:-success}" != head-always-fail ]] || exit 1
    if [[ "${AWS_SCENARIO:-success}" == verify-failure-once ]]; then
      verify_count="$bucket_dir/verify-count"
      count=0; [[ ! -f "$verify_count" ]] || count="$(cat "$verify_count")"
      count=$((count + 1)); printf '%s' "$count" > "$verify_count"
      (( count > 1 )) || exit 1
    fi
    token="$(sed -n 's/.*token=\([^,]*\).*/\1/p' "$bucket_dir/marker")"
    claim="$(sed -n 's/.*claim=\([^,]*\).*/\1/p' "$bucket_dir/marker")"
    printf '%s:%s\n' "$token" "$claim"
    ;;
  s3:cp)
    if [[ "${AWS_SCENARIO:-success}" == hung-upload ]]; then
      (trap '' TERM; while :; do sleep 1; done) & child=$!
      printf '%s\n' "$child" > "$AWS_STUB_STATE/hung-child"
      trap '' TERM
      wait "$child"
    fi
    [[ "${AWS_SCENARIO:-success}" != upload-failure ]]
    ;;
  s3:rm) rm -f "$bucket_dir/marker" "$bucket_dir/verify-count" ;;
  s3api:delete-bucket) rmdir "$bucket_dir" ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/aws" "$TMP_DIR/bin/openssl"
export PATH="$TMP_DIR/bin:$PATH" AWS_CALLS="$TMP_DIR/calls" AWS_STUB_STATE="$TMP_DIR/state"
# shellcheck disable=SC1090
source "$LIB"

binary="$TMP_DIR/hivemind"
printf binary > "$binary"

prepare() {
  TEST_RANDOM_TOKEN="$1" TEST_RANDOM_CLAIM="$2" hivemind_artifact_prepare us-east-1
}

# Concurrent invocations own disjoint, immutable artifacts.
(
  prepare aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 11111111111111111111111111111111
  hivemind_artifact_upload "$binary" hivemind
  printf '%s %s\n' "$HIVEMIND_ARTIFACT_BUCKET" "$HIVEMIND_ARTIFACT_URI" > "$TMP_DIR/a"
) & a=$!
(
  prepare bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 22222222222222222222222222222222
  hivemind_artifact_upload "$binary" hivemind
  printf '%s %s\n' "$HIVEMIND_ARTIFACT_BUCKET" "$HIVEMIND_ARTIFACT_URI" > "$TMP_DIR/b"
) & b=$!
wait "$a" "$b"
[[ "$(cut -d' ' -f1 "$TMP_DIR/a")" != "$(cut -d' ' -f1 "$TMP_DIR/b")" ]]
grep -Eq 'hivemind-[0-9a-f]{64}$' "$TMP_DIR/a"
grep -Eq 'hivemind-[0-9a-f]{64}$' "$TMP_DIR/b"

# us-east-1 already-owned CreateBucket semantics never become this run's ownership.
mkdir -p "$TMP_DIR/state/buckets/hivemind-bench-123456789012-cccccccccccccccccccccccccccccccc"
if prepare cccccccccccccccccccccccccccccccc 33333333333333333333333333333333; then
  echo 'pre-existing bucket unexpectedly claimed' >&2; exit 1
fi
[[ "${HIVEMIND_ARTIFACT_OWNED:-0}" == 0 ]]
: > "$AWS_CALLS"
hivemind_artifact_cleanup 1 || true
[[ -d "$TMP_DIR/state/buckets/hivemind-bench-123456789012-cccccccccccccccccccccccccccccccc" ]]
if grep -Eq 's3 rm|delete-bucket' "$AWS_CALLS"; then
  echo 'prior bucket was touched without ownership' >&2; exit 1
fi

# A timed-out conditional write that committed is reconciled to exact ownership.
AWS_SCENARIO=put-timeout-committed prepare 67676767676767676767676767676767 78787878787878787878787878787878
[[ "$HIVEMIND_ARTIFACT_OWNED" == 1 ]]
: > "$AWS_CALLS"
hivemind_artifact_cleanup 0
grep -q 'delete-bucket .*67676767676767676767676767676767' "$AWS_CALLS"

# Conditional success establishes provisional ownership before later read failure.
if AWS_SCENARIO=verify-failure-once prepare 89898989898989898989898989898989 90909090909090909090909090909090; then
  echo 'verification failure unexpectedly passed' >&2; exit 1
fi
[[ "$HIVEMIND_ARTIFACT_OWNED" == 1 ]]
: > "$AWS_CALLS"
hivemind_artifact_cleanup 0
grep -q 'delete-bucket .*89898989898989898989898989898989' "$AWS_CALLS"

# An ambiguous failed write with a different marker never grants deletion authority.
if AWS_SCENARIO=put-timeout-claim-mismatch prepare 91919191919191919191919191919191 92929292929292929292929292929292; then
  echo 'mismatched ambiguous write unexpectedly passed' >&2; exit 1
fi
[[ "${HIVEMIND_ARTIFACT_OWNED:-0}" == 0 ]]
: > "$AWS_CALLS"
hivemind_artifact_cleanup 1 || true
[[ -d "$TMP_DIR/state/buckets/hivemind-bench-123456789012-91919191919191919191919191919191" ]]
if grep -Eq 's3 rm|delete-bucket' "$AWS_CALLS"; then
  echo 'ambiguous mismatched marker triggered deletion' >&2; exit 1
fi

assert_prepare_partial_rejected() {
  local scenario="$1" token="$2" claim="$3"
  if AWS_SCENARIO="$scenario" prepare "$token" "$claim"; then
    echo "$scenario unexpectedly established ownership" >&2; exit 1
  fi
  [[ "${HIVEMIND_ARTIFACT_OWNED:-0}" == 0 ]]
  : > "$AWS_CALLS"
  hivemind_artifact_cleanup 1 || true
  if grep -Eq 's3 rm|delete-bucket' "$AWS_CALLS"; then
    echo "$scenario triggered deletion" >&2; exit 1
  fi
}
assert_prepare_partial_rejected put-timeout-token-mismatch a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1 b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1
assert_prepare_partial_rejected put-timeout-empty-token a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2 b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
assert_prepare_partial_rejected put-timeout-empty-claim a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3 b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3

# A same-token race has one marker winner; the loser never removes the preserved bucket.
: > "$AWS_CALLS"
(
  if prepare dddddddddddddddddddddddddddddddd 44444444444444444444444444444444; then
    HIVEMIND_KEEP_ARTIFACTS=1 hivemind_artifact_cleanup 0
    echo won > "$TMP_DIR/race-a"
  else echo lost > "$TMP_DIR/race-a"; fi
) & a=$!
(
  if prepare dddddddddddddddddddddddddddddddd 55555555555555555555555555555555; then
    HIVEMIND_KEEP_ARTIFACTS=1 hivemind_artifact_cleanup 0
    echo won > "$TMP_DIR/race-b"
  else echo lost > "$TMP_DIR/race-b"; fi
) & b=$!
wait "$a" "$b"
printf '%s\n' "$(cat "$TMP_DIR/race-a")" "$(cat "$TMP_DIR/race-b")" | sort | diff -u <(printf 'lost\nwon\n') -
[[ -d "$TMP_DIR/state/buckets/hivemind-bench-123456789012-dddddddddddddddddddddddddddddddd" ]]
if grep -Eq 's3 rm|delete-bucket' "$AWS_CALLS"; then
  echo 'same-token loser deleted the preserved bucket' >&2; exit 1
fi

# Creation/upload failures are fail-closed.
if AWS_SCENARIO=creation-failure prepare eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee 66666666666666666666666666666666; then
  echo 'creation failure unexpectedly passed' >&2; exit 1
fi
prepare ffffffffffffffffffffffffffffffff 77777777777777777777777777777777
if AWS_SCENARIO=upload-failure hivemind_artifact_upload "$binary" hivemind; then
  echo 'upload failure unexpectedly passed' >&2; exit 1
fi

# Hard process-group deadline kills TERM-ignoring parent and child, then later cleanup remains usable.
start=$SECONDS
if HIVEMIND_ARTIFACT_AWS_TIMEOUT_SEC=1 HIVEMIND_ARTIFACT_KILL_AFTER_SEC=1 AWS_SCENARIO=hung-upload \
  hivemind_artifact_upload "$binary" hivemind; then
  echo 'hung upload unexpectedly passed' >&2; exit 1
fi
(( SECONDS - start < 5 ))
hung_child="$(cat "$TMP_DIR/state/hung-child")"
if kill -0 "$hung_child" 2>/dev/null; then
  echo 'TERM-ignoring AWS descendant survived hard deadline' >&2; exit 1
fi
: > "$AWS_CALLS"
hivemind_artifact_cleanup 0
grep -q 's3 rm .*runs/123456789012/ffffffffffffffffffffffffffffffff' "$AWS_CALLS"
grep -q 's3api delete-bucket .*hivemind-bench-123456789012-ffffffffffffffffffffffffffffffff' "$AWS_CALLS"

# Keep mode performs no mutation.
prepare 99999999999999999999999999999999 88888888888888888888888888888888
: > "$AWS_CALLS"
HIVEMIND_KEEP_ARTIFACTS=1 hivemind_artifact_cleanup 0
[[ ! -s "$AWS_CALLS" ]]

# A failed current marker read cannot reuse stale observed ownership.
prepare 13131313131313131313131313131313 14141414141414141414141414141414
: > "$AWS_CALLS"
if AWS_SCENARIO=head-always-fail hivemind_artifact_cleanup 0; then
  echo 'failed current marker read unexpectedly cleaned' >&2; exit 1
fi
if grep -Eq 's3 rm|delete-bucket' "$AWS_CALLS"; then
  echo 'stale marker observation triggered deletion' >&2; exit 1
fi

assert_cleanup_partial_rejected() {
  local token="$1" claim="$2" marker="$3" label="$4"
  prepare "$token" "$claim"
  printf '%s\n' "$marker" > "$TMP_DIR/state/buckets/$HIVEMIND_ARTIFACT_BUCKET/marker"
  : > "$AWS_CALLS"
  if hivemind_artifact_cleanup 0; then
    echo "$label unexpectedly cleaned" >&2; exit 1
  fi
  if grep -Eq 's3 rm|delete-bucket' "$AWS_CALLS"; then
    echo "$label triggered deletion" >&2; exit 1
  fi
}
assert_cleanup_partial_rejected abababababababababababababababab 12121212121212121212121212121212 \
  'account=123456789012,token=00000000000000000000000000000000,claim=12121212121212121212121212121212' token-only-mismatch
assert_cleanup_partial_rejected acacacacacacacacacacacacacacacac 23232323232323232323232323232323 \
  'account=123456789012,token=acacacacacacacacacacacacacacacac,claim=00000000000000000000000000000000' claim-only-mismatch
assert_cleanup_partial_rejected adadadadadadadadadadadadadadadad 24242424242424242424242424242424 \
  'account=123456789012,token=,claim=24242424242424242424242424242424' empty-token
assert_cleanup_partial_rejected aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae 25252525252525252525252525252525 \
  'account=123456789012,token=aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae,claim=' empty-claim

# A complete current marker remains deletable.
prepare afafafafafafafafafafafafafafafaf 26262626262626262626262626262626
: > "$AWS_CALLS"
hivemind_artifact_cleanup 0
grep -q 'delete-bucket .*afafafafafafafafafafafafafafafaf' "$AWS_CALLS"

mkdir -p "$TMP_DIR/non-gnu"
cat > "$TMP_DIR/non-gnu/timeout" <<'EOF'
#!/usr/bin/env bash
echo 'BusyBox timeout'
EOF
chmod +x "$TMP_DIR/non-gnu/timeout"
if PATH="$TMP_DIR/non-gnu:$PATH" HIVEMIND_ARTIFACT_TIMEOUT_READY=0 hivemind_artifact_aws sts get-caller-identity; then
  echo 'non-GNU timeout unexpectedly accepted' >&2; exit 1
fi

trap_line="$(grep -n 'trap .*hivemind_deploy_cleanup.*EXIT' "$DEPLOY" | cut -d: -f1)"
prepare_line="$(grep -n 'hivemind_artifact_prepare' "$DEPLOY" | cut -d: -f1)"
[[ "$trap_line" -lt "$prepare_line" ]]
grep -q 'HIVEMIND_ARTIFACT_URI' "$DEPLOY"
if grep -q 'HIVEMIND_RUN_TOKEN' "$DEPLOY"; then
  echo 'deploy accepts externally reusable run identity' >&2; exit 1
fi
echo 'bench artifact lifecycle fixtures: PASS'

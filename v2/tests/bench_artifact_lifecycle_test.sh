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
[[ "$*" == "rand -hex 16" ]]
count_file="$AWS_STUB_STATE/random/$PPID"
exec 9>"$count_file.lock"; flock -x 9
count=0; [[ ! -f "$count_file" ]] || count="$(cat "$count_file")"
count=$((count + 1)); printf '%s' "$count" > "$count_file"
if (( count % 2 == 1 )); then printf '%s\n' "$TEST_RANDOM_TOKEN"; else printf '%s\n' "$TEST_RANDOM_CLAIM"; fi
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
    printf '%s\n' "$metadata" > "$bucket_dir/marker"
    ;;
  s3api:head-object)
    [[ -f "$bucket_dir/marker" ]] || exit 1
    claim="$(sed -n 's/.*claim=\([^,]*\).*/\1/p' "$bucket_dir/marker")"
    printf '%s\n' "$claim"
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
  s3:rm) rm -f "$bucket_dir/marker" ;;
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

# Cleanup revalidates the invocation claim and refuses a changed marker.
prepare abababababababababababababababab 12121212121212121212121212121212
printf '%s\n' 'account=123456789012,token=abababababababababababababababab,claim=34343434343434343434343434343434' \
  > "$TMP_DIR/state/buckets/$HIVEMIND_ARTIFACT_BUCKET/marker"
: > "$AWS_CALLS"
if hivemind_artifact_cleanup 0; then
  echo 'mismatched ownership marker unexpectedly cleaned' >&2; exit 1
fi
if grep -Eq 's3 rm|delete-bucket' "$AWS_CALLS"; then
  echo 'mismatched ownership marker triggered deletion' >&2; exit 1
fi

mkdir -p "$TMP_DIR/non-gnu"
cat > "$TMP_DIR/non-gnu/timeout" <<'EOF'
#!/usr/bin/env bash
echo 'BusyBox timeout'
EOF
chmod +x "$TMP_DIR/non-gnu/timeout"
if PATH="$TMP_DIR/non-gnu:$PATH" HIVEMIND_ARTIFACT_TIMEOUT_READY=0 hivemind_artifact_aws sts get-caller-identity; then
  echo 'non-GNU timeout unexpectedly accepted' >&2; exit 1
fi

grep -q 'trap .*hivemind_deploy_cleanup.*EXIT' "$DEPLOY"
grep -q 'HIVEMIND_ARTIFACT_URI' "$DEPLOY"
if grep -q 'HIVEMIND_RUN_TOKEN' "$DEPLOY"; then
  echo 'deploy accepts externally reusable run identity' >&2; exit 1
fi
echo 'bench artifact lifecycle fixtures: PASS'

#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/infra/bench/artifact_lifecycle.sh"
DEPLOY="$ROOT_DIR/infra/bench/deploy.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
: > "$TMP_DIR/calls"

cat > "$TMP_DIR/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$AWS_CALLS"; echo >> "$AWS_CALLS"
case "$1:$2" in
  sts:get-caller-identity) printf '%s\n' "${AWS_ACCOUNT:-123456789012}" ;;
  s3api:create-bucket) [[ "${AWS_SCENARIO:-success}" != creation-failure ]] ;;
  s3:cp) [[ "${AWS_SCENARIO:-success}" != upload-failure ]] ;;
  s3:rm|s3api:delete-bucket) exit 0 ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/aws"
export PATH="$TMP_DIR/bin:$PATH" AWS_CALLS="$TMP_DIR/calls"
# shellcheck disable=SC1090
source "$LIB"

binary="$TMP_DIR/hivemind"; bench="$TMP_DIR/bench"
printf binary > "$binary"; printf bench > "$bench"

# Concurrent identities own disjoint buckets and immutable keys.
(
  HIVEMIND_RUN_TOKEN=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa hivemind_artifact_prepare us-east-1
  hivemind_artifact_upload "$binary" hivemind
  printf '%s %s\n' "$HIVEMIND_ARTIFACT_BUCKET" "$HIVEMIND_ARTIFACT_URI" > "$TMP_DIR/a"
) & a=$!
(
  HIVEMIND_RUN_TOKEN=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb hivemind_artifact_prepare us-east-1
  hivemind_artifact_upload "$binary" hivemind
  printf '%s %s\n' "$HIVEMIND_ARTIFACT_BUCKET" "$HIVEMIND_ARTIFACT_URI" > "$TMP_DIR/b"
) & b=$!
wait "$a" "$b"
[[ "$(cut -d' ' -f1 "$TMP_DIR/a")" != "$(cut -d' ' -f1 "$TMP_DIR/b")" ]]
grep -Eq 'hivemind-[0-9a-f]{64}$' "$TMP_DIR/a"
grep -Eq 'hivemind-[0-9a-f]{64}$' "$TMP_DIR/b"

if AWS_SCENARIO=creation-failure HIVEMIND_RUN_TOKEN=cccccccccccccccccccccccccccccccc \
  hivemind_artifact_prepare us-east-1; then
  echo 'creation failure unexpectedly passed' >&2; exit 1
fi
[[ "${HIVEMIND_ARTIFACT_OWNED:-0}" == 0 ]]

HIVEMIND_RUN_TOKEN=dddddddddddddddddddddddddddddddd hivemind_artifact_prepare us-east-1
if AWS_SCENARIO=upload-failure hivemind_artifact_upload "$binary" hivemind; then
  echo 'upload failure unexpectedly passed' >&2; exit 1
fi

: > "$AWS_CALLS"
HIVEMIND_KEEP_ARTIFACTS=0 hivemind_artifact_cleanup 0
 grep -q 's3 rm .*runs/123456789012/dddddddddddddddddddddddddddddd.*--recursive' "$AWS_CALLS"
 grep -q 's3api delete-bucket .*hivemind-bench-123456789012-dddddddddddddddddddddddddddddd' "$AWS_CALLS"

HIVEMIND_RUN_TOKEN=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee hivemind_artifact_prepare us-east-1
: > "$AWS_CALLS"
HIVEMIND_KEEP_ARTIFACTS=1 hivemind_artifact_cleanup 0
[[ ! -s "$AWS_CALLS" ]]

grep -q 'trap .*hivemind_deploy_cleanup.*EXIT' "$DEPLOY"
grep -q 'HIVEMIND_ARTIFACT_URI' "$DEPLOY"
if grep -q 'date +%s' "$DEPLOY"; then
  echo 'second-resolution bucket identity remains' >&2; exit 1
fi
echo 'bench artifact lifecycle fixtures: PASS'

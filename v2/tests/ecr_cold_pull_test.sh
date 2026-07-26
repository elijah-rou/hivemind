#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../infra/poc/ecr-cold-pull.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'aws:%s\n' "$*" >>"$FIXTURE_LOG"
case "$*" in
 ecr\ describe-images*) echo 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
 *) exit 9 ;;
esac
STUB
cat >"$TMP/bin/ssh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh:%s\n' "$*" >>"$FIXTURE_LOG"
cat >/dev/null
cat <<EOF
cache_before=owned
removed_exact=${FIXTURE_IMAGE:?}
pull_auth=temporary-ecr-hosts-file
pulled_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cache_after=owned
EOF
STUB
chmod +x "$TMP/bin/aws" "$TMP/bin/ssh"
export PATH="$TMP/bin:/usr/bin:/bin" FIXTURE_LOG="$TMP/calls" AWS_REGION=us-test-1
account="$(printf '1%.0s' {1..12})"
image="$account.dkr.ecr.us-test-1.amazonaws.com/hm-e1fixtureabc123:run"
export FIXTURE_IMAGE="$image"

if REQUIRE_ECR_COLD_PULL=0 "$SCRIPT" "$image" e1fixtureabc123 host user "$TMP/optional" >"$TMP/skip"; then
  grep -q 'SKIP: cold-cache ECR mode not required' "$TMP/skip"
else echo "FAIL: optional cold-cache mode" >&2; exit 1; fi
[[ ! -e "$FIXTURE_LOG" ]]

REQUIRE_ECR_COLD_PULL=1 "$SCRIPT" "$image" e1fixtureabc123 host user "$TMP/evidence"
grep -q 'removed_exact=.*hm-e1fixtureabc123:run' "$TMP/evidence/cold-pull.txt"
grep -q 'pull_auth=temporary-ecr-hosts-file' "$TMP/evidence/cold-pull.txt"
grep -q 'pulled_digest=sha256:' "$TMP/evidence/cold-pull.txt"

if REQUIRE_ECR_COLD_PULL=1 "$SCRIPT" 'docker.io/library/nginx:latest' e1fixtureabc123 host user "$TMP/bad" 2>/dev/null; then
  echo "FAIL: non-owned image accepted" >&2; exit 1
fi
echo "PASS: ECR cold-cache requires owned image, credentials, removal, pull, and digest evidence"

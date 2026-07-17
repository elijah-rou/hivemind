#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%q ' "$@" > "$CURL_CALLS"
case "$CURL_STUB_SCENARIO" in
  success) printf 'ok\n' ;;
  timeout) exit 28 ;;
  hung) sleep 10 ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/curl"
export PATH="$TMP_DIR/bin:$PATH" CURL_CALLS="$TMP_DIR/calls"
# shellcheck disable=SC1091
source "$ROOT_DIR/infra/poc/http.sh"

CURL_STUB_SCENARIO=success hivemind_curl -fsS http://example.invalid > "$TMP_DIR/out"
grep -qx ok "$TMP_DIR/out"
grep -q -- '--connect-timeout 5 --max-time 30' "$CURL_CALLS"

if CURL_STUB_SCENARIO=timeout hivemind_curl -fsS http://example.invalid; then
  echo 'timeout unexpectedly passed' >&2; exit 1
fi

# A non-cooperative stub demonstrates the caller remains externally deadline-compatible.
# shellcheck disable=SC2016
if CURL_STUB_SCENARIO=hung timeout 1 bash -c 'source "$1"; hivemind_curl -fsS http://example.invalid' _ "$ROOT_DIR/infra/poc/http.sh"; then
  echo 'hung curl unexpectedly passed' >&2; exit 1
fi

# These are literal contract patterns, not shell expansions.
# shellcheck disable=SC2016
for caller in failure-drills.sh smoke-test.sh workload-test.sh operator-workflow.sh; do
  grep -q 'source "$SCRIPT_DIR/run_retry.sh"' "$ROOT_DIR/infra/poc/$caller"
done
# shellcheck disable=SC2016
 grep -q 'source "$SCRIPT_DIR/http.sh"' "$ROOT_DIR/infra/poc/scale-matrix.sh"
# shellcheck disable=SC2016
 grep -q 'source "$_HIVEMIND_POC_HELPER_DIR/http.sh"' "$ROOT_DIR/infra/poc/run_retry.sh"
echo 'shared bounded HTTP fixtures: PASS'

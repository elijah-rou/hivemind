#!/usr/bin/env bash
# Contract: active docs must describe the repo-root v1 frozen / v2 active layout,
# and every path asserted by this fixture must exist on disk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V2_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$V2_ROOT/.." && pwd)"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

assert_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    pass "exists: $path"
  else
    fail "missing: $path"
  fi
}

assert_dir() {
  local path="$1"
  if [[ -d "$path" ]]; then
    pass "exists dir: $path"
  else
    fail "missing dir: $path"
  fi
}

assert_contains() {
  local path="$1"
  local pattern="$2"
  if grep -qE -- "$pattern" "$path"; then
    pass "contains in $(basename "$path"): $pattern"
  else
    fail "$(basename "$path") missing pattern: $pattern"
  fi
}

assert_lacks() {
  local path="$1"
  local pattern="$2"
  if grep -qE -- "$pattern" "$path"; then
    fail "$(basename "$path") has forbidden pattern: $pattern"
  else
    pass "lacks in $(basename "$path"): $pattern"
  fi
}

# Repo-root layout
assert_dir "$REPO_ROOT/v1"
assert_dir "$REPO_ROOT/v2"
assert_file "$REPO_ROOT/README.md"
assert_file "$REPO_ROOT/AGENTS.md"
assert_contains "$REPO_ROOT/README.md" 'v1/.*frozen|frozen POC V1|final POC V1'
assert_contains "$REPO_ROOT/README.md" 'v2/.*active|active development'
assert_contains "$REPO_ROOT/AGENTS.md" 'v1/.*frozen|Do not change it unless correcting'
assert_contains "$REPO_ROOT/AGENTS.md" 'v2/.*active'

# Active docs under v2/
STATUS="$V2_ROOT/docs/STATUS.md"
FINDINGS="$V2_ROOT/docs/FINDINGS_AND_ISSUES.md"
ENGINEERING="$V2_ROOT/docs/ENGINEERING.md"
assert_file "$STATUS"
assert_file "$FINDINGS"
assert_file "$ENGINEERING"

# Must not claim repo-root v1/ was removed while it is the frozen snapshot.
assert_lacks "$STATUS" 'old `v1/`.*,.*are removed'
assert_lacks "$STATUS" 'removed old `v1/` implementation'
assert_contains "$STATUS" 'frozen POC V1|repo-root `v1/`|`v1/` is the frozen'
assert_contains "$STATUS" '`v2/` is the active|active development line'
assert_contains "$STATUS" 'mixed-version peer clusters.*unsupported'
assert_contains "$STATUS" 'stop the full cluster'
assert_contains "$STATUS" 'no rolling migration or incarnation protocol claim'
assert_contains "$ENGINEERING" 'mixed-version peer clusters.*legacy-v1 journal upgrades'
assert_contains "$ENGINEERING" 'stop the full cluster'
assert_contains "$ENGINEERING" 'No rolling migration or incarnation protocol.*claimed'

assert_lacks "$FINDINGS" '`v1/` \| Removed old implementation'
assert_lacks "$FINDINGS" '`v1/`, `hivemind/`, and `honeybee/` were removed from active tree'
assert_contains "$FINDINGS" 'repo-root `v1/`|frozen POC V1 snapshot'
assert_contains "$FINDINGS" 'worker/'
assert_lacks "$FINDINGS" 'agent/src/agent\.rs'

# Documented paths that this fixture owns must exist (v2-relative).
for rel in \
  docs/STATUS.md \
  docs/FINDINGS_AND_ISSUES.md \
  docs/ENGINEERING.md \
  docs/POC_ACCEPTANCE.md \
  docs/POC_CHANGELOG.md \
  docs/POC_V2_ACCEPTANCE.md \
  docs/frozen/ARCHITECTURE.md \
  docs/design/HIVEMIND_NATIVE_PLATFORM.md \
  core/src/main.zig \
  worker/src/worker.rs \
  api/main.go \
  infra/gpu-test/run-tests.sh \
  infra/bench/ssm_wait.sh
do
  assert_file "$V2_ROOT/$rel"
done

if [[ "$FAIL" -ne 0 ]]; then
  echo "FAIL: docs_layout_paths_test ($FAIL assertion(s))"
  exit 1
fi
echo "PASS: docs_layout_paths_test"
exit 0

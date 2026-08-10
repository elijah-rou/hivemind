#!/usr/bin/env bash
# Contract: repository layout and every path owned by this fixture are stable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
V2_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$V2_ROOT/.." && pwd)"

failures=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

assert_file() {
    local path="$1"
    if [[ -f "$path" ]]; then pass "exists: $path"; else fail "missing: $path"; fi
}

assert_dir() {
    local path="$1"
    if [[ -d "$path" ]]; then pass "exists dir: $path"; else fail "missing dir: $path"; fi
}

assert_contains() {
    local path="$1"
    local pattern="$2"
    if grep -qE -- "$pattern" "$path"; then
        pass "layout ownership in $(basename "$path")"
    else
        fail "$(basename "$path") does not describe required layout ownership"
    fi
}

assert_dir "$REPO_ROOT/v1"
assert_dir "$REPO_ROOT/v2"
assert_file "$REPO_ROOT/README.md"
assert_file "$REPO_ROOT/AGENTS.md"
assert_contains "$REPO_ROOT/README.md" 'v1/.*frozen|frozen POC V1|final POC V1'
assert_contains "$REPO_ROOT/README.md" 'v2/.*active|active development'
assert_contains "$REPO_ROOT/AGENTS.md" 'v1/.*frozen|Do not change it unless correcting'
assert_contains "$REPO_ROOT/AGENTS.md" 'v2/.*active'

for relative_path in \
    AGENTS.md \
    CLAUDE.md \
    docs/TESTING.md \
    docs/HANDOFF.md \
    docs/STATUS.md \
    docs/FINDINGS_AND_ISSUES.md \
    docs/ENGINEERING.md \
    docs/POC_ACCEPTANCE.md \
    docs/POC_CHANGELOG.md \
    docs/POC_V2_ACCEPTANCE.md \
    docs/design/CONTROL_PLANE_CONTRACT.md \
    docs/design/TESTING.md \
    docs/frozen/ARCHITECTURE.md \
    tests/README.md \
    tests/wire/README.md \
    tests/wire/contract-v6.json \
    tests/wire-contract-test.sh \
    core/src/main.zig \
    worker/src/worker.rs \
    api/main.go
do
    assert_file "$V2_ROOT/$relative_path"
done

assert_contains "$V2_ROOT/docs/TESTING.md" 'Shared wire contract'
assert_contains "$V2_ROOT/docs/ENGINEERING.md" 'contract-v6.json'
assert_contains "$V2_ROOT/tests/README.md" 'wire-contract-test.sh'
assert_contains "$V2_ROOT/tests/wire/README.md" 'bounded canonical byte corpus|bounded canonical cross-language fixture corpus'

if [[ "$failures" -ne 0 ]]; then
    printf 'FAIL: docs_layout_paths_test (%d assertion(s))\n' "$failures" >&2
    exit 1
fi

printf 'PASS: docs_layout_paths_test\n'
exit 0

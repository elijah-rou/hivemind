#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECK="$SCRIPT_DIR/lib/require_capability.sh"
RUN_ALL="$SCRIPT_DIR/run-all.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL=$((FAIL + 1)); }

cat >"$TMP_DIR/available" <<'STUB'
#!/usr/bin/env bash
printf 'device=fixture capability=available\n'
STUB
cat >"$TMP_DIR/unavailable" <<'STUB'
#!/usr/bin/env bash
printf 'fixture capability unavailable\n' >&2
exit 1
STUB
cat >"$TMP_DIR/empty" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$TMP_DIR/available" "$TMP_DIR/unavailable" "$TMP_DIR/empty"

for capability in CONTAINERD GPU NYDUS JUICEFS; do
    if REQUIRE_FLAG="REQUIRE_${capability}" "$CHECK" "$capability" 0 "$TMP_DIR/unavailable" >"$TMP_DIR/$capability.skip" 2>&1 &&
       grep -q "SKIP: $capability unavailable" "$TMP_DIR/$capability.skip"; then
        pass "$capability optional mode records an explicit skip"
    else
        fail "$capability optional mode must record an explicit skip"
    fi

    if REQUIRE_FLAG="REQUIRE_${capability}" "$CHECK" "$capability" 1 "$TMP_DIR/unavailable" >"$TMP_DIR/$capability.fail" 2>&1; then
        fail "$capability required mode must fail when unavailable"
    elif grep -q "FAIL: REQUIRE_${capability}=1" "$TMP_DIR/$capability.fail"; then
        pass "$capability required mode fails rather than skips"
    else
        fail "$capability required failure lacks explicit evidence"
    fi

    if REQUIRE_FLAG="REQUIRE_${capability}" "$CHECK" "$capability" 1 "$TMP_DIR/available" >"$TMP_DIR/$capability.pass" 2>&1 &&
       grep -q "PASS: $capability" "$TMP_DIR/$capability.pass"; then
        pass "$capability required mode accepts nonempty probe evidence"
    else
        fail "$capability required mode rejected valid evidence"
    fi

done

if REQUIRE_FLAG=REQUIRE_GPU "$CHECK" GPU 1 "$TMP_DIR/empty" >"$TMP_DIR/empty.out" 2>&1; then
    fail "required capability must reject empty evidence"
else
    pass "required capability rejects empty evidence"
fi

missing_runner="$TMP_DIR/deliberately-missing-containerd-runner"
if HIVEMIND_CONTAINERD_RUNNER="$missing_runner" "$RUN_ALL" --require-containerd >"$TMP_DIR/run-all.out" 2>&1; then
    fail "--require-containerd must fail for unavailable fixture runner"
elif grep -q 'required containerd runner is not executable' "$TMP_DIR/run-all.out" &&
     ! grep -q 'Zig tests' "$TMP_DIR/run-all.out"; then
    pass "--require-containerd fails safely before aggregate resource use"
else
    fail "--require-containerd failure was late or lacked evidence"
fi

if "$RUN_ALL" --skip-containerd --require-containerd >"$TMP_DIR/conflict.out" 2>&1; then
    fail "conflicting containerd flags must fail"
elif grep -q 'cannot combine --skip-containerd and --require-containerd' "$TMP_DIR/conflict.out"; then
    pass "conflicting containerd flags fail explicitly"
else
    fail "conflicting containerd flags lack an explicit error"
fi

if [[ "$FAIL" -ne 0 ]]; then
    echo "FAIL: strict_capabilities_test ($FAIL assertion(s))" >&2
    exit 1
fi
echo "PASS: strict_capabilities_test ($PASS assertions)"

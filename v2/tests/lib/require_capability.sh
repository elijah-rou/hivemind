#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: require_capability.sh NAME REQUIRE PROBE [ARG ...]" >&2
    exit 2
fi

CAPABILITY="$1"
REQUIRE="$2"
PROBE="$3"
shift 3
REQUIRE_FLAG="${REQUIRE_FLAG:-REQUIRE_${CAPABILITY}}"

if [[ ! "$CAPABILITY" =~ ^[A-Z][A-Z0-9_]{0,31}$ ]]; then
    echo "FAIL: invalid capability name" >&2
    exit 2
fi
if [[ ! "$REQUIRE_FLAG" =~ ^REQUIRE_[A-Z][A-Z0-9_]{0,31}$ ]]; then
    echo "FAIL: invalid requirement flag name" >&2
    exit 2
fi
if [[ "$REQUIRE" != "0" && "$REQUIRE" != "1" ]]; then
    echo "FAIL: $REQUIRE_FLAG must be 0 or 1" >&2
    exit 2
fi

if [[ ! -x "$PROBE" ]]; then
    if [[ "$REQUIRE" == "1" ]]; then
        echo "FAIL: $REQUIRE_FLAG=1 but probe is not executable: $PROBE" >&2
        exit 1
    fi
    echo "SKIP: $CAPABILITY unavailable; probe is not executable: $PROBE"
    exit 0
fi

OUTPUT_FILE="$(mktemp)"
trap 'rm -f "$OUTPUT_FILE"' EXIT
if ! timeout --foreground --kill-after=2s "${CAPABILITY_PROBE_TIMEOUT_SECONDS:-15}s" "$PROBE" "$@" >"$OUTPUT_FILE" 2>&1; then
    cat "$OUTPUT_FILE" >&2
    if [[ "$REQUIRE" == "1" ]]; then
        echo "FAIL: $REQUIRE_FLAG=1 but $CAPABILITY probe failed" >&2
        exit 1
    fi
    echo "SKIP: $CAPABILITY unavailable; probe failed"
    exit 0
fi
if [[ ! -s "$OUTPUT_FILE" ]]; then
    if [[ "$REQUIRE" == "1" ]]; then
        echo "FAIL: $REQUIRE_FLAG=1 but $CAPABILITY probe returned no evidence" >&2
        exit 1
    fi
    echo "SKIP: $CAPABILITY unavailable; probe returned no evidence"
    exit 0
fi

while IFS= read -r line; do
    printf 'EVIDENCE[%s]: %s\n' "$CAPABILITY" "$line"
done <"$OUTPUT_FILE"
echo "PASS: $CAPABILITY capability probe"

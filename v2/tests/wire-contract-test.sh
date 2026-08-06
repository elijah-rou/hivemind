#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT="$SCRIPT_DIR/wire/contract-v6.json"

python3 "$SCRIPT_DIR/wire_contract_schema_test.py"
python3 "$SCRIPT_DIR/wire_contract_validator.py" "$CONTRACT"

python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import sys

repo_root = pathlib.Path(sys.argv[1])
constant_patterns = {
    "core/src/message.zig": r"pub const PROTOCOL_VERSION: u16 = 6;",
    "worker/src/protocol.rs": r"pub const PROTOCOL_VERSION: u16 = 6;",
    "api/client.go": r"const ProtocolVersion uint16 = 6",
    "bench/main.go": r"ProtocolVersion\s+uint16 = 6",
}
for relative_path, pattern in constant_patterns.items():
    text = (repo_root / relative_path).read_text()
    if re.search(pattern, text) is None:
        raise SystemExit(f"{relative_path} protocol version is not exactly 6")
PY

(
    cd "$REPO_ROOT/core"
    zig build test
)
(
    cd "$REPO_ROOT/worker"
    cargo test wire_contract
)
(
    cd "$REPO_ROOT/api"
    go test -run '^TestWireContract$' ./...
)
(
    cd "$REPO_ROOT/bench"
    go test -run '^TestWireContract$' ./...
)

echo "wire contract: PASS"

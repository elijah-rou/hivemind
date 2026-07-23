#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT="$SCRIPT_DIR/wire/contract-v6.json"

python3 - "$CONTRACT" "$REPO_ROOT" <<'PY'
import json
import pathlib
import re
import sys

contract_path = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])
max_contract_bytes = 256 * 1024
max_vectors = 32
max_frame_bytes = 64 * 1024

raw = contract_path.read_bytes()
assert 0 < len(raw) <= max_contract_bytes, "wire contract size is outside its bound"
contract = json.loads(raw)
assert set(contract) == {"schema", "protocol_version", "encoding", "test_material", "statuses", "vectors"}
assert contract["schema"] == "hivemind-wire-contract-v1"
assert contract["protocol_version"] == 6
assert set(contract["encoding"]) == {"byte_order", "hex", "plaintext_frame", "encrypted_frame", "aad", "peer_body"}
assert contract["encoding"]["byte_order"] == "little-endian"
assert contract["encoding"]["hex"] == "lowercase, even-length, no prefix"
assert set(contract["test_material"]) == {"warning", "psk_hex", "nonce_hex"}
assert "INSECURE TEST MATERIAL" in contract["test_material"]["warning"]

hex_pattern = re.compile(r"(?:[0-9a-f]{2})*")
def decode_hex(value, field, max_bytes=max_frame_bytes):
    assert isinstance(value, str), f"{field} must be a string"
    assert hex_pattern.fullmatch(value), f"{field} is not canonical lowercase hex"
    decoded = bytes.fromhex(value)
    assert len(decoded) <= max_bytes, f"{field} exceeds {max_bytes} bytes"
    return decoded

assert len(decode_hex(contract["test_material"]["psk_hex"], "test_material.psk_hex")) == 32
assert len(decode_hex(contract["test_material"]["nonce_hex"], "test_material.nonce_hex")) == 24

statuses = contract["statuses"]
assert len(statuses) == 10
assert [status["byte"] for status in statuses] == list(range(10))
assert [status["name"] for status in statuses] == [
    "ok", "deployment_not_found", "queue_full", "invalid_payload",
    "response_too_large", "outcome_ambiguous", "forwarding_failed",
    "no_running_pod", "unavailable", "not_leader",
]
for status in statuses:
    assert set(status) == {"byte", "name", "origins"}
    assert status["origins"] in (["worker", "core"], ["core"])
assert statuses[9]["origins"] == ["core"]

vectors = contract["vectors"]
assert 1 <= len(vectors) <= max_vectors
expected_keys = {"id", "channel", "direction", "message", "flags", "tag", "key_purpose", "payload_hex", "plaintext_hex", "frame_hex", "consumers"}
ids = set()
messages = set()
encrypted_channels = set()
for vector in vectors:
    assert set(vector) == expected_keys
    vector_id = vector["id"]
    assert re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", vector_id)
    assert vector_id not in ids
    ids.add(vector_id)
    assert vector["channel"] in {"worker", "client", "peer"}
    assert vector["direction"] in {"to-core", "from-core", "peer-to-peer"}
    assert vector["flags"] in {0, 1}
    assert isinstance(vector["tag"], int) and 0 <= vector["tag"] <= 255
    assert vector["key_purpose"] in {None, "worker", "client", "peer"}
    assert isinstance(vector["consumers"], list) and vector["consumers"]
    assert len(vector["consumers"]) == len(set(vector["consumers"]))
    assert set(vector["consumers"]) <= {"zig", "rust", "go-api", "go-bench"}

    payload = decode_hex(vector["payload_hex"], f"{vector_id}.payload_hex", 16 * 1024)
    plaintext = decode_hex(vector["plaintext_hex"], f"{vector_id}.plaintext_hex")
    frame = decode_hex(vector["frame_hex"], f"{vector_id}.frame_hex")
    assert len(frame) >= 8
    assert int.from_bytes(frame[:4], "little") == len(frame) - 4
    assert frame[4] == vector["flags"]
    assert plaintext[:2] == b"\x06\x00"
    assert plaintext[2] == vector["tag"]
    assert plaintext[3:] == payload
    if vector["flags"] == 0:
        assert vector["key_purpose"] is None
        assert frame[5:] == plaintext
    else:
        assert vector["key_purpose"] == vector["channel"]
        assert len(frame) == 5 + 24 + len(plaintext) + 16
        encrypted_channels.add(vector["channel"])
    messages.add(vector["message"])

required_messages = {"register", "heartbeat", "pod-status", "start-pod", "run-request", "run-response", "leader-probe-request", "leader-probe-response", "peer-envelope"}
assert required_messages <= messages
assert encrypted_channels == {"worker", "client", "peer"}

constant_patterns = {
    "core/src/message.zig": r"pub const PROTOCOL_VERSION: u16 = 6;",
    "worker/src/protocol.rs": r"pub const PROTOCOL_VERSION: u16 = 6;",
    "api/client.go": r"const ProtocolVersion uint16 = 6",
    "bench/main.go": r"ProtocolVersion\s+uint16 = 6",
}
for relative_path, pattern in constant_patterns.items():
    text = (repo_root / relative_path).read_text()
    assert re.search(pattern, text), f"{relative_path} protocol version is not exactly 6"
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

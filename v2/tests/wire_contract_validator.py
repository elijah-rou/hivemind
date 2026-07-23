#!/usr/bin/env python3
import json
import re
import sys

MAX_CONTRACT_BYTES = 256 * 1024
MAX_VECTORS = 32
MAX_FRAME_BYTES = 64 * 1024
MAX_PAYLOAD_BYTES = 16 * 1024

STATUS_NAMES = [
    "ok",
    "deployment_not_found",
    "queue_full",
    "invalid_payload",
    "response_too_large",
    "outcome_ambiguous",
    "forwarding_failed",
    "no_running_pod",
    "unavailable",
    "not_leader",
]
EXPECTED_TUPLES = {
    ("worker", "to-core", "register", 16),
    ("worker", "to-core", "heartbeat", 17),
    ("worker", "to-core", "pod-status", 18),
    ("worker", "from-core", "start-pod", 2),
    ("worker", "from-core", "run-request", 4),
    ("worker", "to-core", "run-response", 19),
    ("client", "to-core", "run-request", 34),
    ("client", "from-core", "run-response", 35),
    ("client", "to-core", "leader-probe-request", 38),
    ("client", "from-core", "leader-probe-response", 39),
    ("peer", "peer-to-peer", "peer-envelope", 1),
}
VECTOR_KEYS = {
    "id",
    "channel",
    "direction",
    "message",
    "flags",
    "tag",
    "key_purpose",
    "payload_hex",
    "plaintext_hex",
    "frame_hex",
    "consumers",
}
HEX_PATTERN = re.compile(r"(?:[0-9a-f]{2})*")
ID_PATTERN = re.compile(r"[a-z0-9]+(?:-[a-z0-9]+)*")


class ContractError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def decode_hex(value, field, max_bytes=MAX_FRAME_BYTES):
    require(isinstance(value, str), f"{field} must be a string")
    require(HEX_PATTERN.fullmatch(value) is not None, f"{field} is not canonical lowercase hex")
    decoded = bytes.fromhex(value)
    require(len(decoded) <= max_bytes, f"{field} exceeds {max_bytes} bytes")
    return decoded


def expected_consumers(channel, flags):
    if channel == "worker":
        return ["zig", "rust"]
    if channel == "client":
        return ["zig", "go-api"] if flags == 1 else ["zig", "go-api", "go-bench"]
    require(channel == "peer", f"unknown channel {channel!r}")
    return ["zig"]


def validate_contract_bytes(raw):
    require(isinstance(raw, bytes), "wire contract input must be bytes")
    require(0 < len(raw) <= MAX_CONTRACT_BYTES, "wire contract size is outside its bound")
    try:
        contract = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError(f"wire contract is not valid JSON: {error}") from error
    require(isinstance(contract, dict), "wire contract root must be an object")
    require(set(contract) == {"schema", "protocol_version", "encoding", "test_material", "statuses", "vectors"}, "wire contract top-level fields differ")
    require(contract["schema"] == "hivemind-wire-contract-v1", "wire contract schema differs")
    require(contract["protocol_version"] == 6, "wire contract protocol version differs")

    encoding = contract["encoding"]
    require(isinstance(encoding, dict), "encoding must be an object")
    require(set(encoding) == {"byte_order", "hex", "plaintext_frame", "encrypted_frame", "aad", "peer_body"}, "encoding fields differ")
    require(encoding["byte_order"] == "little-endian", "byte order differs")
    require(encoding["hex"] == "lowercase, even-length, no prefix", "hex definition differs")

    material = contract["test_material"]
    require(isinstance(material, dict), "test_material must be an object")
    require(set(material) == {"warning", "psk_hex", "nonce_hex"}, "test_material fields differ")
    require(isinstance(material["warning"], str) and "INSECURE TEST MATERIAL" in material["warning"], "test material warning missing")
    require(len(decode_hex(material["psk_hex"], "test_material.psk_hex")) == 32, "test PSK must be 32 bytes")
    require(len(decode_hex(material["nonce_hex"], "test_material.nonce_hex")) == 24, "test nonce must be 24 bytes")

    statuses = contract["statuses"]
    require(isinstance(statuses, list) and len(statuses) == 10, "status inventory must contain ten entries")
    for byte, status in enumerate(statuses):
        require(isinstance(status, dict) and set(status) == {"byte", "name", "origins"}, f"status {byte} fields differ")
        require(status["byte"] == byte, f"status byte {byte} differs")
        require(status["name"] == STATUS_NAMES[byte], f"status name {byte} differs")
        origins = ["worker", "core"] if byte < 9 else ["core"]
        require(status["origins"] == origins, f"status {byte} origins differ")

    vectors = contract["vectors"]
    require(isinstance(vectors, list) and 1 <= len(vectors) <= MAX_VECTORS, "vector count is outside its bound")
    ids = set()
    tuples = set()
    encrypted_channels = set()
    status_vectors = {"worker": set(), "client": set()}
    for index, vector in enumerate(vectors):
        require(isinstance(vector, dict) and set(vector) == VECTOR_KEYS, f"vector {index} fields differ")
        vector_id = vector["id"]
        require(isinstance(vector_id, str) and ID_PATTERN.fullmatch(vector_id) is not None, f"vector {index} id is invalid")
        require(vector_id not in ids, f"duplicate vector id {vector_id}")
        ids.add(vector_id)

        vector_tuple = (vector["channel"], vector["direction"], vector["message"], vector["tag"])
        require(vector_tuple in EXPECTED_TUPLES, f"{vector_id} message tuple is invalid: {vector_tuple!r}")
        tuples.add(vector_tuple)
        require(vector["flags"] in (0, 1), f"{vector_id} flags are invalid")
        consumers = vector["consumers"]
        require(consumers == expected_consumers(vector["channel"], vector["flags"]), f"{vector_id} consumers differ from the required matrix")

        payload = decode_hex(vector["payload_hex"], f"{vector_id}.payload_hex", MAX_PAYLOAD_BYTES)
        plaintext = decode_hex(vector["plaintext_hex"], f"{vector_id}.plaintext_hex")
        frame = decode_hex(vector["frame_hex"], f"{vector_id}.frame_hex")
        require(len(frame) >= 8, f"{vector_id} frame is too short")
        require(int.from_bytes(frame[:4], "little") == len(frame) - 4, f"{vector_id} frame length differs")
        require(frame[4] == vector["flags"], f"{vector_id} frame flags differ")
        require(plaintext[:2] == b"\x06\x00", f"{vector_id} plaintext version differs")
        require(len(plaintext) >= 3 and plaintext[2] == vector["tag"], f"{vector_id} plaintext tag differs")
        require(plaintext[3:] == payload, f"{vector_id} plaintext payload differs")
        if vector["flags"] == 0:
            require(vector["key_purpose"] is None, f"{vector_id} plaintext key purpose must be null")
            require(frame[5:] == plaintext, f"{vector_id} plaintext frame differs")
        else:
            require(vector["key_purpose"] == vector["channel"], f"{vector_id} encrypted key purpose differs")
            require(len(frame) == 5 + 24 + len(plaintext) + 16, f"{vector_id} encrypted frame length differs")
            encrypted_channels.add(vector["channel"])

        if vector["message"] == "run-response":
            require(len(payload) >= 9, f"{vector_id} run response is too short")
            status = payload[8]
            require(status < 10, f"{vector_id} run response status is invalid")
            require(status < 9 or vector["channel"] == "client", f"{vector_id} worker status 9 is forbidden")
            status_vectors[vector["channel"]].add(status)

    require(tuples == EXPECTED_TUPLES, "message tuple inventory is incomplete")
    require(encrypted_channels == {"worker", "client", "peer"}, "encrypted channel inventory is incomplete")
    require(status_vectors == {"worker": set(range(9)), "client": set(range(10))}, f"run-response status vectors are incomplete: {status_vectors!r}")
    return contract


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} CONTRACT", file=sys.stderr)
        return 2
    try:
        with open(argv[1], "rb") as contract_file:
            validate_contract_bytes(contract_file.read(MAX_CONTRACT_BYTES + 1))
    except (OSError, ContractError) as error:
        print(f"wire contract validation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

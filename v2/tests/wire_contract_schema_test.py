#!/usr/bin/env python3
import copy
import json
import pathlib
import unittest

import wire_contract_validator as validator


CONTRACT_PATH = pathlib.Path(__file__).with_name("wire") / "contract-v6.json"
ENCODING_FIELDS = (
    "byte_order",
    "hex",
    "plaintext_frame",
    "encrypted_frame",
    "aad",
    "peer_body",
)


class WireContractSchemaTest(unittest.TestCase):
    def setUp(self):
        self.contract = json.loads(CONTRACT_PATH.read_bytes())

    def validate(self, contract):
        validator.validate_contract_bytes(json.dumps(contract).encode())

    def test_committed_contract_is_complete(self):
        validator.validate_contract_bytes(CONTRACT_PATH.read_bytes())

    def test_consumer_cannot_be_removed_from_all_vectors(self):
        contract = copy.deepcopy(self.contract)
        for vector in contract["vectors"]:
            vector["consumers"] = [consumer for consumer in vector["consumers"] if consumer != "rust"]
        with self.assertRaisesRegex(validator.ContractError, "consumers"):
            self.validate(contract)

    def test_message_tuple_binds_channel_direction_tag_and_consumers(self):
        contract = copy.deepcopy(self.contract)
        contract["vectors"][0]["tag"] = 255
        with self.assertRaisesRegex(validator.ContractError, "tuple"):
            self.validate(contract)

    def test_status_origins_are_exact(self):
        contract = copy.deepcopy(self.contract)
        contract["statuses"][1]["origins"] = ["core"]
        with self.assertRaisesRegex(validator.ContractError, "origins"):
            self.validate(contract)

    def test_encoding_definitions_are_exact(self):
        for field in ENCODING_FIELDS:
            with self.subTest(field=field):
                contract = copy.deepcopy(self.contract)
                contract["encoding"][field] = "contradictory definition"
                with self.assertRaisesRegex(validator.ContractError, f"encoding {field} differs"):
                    self.validate(contract)

    def test_each_legal_status_origin_has_a_run_response_vector(self):
        contract = copy.deepcopy(self.contract)
        contract["vectors"] = [
            vector
            for vector in contract["vectors"]
            if not (
                vector["channel"] == "worker"
                and vector["message"] == "run-response"
                and bytes.fromhex(vector["payload_hex"])[8] == 1
            )
        ]
        with self.assertRaisesRegex(validator.ContractError, "status vectors"):
            self.validate(contract)

    def test_exact_size_limit_is_accepted_and_overflow_is_rejected(self):
        raw = CONTRACT_PATH.read_bytes()
        exact = raw + b" " * (validator.MAX_CONTRACT_BYTES - len(raw))
        validator.validate_contract_bytes(exact)
        with self.assertRaisesRegex(validator.ContractError, "size"):
            validator.validate_contract_bytes(exact + b" ")


if __name__ == "__main__":
    unittest.main()

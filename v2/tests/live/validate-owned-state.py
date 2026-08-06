#!/usr/bin/env python3
"""Validate the exact state or saved destroy plan guarded cleanup may apply."""

import json
import re
import sys
from typing import NoReturn

TOKEN_RE = re.compile(r"^[a-z][a-z0-9]{11,31}$")
EXPECTED_TYPES = {
    "aws_ecr_repository.workloads": "aws_ecr_repository",
    "aws_key_pair.poc": "aws_key_pair",
    "aws_security_group.hivemind": "aws_security_group",
    **{f"aws_instance.replica[{index}]": "aws_instance" for index in range(5)},
    "aws_instance.worker_cpu": "aws_instance",
    "aws_instance.worker_gpu": "aws_instance",
}


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def require_string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"state has invalid {context}")
    return value


def managed_resources(module: object) -> list[dict[str, object]]:
    if not isinstance(module, dict):
        fail("state lacks root module")
    result: list[dict[str, object]] = []
    resources = module.get("resources", [])
    if not isinstance(resources, list):
        fail("state resources are malformed")
    for resource in resources:
        if not isinstance(resource, dict):
            fail("state contains a malformed resource")
        if resource.get("mode") == "managed":
            result.append(resource)
    children = module.get("child_modules", [])
    if not isinstance(children, list):
        fail("state child modules are malformed")
    for child in children:
        result.extend(managed_resources(child))
    return result


def managed_resources_from_destroy_plan(changes: object) -> list[dict[str, object]]:
    if not isinstance(changes, list):
        fail("destroy plan resource changes are malformed")
    result: list[dict[str, object]] = []
    for resource in changes:
        if not isinstance(resource, dict):
            fail("destroy plan contains a malformed resource change")
        if resource.get("mode") != "managed":
            continue
        change = resource.get("change")
        if not isinstance(change, dict):
            fail("destroy plan lacks managed change data")
        if change.get("actions") != ["delete"] or change.get("after") is not None:
            fail("destroy plan contains a managed action other than exact deletion")
        before = change.get("before")
        if not isinstance(before, dict):
            fail("destroy plan deletion lacks prior resource values")
        result.append({
            "address": resource.get("address"),
            "mode": "managed",
            "type": resource.get("type"),
            "values": before,
        })
    return result


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: validate-owned-state.py STATE_OR_DESTROY_PLAN_JSON RUN_TOKEN ECR_NAME")
    state_path, token, ecr_name = sys.argv[1:]
    if not TOKEN_RE.fullmatch(token):
        fail("invalid guarded run token")
    if token not in ecr_name:
        fail("guarded ECR name lacks the exact run token")

    with open(state_path, encoding="utf-8") as source:
        state: object = json.load(source)
    if not isinstance(state, dict):
        fail("Terraform state or plan JSON must be an object")
    if "resource_changes" in state:
        resources = managed_resources_from_destroy_plan(state.get("resource_changes"))
    else:
        values = state.get("values")
        if not isinstance(values, dict):
            fail("Terraform state lacks values")
        resources = managed_resources(values.get("root_module"))
    by_address: dict[str, dict[str, object]] = {}
    for resource in resources:
        address = require_string(resource.get("address"), "resource address")
        if address in by_address:
            fail(f"state repeats managed resource address: {address}")
        by_address[address] = resource
    if set(by_address) != set(EXPECTED_TYPES):
        fail("state managed resource addresses differ from the exact guarded topology")

    resource_values: dict[str, dict[str, object]] = {}
    for address, expected_type in EXPECTED_TYPES.items():
        resource = by_address[address]
        if resource.get("type") != expected_type:
            fail(f"state resource type differs from guarded topology: {address}")
        current = resource.get("values")
        if not isinstance(current, dict):
            fail(f"state resource values are malformed: {address}")
        tags = current.get("tags_all", current.get("tags"))
        if not isinstance(tags, dict) or tags.get("HivemindRunToken") != token:
            fail(f"state resource lacks exact ownership token: {address}")
        resource_values[address] = current

    ecr = resource_values["aws_ecr_repository.workloads"]
    if ecr.get("name") != ecr_name:
        fail("state ECR repository differs from guarded name")
    key = resource_values["aws_key_pair.poc"]
    key_name = require_string(key.get("key_name"), "key pair name")
    if key_name != f"hivemind-{token}-deployer":
        fail("state key pair differs from guarded run")
    security_group = resource_values["aws_security_group.hivemind"]
    security_group_id = require_string(security_group.get("id"), "security group id")

    expected_names = {
        **{f"aws_instance.replica[{index}]": f"hivemind-{token}-replica-{index}" for index in range(5)},
        "aws_instance.worker_cpu": f"hivemind-{token}-worker-cpu",
        "aws_instance.worker_gpu": f"hivemind-{token}-worker-gpu",
    }
    expected_roles = {
        **{f"aws_instance.replica[{index}]": "replica" for index in range(5)},
        "aws_instance.worker_cpu": "worker",
        "aws_instance.worker_gpu": "worker",
    }
    for address, expected_name in expected_names.items():
        instance = resource_values[address]
        tags = instance.get("tags_all", instance.get("tags"))
        assert isinstance(tags, dict)
        if tags.get("Name") != expected_name or tags.get("Role") != expected_roles[address]:
            fail(f"state instance identity differs from guarded topology: {address}")
        if instance.get("key_name") != key_name:
            fail(f"state instance key relationship differs from guarded topology: {address}")
        groups = instance.get("vpc_security_group_ids")
        if groups != [security_group_id]:
            fail(f"state instance security-group relationship differs from guarded topology: {address}")


if __name__ == "__main__":
    main()

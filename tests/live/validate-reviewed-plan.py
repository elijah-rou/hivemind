#!/usr/bin/env python3
import json
import sys
from typing import NoReturn

MAX_RESOURCE_CHANGES = 128
OWNED_TYPES = {
    "aws_instance",
    "aws_ebs_volume",
    "aws_security_group",
    "aws_key_pair",
    "aws_ecr_repository",
}
ALLOWED_ACTIONS = {
    ("no-op",),
    ("create",),
    ("read",),
    ("update",),
    ("delete",),
    ("delete", "create"),
    ("create", "delete"),
}


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def string_field(record: dict[str, object], key: str, context: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value:
        fail(f"plan has invalid {key}: {context}")
    return value


def owned(record: object, token: str, context: str) -> bool:
    if not isinstance(record, dict):
        fail(f"plan has invalid resource values: {context}")
    tags = record.get("tags")
    return isinstance(tags, dict) and tags.get("HivemindRunToken") == token


def main() -> None:
    if len(sys.argv) != 4:
        fail("usage: validate-reviewed-plan.py PLAN_JSON RUN_TOKEN ECR_NAME")
    plan_path, token, ecr_name = sys.argv[1:]
    with open(plan_path, encoding="utf-8") as source:
        plan: object = json.load(source)
    if not isinstance(plan, dict):
        fail("reviewed plan JSON must be an object")
    changes = plan.get("resource_changes")
    if not isinstance(changes, list) or not 1 <= len(changes) <= MAX_RESOURCE_CHANGES:
        fail("reviewed plan resource count is empty or unbounded")

    for change_value in changes:
        if not isinstance(change_value, dict):
            fail("reviewed plan contains a malformed resource change")
        change: dict[str, object] = change_value
        address = string_field(change, "address", "resource change")
        mode = string_field(change, "mode", address)
        if mode != "managed":
            continue
        resource_type = string_field(change, "type", address)
        if resource_type not in OWNED_TYPES:
            fail(f"plan contains unsupported managed resource type: {address}")
        values_value = change.get("change")
        if not isinstance(values_value, dict):
            fail(f"plan lacks bounded change data: {address}")
        values: dict[str, object] = values_value
        actions_value = values.get("actions")
        if not isinstance(actions_value, list) or not all(isinstance(action, str) for action in actions_value):
            fail(f"plan contains malformed managed actions: {address}")
        actions = tuple(actions_value)
        if actions not in ALLOWED_ACTIONS:
            fail(f"plan contains unsupported managed action set: {address}")
        before = values.get("before")
        after = values.get("after")
        if before is not None and not owned(before, token, address):
            fail(f"plan would mutate unowned resource: {address}")
        if after is not None and not owned(after, token, address):
            fail(f"plan lacks ownership tag: {address}")
        if resource_type == "aws_ecr_repository" and after is not None:
            if not isinstance(after, dict) or after.get("name") != ecr_name:
                fail("plan ECR repository differs from guarded name")


if __name__ == "__main__":
    main()

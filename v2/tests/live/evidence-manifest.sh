#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PY'
import argparse, hashlib, json, os, re, sys

MAX_ARTIFACT_BYTES = 1_048_576
MAX_COMMANDS = 128
sha256_pattern = re.compile(r"^[0-9a-f]{64}$")
commit_pattern = re.compile(r"^[0-9a-f]{40,64}$")

parser = argparse.ArgumentParser()
parser.add_argument("--commit", required=True)
parser.add_argument("--binary-sha", required=True)
parser.add_argument("--image-sha", required=True)
parser.add_argument("--binary-list", required=True)
parser.add_argument("--image-digests", required=True)
parser.add_argument("--plan-sha", required=True)
parser.add_argument("--command-statuses", required=True)
parser.add_argument("--metrics", required=True)
parser.add_argument("--journals", required=True)
parser.add_argument("--cleanup", required=True)
parser.add_argument("--source-state", required=True)
parser.add_argument("--pre-inventory", required=True)
parser.add_argument("--redaction-status", required=True, type=int)
parser.add_argument("--output", required=True)
args = parser.parse_args()

if not commit_pattern.fullmatch(args.commit):
    raise SystemExit("invalid commit SHA")
for name, value in (("binary", args.binary_sha), ("image", args.image_sha), ("plan", args.plan_sha)):
    if not sha256_pattern.fullmatch(value):
        raise SystemExit(f"invalid {name} SHA-256")
if not 0 <= args.redaction_status <= 255:
    raise SystemExit("redaction status must be 0..255")

def artifact(path):
    if os.path.islink(path) or not os.path.isfile(path):
        raise SystemExit(f"artifact must be a regular non-symlink file: {path}")
    size = os.path.getsize(path)
    if size > MAX_ARTIFACT_BYTES:
        raise SystemExit(f"artifact exceeds {MAX_ARTIFACT_BYTES} bytes: {path}")
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        while chunk := source.read(65536):
            digest.update(chunk)
    return {"path": os.path.abspath(path), "bytes": size, "sha256": digest.hexdigest()}

statuses = {}
status_artifact = artifact(args.command_statuses)
with open(args.command_statuses, encoding="utf-8") as source:
    for line_number, line in enumerate(source, 1):
        fields = line.rstrip("\n").split("\t")
        if len(fields) != 2 or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,64}", fields[0]):
            raise SystemExit(f"invalid command status line {line_number}")
        try:
            status = int(fields[1])
        except ValueError:
            raise SystemExit(f"invalid command exit status line {line_number}")
        if not 0 <= status <= 255 or fields[0] in statuses:
            raise SystemExit(f"invalid or duplicate command status line {line_number}")
        statuses[fields[0]] = status
        if len(statuses) > MAX_COMMANDS:
            raise SystemExit(f"more than {MAX_COMMANDS} command statuses")
if not statuses:
    raise SystemExit("at least one command status is required")

required_environment = (
    "HIVEMIND_EVIDENCE_STARTED_AT", "HIVEMIND_EVIDENCE_ENDED_AT",
    "HIVEMIND_EVIDENCE_COMMAND", "HIVEMIND_EVIDENCE_REGION",
    "HIVEMIND_EVIDENCE_OWNERSHIP_HASH", "HIVEMIND_EVIDENCE_WORKSPACE_HASH",
    "HIVEMIND_EVIDENCE_KEEP_INFRA", "HIVEMIND_EVIDENCE_FINAL_STATUS",
)
environment = {name: os.environ.get(name, "") for name in required_environment}
if any(not value for value in environment.values()):
    missing = [name for name, value in environment.items() if not value]
    raise SystemExit(f"missing evidence environment: {', '.join(missing)}")
if environment["HIVEMIND_EVIDENCE_KEEP_INFRA"] not in ("0", "1"):
    raise SystemExit("invalid KEEP_INFRA evidence value")
if environment["HIVEMIND_EVIDENCE_FINAL_STATUS"] != "0":
    raise SystemExit("successful manifest requires final status 0")
capabilities = {}
for name in ("REQUIRE_CONTAINERD", "REQUIRE_GPU", "REQUIRE_NYDUS", "REQUIRE_JUICEFS", "REQUIRE_ECR_COLD_PULL"):
    value = os.environ.get(name, "0")
    if value not in ("0", "1"):
        raise SystemExit(f"invalid capability evidence: {name}")
    capabilities[name] = int(value)

manifest = {
    "commit_sha": args.commit,
    "binary_sha256": args.binary_sha,
    "image_sha256": args.image_sha,
    "exact_binary_digests": artifact(args.binary_list),
    "exact_image_digests": artifact(args.image_digests),
    "terraform_plan_sha256": args.plan_sha,
    "command_exit_statuses": statuses,
    "command_status_artifact": status_artifact,
    "metrics": artifact(args.metrics),
    "journals": artifact(args.journals),
    "source_state": artifact(args.source_state),
    "pre_ownership_inventory": artifact(args.pre_inventory),
    "cleanup_inventory": artifact(args.cleanup),
    "started_at_utc": environment["HIVEMIND_EVIDENCE_STARTED_AT"],
    "ended_at_utc": environment["HIVEMIND_EVIDENCE_ENDED_AT"],
    "exact_command": environment["HIVEMIND_EVIDENCE_COMMAND"],
    "region": environment["HIVEMIND_EVIDENCE_REGION"],
    "ownership_token_sha256": environment["HIVEMIND_EVIDENCE_OWNERSHIP_HASH"],
    "workspace_sha256": environment["HIVEMIND_EVIDENCE_WORKSPACE_HASH"],
    "keep_infra": int(environment["HIVEMIND_EVIDENCE_KEEP_INFRA"]),
    "capability_requirements": capabilities,
    "final_exit_status": int(environment["HIVEMIND_EVIDENCE_FINAL_STATUS"]),
    "redaction_scan_command": "tests/live/redaction-scan.sh EVIDENCE_DIR",
    "redaction_scan_exit_status": args.redaction_status,
}
output_parent = os.path.dirname(os.path.abspath(args.output))
if not os.path.isdir(output_parent):
    raise SystemExit("output parent does not exist")
if os.path.lexists(args.output) and os.path.islink(args.output):
    raise SystemExit("output must not be a symlink")
with open(args.output, "x", encoding="utf-8") as output:
    json.dump(manifest, output, sort_keys=True, indent=2)
    output.write("\n")
PY

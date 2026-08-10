#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PY'
import argparse, hashlib, json, os, re, sys

MAX_ARTIFACT_BYTES = 1_048_576
MAX_COMMANDS = 128
MAX_TREE_FILES = 256
MAX_TREE_BYTES = 64 * 1_048_576
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
parser.add_argument("--post-apply-inventory", required=True)
parser.add_argument("--pre-cleanup-inventory", required=True)
parser.add_argument("--retention-record", required=True)
parser.add_argument("--review-record", required=True)
parser.add_argument("--apply-log", required=True)
parser.add_argument("--destroy-log", required=True)
parser.add_argument("--terraform-outputs", required=True)
parser.add_argument("--runbook-artifacts", required=True)
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

def artifact_tree(root):
    if os.path.islink(root) or not os.path.isdir(root):
        raise SystemExit(f"artifact tree must be a directory: {root}")
    records = []
    total_bytes = 0
    for directory, directories, files in os.walk(root):
        directories.sort()
        files.sort()
        if any(os.path.islink(os.path.join(directory, name)) for name in directories):
            raise SystemExit(f"artifact tree contains a symlink directory: {directory}")
        for name in files:
            path = os.path.join(directory, name)
            record = artifact(path)
            total_bytes += record["bytes"]
            if total_bytes > MAX_TREE_BYTES:
                raise SystemExit(f"artifact tree exceeds {MAX_TREE_BYTES} bytes: {root}")
            record["relative_path"] = os.path.relpath(path, root)
            records.append(record)
            if len(records) > MAX_TREE_FILES:
                raise SystemExit(f"artifact tree exceeds {MAX_TREE_FILES} files: {root}")
    if not records:
        raise SystemExit(f"artifact tree is empty: {root}")
    return records

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
    "HIVEMIND_EVIDENCE_COMMAND", "HIVEMIND_EVIDENCE_ACCOUNT_ALIAS",
    "HIVEMIND_EVIDENCE_REGION", "HIVEMIND_EVIDENCE_RUN_ID", "HIVEMIND_EVIDENCE_WORKSPACE",
    "HIVEMIND_EVIDENCE_UNAVAILABLE_CAPABILITIES",
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
if not re.fullmatch(r"[A-Za-z0-9_.@-]{1,64}", environment["HIVEMIND_EVIDENCE_ACCOUNT_ALIAS"]):
    raise SystemExit("invalid account alias")
if not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", environment["HIVEMIND_EVIDENCE_RUN_ID"]):
    raise SystemExit("invalid run ID")
try:
    unavailable_capabilities = json.loads(environment["HIVEMIND_EVIDENCE_UNAVAILABLE_CAPABILITIES"])
except json.JSONDecodeError as error:
    raise SystemExit("invalid unavailable capability evidence") from error
if not isinstance(unavailable_capabilities, list) or len(unavailable_capabilities) > 16 or any(
    not isinstance(value, str) or not re.fullmatch(r"[A-Z0-9_]{1,64}", value)
    for value in unavailable_capabilities
):
    raise SystemExit("invalid unavailable capability evidence")
capabilities = {}
for name in ("REQUIRE_CONTAINERD", "REQUIRE_GPU", "REQUIRE_NYDUS", "REQUIRE_JUICEFS", "REQUIRE_ECR_COLD_PULL"):
    value = os.environ.get(name, "0")
    if value not in ("0", "1"):
        raise SystemExit(f"invalid capability evidence: {name}")
    capabilities[name] = int(value)

runbook_records = artifact_tree(args.runbook_artifacts)
runbook_by_path = {record["relative_path"]: record for record in runbook_records}
required_runbook = {
    "api-identities.jsonl", "fault-period-metrics.txt", "intermediate-inventory.txt",
    "runtime-proof.txt", "ecr-proof.txt", "journal-proof.txt",
}
missing_runbook = sorted(required_runbook - set(runbook_by_path))
if missing_runbook:
    raise SystemExit(f"runbook evidence contract is incomplete: {', '.join(missing_runbook)}")

def runbook_text(relative_path):
    with open(runbook_by_path[relative_path]["path"], encoding="utf-8") as source:
        return source.read(MAX_ARTIFACT_BYTES + 1).strip()

def exact_pairs(relative_path, required_keys):
    text = runbook_text(relative_path)
    fields = text.split()
    pairs = {}
    for field in fields:
        if "=" not in field:
            raise SystemExit(f"runbook evidence has malformed field: {relative_path}")
        key, value = field.split("=", 1)
        if not re.fullmatch(r"[a-z_]{1,32}", key) or not value or key in pairs:
            raise SystemExit(f"runbook evidence has invalid or duplicate field: {relative_path}")
        pairs[key] = value
    if set(pairs) != set(required_keys):
        raise SystemExit(f"runbook evidence schema differs: {relative_path}")
    return pairs

api_ids = set()
api_lines = runbook_text("api-identities.jsonl").splitlines()
if not 1 <= len(api_lines) <= 128:
    raise SystemExit("API identity evidence count is empty or unbounded")
for line in api_lines:
    try:
        record = json.loads(line)
    except json.JSONDecodeError as error:
        raise SystemExit("API identity evidence is malformed") from error
    if set(record) != {"request_id", "status"}:
        raise SystemExit("API identity evidence schema differs")
    request_id, status = record["request_id"], record["status"]
    if not isinstance(request_id, int) or isinstance(request_id, bool) or request_id <= 0:
        raise SystemExit("API request identity must be positive")
    if request_id in api_ids or not isinstance(status, int) or isinstance(status, bool) or not 0 <= status <= 9:
        raise SystemExit("API identity evidence is duplicate or has invalid status")
    api_ids.add(request_id)

fault = exact_pairs("fault-period-metrics.txt", ("fault", "queue"))
if not re.fullmatch(r"[a-z0-9_-]{1,64}", fault["fault"]) or not fault["queue"].isdigit():
    raise SystemExit("fault-period evidence lacks a bounded identity or queue count")
inventory = exact_pairs("intermediate-inventory.txt", ("instances",))
if not inventory["instances"].isdigit() or int(inventory["instances"]) < 1:
    raise SystemExit("intermediate inventory does not prove owned instances")
runtime = exact_pairs("runtime-proof.txt", ("tasks", "containers", "cdi", "cgroup", "gpu"))
if not runtime["tasks"].isdigit() or int(runtime["tasks"]) < 1:
    raise SystemExit("runtime evidence does not prove a task")
if not runtime["containers"].isdigit() or int(runtime["containers"]) < 1:
    raise SystemExit("runtime evidence does not prove a container")
if any(runtime[key] != "verified" for key in ("cdi", "cgroup", "gpu")):
    raise SystemExit("runtime capability evidence is not verified")
ecr = exact_pairs("ecr-proof.txt", ("cold_pull", "digest"))
if ecr["cold_pull"] != "verified" or not re.fullmatch(r"sha256:[0-9a-f]{64}", ecr["digest"]):
    raise SystemExit("ECR cold-pull evidence is invalid")
journal = exact_pairs("journal-proof.txt", ("mode", "checksum", "recovery"))
if not re.fullmatch(r"0[0-7]{3}", journal["mode"]):
    raise SystemExit("journal mode evidence is invalid")
if not sha256_pattern.fullmatch(journal["checksum"]) or journal["recovery"] != "verified":
    raise SystemExit("journal checksum or recovery evidence is invalid")

manifest = {
    "commit_sha": args.commit,
    "binary_sha256": args.binary_sha,
    "image_sha256": args.image_sha,
    "exact_binary_digests": artifact(args.binary_list),
    "exact_image_digests": artifact(args.image_digests),
    "terraform_plan_sha256": args.plan_sha,
    "reviewed_plan_record": artifact(args.review_record),
    "terraform_apply_log": artifact(args.apply_log),
    "terraform_destroy_log": artifact(args.destroy_log),
    "terraform_outputs": artifact(args.terraform_outputs),
    "runbook_artifacts": runbook_records,
    "command_exit_statuses": statuses,
    "command_status_artifact": status_artifact,
    "metrics": artifact(args.metrics),
    "journals": artifact(args.journals),
    "source_state": artifact(args.source_state),
    "pre_ownership_inventory": artifact(args.pre_inventory),
    "post_apply_inventory": artifact(args.post_apply_inventory),
    "pre_cleanup_inventory": artifact(args.pre_cleanup_inventory),
    "cleanup_inventory": artifact(args.cleanup),
    "retention_record": artifact(args.retention_record),
    "started_at_utc": environment["HIVEMIND_EVIDENCE_STARTED_AT"],
    "ended_at_utc": environment["HIVEMIND_EVIDENCE_ENDED_AT"],
    "exact_command": environment["HIVEMIND_EVIDENCE_COMMAND"],
    "account_alias": environment["HIVEMIND_EVIDENCE_ACCOUNT_ALIAS"],
    "region": environment["HIVEMIND_EVIDENCE_REGION"],
    "run_id": environment["HIVEMIND_EVIDENCE_RUN_ID"],
    "workspace": environment["HIVEMIND_EVIDENCE_WORKSPACE"],
    "unavailable_capabilities": unavailable_capabilities,
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

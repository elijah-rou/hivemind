# Live test safety contract

> **Prepared, never default:** `tests/live/run.sh` is the unified guarded acceptance wrapper. E1 exercised only deterministic stub fixtures. No cloud, provider, containerd, GPU, registry, storage, systemd, SSM, S3, or destructive boundary ran. This document does not authorize a live run.

The wrapper requires an already reviewed saved Terraform plan and a bounded per-run JSON approval record that binds the account, account alias, region, run ID, ownership-token SHA-256, workspace, plan SHA-256, maximum duration, maximum estimated cost, expiry, quota confirmation, and destructive-cleanup approval. Prepare the plan outside the execution command, record its SHA-256 as the sole line in a protected review record, then supply both records to the wrapper. `HIVEMIND_LIVE_PREFLIGHT_ONLY=1` performs guard and read-only zero-inventory checks without invoking the executor. Do not use fixture mode outside `live_guardrails_test.sh`.

The POC runbook refuses direct invocation unless the wrapper activates guardrails. Other legacy/operator scripts under `infra/` are not unified acceptance entry points. Deterministic fixtures, offline Terraform validation, historical artifacts, and prepared privileged scripts are not live evidence.

Required execution environment includes `HIVEMIND_ALLOW_LIVE=1`, `HIVEMIND_AWS_ACCOUNT_ALLOWLIST`, `HIVEMIND_AWS_ACCOUNT_ALIAS`, `HIVEMIND_AWS_REGION_ALLOWLIST`, `AWS_REGION`, `HIVEMIND_RUN_ID`, `HIVEMIND_RUN_TOKEN`, token-containing `TF_WORKSPACE`, `HIVEMIND_LIVE_BUCKET`, and `HIVEMIND_LIVE_ECR`, `HIVEMIND_COST_APPROVED=1`, `HIVEMIND_CLEANUP_APPROVED=1`, `HIVEMIND_QUOTA_CONFIRMED=1`, `HIVEMIND_LIVE_APPROVAL_RECORD`, `HIVEMIND_TF_PLAN`, `HIVEMIND_APPROVED_PLAN_SHA256`, `HIVEMIND_PLAN_REVIEW_RECORD`, `HIVEMIND_WORKSPACE_CREATION_RECORD`, and every required capability flag set to `1`. Production mode canonicalizes and accepts only repository-owned executor, cleanup, and inventory hooks. `KEEP_INFRA` defaults to `0`. The outer command is `cd v2 && timeout --foreground --kill-after=2200s 16740s ./tests/live/run.sh`; its deadline reserves the wrapper's full 14,400-second executor, 1,800-second cleanup, and two 300-second inventory budgets, and its kill grace exceeds cleanup plus inventory. The wrapper currently refuses before ownership because strict pre-mutation JuiceFS/containerd/GPU/Nydus evidence is unavailable. Do not paste numeric account identifiers or credentials into tracked files or command transcripts.

## Mandatory preflight

The live entry point exits nonzero before ownership unless every condition below is satisfied:

1. `HIVEMIND_ALLOW_LIVE` is exactly `1`.
2. The caller identity is resolved read-only and its account matches an explicit external allowlist. Documentation, logs, and committed configuration must not contain a real account number.
3. Region is explicitly selected, appears in an allowlist, and is echoed for approval. There is no implicit provider-default region.
4. Required service quotas, instance types, GPU availability, addresses, registry limits, and storage prerequisites are checked without mutation.
5. The complete cost scope and estimated maximum run duration are displayed and explicitly approved for this run.
6. Terraform destroy, bucket/repository deletion, process termination, container removal, unmount, and other destructive cleanup are separately and explicitly approved.
7. Run ID, Terraform workspace, bucket, ECR repository, and ownership token are unique and unpredictable. Provider resource names/tags derive from the run identity where supported.
8. `KEEP_INFRA=0` is the default. Only literal `0` and `1` are accepted. `1` requires named ownership, cost approval, expiry, and a later cleanup plan.
9. Cleanup traps are installed and tested before the process can acquire resource ownership.
10. Terraform is initialized safely and produces a saved plan. A human reviews that saved plan, including replacements and deletes, before apply; apply uses exactly the reviewed plan.
11. Pre-apply inventory proves the run does not already own resources. The gate refuses to adopt, mutate, unlock, or delete anything without an exact ownership token/marker and expected run tags/state.
12. Acceptance mode enables strict capability semantics. Any required capability that is absent, skipped, degraded, or unverifiable fails nonzero before acceptance.

Authorization is per run. Prior credentials, a prior approval, or an existing Terraform workspace do not satisfy a new run. Canonical private helpers also require an inherited wrapper-created file-descriptor capability and verify the actual Bash script identity through `/proc/*/fd/255`; caller-supplied environment values or forged argv text are insufficient.

## Required functional matrix

Every row remains **not run for E1** until the guarded entry point completes and produces a valid current manifest.

| ID | Required topology/capability | Observable pass condition | Required artifacts |
|---|---|---|---|
| F1 | Reviewed Terraform plan | Saved plan digest matches the applied plan; apply exits zero | Saved plan, digest, review record, apply log, outputs |
| F2 | Five replicas | All five are active and exactly one is leader | Health JSON, per-replica metrics, systemd journals |
| F3 | CPU worker | Worker registers with expected CPU/memory capacity | Worker/dashboard snapshot, metrics, journal |
| F4 | GPU worker | Worker registers with expected GPU type and count | Worker snapshot, metrics, CDI inventory |
| F5 | CPU inference | Real CPU workload returns the expected semantic response through `/run` | Request/response, image digest, latency |
| F6 | CUDA inference | Real GPU workload returns the expected CUDA result through `/run` | Request/response, image digest, latency |
| F7 | GPU isolation | CDI-selected device is visible and `nvidia-smi` succeeds inside the actual workload task | `ctr` task/container identity and in-container output |
| F8 | Containerd | Real worker uses real containerd namespace/cgroups and leaves the expected task inventory | `ctr` tasks/containers plus cgroup evidence |
| F9 | Private image | Unique private ECR image is cold-pulled after removing the owned cache entry | ECR digest, pull logs, pre/post cache inventory |
| F10 | Nydus when required | `REQUIRE_NYDUS=1`; active use is proven, not merely installation | Runtime, configuration, snapshotter, and task evidence |
| F11 | JuiceFS when required | `REQUIRE_JUICEFS=1`; required mount succeeds and workload reads/writes it | Mount table, workload output, cleanup table |
| F12 | Observability | Metrics and journals identify the run and remain readable through faults | Before/during/after snapshots |
| F13 | Journal permissions and recovery | Data directory/file modes match the contract; controlled restart recovers committed state | `stat`, journal metadata/checksums, restart log |

A strict containerd/GPU/Nydus/JuiceFS requirement fails if unavailable; logging “skip” cannot satisfy its row. `REQUIRE_GPU=1` requires one CDI-selected task plus successful in-container `nvidia-smi`. `REQUIRE_JUICEFS=1` currently fails before apply because the AppSpec/API required-mount surface is absent, so that row remains blocked rather than skipped.

## Required resilience matrix

| ID | Fault | Required observation | Pass condition |
|---|---|---|---|
| R1 | Kill current leader | Leader identity before/after, continuous requests, metrics and journals | A different leader is elected and requests continue |
| R2 | Restart old leader | Replica status, commit watermark, committed state digest | Old replica rejoins and converges to committed state |
| R3 | Restart worker | Registration, request identity, containerd inventory | Existing task is safely adopted or recreated; request path recovers without duplicate unsafe execution |
| R4 | Force client timeout/abandonment | Queue and in-flight metrics before/during/after | Both return to exact zero within a recorded bounded deadline |
| R5 | Controlled full-service restart | Retained journals and original named state | Original committed state survives and a new command commits |
| R6 | GPU workload during/after recovery | GPU task/device evidence and `/run` result | GPU request succeeds with the intended device after recovery |
| R7 | Required capability unavailable | Strict flag, mutation inventory, exit status | Gate fails nonzero before affected mutation; no skip counts as acceptance |

[`infra/poc/failure-drills.sh`](../../infra/poc/failure-drills.sh) now requires old-replica normal rejoin, equal commit/state digests, and exact-zero queue/in-flight gauges. It remains only one part of this larger matrix and has not been executed for E1.

## Required cleanup matrix

Acceptance remains incomplete until each owned category is proven absent, or retained under an explicitly approved `KEEP_INFRA=1` record.

| Owned category | Ownership proof before mutation | Cleanup action | Post-cleanup pass evidence |
|---|---|---|---|
| Terraform workspace/state | Unique run/workspace token and expected state backend | Destroy, select default, delete owned workspace | Destroy exit zero and workspace absent |
| EC2 instances | Exact run tags/token and Terraform state | Terraform destroy; targeted cleanup only for proven owned leftovers | No owned instances remain |
| EBS volumes | Run tags/token plus attachment inventory | Terraform destroy or delete proven owned leftovers | No owned volumes remain |
| S3 buckets/prefixes | Exact conditional marker and ownership claim | Delete owned prefix, then owned bucket | Marker, prefix, and bucket absent |
| ECR repository/images | Unique repository plus exact ownership tags/token | Force-delete the owned repository | Repository absent |
| Security groups, key pairs, and network resources | Terraform state plus exact ownership tags | Terraform destroy | No owned network/key resources remain |
| SSM commands/artifacts | Run-scoped command IDs | Record terminal status; remove owned artifacts where applicable | Inventory records terminal or absent state |
| systemd units/processes | Host and run inventory | Restore expected services; remove transient owned units/processes | Expected services active or owned units/processes absent |
| containerd tasks/containers | Namespace plus exact run/pod identity | Stop and remove owned tasks/containers | No owned task/container remains |
| JuiceFS mounts/temp paths | Run token and exact mount path | Unmount and remove owned path | Mount and filesystem inventories clean |
| Local temporary files | Recorded artifact/temp manifest | Remove secret-bearing temporary files | Inventory clean |
| Test deployments | Recorded deployment IDs | Delete through API | Deployments absent |
| Terraform locks | Workspace/state ownership proof | Normal unlock only | No owned lock remains; never break an unowned lock |

Useful current patterns do not form a unified gate: [`infra/gpu-test/run-tests.sh`](../../infra/gpu-test/run-tests.sh) installs cleanup and propagates cleanup failure, while [`infra/bench/artifact_lifecycle.sh`](../../infra/bench/artifact_lifecycle.sh) conditionally claims and revalidates exact S3 ownership before scoped deletion. Future orchestration should preserve those fail-closed properties.

## Required evidence manifest

A successful live run must retain a bounded, reviewable manifest containing:

- full source commit SHA and explicit clean/dirty declaration;
- UTC start/end timestamps, exact command, phase exit statuses, and final exit status;
- account alias, region, run ID, and token-redacted workspace, with the numeric account identifier redacted;
- every capability flag and any capability detected as unavailable;
- Terraform saved-plan SHA-256, review record, apply log, outputs, destroy log, and state/workspace disposition;
- binary and image SHA-256 digests, including the exact private ECR digest when exercised;
- API request/response artifacts and request identities needed to reason about retries, summarized in `api-identities.jsonl`;
- metrics before, during, and after each fault;
- systemd journals and service-state snapshots;
- containerd task/container/CDI/cgroup evidence and in-task GPU output, summarized in `runtime-proof.txt`;
- exact cold-pull digest evidence in `ecr-proof.txt`;
- journal metadata/checksums, permission evidence, and recovery result in `journal-proof.txt`;
- fault-period queue snapshots in `fault-period-metrics.txt`;
- resource inventory before ownership, after apply, before cleanup, and after cleanup;
- `KEEP_INFRA` value and, when `1`, owner/reason/expiry/cost/cleanup record;
- exact redaction and credential-scan command/result.

Raw Terraform and runbook output is bounded to 1 MiB per file in a mode-0700 temporary staging directory. Only explicit byte-redacted copies enter the manifest tree; the staging directory is removed after cleanup. Evidence is current only for the recorded commit, environment, capabilities, and run. Historical evidence is not silently promoted.

## Redaction contract

- Never commit or publish numeric account IDs, credentials, session tokens, private keys, ownership tokens, registry passwords, secret values, signed URLs, private addresses, or raw Terraform state.
- Hash the ownership token when correlating logs; retain the original only in the protected run workspace needed for cleanup.
- Redact account numbers from ARN-like values while preserving service, region, resource type, and run-scoped name needed for review.
- Keep raw secret-bearing command output in an access-controlled temporary location, not the evidence bundle.
- Scan changed/generated evidence before publication and record the scanner and exit status.
- Redaction must not remove the run ID, resource category, digest, timestamps, exits, or cleanup disposition needed to audit the run.

## Cleanup-failure recovery

If automatic cleanup fails:

1. Preserve the original test exit status and record cleanup failures separately; cleanup failure makes the overall run failed.
2. Emit the account alias, region, run ID, workspace, ownership-token hash, and redacted resource inventory.
3. Do not retry broad deletion and do not adopt resources lacking exact ownership proof.
4. Re-run bounded read-only inventory commands and save their exits/output.
5. Obtain explicit approval before manual destructive recovery.
6. Clean one proven-owned category at a time and record each action.
7. Re-run the full inventory and redaction scan.
8. Keep the run failed until inventory proves every owned category absent.
9. If authorized `KEEP_INFRA=1` applies, record owner, reason, expiry, estimated continuing cost, and the exact later cleanup command in the protected handoff.

Do not break a lock, reuse a workspace, or broaden selectors merely to make cleanup succeed.

## Forbidden behavior

| Forbidden action or claim | Reason |
|---|---|
| Default, CI-default, or automatic live execution | Live work requires per-run authorization, cost, and destructive approval |
| Live mutation without exact `HIVEMIND_ALLOW_LIVE=1` and separate authorization | Environment presence is not consent |
| Embedding real account IDs, credentials, tokens, keys, or resource identifiers | Secrets and infrastructure identity must not enter repository docs/artifacts |
| Adopting, mutating, unlocking, or deleting an unowned or ambiguously owned resource | Cleanup and deployment are scoped to exact ownership proof |
| Treating an optional skip as acceptance | Required capability absence must fail nonzero |
| `KEEP_INFRA=1` without owner, cost approval, expiry, and cleanup plan | Retained infrastructure has cost and cleanup liability |
| Applying a regenerated or unreviewed plan | Approval covers the saved reviewed plan only |
| Calling mocks, Terraform validation, fixtures, historical cloud artifacts, or runtime-only containerd tests live evidence | They do not cross the guarded current live boundary |
| Claiming private ECR, Nydus, JuiceFS, GPU/CDI, S3/SSM/systemd, Doppler, or containerd acceptance without strict current-head artifacts | Tooling presence and host-only checks do not prove the functional contract |
| Declaring success while cleanup inventory is incomplete or cleanup failed | A live run includes destruction and absence proof |

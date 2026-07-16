# Hivemind Local Agent Rules

Read this file before implementation work in this repo.

## Mandatory simulation rule

This repo is **simulation-first**.

If a change affects the Hivemind cluster / control plane and is representable in simulation, it **must** be covered in the Zig VOPR simulation or related deterministic cluster tests.

If a change affects the Rust agent and is representable in simulation, it **must** be covered in the agent's deterministic simulation/runtime tests.

Do not treat simulation as optional polish. It is part of the implementation.

## Required mapping

- **Control plane / replica / scheduler / gossip / recovery / liveness / failover** changes → add or extend **`core/src/vopr/`** coverage when applicable.
- **Agent lifecycle / runtime / registration / heartbeats / pod state / request forwarding / failures** changes → add or extend **`worker/src/sim/`** coverage when applicable.
- **Pure wire format changes** → add cross-language/unit coverage on both sides and simulation coverage if behavior changes at runtime.
- **Real infra-only glue** that cannot be simulated → still add the nearest deterministic unit/integration test possible and document why simulation is not applicable.

## Default workflow

1. Read `docs/STATUS.md`, `docs/FINDINGS_AND_ISSUES.md`, `docs/ENGINEERING.md`.
2. For POC-facing work, also read `docs/POC_ACCEPTANCE.md` and `docs/POC_CHANGELOG.md`.
3. Identify whether the change belongs to:
   - Hivemind cluster simulation
   - Worker simulation
   - both
4. Add failing deterministic test/sim coverage first where practical.
5. Implement.
6. Re-run relevant Zig/Rust/Go tests.
7. Update docs when behavior, scope, or POC readiness changed.
8. If the work affects the POC, update `docs/POC_CHANGELOG.md` in the same change.

## POC rule

Goal is a **real workload POC**, not a production launch. But any claim that the system "works" should be backed by deterministic simulation when the behavior is simulatable.

## POC progress tracking

When work changes the POC plan, acceptance status, infra readiness, locality/routing design, or evidence state, update `docs/POC_CHANGELOG.md`.

Each meaningful entry should record at least:

- date
- what changed
- why it matters for the POC
- current acceptance progress using concrete counts, not hand-wavy percentages
  - preferred: completed acceptance sections / total sections
  - optional: completed execution steps / total execution steps
- next 1-3 concrete steps
- current blocker(s) or unknowns
- live infra status (`up`, `destroyed`, or `mixed`)

Do not invent fake certainty. If progress cannot be quantified cleanly, state why.

## Current priority

Prefer work that moves the project toward a real workload POC **and** can be validated in simulation:

1. reconnect / stale-node handling
2. containerd run/probe/request path correctness
3. `/run` response contract cleanup
4. auth / TLS slices that can be exercised deterministically
5. richer app spec model

## Notes

- Repo has `CLAUDE.md`; this file is the repo-local equivalent for implementation discipline.
- If a proposed change cannot be reflected in simulation, say so explicitly before coding.

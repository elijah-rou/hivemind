# Log Repair After View Change

## Problem

VOPR finds ~9% safety violations across 500 random-fault seeds. The nack protocol is correctly implemented but insufficient alone. The remaining violations come from this scenario:

1. R0 (leader v0) commits ops with R1 (partial partition -- R2 isolated)
2. R0 gets partitioned. R1 and R2 form view change quorum.
3. R1's DVC carries the committed ops. New leader installs them. **This works.**
4. BUT: if R1 is ALSO partitioned before the view change, R2 forms quorum with R0 (after R0 heals). R0's DVC has stale entries. The committed ops from R1 are lost because R1 isn't in the quorum.

The core issue: after view change completes, the new leader may have "holes" in its log -- ops that should exist but aren't in any DVC that participated. These holes correspond to ops that reached quorum_replication on replicas not in the current view change quorum.

## Solution: Post-View-Change Log Repair

TigerBeetle's approach: after the new leader sends StartView and transitions to normal, it enters a **repair phase** where it requests missing log entries from all replicas (including ones that weren't in the view change quorum).

### Protocol

New message types:
```
RequestPrepare { view_number, op_number }
SendPrepare    { view_number, entry: LogEntry }
```

Flow:
1. New leader completes view change (maybeStartView)
2. Leader identifies gaps: ops between commit_number and op_number where logSlot returns null
3. For each gap, leader broadcasts RequestPrepare to all replicas
4. Any replica that has the entry responds with SendPrepare
5. Leader installs the entry and can now commit up to that point

### Implementation Plan

#### Step 1: Message types (`src/message.zig`)
- Add `RequestPrepareMsg` and `SendPrepareMsg` to the Message union
- Update Tag enum and serialize/deserialize

#### Step 2: Repair state on Replica (`src/consensus.zig`)
- Add `repair_pending: bool` field -- true after view change until all gaps filled
- While `repair_pending`, leader still accepts new requests (assigns at op_number+1) but doesn't commit past the gap

#### Step 3: Repair tick (`src/consensus.zig`)
- In `tick()`, if leader and `repair_pending`:
  - Scan log for gaps between commit_number and op_number
  - If no gaps: set `repair_pending = false`
  - If gaps: send RequestPrepare for the lowest missing op (one at a time)

#### Step 4: Message handlers (`src/consensus.zig`)
- `onRequestPrepare`: if we have the entry in our log, respond with SendPrepare
- `onSendPrepare`: if the entry fills a gap, install it. Check if all gaps filled.

#### Step 5: Unit tests (`src/unit_tests.zig`)
Write BEFORE implementing:
1. Leader identifies gaps after view change
2. RequestPrepare sent for missing op
3. SendPrepare fills the gap
4. All gaps filled -> repair_pending cleared
5. Commit advances past repaired entries

#### Step 6: VOPR verification
- All 3 regression seeds pass
- 500-seed sweep targets 0 safety violations

### Key Invariants
- Committed entries are NEVER lost (they're in at least quorum_replication replicas)
- The repair phase is bounded: at most `op_number - commit_number` gaps
- New requests continue during repair (assigned at op_number+1, committed when contiguous)
- Repair messages respect partitions (RequestPrepare goes through network)

### Files to Modify
| File | Change |
|------|--------|
| `src/message.zig` | Add RequestPrepareMsg, SendPrepareMsg, update Message union |
| `src/consensus.zig` | Add repair_pending, repair tick logic, onRequestPrepare, onSendPrepare |
| `src/unit_tests.zig` | 5 new repair unit tests |
| `src/state_checker.zig` | Optional: add repair progress tracking |

### Current State (as of commit be611eb)
- 73 tests passing (55 unit + 18 integration)
- VOPR: 48% pass, 43% liveness failure, 9% safety violation
- Nack protocol implemented and verified
- Log forwarding in DVC and StartView working
- Truncation on step-down working
- `quorum_nack_prepare` computed and asserted

# State Transfer for Liveness

## Problem

VOPR shows ~43% liveness failures across 500 random-fault seeds. After partitions heal and the cluster stabilizes, replicas that missed Prepare messages have gaps in their logs and can never commit those entries. The cluster cannot converge because replicas disagree on commit_number.

Two distinct scenarios:

### Scenario A: Follower missed Prepares during partition
1. R0 (leader) commits ops 1-5 with R1
2. R2 is partitioned, misses Prepare for ops 2-5
3. Partition heals. R2 has op 1 committed, op_number=1
4. R0 sends Prepare for op 6. R2 rejects it (expects op_number+1=2, gets 6)
5. R2 is permanently stuck -- can never accept new Prepares or catch up

### Scenario B: New leader has log gaps after view change
1. View change completes. New leader has ops 1-3 but op_number=5 (from DVC best_op)
2. Ops 4-5 were nack-preserved but the entries aren't in any DVC that participated
3. Leader can't commit ops 4-5 (no entries). New ops start at 6. Commit stuck at 3.

## Solution: Two mechanisms

### 1. Log Repair (Leader-initiated, fixes Scenario B)

After view change, the new leader identifies gaps in its own log and requests the missing entries from all replicas.

**Messages:**
```
RequestPrepare { view_number, op_number }
SendPrepare    { view_number, entry: LogEntry }
```

**Flow:**
1. `maybeStartView` completes, sets `repair_pending = true` if gaps exist
2. On each `tick()`, leader scans for lowest gap: op where `logSlot(op) == null` and `op <= op_number`
3. Leader broadcasts `RequestPrepare(view, op)` to all replicas
4. Any replica with the entry responds `SendPrepare(view, entry)`
5. Leader installs the entry. Repeat until no gaps remain.
6. Set `repair_pending = false`. Commit advances normally.

**Invariants:**
- Leader still accepts new requests during repair (assigned at op_number+1)
- Leader does NOT commit past a gap (commitUpTo stops at first missing slot)
- Repair bounded: at most `op_number - commit_number` gaps
- RequestPrepare goes through the network (respects partitions)

### 2. State Transfer (Follower-initiated, fixes Scenario A)

A follower that falls behind requests a status update from the leader, then fetches missing entries.

**Messages:**
```
RequestStatus  { view_number }
SendStatus     { view_number, op_number, commit_number }
```

Reuses `RequestPrepare`/`SendPrepare` for fetching individual entries.

**Flow:**
1. Follower receives Prepare with `op > self.op_number + 1` (gap detected)
2. Follower sends `RequestStatus(view)` to the leader
3. Leader responds `SendStatus(view, op_number, commit_number)`
4. Follower now knows which ops it's missing
5. For each missing op from `self.op_number + 1` to leader's `op_number`:
   - Follower sends `RequestPrepare(view, op)` to leader
   - Leader responds `SendPrepare(view, entry)`
   - Follower installs the entry, advances op_number
6. Once caught up, follower processes buffered Prepares normally
7. Leader's Commit messages advance the follower's commit_number

**Invariants:**
- Follower buffers incoming Prepares that are too far ahead (optional -- can just drop and re-request)
- State transfer is idempotent (re-requesting an op it already has is a no-op)
- A follower in state transfer still responds to view change messages

### 3. Periodic Commit Heartbeat Enhancement

Currently the leader sends `Commit(view, commit_number)` as a heartbeat. Enhance it to also include `op_number` so followers can detect they're behind without waiting for a Prepare gap.

**Change:** Add `op_number` to `CommitMsg`. Follower checks: if `commit_msg.op_number > self.op_number`, initiate state transfer.

## Implementation Plan

### Step 1: Message types (`src/message.zig`)
Already partially done (RequestPrepareMsg, SendPrepareMsg, RequestStatusMsg, SendStatusMsg added).
- Add `op_number` field to `CommitMsg`
- Verify serialize/deserialize handles new message types

### Step 2: Leader log repair (`src/consensus.zig`)
- Add `repair_pending: bool` field to Replica (already added)
- In `maybeStartView`: set `repair_pending = true` if any gap exists between commit_number and op_number
- Add `tickRepair()`: find lowest gap, broadcast RequestPrepare
- Add `onRequestPrepare(from, msg)`: if we have the entry, respond SendPrepare
- Add `onSendPrepare(from, msg)`: install entry if it fills a gap, check if repair complete
- Throttle: only one outstanding RequestPrepare at a time (track `repair_requesting_op`)

### Step 3: Follower state transfer (`src/consensus.zig`)
- In `onPrepare`: if `prepare.op_number > self.op_number + 1`, initiate state transfer
- Add `transfer_pending: bool` field
- Add `transfer_target_op: OpNumber` -- the op we're trying to reach
- On each `tick()` as backup with `transfer_pending`: request next missing op via RequestPrepare
- `onSendPrepare` (same handler as leader repair): install entry, advance op_number
- When `self.op_number >= transfer_target_op`: set `transfer_pending = false`

### Step 4: Enhanced commit heartbeat
- Add `op_number` to CommitMsg
- In `onCommit`: if `commit_msg.op_number > self.op_number`, set `transfer_target_op` and initiate

### Step 5: Unit tests (write FIRST)
1. Leader identifies gap after view change, requests repair
2. Replica responds to RequestPrepare with SendPrepare
3. Leader completes repair, commit advances
4. Follower detects gap from Prepare, initiates state transfer
5. Follower catches up via RequestPrepare/SendPrepare
6. Follower commits after catching up
7. State transfer during partition (requests dropped, retried after heal)

### Step 6: Integration tests
1. Partition heal scenario: R2 catches up after missing ops
2. View change + repair: new leader fills gaps, cluster converges
3. Multiple view changes: cluster still converges after heal

### Step 7: VOPR verification
1. All regression seeds pass (0 safety violations)
2. 500-seed sweep: 0 safety violations (nack protocol)
3. 500-seed sweep: target >80% liveness (up from ~50%)
4. If liveness < 80%, capture failing seeds and investigate

## Files to Modify

| File | Change |
|------|--------|
| `src/message.zig` | Add op_number to CommitMsg (RequestPrepare/SendPrepare/RequestStatus/SendStatus already added) |
| `src/consensus.zig` | tickRepair, onRequestPrepare, onSendPrepare, follower state transfer in onPrepare/onCommit, enhanced commit heartbeat |
| `src/unit_tests.zig` | 7 new unit tests for repair + state transfer |
| `src/integration_tests.zig` | 3 new integration tests for catch-up scenarios |
| `src/test_harness.zig` | No changes expected |
| `src/state_checker.zig` | Optional: track repair progress metrics |

## Current State (as of commit 2ff59de + uncommitted changes)
- 73+ tests passing
- VOPR: ~48% pass, ~43% liveness failure, ~9% safety violation
- Message types for repair/status already added to message.zig
- repair_pending field already added to Replica
- tickRepair, onRequestPrepare, onSendPrepare, onRequestStatus, onSendStatus handlers scaffolded in consensus.zig
- Nack protocol implemented
- Log forwarding in DVC/StartView working
- Truncation on step-down working

## Key Design Decisions

1. **No snapshots (yet).** Repair fetches individual log entries. For the current scale (256 max log entries), this is fine. Snapshots needed later for production (32K+ ops).

2. **Leader repair and follower state transfer share the same messages.** RequestPrepare/SendPrepare works for both -- the difference is who initiates (leader for its own gaps, follower for missed Prepares).

3. **Drop-and-retry, no buffering.** Followers drop Prepares that are too far ahead rather than buffering them. Simpler, and the leader's commit heartbeat will trigger state transfer anyway.

4. **One outstanding request at a time.** Prevents flooding the network with RequestPrepare messages. The tick-based approach naturally throttles.

5. **Repair is bounded and monotonic.** The leader scans from commit_number+1 upward. Each successful repair advances the "repaired up to" point. No backtracking.

# TigerBeetle VRR Alignment

## Motivation

Our VRR implementation is correct (0% safety violations, ~99% pass rate across 500 VOPR seeds) but simplified. TigerBeetle's VRR is the reference Zig implementation and has patterns we need for production:

1. **Hash chain** - detect silent corruption, validate log integrity on recovery
2. **Follower ack on StartView** - immediate quorum after view change, eliminates heartbeat delay
3. **present_bitset in DVC** - targeted repair instead of broadcast, faster convergence
4. **commit_min + commit_max** - pipeline commits, separate "known committed" from "executed"
5. **Disk persistence** - crash recovery, journal with dirty/clean tracking

## Dependency Order

```
1. Hash chain (changes LogEntry, Prepare format)
   └─ 2. Follower ack on StartView (uses hash chain for entry validation)
   └─ 3. present_bitset in DVC (independent, but benefits from hash chain checksums)
4. commit_min + commit_max (pervasive change, independent of above)
5. Disk persistence (depends on all above being stable)
```

Changes 1-3 form a cluster. Change 4 is independent. Change 5 is last.

---

## Change 1: Hash Chain

### Problem

No integrity verification on log entries. A corrupted entry accepted during view change or repair would cause silent divergence. TigerBeetle chains every Prepare with a parent checksum.

### Design

Add two fields to `LogEntry`:

```zig
pub const LogEntry = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    checksum: u64 = 0,         // hash of this entry (all fields except checksum itself)
    parent_checksum: u64 = 0,  // checksum of the entry at op_number - 1
    command: Command = .{ .noop = {} },
    client_id: u128 = 0,
    request_id: RequestId = 0,
};
```

Hash function: use `std.hash.Wyhash` (fast, deterministic, no allocation). Hash all fields except `checksum`.

### Changes

**message.zig:**
- Add `checksum` and `parent_checksum` to LogEntry
- Add `fn computeChecksum(entry: *const LogEntry) u64` - hashes all fields except checksum
- Add `fn verifyChecksum(entry: *const LogEntry) bool`
- Add `fn verifyChain(entry: *const LogEntry, parent: *const LogEntry) bool`

**consensus.zig:**
- `onRequest` (leader assigns entry): compute checksum, set parent_checksum from previous entry
- `onPrepare` (follower receives): verify checksum, verify chain against local log
- `maybeStartView`: verify checksums on DVC entries before installing
- `onSendPrepare`: verify checksum before installing repaired entry
- `onStartView`: verify checksums on installed entries

### Invariants

- `entry.checksum == computeChecksum(entry)` for all entries in log
- `entry.parent_checksum == log[logSlot(entry.op_number - 1)].checksum` when chain is contiguous
- First entry (op_number == 1) has `parent_checksum = 0`

### Tests

- Verify checksum computation is deterministic
- Verify chain validation catches mismatched parent
- Verify corrupted entry is rejected in onPrepare
- Verify corrupted DVC entry is rejected in maybeStartView
- VOPR: 0% safety, no regressions

---

## Change 2: Follower Ack on StartView

### Problem

After view change, the leader has uncommitted entries but prepare_ok_counts = 1 (self only). Followers receive entries via StartView but don't ack until the leader resends Prepares (up to HEARTBEAT_INTERVAL delay). This causes ~1% liveness failures.

### Design

In `onStartView`, after installing entries, followers immediately send PrepareOk for each uncommitted entry they received.

### Changes

**consensus.zig - onStartView (after entry installation):**

```zig
// Ack uncommitted entries received from the leader
const new_leader = self.leader();
var ack_op = sv.commit_number + 1;
while (ack_op <= self.op_number) : (ack_op += 1) {
    if (self.logSlot(ack_op)) |slot| {
        // Verify checksum before acking (Change 1)
        if (!msg.verifyChecksum(&self.log[slot])) continue;
        self.sendTo(new_leader, .{ .prepare_ok = .{
            .view_number = self.view_number,
            .op_number = ack_op,
            .replica_id = self.replica_id,
        } });
    }
}
```

**Key safety constraint**: With Change 1 (hash chain), the follower can verify entries match the leader's authoritative log before acking. Without hash chain, there's a risk of acking an entry the leader later replaces during repair. The hash chain eliminates this risk.

### Impact

- Removes need for `resendUncommittedPrepares` as primary convergence mechanism (keep it as fallback)
- Leader reaches quorum within one network RTT of StartView broadcast
- Closes remaining ~1% liveness gap

### Tests

- Follower sends PrepareOk after onStartView for uncommitted entries
- Leader reaches quorum and commits after receiving StartView acks
- VOPR: 100% pass rate target

---

## Change 3: present_bitset in DVC

### Problem

After view change, the leader broadcasts RequestPrepare to ALL replicas for each missing op. TigerBeetle tracks which replicas have which prepares, enabling targeted repair.

### Design

Add bitset fields to DoViewChangeMsg:

```zig
pub const DoViewChangeMsg = struct {
    view_number: ViewNumber = 0,
    replica_id: u8 = 0,
    last_normal_view: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_number: OpNumber = 0,
    log_entries: [DVC_LOG_MAX]LogEntry = undefined,
    log_entry_count: u8 = 0,
    present_bitset: u256 = 0,  // bit N = 1 if this replica has op N in its log
    nack_bitset: u256 = 0,     // bit N = 1 if this replica does NOT have op N
};
```

u256 supports up to 256 ops (matches LOG_SIZE_MAX). Zig has `u256` as a native integer type.

### Changes

**message.zig:**
- Add `present_bitset: u256` and `nack_bitset: u256` to DoViewChangeMsg

**consensus.zig - buildDvc():**
```zig
// Build bitsets from log state
var present: u256 = 0;
var nack: u256 = 0;
for (1..self.op_number + 1) |op| {
    const bit: u256 = @as(u256, 1) << @intCast(op);
    if (self.logSlot(@intCast(op)) != null) {
        present |= bit;
    } else {
        nack |= bit;
    }
}
dvc.present_bitset = present;
dvc.nack_bitset = nack;
```

**consensus.zig - maybeStartView():**
- Use nack_bitset for nack counting (instead of scanning DVC log entries)
- After installing entries, collect present_bitsets from all DVCs
- Store "who has what" for targeted repair

**consensus.zig - tickRepair():**
- Instead of `sendToAllOthers(RequestPrepare)`, send only to replicas whose DVC had the op in `present_bitset`
- Fall back to broadcast if no DVC had it (op was on a non-quorum replica)

### Tests

- buildDvc produces correct bitsets
- maybeStartView uses nack_bitset for truncation decisions
- tickRepair sends targeted RequestPrepare
- VOPR: no regressions

---

## Change 4: commit_min + commit_max

### Problem

Single `commit_number` conflates "what we've executed" with "what we know is committed." TigerBeetle separates these:
- `commit_min`: highest op we've executed and applied to state machine
- `commit_max`: highest op we know is committed (from leader's Commit messages) but may not have executed yet (may not have the entry)

This enables:
- Followers can know ops are committed before having the entries
- Leader can pipeline: broadcast commit_max ahead of followers executing
- Better view change: DVCs carry both, giving the new leader more information

### Design

Replace `commit_number: OpNumber` with:

```zig
commit_min: OpNumber,  // highest op executed (applied to state machine)
commit_max: OpNumber,  // highest op known committed (from leader)
```

Invariant: `commit_min <= commit_max <= op_number`

### Mapping from current code

| Current usage | Becomes |
|---------------|---------|
| `commitEntry` sets `commit_number = op` | Sets `commit_min = op` |
| `commitUpTo(target)` | Sets `commit_max = max(commit_max, target)`, then executes up to commit_max |
| `advanceCommit` checks `commit_number < op_number` | Checks `commit_min < commit_max` (only commit what we know is committed) |
| PrepareMsg.commit_number | PrepareMsg.commit_min (leader's executed frontier) |
| CommitMsg.commit_number | CommitMsg.commit_min + CommitMsg.commit_max |
| DVC.commit_number | DVC.commit_min + DVC.commit_max |
| StartView.commit_number | StartView.commit_min + StartView.commit_max |
| `truncateAbove` protects `<= commit_number` | Protects `<= commit_min` (only protect executed entries) |
| Gap detection `commit_number + 1` | Uses `commit_min + 1` for execution, `commit_max` for known-committed range |

### Changes

**message.zig:** Replace `commit_number` with `commit_min` + `commit_max` in PrepareMsg, CommitMsg, DoViewChangeMsg, StartViewMsg, SendStatusMsg.

**consensus.zig:** ~50 reference points. Key semantic changes:
- `commitEntry`: only changes `commit_min`
- `onCommit`: sets `commit_max = max(self.commit_max, msg.commit_max)`, then calls `advanceCommitMin()` which executes entries between `commit_min` and `commit_max` that have entries in log
- `advanceCommit` (leader): increments `commit_max` when quorum reached, then advances `commit_min`
- `onPrepare`: follower sets `commit_max` from prepare.commit_max, executes up to it
- View change: `max_commit` in maybeStartView becomes `max(all DVC.commit_max)`
- Repair: gaps scan from `commit_min + 1` (need entries to execute)

### Tests

- commit_max advances ahead of commit_min
- Follower sets commit_max from Commit message
- advanceCommitMin executes entries up to commit_max
- commit_min never exceeds commit_max
- View change uses max of all commit_max values
- VOPR: 0% safety, no regressions

---

## Change 5: Disk Persistence

### Problem

All state is in-memory. A replica crash loses everything. Production requires crash recovery.

### Design

Two persistent artifacts:
1. **Journal** - log entries, append-only with periodic compaction
2. **Metadata** - replica state (view, op, commits, last_normal_view)

#### Journal Format

Fixed-size slots. Each slot = sizeof(LogEntry). Journal file = LOG_SIZE_MAX * sizeof(LogEntry).

```
journal.bin:
  [slot 0: LogEntry]  (op 1)
  [slot 1: LogEntry]  (op 2)
  ...
  [slot 255: LogEntry] (op 256)
```

Slot index = (op_number - 1) % LOG_SIZE_MAX. This gives O(1) lookup by op_number (no linear scan). Replaces the current `logSlot()` linear scan.

#### Metadata Format

```
metadata.bin:
  view_number:      u64
  last_normal_view: u64
  op_number:        u64
  commit_min:       u64
  commit_max:       u64
  log_len:          u64
  checksum:         u64  (hash of above fields)
```

Written atomically (write to temp, fsync, rename).

#### Dirty Tracking

```zig
// Per-slot dirty bits (need to be written to disk)
journal_dirty: [LOG_SIZE_MAX]bool,
metadata_dirty: bool,
```

#### Write Path

- `appendLog(entry)` -> set `journal_dirty[slot] = true`
- View/commit changes -> set `metadata_dirty = true`
- `persistIfNeeded()` called at end of `tick()`:
  - Write all dirty journal slots
  - Write metadata if dirty
  - `fsync` journal, then metadata (ordering matters for crash consistency)

#### Recovery Path

```zig
fn recover(self: *Replica) !void {
    // 1. Read metadata.bin, verify checksum
    // 2. Restore view_number, op_number, commit_min, commit_max, last_normal_view
    // 3. Read journal.bin slots 0..log_len
    // 4. Verify hash chain integrity (Change 1)
    // 5. Set status = .recovering
    // 6. Participate in view change to rejoin cluster
}
```

#### Io Interface Extension

```zig
pub const DiskIo = struct {
    fn writeJournalSlot(slot: usize, entry: *const LogEntry) !void;
    fn readJournalSlot(slot: usize) !LogEntry;
    fn writeMetadata(meta: *const Metadata) !void;
    fn readMetadata() !Metadata;
    fn fsync() !void;
};
```

SimulatedIo gets a simulated disk (in-memory buffer that can be faulted for DST).

#### Log Structure Change

**This is the biggest refactor.** The current log is a compacted array with linear scan lookup. Change to slot-indexed:

```zig
// Current (scan-based):
log: [LOG_SIZE_MAX]LogEntry,
log_len: usize,
fn logSlot(op) ?usize { linear scan }

// New (slot-indexed):
journal: [LOG_SIZE_MAX]LogEntry,
journal_occupied: [LOG_SIZE_MAX]bool,  // which slots have valid entries
fn journalSlot(op: OpNumber) usize { return (op - 1) % LOG_SIZE_MAX; }
fn hasEntry(op: OpNumber) bool { return journal_occupied[journalSlot(op)]; }
fn getEntry(op: OpNumber) ?*LogEntry {
    const slot = journalSlot(op);
    if (!journal_occupied[slot]) return null;
    if (journal[slot].op_number != op) return null;  // slot recycled
    return &journal[slot];
}
```

Benefits:
- O(1) lookup instead of O(n) linear scan
- Direct mapping to disk slots
- No compaction needed (slots are reused as ops wrap around)
- `prepare_ok_counts` can be indexed by slot directly

### Tests

- Write and recover metadata
- Write and recover journal entries
- Hash chain validates on recovery
- Corrupted journal slot detected on recovery
- Replica rejoins cluster after simulated crash
- VOPR with crash faults: inject crashes, verify recovery
- No regressions on existing tests

---

## Implementation Plan

### Phase A: Hash Chain + Follower Ack (2 commits)

**Commit A1: Hash chain on LogEntry**
- Add checksum + parent_checksum to LogEntry
- Add computeChecksum, verifyChecksum, verifyChain functions
- Leader computes checksums in onRequest
- Follower verifies in onPrepare
- View change verifies in maybeStartView
- State transfer verifies in onSendPrepare
- Tests: checksum computation, chain validation, corruption rejection

**Commit A2: Follower ack on StartView**
- onStartView sends PrepareOk for uncommitted entries (after checksum verification)
- Possible removal of resendUncommittedPrepares as primary mechanism (keep as fallback)
- Tests: follower acks on SV, leader commits after SV acks
- VOPR: target 100% pass rate

### Phase B: present_bitset (1 commit)

**Commit B1: DVC bitsets and targeted repair**
- Add present_bitset + nack_bitset to DoViewChangeMsg
- buildDvc computes bitsets
- maybeStartView uses nack_bitset for CTRL protocol
- tickRepair uses present_bitset for targeted RequestPrepare
- Tests: bitset computation, targeted repair, nack protocol with bitsets
- VOPR: no regressions

### Phase C: commit_min + commit_max (1 commit)

**Commit C1: Split commit tracking**
- Replace commit_number with commit_min + commit_max everywhere
- Update all message types
- Split advanceCommit into advanceCommitMax + advanceCommitMin
- Update view change, repair, transfer logic
- Tests: commit_max ahead of commit_min, follower commit_max from heartbeat
- VOPR: 0% safety, no regressions

### Phase D: Disk Persistence (2-3 commits)

**Commit D1: Slot-indexed journal**
- Replace log[]/log_len/logSlot with journal[]/journal_occupied/journalSlot
- O(1) lookup, no compaction
- Update ALL log access points (~30 call sites)
- Tests: all existing tests pass with new structure

**Commit D2: Disk I/O and dirty tracking**
- Add journal_dirty[], metadata_dirty flags
- Add writeJournalSlot, readJournalSlot, writeMetadata, readMetadata
- SimulatedDisk in-memory implementation for testing
- persistIfNeeded() called in tick()
- Tests: writes happen on mutations, reads match writes

**Commit D3: Crash recovery**
- recover() function: read metadata + journal, verify hash chain
- Status transitions: recovering -> view_change -> normal
- VOPR with crash faults
- Tests: crash and recover, rejoin cluster, no data loss

---

## Risk Assessment

| Change | Risk | Mitigation |
|--------|------|------------|
| Hash chain | Low - additive, doesn't change control flow | Verify checksum disabled until all paths compute it |
| Follower ack | Medium - could cause safety regression if entries change post-ack | Hash chain verification before acking |
| present_bitset | Low - optimization, doesn't change correctness | Fall back to broadcast if bitset is empty |
| commit_min/max | High - pervasive change, 50+ reference points | Incremental: rename first, split semantics second |
| Disk persistence | High - new failure mode (disk corruption, partial writes) | SimulatedDisk with fault injection in VOPR |

## Files Modified

| Phase | Files |
|-------|-------|
| A (hash chain + ack) | message.zig, consensus.zig, unit_tests.zig |
| B (present_bitset) | message.zig, consensus.zig, unit_tests.zig |
| C (commit_min/max) | message.zig, consensus.zig, unit_tests.zig, state_checker.zig, vopr.zig |
| D (disk persistence) | consensus.zig, io.zig, unit_tests.zig, vopr.zig, new: journal.zig |

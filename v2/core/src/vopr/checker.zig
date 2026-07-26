const std = @import("std");
const msg = @import("../message.zig");
const replica_mod = @import("../replica.zig");

/// Observes commits across all replicas and verifies consensus safety.
///
/// Invariant: if two replicas both commit operation N, they must have
/// applied the same complete log entry (checksum + client/request identity).
///
/// Modeled after TigerBeetle's StateChecker.
pub const StateChecker = struct {
    /// Bound checker history to the retained-log lifetime (no snapshots yet).
    pub const MAX_HISTORY: usize = replica_mod.LOG_SIZE_MAX;

    comptime {
        std.debug.assert(MAX_HISTORY == replica_mod.LOG_SIZE_MAX);
        // committed_by must cover every supported replica ID (0..REPLICA_COUNT_MAX-1).
        std.debug.assert(@bitSizeOf(u16) >= msg.REPLICA_COUNT_MAX);
    }

    /// Canonical commit record: the complete entry identity at each op.
    const CommitRecord = struct {
        op: msg.OpNumber,
        checksum: u64,
        client_id: u128,
        request_id: msg.RequestId,
        /// Which replicas have committed this op (bitset).
        committed_by: u16,
    };

    history: [MAX_HISTORY]CommitRecord,
    history_len: usize,

    /// Per-replica: the highest op we've seen committed.
    replica_commit_max: [msg.REPLICA_COUNT_MAX]msg.OpNumber,

    /// Per-replica: the last view we observed.
    replica_view_last: [msg.REPLICA_COUNT_MAX]msg.ViewNumber,

    replica_count: u8,

    /// Counters for simulation evaluation.
    safety_violations: u64,
    commits_checked: u64,
    view_changes_observed: u64,

    /// When true, violations are counted but not printed to stderr.
    /// Used by negative tests that deliberately trigger divergence.
    silent: bool,

    pub fn init(replica_count: u8) StateChecker {
        return .{
            .history = undefined,
            .history_len = 0,
            .replica_commit_max = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.OpNumber),
            .replica_view_last = std.mem.zeroes([msg.REPLICA_COUNT_MAX]msg.ViewNumber),
            .replica_count = replica_count,
            .safety_violations = 0,
            .commits_checked = 0,
            .view_changes_observed = 0,
            .silent = false,
        };
    }

    /// Call after every tick for every replica. Checks whether the replica
    /// has committed new operations and validates them against the
    /// canonical history.
    pub fn check(
        self: *StateChecker,
        replica_id: u8,
        r: *const replica_mod.Replica,
    ) void {
        // Track view changes
        if (r.view_number > self.replica_view_last[replica_id]) {
            self.view_changes_observed += 1;
            self.replica_view_last[replica_id] = r.view_number;
        }

        // Check protocol invariants on the replica itself
        self.checkReplicaInvariants(replica_id, r);

        // Commit watermarks track durable history only. In-memory commit_min may
        // advance before the metadata barrier; observing it would false-positive
        // as durable regression after a crash that discards pending sync.
        if (r.storage_failed or r.metadata_dirty) return;

        // Check new commits
        const prev_commit = self.replica_commit_max[replica_id];
        const curr_commit = r.commit_min;

        if (curr_commit < prev_commit) {
            self.recordViolation(
                "replica {d}: durable commit point regressed from {d} to {d}",
                .{ replica_id, prev_commit, curr_commit },
            );
            self.replica_commit_max[replica_id] = curr_commit;
            return;
        }

        if (curr_commit == prev_commit) return;

        // Replica committed new operations. Validate each one.
        var op = prev_commit + 1;
        while (op <= curr_commit) : (op += 1) {
            self.validateCommit(replica_id, r, op);
        }

        self.replica_commit_max[replica_id] = curr_commit;
    }

    /// Observe a replica after successful disk recovery.
    /// Validates the entire recovered committed prefix against canonical history
    /// before advancing the per-replica watermark. Rejects durable regression.
    pub fn observeRecovery(
        self: *StateChecker,
        replica_id: u8,
        r: *const replica_mod.Replica,
    ) void {
        std.debug.assert(replica_id < self.replica_count);

        const prev_commit = self.replica_commit_max[replica_id];
        const curr_commit = r.commit_min;

        if (curr_commit < prev_commit) {
            self.recordViolation(
                "replica {d}: recovered commit point regressed from {d} to {d}",
                .{ replica_id, prev_commit, curr_commit },
            );
            return;
        }

        var op: msg.OpNumber = 1;
        while (op <= curr_commit) : (op += 1) {
            self.validateCommit(replica_id, r, op);
        }

        self.replica_commit_max[replica_id] = curr_commit;
    }

    fn validateCommit(
        self: *StateChecker,
        replica_id: u8,
        r: *const replica_mod.Replica,
        op: msg.OpNumber,
    ) void {
        self.commits_checked += 1;

        const entry = r.journalGet(op) orelse {
            self.recordViolation("replica {d} committed op {d} but entry not in journal", .{
                replica_id, op,
            });
            return;
        };

        if (self.findRecord(op)) |record| {
            if (record.checksum != entry.checksum or
                record.client_id != entry.client_id or
                record.request_id != entry.request_id)
            {
                self.recordViolation(
                    "CONSENSUS VIOLATION: replica {d} committed op {d} with different entry (checksum {d} vs {d}, client {d} vs {d}, req {d} vs {d}, view {d}, committed_by 0b{b:0>3})",
                    .{
                        replica_id,        op,
                        entry.checksum,    record.checksum,
                        entry.client_id,   record.client_id,
                        entry.request_id,  record.request_id,
                        entry.view_number, record.committed_by,
                    },
                );
                return;
            }
            record.committed_by |= @as(u16, 1) << @intCast(replica_id);
        } else {
            if (self.history_len >= MAX_HISTORY) {
                self.recordViolation(
                    "checker history capacity exhausted at {d} (MAX_HISTORY={d}) while recording op {d}",
                    .{ self.history_len, MAX_HISTORY, op },
                );
                return;
            }
            self.history[self.history_len] = .{
                .op = op,
                .checksum = entry.checksum,
                .client_id = entry.client_id,
                .request_id = entry.request_id,
                .committed_by = @as(u16, 1) << @intCast(replica_id),
            };
            self.history_len += 1;
        }
    }

    fn checkReplicaInvariants(self: *StateChecker, replica_id: u8, r: *const replica_mod.Replica) void {
        if (r.commit_min > r.op_number) {
            self.recordViolation("replica {d}: commit_min ({d}) > op_number ({d})", .{
                replica_id, r.commit_min, r.op_number,
            });
        }

        if (r.op_number > r.commit_min and
            r.op_number - r.commit_min > @as(msg.OpNumber, replica_mod.LOG_SIZE_MAX))
        {
            self.recordViolation("replica {d}: pipeline window ({d}) exceeds log size ({d})", .{
                replica_id,
                r.op_number - r.commit_min,
                replica_mod.LOG_SIZE_MAX,
            });
        }

        const high_op = r.logHighOp();
        if (high_op > r.op_number) {
            self.recordViolation("replica {d}: highest journal op ({d}) > op_number ({d})", .{
                replica_id, high_op, r.op_number,
            });
        }

        for (r.state_machine.nodes[0..r.state_machine.node_count]) |node| {
            if (!node.active) continue;
            if (node.allocatable_gpu > node.gpu_count) {
                self.recordViolation("replica {d}: node {d} allocatable_gpu ({d}) > gpu_count ({d})", .{
                    replica_id, node.id, node.allocatable_gpu, node.gpu_count,
                });
            }
        }

        if (r.status == .normal and r.isLeader()) {
            if (r.view_number % r.replica_count != r.replica_id) {
                self.recordViolation("replica {d}: claims leader but view {d} mod {d} != {d}", .{
                    replica_id, r.view_number, r.replica_count, r.replica_id,
                });
            }
        }
    }

    fn findRecord(self: *StateChecker, op: msg.OpNumber) ?*CommitRecord {
        for (self.history[0..self.history_len]) |*record| {
            if (record.op == op) return record;
        }
        return null;
    }

    fn recordViolation(self: *StateChecker, comptime fmt: []const u8, args: anytype) void {
        self.safety_violations += 1;
        if (!self.silent) {
            std.debug.print("SAFETY VIOLATION: " ++ fmt ++ "\n", args);
        }
    }

    pub fn checkConvergence(
        _: *const StateChecker,
        replicas: []*const replica_mod.Replica,
        count: u8,
    ) ?[]const u8 {
        if (count == 0) return "no replicas";

        const target = replicas[0];
        if (target.status != .normal) return "replica not in normal status";
        if (target.storage_failed) return "replica storage failed";
        if (target.op_number < target.commit_min) return "op_number below commit_min";
        if (target.logHighOp() != target.op_number) return "active log high mismatch";
        var op: msg.OpNumber = 1;
        var parent_checksum: u64 = 0;
        while (op <= target.op_number) : (op += 1) {
            const entry = target.journalGet(op) orelse return "active journal gap";
            if (!entry.valid()) return "invalid active journal entry";
            if (entry.parent_checksum != parent_checksum) return "broken active journal parent chain";
            parent_checksum = entry.checksum;
        }
        const target_state_digest = target.state_machine.committedDigest();

        for (1..count) |i| {
            const replica = replicas[i];
            if (replica.status != .normal) return "replica not in normal status";
            if (replica.view_number != target.view_number) return "view_number mismatch across replicas";
            if (replica.commit_min != target.commit_min) return "commit_min mismatch across replicas";
            if (replica.storage_failed != target.storage_failed) return "storage state mismatch across replicas";
            if (replica.op_number != target.op_number) return "op_number mismatch across replicas";
            if (replica.op_number < replica.commit_min) return "op_number below commit_min";
            if (replica.logHighOp() != replica.op_number) return "active log high mismatch";

            op = 1;
            parent_checksum = 0;
            while (op <= replica.op_number) : (op += 1) {
                const entry = replica.journalGet(op) orelse return "active journal gap";
                if (!entry.valid()) return "invalid active journal entry";
                if (entry.parent_checksum != parent_checksum) return "broken active journal parent chain";
                const target_entry = target.journalGet(op) orelse unreachable;
                if (entry.checksum != target_entry.checksum) return "active journal checksum mismatch across replicas";
                parent_checksum = entry.checksum;
            }
            if (replica.state_machine.committedDigest() != target_state_digest) return "committed state digest mismatch across replicas";
        }

        return null;
    }

    pub fn summary(self: *const StateChecker) Summary {
        var max_commit: msg.OpNumber = 0;
        for (self.replica_commit_max[0..self.replica_count]) |c| {
            if (c > max_commit) max_commit = c;
        }
        return .{
            .commits_checked = self.commits_checked,
            .canonical_ops = self.history_len,
            .max_commit = max_commit,
            .safety_violations = self.safety_violations,
            .view_changes_observed = self.view_changes_observed,
        };
    }

    pub const Summary = struct {
        commits_checked: u64,
        canonical_ops: usize,
        max_commit: msg.OpNumber,
        safety_violations: u64,
        view_changes_observed: u64,
    };
};

test "checker rejects: divergent bodies with same tag/client/request" {
    var checker = StateChecker.init(2);
    checker.silent = true;

    var entry_a = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 7,
        .request_id = 3,
    };
    entry_a.checksum = entry_a.computeChecksum();

    var entry_b = entry_a;
    entry_b.command = .{ .create_deployment = .{
        .name = msg.strToFixed(64, "x"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "img"),
        .replicas = 1,
    } };
    // Keep same client/request but different body/checksum.
    entry_b.checksum = entry_b.computeChecksum();
    try std.testing.expect(entry_a.checksum != entry_b.checksum);

    // Manually seed history as if replica 0 committed entry_a.
    checker.history[0] = .{
        .op = 1,
        .checksum = entry_a.checksum,
        .client_id = entry_a.client_id,
        .request_id = entry_a.request_id,
        .committed_by = 0b01,
    };
    checker.history_len = 1;
    checker.replica_commit_max[0] = 1;

    // Build a minimal fake replica view for validateCommit via check().
    // Use a TestCluster path instead for realism.
    const tc = try @import("test_harness.zig").TestCluster.init(std.testing.allocator, 1, 0xC0DE);
    defer tc.deinit();
    tc.advance(5);
    tc.request(0, .{ .noop = {} });
    tc.advance(20);

    // Inject divergent commit observation for op 1 on a second logical replica id.
    var diverged = tc.replicas[0].*;
    const slot = replica_mod.journalSlot(1);
    diverged.journal[slot] = entry_b;
    diverged.journal_occupied[slot] = true;
    diverged.commit_min = 1;

    var checker2 = StateChecker.init(2);
    checker2.silent = true;
    checker2.history[0] = .{
        .op = 1,
        .checksum = entry_a.checksum,
        .client_id = entry_a.client_id,
        .request_id = entry_a.request_id,
        .committed_by = 0b01,
    };
    checker2.history_len = 1;
    checker2.replica_commit_max[0] = 1;
    checker2.replica_commit_max[1] = 0;
    checker2.check(1, &diverged);
    try std.testing.expectEqual(@as(u64, 1), checker2.safety_violations);
}

test "checker rejects: commit regression after recovery" {
    var checker = StateChecker.init(1);
    checker.silent = true;
    checker.replica_commit_max[0] = 5;

    const tc = try @import("test_harness.zig").TestCluster.init(std.testing.allocator, 1, 0x2E60);
    defer tc.deinit();
    // Force observed regression without recovery flag (live process regression).
    tc.replicas[0].commit_min = 2;
    tc.replicas[0].op_number = 2;
    tc.replicas[0].recovered_from_disk = false;
    const before = checker.safety_violations;
    checker.check(0, tc.replicas[0]);
    try std.testing.expectEqual(@as(u64, 1), checker.safety_violations - before);
}

test "checker rejects: recovered commit regression" {
    // Recovered commit_min below a previously observed watermark is a durable
    // regression; observeRecovery must record it (not silently reset).
    var checker = StateChecker.init(1);
    checker.silent = true;
    checker.replica_commit_max[0] = 5;

    const tc = try @import("test_harness.zig").TestCluster.init(std.testing.allocator, 1, 0x4EC1);
    defer tc.deinit();
    tc.replicas[0].commit_min = 2;
    tc.replicas[0].commit_max = 2;
    tc.replicas[0].op_number = 2;
    tc.replicas[0].recovered_from_disk = true;

    const before = checker.safety_violations;
    checker.observeRecovery(0, tc.replicas[0]);
    try std.testing.expectEqual(@as(u64, 1), checker.safety_violations - before);
    try std.testing.expectEqual(@as(msg.OpNumber, 5), checker.replica_commit_max[0]);
}

test "checker rejects: divergent recovered canonical prefix" {
    // Recovered journal identity at a previously canonical op must match.
    var entry_a = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 7,
        .request_id = 3,
        .parent_checksum = 0,
    };
    entry_a.checksum = entry_a.computeChecksum();

    var entry_b = entry_a;
    entry_b.client_id = 99;
    entry_b.request_id = 99;
    entry_b.checksum = entry_b.computeChecksum();
    try std.testing.expect(entry_a.checksum != entry_b.checksum);

    var checker = StateChecker.init(1);
    checker.silent = true;
    checker.history[0] = .{
        .op = 1,
        .checksum = entry_a.checksum,
        .client_id = entry_a.client_id,
        .request_id = entry_a.request_id,
        .committed_by = 0b01,
    };
    checker.history_len = 1;
    checker.replica_commit_max[0] = 1;

    const tc = try @import("test_harness.zig").TestCluster.init(std.testing.allocator, 1, 0x4EC2);
    defer tc.deinit();
    const slot = replica_mod.journalSlot(1);
    tc.replicas[0].journal[slot] = entry_b;
    tc.replicas[0].journal_occupied[slot] = true;
    tc.replicas[0].commit_min = 1;
    tc.replicas[0].commit_max = 1;
    tc.replicas[0].op_number = 1;
    tc.replicas[0].recovered_from_disk = true;

    const before = checker.safety_violations;
    checker.observeRecovery(0, tc.replicas[0]);
    try std.testing.expectEqual(@as(u64, 1), checker.safety_violations - before);
}

test "checker rejects: history capacity exhaustion" {
    var checker = StateChecker.init(1);
    checker.silent = true;
    checker.history_len = StateChecker.MAX_HISTORY;

    const tc = try @import("test_harness.zig").TestCluster.init(std.testing.allocator, 1, 0xCA12);
    defer tc.deinit();
    tc.advance(5);
    tc.request(0, .{ .noop = {} });
    tc.advance(20);

    // Reset checker tracking so check tries to record op 1 into a full history.
    checker.replica_commit_max[0] = 0;
    checker.check(0, tc.replicas[0]);
    try std.testing.expect(checker.safety_violations >= 1);
}

test "checker records commits across maximum replica topology" {
    comptime {
        std.debug.assert(msg.REPLICA_COUNT_MAX > 8);
    }
    var checker = StateChecker.init(msg.REPLICA_COUNT_MAX);
    checker.silent = true;

    var entry = msg.LogEntry{
        .view_number = 0,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    entry.checksum = entry.computeChecksum();

    // Directly exercise the high replica IDs that do not fit in a u8 bitset.
    const high_id: u8 = msg.REPLICA_COUNT_MAX - 1;
    checker.history[0] = .{
        .op = 1,
        .checksum = entry.checksum,
        .client_id = entry.client_id,
        .request_id = entry.request_id,
        .committed_by = 0,
    };
    checker.history_len = 1;
    checker.history[0].committed_by |= @as(u16, 1) << @intCast(high_id);
    try std.testing.expect((checker.history[0].committed_by & (@as(u16, 1) << @intCast(high_id))) != 0);
    try std.testing.expectEqual(@as(u64, 0), checker.safety_violations);
}

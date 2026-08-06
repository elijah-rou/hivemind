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
    }

    /// Canonical commit record: the complete entry identity at each op.
    const CommitRecord = struct {
        op: msg.OpNumber,
        checksum: u64,
        client_id: u128,
        request_id: msg.RequestId,
        /// Which replicas have committed this op (bitset).
        committed_by: u8,
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
        // advance before the metadata barrier.
        if (r.storage_failed or r.metadata_dirty) return;

        const prev_commit = self.replica_commit_max[replica_id];
        const curr_commit = r.commit_min;

        if (curr_commit < prev_commit) {
            self.recordViolation(
                "replica {d}: durable commit point regressed from {d} to {d}",
                .{ replica_id, prev_commit, curr_commit },
            );
            return;
        }

        if (curr_commit == prev_commit) return;

        var op = prev_commit + 1;
        while (op <= curr_commit) : (op += 1) {
            self.validateCommit(replica_id, r, op);
        }

        self.replica_commit_max[replica_id] = curr_commit;
    }

    /// Validate recovered durable history before advancing the process watermark.
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
                        replica_id,          op,
                        entry.checksum,      record.checksum,
                        entry.client_id,     record.client_id,
                        entry.request_id,    record.request_id,
                        entry.view_number,
                        record.committed_by,
                    },
                );
                return;
            }
            record.committed_by |= @as(u8, 1) << @intCast(replica_id);
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
                .committed_by = @as(u8, 1) << @intCast(replica_id),
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

        const target_commit = replicas[0].commit_min;
        for (1..count) |i| {
            if (replicas[i].commit_min != target_commit) {
                return "commit_min mismatch across replicas";
            }
        }

        for (0..count) |i| {
            if (replicas[i].status != .normal) {
                return "replica not in normal status";
            }
        }

        const target_view = replicas[0].view_number;
        for (1..count) |i| {
            if (replicas[i].view_number != target_view) {
                return "view_number mismatch across replicas";
            }
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

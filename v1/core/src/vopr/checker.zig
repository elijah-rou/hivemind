const std = @import("std");
const msg = @import("../message.zig");
const replica_mod = @import("../replica.zig");

/// Observes commits across all replicas and verifies consensus safety.
///
/// Invariant: if two replicas both commit operation N, they must have
/// applied the same command. We track a canonical commit history --
/// first replica to commit op N establishes truth, all others must match.
///
/// Modeled after TigerBeetle's StateChecker.
pub const StateChecker = struct {
    pub const MAX_HISTORY: usize = 4096;

    /// Canonical commit record: the command that was committed at each op.
    const CommitRecord = struct {
        op: msg.OpNumber,
        command_tag: u8,
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

        // Check new commits
        const prev_commit = self.replica_commit_max[replica_id];
        const curr_commit = r.commit_min;

        if (curr_commit <= prev_commit) return;

        // Replica committed new operations. Validate each one.
        var op = prev_commit + 1;
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

        // Get the journal entry for this op
        const entry = r.journalGet(op) orelse {
            self.recordViolation("replica {d} committed op {d} but entry not in journal", .{
                replica_id, op,
            });
            return;
        };
        const command_tag: u8 = @intFromEnum(std.meta.activeTag(entry.command));

        // Check against canonical history
        if (self.findRecord(op)) |record| {
            // Another replica already committed this op. Must match.
            if (record.command_tag != command_tag or
                record.client_id != entry.client_id or
                record.request_id != entry.request_id)
            {
                self.recordViolation(
                    "CONSENSUS VIOLATION: replica {d} committed op {d} with different command (tag {d} vs {d}, client {d} vs {d}, req {d} vs {d}, view {d}, committed_by 0b{b:0>3})",
                    .{
                        replica_id, op,
                        command_tag,         record.command_tag,
                        entry.client_id,     record.client_id,
                        entry.request_id,    record.request_id,
                        entry.view_number,
                        record.committed_by,
                    },
                );
                return;
            }
            // Mark this replica as having committed
            record.committed_by |= @as(u8, 1) << @intCast(replica_id);
        } else {
            // First replica to commit this op. Establish canonical record.
            if (self.history_len >= MAX_HISTORY) {
                return;
            }
            self.history[self.history_len] = .{
                .op = op,
                .command_tag = command_tag,
                .client_id = entry.client_id,
                .request_id = entry.request_id,
                .committed_by = @as(u8, 1) << @intCast(replica_id),
            };
            self.history_len += 1;
        }
    }

    /// Check per-replica protocol invariants.
    fn checkReplicaInvariants(self: *StateChecker, replica_id: u8, r: *const replica_mod.Replica) void {
        // commit_min must never exceed op_number
        if (r.commit_min > r.op_number) {
            self.recordViolation("replica {d}: commit_min ({d}) > op_number ({d})", .{
                replica_id, r.commit_min, r.op_number,
            });
        }

        // Pipeline window must fit in circular journal.
        // Bound is over own commit_min -- retention_floor is informational only.
        if (r.op_number > r.commit_min and
            r.op_number - r.commit_min > @as(msg.OpNumber, replica_mod.LOG_SIZE_MAX))
        {
            self.recordViolation("replica {d}: pipeline window ({d}) exceeds log size ({d})", .{
                replica_id,
                r.op_number - r.commit_min,
                replica_mod.LOG_SIZE_MAX,
            });
        }

        // Journal's highest op must not exceed op_number.
        const high_op = r.logHighOp();
        if (high_op > r.op_number) {
            self.recordViolation("replica {d}: highest journal op ({d}) > op_number ({d})", .{
                replica_id, high_op, r.op_number,
            });
        }

        // GPU capacity accounting: allocated must never exceed total
        for (r.state_machine.nodes[0..r.state_machine.node_count]) |node| {
            if (!node.active) continue;
            if (node.allocatable_gpu > node.gpu_count) {
                self.recordViolation("replica {d}: node {d} allocatable_gpu ({d}) > gpu_count ({d})", .{
                    replica_id, node.id, node.allocatable_gpu, node.gpu_count,
                });
            }
        }

        // Leader in normal status must have view_number % replica_count == replica_id
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

    // -----------------------------------------------------------------------
    // Liveness evaluation
    // -----------------------------------------------------------------------

    /// Check whether all (non-partitioned) replicas have converged to the
    /// same commit point. Returns null if converged, or a reason string.
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

        return null; // converged
    }

    // -----------------------------------------------------------------------
    // Summary
    // -----------------------------------------------------------------------

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

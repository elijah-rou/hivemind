const std = @import("std");
const msg = @import("message.zig");

pub const LOG_SIZE_MAX: usize = msg.LOG_BITSET_BITS;
pub const MAX_CANDIDATE_BYTES: usize = LOG_SIZE_MAX * (@sizeOf(msg.LogEntry) + @sizeOf(bool));

comptime {
    std.debug.assert(LOG_SIZE_MAX == 1024);
    std.debug.assert(MAX_CANDIDATE_BYTES > 6 * 1024 * 1024);
    std.debug.assert(MAX_CANDIDATE_BYTES < 7 * 1024 * 1024);
}

pub const ViewSelectionPhase = enum {
    idle,
    collecting_dvc,
    fetching_candidate,
    candidate_complete,
    persisting_start_view,
};

pub const PendingStartViewRole = enum { none, leader, follower };

/// Compact publication record. StartView is reconstructed from the installed log.
pub const PendingStartView = struct {
    active: bool = false,
    role: PendingStartViewRole = .none,
    source_replica: u8 = 0,
    target_view: msg.ViewNumber = 0,
    source_last_normal_view: msg.ViewNumber = 0,
    tip_checksum: u64 = 0,
    op_number: msg.OpNumber = 0,
    commit_min: msg.OpNumber = 0,
    retention_floor: msg.OpNumber = 0,
    last_normal_view: msg.ViewNumber = 0,
};

comptime {
    std.debug.assert(@sizeOf(PendingStartView) <= 80);
    std.debug.assert(@sizeOf(PendingStartView) < @sizeOf(msg.StartViewMsg));
}

pub const Metadata = struct {
    source_replica: u8,
    target_view: msg.ViewNumber,
    source_last_normal_view: msg.ViewNumber,
    base_op: msg.OpNumber,
    tip_op: msg.OpNumber,
    tip_checksum: u64,
    commit_bound: msg.OpNumber,
    deadline_tick: u64,
};

pub const ViewChangeCandidate = struct {
    allocator: ?std.mem.Allocator = null,
    entries: []msg.LogEntry = &.{},
    present: []bool = &.{},
    metadata: Metadata = .{
        .source_replica = 0,
        .target_view = 0,
        .source_last_normal_view = 0,
        .base_op = 0,
        .tip_op = 0,
        .tip_checksum = 0,
        .commit_bound = 0,
        .deadline_tick = 0,
    },
    phase: ViewSelectionPhase = .idle,
    present_count: usize = 0,

    pub fn allocate(allocator: std.mem.Allocator, metadata: Metadata) !ViewChangeCandidate {
        if (metadata.base_op == 0) return error.InvalidRange;
        if (metadata.tip_op < metadata.base_op) return error.InvalidRange;
        if (metadata.tip_op > LOG_SIZE_MAX) return error.RangeTooLarge;
        if (metadata.tip_checksum == 0) return error.InvalidTip;
        if (metadata.commit_bound > metadata.tip_op) return error.InvalidCommitBound;

        const range_minus_one = try std.math.sub(msg.OpNumber, metadata.tip_op, metadata.base_op);
        const entry_count_u64 = try std.math.add(msg.OpNumber, range_minus_one, 1);
        if (entry_count_u64 > LOG_SIZE_MAX) return error.RangeTooLarge;
        const entry_count: usize = @intCast(entry_count_u64);

        const entries = try allocator.alloc(msg.LogEntry, entry_count);
        errdefer allocator.free(entries);
        const present = try allocator.alloc(bool, entry_count);
        @memset(present, false);

        return .{
            .allocator = allocator,
            .entries = entries,
            .present = present,
            .metadata = metadata,
            .phase = .fetching_candidate,
            .present_count = 0,
        };
    }

    pub fn add(self: *ViewChangeCandidate, entry: msg.LogEntry) !void {
        if (self.phase != .fetching_candidate and self.phase != .candidate_complete) return error.InvalidPhase;
        if (!entry.valid()) return error.InvalidEntry;
        if (entry.op_number < self.metadata.base_op or entry.op_number > self.metadata.tip_op) return error.OutOfRange;
        const index: usize = @intCast(entry.op_number - self.metadata.base_op);
        std.debug.assert(index < self.entries.len);
        if (self.present[index]) {
            if (self.entries[index].checksum != entry.checksum) return error.IdentityConflict;
            return;
        }
        self.entries[index] = entry;
        self.present[index] = true;
        self.present_count += 1;
        std.debug.assert(self.present_count <= self.entries.len);
        if (self.present_count == self.entries.len) self.phase = .candidate_complete;
    }

    pub fn complete(self: *const ViewChangeCandidate) bool {
        return self.entries.len > 0 and self.present_count == self.entries.len;
    }

    pub fn validate(self: *const ViewChangeCandidate, committed_op: msg.OpNumber, committed_checksum: u64) !void {
        if (!self.complete()) return error.Incomplete;
        if (self.metadata.base_op != committed_op + 1) return error.InvalidCommittedOverlap;
        if (self.metadata.commit_bound > self.metadata.tip_op) return error.InvalidCommitBound;

        var parent_checksum = if (committed_op == 0) @as(u64, 0) else committed_checksum;
        for (self.entries, 0..) |entry, index| {
            const expected_op = self.metadata.base_op + @as(msg.OpNumber, @intCast(index));
            if (!self.present[index]) return error.Incomplete;
            if (entry.op_number != expected_op) return error.InvalidSequence;
            if (!entry.valid()) return error.InvalidEntry;
            if (entry.parent_checksum != parent_checksum) return error.InvalidParent;
            parent_checksum = entry.checksum;
        }
        if (parent_checksum != self.metadata.tip_checksum) return error.InvalidTip;
    }

    pub fn reset(self: *ViewChangeCandidate) void {
        const allocator = self.allocator orelse {
            self.* = .{};
            return;
        };
        if (self.entries.len > 0) allocator.free(self.entries);
        if (self.present.len > 0) allocator.free(self.present);
        self.* = .{ .allocator = allocator };
    }

    pub fn deinit(self: *ViewChangeCandidate) void {
        self.reset();
        self.allocator = null;
    }
};

fn testEntry(op: msg.OpNumber, parent_checksum: u64, request_id: msg.RequestId) msg.LogEntry {
    var entry = msg.LogEntry{
        .view_number = 3,
        .op_number = op,
        .command = .{ .noop = {} },
        .client_id = 7,
        .request_id = request_id,
        .parent_checksum = parent_checksum,
    };
    entry.checksum = entry.computeChecksum();
    return entry;
}

fn testMetadata(base_op: msg.OpNumber, tip_op: msg.OpNumber, tip_checksum: u64) Metadata {
    return .{
        .source_replica = 2,
        .target_view = 4,
        .source_last_normal_view = 3,
        .base_op = base_op,
        .tip_op = tip_op,
        .tip_checksum = tip_checksum,
        .commit_bound = if (base_op == 0) 0 else base_op - 1,
        .deadline_tick = 100,
    };
}

test "candidate maximum allocation byte bound is exact and bounded" {
    try std.testing.expectEqual(LOG_SIZE_MAX * (@sizeOf(msg.LogEntry) + @sizeOf(bool)), MAX_CANDIDATE_BYTES);
    try std.testing.expect(MAX_CANDIDATE_BYTES > 6 * 1024 * 1024);
    try std.testing.expect(MAX_CANDIDATE_BYTES < 7 * 1024 * 1024);

    const tip = testEntry(LOG_SIZE_MAX, 0, LOG_SIZE_MAX);
    var candidate = try ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(1, LOG_SIZE_MAX, tip.checksum));
    defer candidate.deinit();
    try std.testing.expectEqual(@as(usize, LOG_SIZE_MAX), candidate.entries.len);
    try std.testing.expectEqual(@as(usize, LOG_SIZE_MAX), candidate.present.len);
}

test "candidate rejects zero reversed oversized and overflow ranges" {
    try std.testing.expectError(error.InvalidRange, ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(0, 1, 1)));
    try std.testing.expectError(error.InvalidRange, ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(2, 1, 1)));
    try std.testing.expectError(error.RangeTooLarge, ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(1, LOG_SIZE_MAX + 1, 1)));
    try std.testing.expectError(error.RangeTooLarge, ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(1, std.math.maxInt(msg.OpNumber), 1)));
    try std.testing.expectError(error.InvalidRange, ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(std.math.maxInt(msg.OpNumber), 0, 1)));
}

test "candidate allocation failure leaves no ownership" {
    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, ViewChangeCandidate.allocate(fixed.allocator(), testMetadata(1, 1, 1)));
}

test "candidate add rejects range invalid identity and duplicate conflict" {
    var entry = testEntry(1, 0, 1);
    var candidate = try ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(1, 1, entry.checksum));
    defer candidate.deinit();
    try std.testing.expectError(error.OutOfRange, candidate.add(testEntry(2, entry.checksum, 2)));
    var invalid_checksum = entry;
    invalid_checksum.checksum ^= 1;
    try std.testing.expectError(error.InvalidEntry, candidate.add(invalid_checksum));
    try candidate.add(entry);
    try candidate.add(entry);
    entry.request_id = 9;
    entry.checksum = entry.computeChecksum();
    try std.testing.expectError(error.IdentityConflict, candidate.add(entry));
}

test "candidate validates full exact parent chain and tip" {
    const first = testEntry(2, 0xAA, 1);
    const second = testEntry(3, first.checksum, 2);
    var candidate = try ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(2, 3, second.checksum));
    defer candidate.deinit();
    candidate.metadata.commit_bound = 1;
    try candidate.add(second);
    try std.testing.expect(!candidate.complete());
    try std.testing.expectError(error.Incomplete, candidate.validate(1, 0xAA));
    try candidate.add(first);
    try std.testing.expect(candidate.complete());
    try candidate.validate(1, 0xAA);
}

test "follower candidate permits leader commit below durable follower anchor" {
    const first = testEntry(3, 0xAA, 3);
    const second = testEntry(4, first.checksum, 4);
    var metadata = testMetadata(3, 4, second.checksum);
    metadata.commit_bound = 1;
    var candidate = try ViewChangeCandidate.allocate(std.testing.allocator, metadata);
    defer candidate.deinit();
    try candidate.add(first);
    try candidate.add(second);
    try candidate.validate(2, 0xAA);
}

test "candidate detects missing parent and wrong tip" {
    const first = testEntry(1, 0, 1);
    const second = testEntry(2, 0xBAD, 2);
    var candidate = try ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(1, 2, second.checksum));
    defer candidate.deinit();
    try candidate.add(first);
    try candidate.add(second);
    try std.testing.expectError(error.InvalidParent, candidate.validate(0, 0));
    const valid_second = testEntry(2, first.checksum, 2);
    candidate.entries[1] = valid_second;
    candidate.metadata.tip_checksum = valid_second.checksum ^ 1;
    try std.testing.expectError(error.InvalidTip, candidate.validate(0, 0));
}

test "candidate reset and deinit release allocations" {
    const entry = testEntry(1, 0, 1);
    var candidate = try ViewChangeCandidate.allocate(std.testing.allocator, testMetadata(1, 1, entry.checksum));
    try candidate.add(entry);
    candidate.reset();
    try std.testing.expectEqual(ViewSelectionPhase.idle, candidate.phase);
    try std.testing.expectEqual(@as(usize, 0), candidate.entries.len);
    try std.testing.expectEqual(@as(usize, 0), candidate.present.len);
    candidate.deinit();
    try std.testing.expect(candidate.allocator == null);
}

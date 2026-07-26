const std = @import("std");
const msg = @import("../message.zig");
const replica_mod = @import("../replica.zig");

/// Structured trace event for JSON output.
pub const TraceEvent = struct {
    tick: u64,
    kind: EventKind,
};

pub const EventKind = union(enum) {
    init: struct { replicas: u8, seed: u64 },
    partition: struct { replica: u8 },
    partition_asymmetric: struct { from: u8, to: u8 },
    heal: void,
    crash: struct { replica: u8, pre_view: u64, pre_op: u64, pre_commit: u64, post_view: u64, post_op: u64, post_commit: u64 },
    pause: struct { replica: u8, duration: u16 },
    unpause: struct { replica: u8 },
    drop_next: struct { count: u64, id: u64, from: u8, to: u8, tag: u8 },
    barrier_cut: struct { replica: u8, id: u64, kind: replica_mod.BarrierKind, point: replica_mod.BarrierCutPoint },
    request: struct { leader: u8, request_num: u32 },
    state: [msg.REPLICA_COUNT_MAX]ReplicaSnapshot,
    violation: struct { message_buf: [256]u8, message_len: usize, replica: u8 },
    journal: JournalSnapshot,
    converged: struct { tick: u64 },
};

pub const ReplicaSnapshot = struct {
    id: u8 = 0,
    status: u8 = 0, // 0=N, 1=V, 2=R
    view: u64 = 0,
    op: u64 = 0,
    commit: u64 = 0,
    is_leader: bool = false,
    paused: bool = false,
    barrier_cut_count: u64 = 0,
    last_barrier_cut_id: u64 = 0,
    active: bool = false,
};

pub const JournalSnapshot = struct {
    replica: u8,
    op: u64,
    commit: u64,
    // Bitset: which ops around commit_min are present
    present_start: u64,
    present_bits: [32]u8, // 256 bits = 256 ops from present_start
};

pub const MAX_EVENTS = 16384;
pub const MAX_TRACE_COLLECTOR_BYTES: usize = 16 * 1024 * 1024;

pub const TraceCollector = struct {
    events: [MAX_EVENTS]TraceEvent,
    count: usize,
    replica_count: u8,

    pub fn initInPlace(self: *TraceCollector, replica_count: u8) void {
        std.debug.assert(replica_count > 0);
        std.debug.assert(replica_count <= msg.REPLICA_COUNT_MAX);
        self.count = 0;
        self.replica_count = replica_count;
    }

    pub fn deinit(self: *TraceCollector) void {
        self.count = 0;
    }

    pub fn push(self: *TraceCollector, event: TraceEvent) void {
        if (self.count >= MAX_EVENTS) return;
        self.events[self.count] = event;
        self.count += 1;
    }

    pub fn addInit(self: *TraceCollector, replicas: u8, seed: u64) void {
        self.push(.{ .tick = 0, .kind = .{ .init = .{ .replicas = replicas, .seed = seed } } });
    }

    pub fn addPartition(self: *TraceCollector, tick: u64, replica: u8) void {
        self.push(.{ .tick = tick, .kind = .{ .partition = .{ .replica = replica } } });
    }

    pub fn addHeal(self: *TraceCollector, tick: u64) void {
        self.push(.{ .tick = tick, .kind = .{ .heal = {} } });
    }

    pub fn addCrash(self: *TraceCollector, tick: u64, replica: u8, r: *const replica_mod.Replica, post_r: *const replica_mod.Replica) void {
        self.push(.{ .tick = tick, .kind = .{ .crash = .{
            .replica = replica,
            .pre_view = r.view_number,
            .pre_op = r.op_number,
            .pre_commit = r.commit_min,
            .post_view = post_r.view_number,
            .post_op = post_r.op_number,
            .post_commit = post_r.commit_min,
        } } });
    }

    pub fn addDropNext(self: *TraceCollector, tick: u64, count: u64, id: u64, from: u8, to: u8, tag: u8) void {
        std.debug.assert(count > 0);
        std.debug.assert(id > 0);
        self.push(.{ .tick = tick, .kind = .{ .drop_next = .{ .count = count, .id = id, .from = from, .to = to, .tag = tag } } });
    }

    pub fn addBarrierCut(self: *TraceCollector, tick: u64, replica: u8, cut: replica_mod.BarrierCut) void {
        std.debug.assert(cut.id > 0);
        self.push(.{ .tick = tick, .kind = .{ .barrier_cut = .{
            .replica = replica,
            .id = cut.id,
            .kind = cut.kind,
            .point = cut.point,
        } } });
    }

    pub fn addRequest(self: *TraceCollector, tick: u64, leader: u8, request_num: u32) void {
        self.push(.{ .tick = tick, .kind = .{ .request = .{ .leader = leader, .request_num = request_num } } });
    }

    pub fn addState(self: *TraceCollector, tick: u64, replicas: []const *replica_mod.Replica, paused: []const bool, count: u8) void {
        std.debug.assert(count > 0);
        std.debug.assert(count <= msg.REPLICA_COUNT_MAX);
        std.debug.assert(count <= replicas.len);
        std.debug.assert(count <= paused.len);
        var snap: [msg.REPLICA_COUNT_MAX]ReplicaSnapshot = std.mem.zeroes([msg.REPLICA_COUNT_MAX]ReplicaSnapshot);
        for (0..count) |i| {
            const r = replicas[i];
            snap[i] = .{
                .id = @intCast(i),
                .status = @intFromEnum(r.status),
                .view = r.view_number,
                .op = r.op_number,
                .commit = r.commit_min,
                .is_leader = r.isLeader() and r.status == .normal,
                .paused = paused[i],
                .barrier_cut_count = r.barrier_cut_count,
                .last_barrier_cut_id = r.last_barrier_cut_id,
                .active = true,
            };
        }
        self.push(.{ .tick = tick, .kind = .{ .state = snap } });
    }

    pub fn addViolation(self: *TraceCollector, tick: u64, replica: u8, message: []const u8) void {
        var buf: [256]u8 = std.mem.zeroes([256]u8);
        const len = @min(message.len, buf.len);
        @memcpy(buf[0..len], message[0..len]);
        self.push(.{ .tick = tick, .kind = .{ .violation = .{ .message_buf = buf, .message_len = len, .replica = replica } } });
    }

    pub fn addJournal(self: *TraceCollector, tick: u64, replica: u8, r: *const replica_mod.Replica) void {
        var snap = JournalSnapshot{
            .replica = replica,
            .op = r.op_number,
            .commit = r.commit_min,
            .present_start = if (r.commit_min > 128) r.commit_min - 128 else 1,
            .present_bits = std.mem.zeroes([32]u8),
        };
        // Fill bitset: bit i = 1 if op (present_start + i) is in journal
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const op = snap.present_start + i;
            if (op > r.op_number + 5) break;
            if (op == 0) continue;
            if (r.journalGet(op) != null) {
                snap.present_bits[i / 8] |= @as(u8, 1) << @intCast(i % 8);
            }
        }
        self.push(.{ .tick = tick, .kind = .{ .journal = snap } });
    }

    /// Write all events as JSONL to a file descriptor.
    pub fn writeJsonl(self: *const TraceCollector, fd: c_int) void {
        for (self.events[0..self.count]) |event| {
            var buf: [2048]u8 = undefined;
            const line = formatEvent(&buf, event) orelse continue;
            _ = std.c.write(fd, line.ptr, line.len);
        }
    }
};

comptime {
    std.debug.assert(@sizeOf(TraceCollector) > 1024 * 1024);
    std.debug.assert(@sizeOf(TraceCollector) <= MAX_TRACE_COLLECTOR_BYTES);
}

test "multi-MiB trace collector supports explicit heap lifetime" {
    const collector = try std.testing.allocator.create(TraceCollector);
    collector.initInPlace(5);
    defer {
        collector.deinit();
        std.testing.allocator.destroy(collector);
    }

    try std.testing.expect(@sizeOf(TraceCollector) > 1024 * 1024);
    try std.testing.expect(@sizeOf(TraceCollector) <= MAX_TRACE_COLLECTOR_BYTES);
    try std.testing.expectEqual(@as(usize, 0), collector.count);
    collector.addInit(5, 7);
    try std.testing.expectEqual(@as(usize, 1), collector.count);
}

test "state trace exposes paused replicas" {
    var snapshots = std.mem.zeroes([msg.REPLICA_COUNT_MAX]ReplicaSnapshot);
    snapshots[0] = .{ .id = 0, .active = true, .paused = true };
    var buf: [2048]u8 = undefined;
    const line = formatEvent(&buf, .{ .tick = 7, .kind = .{ .state = snapshots } }).?;
    try std.testing.expect(std.mem.indexOf(u8, line, "\"paused\":true") != null);
}

test "state trace supports the maximum replica topology" {
    var snapshots = std.mem.zeroes([msg.REPLICA_COUNT_MAX]ReplicaSnapshot);
    snapshots[msg.REPLICA_COUNT_MAX - 1] = .{
        .id = msg.REPLICA_COUNT_MAX - 1,
        .active = true,
    };
    try std.testing.expect(snapshots[msg.REPLICA_COUNT_MAX - 1].active);
    try std.testing.expectEqual(@as(u8, msg.REPLICA_COUNT_MAX - 1), snapshots[msg.REPLICA_COUNT_MAX - 1].id);
}

fn formatEvent(buf: *[2048]u8, event: TraceEvent) ?[]const u8 {
    return switch (event.kind) {
        .init => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"init\",\"replicas\":{d},\"seed\":{d}}}\n", .{ event.tick, e.replicas, e.seed }) catch null,
        .partition => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"partition\",\"replica\":{d}}}\n", .{ event.tick, e.replica }) catch null,
        .partition_asymmetric => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"partition_asym\",\"from\":{d},\"to\":{d}}}\n", .{ event.tick, e.from, e.to }) catch null,
        .heal => std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"heal\"}}\n", .{event.tick}) catch null,
        .crash => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"crash\",\"replica\":{d},\"pre\":{{\"view\":{d},\"op\":{d},\"commit\":{d}}},\"post\":{{\"view\":{d},\"op\":{d},\"commit\":{d}}}}}\n", .{
            event.tick, e.replica, e.pre_view, e.pre_op, e.pre_commit, e.post_view, e.post_op, e.post_commit,
        }) catch null,
        .pause => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"pause\",\"replica\":{d},\"duration\":{d}}}\n", .{ event.tick, e.replica, e.duration }) catch null,
        .unpause => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"unpause\",\"replica\":{d}}}\n", .{ event.tick, e.replica }) catch null,
        .drop_next => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"drop_next\",\"count\":{d},\"id\":{d},\"from\":{d},\"to\":{d},\"tag\":{d}}}\n", .{ event.tick, e.count, e.id, e.from, e.to, e.tag }) catch null,
        .barrier_cut => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"barrier_cut\",\"replica\":{d},\"id\":{d},\"kind\":\"{s}\",\"point\":\"{s}\"}}\n", .{ event.tick, e.replica, e.id, @tagName(e.kind), @tagName(e.point) }) catch null,
        .request => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"request\",\"leader\":{d},\"num\":{d}}}\n", .{ event.tick, e.leader, e.request_num }) catch null,
        .state => |snaps| blk: {
            var pos: usize = 0;
            const header = std.fmt.bufPrint(buf[pos..], "{{\"tick\":{d},\"type\":\"state\",\"replicas\":[", .{event.tick}) catch break :blk null;
            pos += header.len;
            var first = true;
            for (&snaps) |*s| {
                if (!s.active) continue;
                if (!first) {
                    buf[pos] = ',';
                    pos += 1;
                }
                first = false;
                const status_str: []const u8 = switch (s.status) {
                    0 => "N",
                    1 => "V",
                    2 => "R",
                    else => "?",
                };
                const entry = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d},\"status\":\"{s}\",\"view\":{d},\"op\":{d},\"commit\":{d},\"leader\":{},\"paused\":{},\"barrier_cuts\":{d},\"last_barrier_cut_id\":{d}}}", .{
                    s.id, status_str, s.view, s.op, s.commit, s.is_leader, s.paused, s.barrier_cut_count, s.last_barrier_cut_id,
                }) catch break :blk null;
                pos += entry.len;
            }
            const footer = std.fmt.bufPrint(buf[pos..], "]}}\n", .{}) catch break :blk null;
            pos += footer.len;
            break :blk buf[0..pos];
        },
        .violation => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"violation\",\"replica\":{d},\"message\":\"{s}\"}}\n", .{
            event.tick, e.replica, e.message_buf[0..e.message_len],
        }) catch null,
        .journal => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"journal\",\"replica\":{d},\"op\":{d},\"commit\":{d}}}\n", .{
            event.tick, e.replica, e.op, e.commit,
        }) catch null,
        .converged => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"converged\"}}\n", .{e.tick}) catch null,
    };
}

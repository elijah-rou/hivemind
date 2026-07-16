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
    request: struct { leader: u8, request_num: u32 },
    state: [8]ReplicaSnapshot,
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

pub const TraceCollector = struct {
    events: [MAX_EVENTS]TraceEvent,
    count: usize,
    replica_count: u8,

    pub fn init(replica_count: u8) TraceCollector {
        return .{
            .events = undefined,
            .count = 0,
            .replica_count = replica_count,
        };
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

    pub fn addRequest(self: *TraceCollector, tick: u64, leader: u8, request_num: u32) void {
        self.push(.{ .tick = tick, .kind = .{ .request = .{ .leader = leader, .request_num = request_num } } });
    }

    pub fn addState(self: *TraceCollector, tick: u64, replicas: []const *replica_mod.Replica, count: u8) void {
        var snap: [8]ReplicaSnapshot = std.mem.zeroes([8]ReplicaSnapshot);
        for (0..count) |i| {
            const r = replicas[i];
            snap[i] = .{
                .id = @intCast(i),
                .status = @intFromEnum(r.status),
                .view = r.view_number,
                .op = r.op_number,
                .commit = r.commit_min,
                .is_leader = r.isLeader() and r.status == .normal,
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
        .request => |e| std.fmt.bufPrint(buf, "{{\"tick\":{d},\"type\":\"request\",\"leader\":{d},\"num\":{d}}}\n", .{ event.tick, e.leader, e.request_num }) catch null,
        .state => |snaps| blk: {
            var pos: usize = 0;
            const header = std.fmt.bufPrint(buf[pos..], "{{\"tick\":{d},\"type\":\"state\",\"replicas\":[", .{event.tick}) catch break :blk null;
            pos += header.len;
            var first = true;
            for (&snaps) |*s| {
                if (!s.active) continue;
                if (!first) { buf[pos] = ','; pos += 1; }
                first = false;
                const status_str: []const u8 = switch (s.status) { 0 => "N", 1 => "V", 2 => "R", else => "?" };
                const entry = std.fmt.bufPrint(buf[pos..], "{{\"id\":{d},\"status\":\"{s}\",\"view\":{d},\"op\":{d},\"commit\":{d},\"leader\":{}}}", .{
                    s.id, status_str, s.view, s.op, s.commit, s.is_leader,
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

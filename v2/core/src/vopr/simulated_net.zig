const std = @import("std");
const msg = @import("../message.zig");
const prng_mod = @import("../prng.zig");
const Prng = prng_mod.Prng;
const Ratio = prng_mod.Ratio;

pub const MESSAGE_SIZE_MAX: usize = 65536;

pub const RecvResult = struct {
    from: u8,
    len: usize,
};

// ---------------------------------------------------------------------------
// Simulated network with configurable delays, drops, and partitions.
// Used by SimulatedIo (simulated_io.zig) to provide message-level networking.
// ---------------------------------------------------------------------------

const QUEUE_CAPACITY: usize = 64;

const PendingMessage = struct {
    data: [MESSAGE_SIZE_MAX]u8,
    len: usize,
    from: u8,
    deliver_at_tick: i64,
};

pub const MessageQueue = struct {
    items: [QUEUE_CAPACITY]PendingMessage,
    count: usize,

    pub fn init() MessageQueue {
        return .{ .items = undefined, .count = 0 };
    }

    pub fn push(self: *MessageQueue, pending: PendingMessage) void {
        if (self.count >= QUEUE_CAPACITY) return;
        self.items[self.count] = pending;
        self.count += 1;
    }

    pub fn popReady(self: *MessageQueue, now: i64, buf: []u8) ?RecvResult {
        return self.popReadyExcluding(now, buf, &[_]bool{});
    }

    pub fn popReadyExcluding(self: *MessageQueue, now: i64, buf: []u8, excluded_from: []const bool) ?RecvResult {
        for (self.items[0..self.count], 0..) |*item, i| {
            if (item.deliver_at_tick > now) continue;
            if (item.from < excluded_from.len and excluded_from[item.from]) continue;
            const result = RecvResult{
                .from = item.from,
                .len = item.len,
            };
            @memcpy(buf[0..item.len], item.data[0..item.len]);
            if (i < self.count - 1) {
                self.items[i] = self.items[self.count - 1];
            }
            self.count -= 1;
            return result;
        }
        return null;
    }
};

/// Message accounting: tracks count and bytes per VRR message tag.
pub const MessageStats = struct {
    sent: [256]u64,
    bytes: [256]u64,

    pub fn init() MessageStats {
        return .{
            .sent = std.mem.zeroes([256]u64),
            .bytes = std.mem.zeroes([256]u64),
        };
    }

    pub fn record(self: *MessageStats, tag: u8, len: usize) void {
        self.sent[tag] += 1;
        self.bytes[tag] += len;
    }

    pub fn totalMessages(self: *const MessageStats) u64 {
        var total: u64 = 0;
        for (self.sent) |n| total += n;
        return total;
    }

    pub fn totalBytes(self: *const MessageStats) u64 {
        var total: u64 = 0;
        for (self.bytes) |n| total += n;
        return total;
    }
};

pub const DropNext = struct {
    id: u64,
    from: u8,
    to: u8,
    tag: u8,
};

pub const SimulatedNetwork = struct {
    queues: [msg.REPLICA_COUNT_MAX]MessageQueue,
    // Asymmetric partition matrix: partitioned[from][to] can differ from [to][from]
    partitioned: [msg.REPLICA_COUNT_MAX][msg.REPLICA_COUNT_MAX]bool,
    prng: Prng,
    drop_rate: Ratio,
    min_delay: i64,
    max_delay: i64,
    current_tick: *i64,
    replica_count: u8,

    // Path clogging: max messages in-flight per (from, to) pair
    path_max_capacity: u8,

    // Packet replay: probability (0-100) of duplicating a delivered message
    replay_rate: Ratio,

    // Stability: ticks since last partition/heal, minimum before next change
    partition_stable_until: [msg.REPLICA_COUNT_MAX]i64,
    heal_stable_until: i64,
    partition_stability: i64, // minimum ticks a partition persists
    heal_stability: i64, // minimum ticks after heal before next partition

    // Deterministic one-shot message fault and accounting.
    drop_next: ?DropNext,
    drop_next_count: u64,
    last_drop_next_id: u64,
    last_drop_next_from: u8,
    last_drop_next_to: u8,
    last_drop_next_tag: u8,

    // Message accounting
    stats: MessageStats,

    pub fn init(seed: u64, replica_count: u8, current_tick: *i64) SimulatedNetwork {
        var network = SimulatedNetwork{
            .queues = undefined,
            .partitioned = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.REPLICA_COUNT_MAX]bool),
            .prng = Prng.init(seed +% 0xBEEF),
            .drop_rate = Ratio.zero(),
            .min_delay = 1,
            .max_delay = 5,
            .current_tick = current_tick,
            .replica_count = replica_count,
            .path_max_capacity = 0, // 0 = unlimited
            .replay_rate = Ratio.zero(),
            .partition_stable_until = std.mem.zeroes([msg.REPLICA_COUNT_MAX]i64),
            .heal_stable_until = 0,
            .partition_stability = 0,
            .heal_stability = 0,
            .drop_next = null,
            .drop_next_count = 0,
            .last_drop_next_id = 0,
            .last_drop_next_from = 0,
            .last_drop_next_to = 0,
            .last_drop_next_tag = 0,
            .stats = MessageStats.init(),
        };
        for (&network.queues) |*q| {
            q.* = MessageQueue.init();
        }
        return network;
    }

    pub fn initInPlace(self: *SimulatedNetwork, seed: u64, replica_count: u8, current_tick: *i64) void {
        self.partitioned = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.REPLICA_COUNT_MAX]bool);
        self.prng = Prng.init(seed +% 0xBEEF);
        self.drop_rate = Ratio.zero();
        self.min_delay = 1;
        self.max_delay = 5;
        self.current_tick = current_tick;
        self.replica_count = replica_count;
        self.path_max_capacity = 0;
        self.replay_rate = Ratio.zero();
        self.partition_stable_until = std.mem.zeroes([msg.REPLICA_COUNT_MAX]i64);
        self.heal_stable_until = 0;
        self.partition_stability = 0;
        self.heal_stability = 0;
        self.drop_next = null;
        self.drop_next_count = 0;
        self.last_drop_next_id = 0;
        self.last_drop_next_from = 0;
        self.last_drop_next_to = 0;
        self.last_drop_next_tag = 0;
        self.stats = MessageStats.init();
        for (&self.queues) |*q| {
            q.* = MessageQueue.init();
        }
    }

    pub fn armDropNext(self: *SimulatedNetwork, id: u64, from: u8, to: u8, tag: u8) void {
        std.debug.assert(id > 0);
        std.debug.assert(from < self.replica_count);
        std.debug.assert(to < self.replica_count);
        std.debug.assert(self.drop_next == null);
        self.drop_next = .{ .id = id, .from = from, .to = to, .tag = tag };
    }

    pub fn enqueueSend(self: *SimulatedNetwork, from: u8, to: u8, data: []const u8) void {
        if (from >= self.replica_count or to >= self.replica_count) return;
        if (self.partitioned[from][to]) return;

        if (self.drop_next) |selection| {
            const tag: u8 = if (data.len == 0) 0 else data[0];
            if (selection.from == from and selection.to == to and selection.tag == tag) {
                self.drop_next = null;
                self.drop_next_count += 1;
                self.last_drop_next_id = selection.id;
                self.last_drop_next_from = from;
                self.last_drop_next_to = to;
                self.last_drop_next_tag = tag;
                return;
            }
        }

        // Drop
        if (!self.drop_rate.isZero()) {
            if (self.prng.chance(self.drop_rate)) return;
        }

        // Path clogging: count in-flight messages from→to
        if (self.path_max_capacity > 0) {
            var in_flight: u8 = 0;
            for (self.queues[to].items[0..self.queues[to].count]) |*item| {
                if (item.from == from) in_flight += 1;
            }
            if (in_flight >= self.path_max_capacity) return; // backpressure
        }

        const delay = self.min_delay + @as(i64, @intCast(self.prng.bounded(
            @intCast(self.max_delay - self.min_delay + 1),
        )));

        var pending = PendingMessage{
            .data = undefined,
            .len = data.len,
            .from = from,
            .deliver_at_tick = self.current_tick.* + delay,
        };
        @memcpy(pending.data[0..data.len], data);
        self.queues[to].push(pending);

        // Message accounting (first byte of VRR data is the message tag)
        const tag: u8 = if (data.len > 0) data[0] else 0;
        self.stats.record(tag, data.len);
    }

    /// Deliver a message and optionally replay it (duplicate delivery).
    pub fn deliverAndMaybeReplay(self: *SimulatedNetwork, to: u8, buf: []u8) ?RecvResult {
        const result = self.queues[to].popReady(self.current_tick.*, buf) orelse return null;

        // Packet replay: re-enqueue the same message with a new delay
        if (!self.replay_rate.isZero() and self.prng.chance(self.replay_rate)) {
            const replay_delay = self.min_delay + @as(i64, @intCast(self.prng.bounded(
                @intCast(self.max_delay * 3), // replayed packets arrive later
            )));
            var replay = PendingMessage{
                .data = undefined,
                .len = result.len,
                .from = result.from,
                .deliver_at_tick = self.current_tick.* + replay_delay,
            };
            @memcpy(replay.data[0..result.len], buf[0..result.len]);
            self.queues[to].push(replay);
        }

        return result;
    }

    /// Symmetric partition: isolate replica from all others.
    pub fn partition(self: *SimulatedNetwork, replica_id: u8) void {
        // Check stability: don't partition if recently healed
        if (self.current_tick.* < self.heal_stable_until) return;

        for (0..self.replica_count) |i| {
            self.partitioned[replica_id][@intCast(i)] = true;
            self.partitioned[@intCast(i)][replica_id] = true;
        }
        self.partition_stable_until[replica_id] = self.current_tick.* + self.partition_stability;
    }

    /// Asymmetric partition: A cannot send to B, but B can still send to A.
    pub fn partitionOneWay(self: *SimulatedNetwork, from: u8, to: u8) void {
        if (self.current_tick.* < self.heal_stable_until) return;
        self.partitioned[from][to] = true;
    }

    pub fn healAll(self: *SimulatedNetwork) void {
        // Check stability: don't heal if any partition is too recent
        for (self.partition_stable_until[0..self.replica_count]) |stable_until| {
            if (self.current_tick.* < stable_until) return;
        }
        self.partitioned = std.mem.zeroes([msg.REPLICA_COUNT_MAX][msg.REPLICA_COUNT_MAX]bool);
        self.heal_stable_until = self.current_tick.* + self.heal_stability;
    }

    /// Heal a specific replica (keep other partitions).
    pub fn healOne(self: *SimulatedNetwork, replica_id: u8) void {
        if (self.current_tick.* < self.partition_stable_until[replica_id]) return;
        for (0..self.replica_count) |i| {
            self.partitioned[replica_id][@intCast(i)] = false;
            self.partitioned[@intCast(i)][replica_id] = false;
        }
    }
};

test "drop-next selection matches sender receiver and message tag once" {
    var tick: i64 = 0;
    const network = try std.testing.allocator.create(SimulatedNetwork);
    defer std.testing.allocator.destroy(network);
    network.initInPlace(1, 3, &tick);
    network.min_delay = 0;
    network.max_delay = 0;
    network.armDropNext(77, 1, 2, @intFromEnum(msg.Tag.request_prepare));

    const matching = [_]u8{@intFromEnum(msg.Tag.request_prepare)};
    const other = [_]u8{@intFromEnum(msg.Tag.commit)};
    network.enqueueSend(0, 2, &matching);
    network.enqueueSend(1, 2, &other);
    try std.testing.expectEqual(@as(u64, 0), network.drop_next_count);
    network.enqueueSend(1, 2, &matching);
    try std.testing.expectEqual(@as(u64, 1), network.drop_next_count);
    try std.testing.expectEqual(@as(u64, 77), network.last_drop_next_id);
    try std.testing.expect(network.drop_next == null);
    network.enqueueSend(1, 2, &matching);
    try std.testing.expectEqual(@as(usize, 3), network.queues[2].count);
}

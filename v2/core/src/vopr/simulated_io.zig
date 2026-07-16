const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Prng = @import("../prng.zig").Prng;
const msg = @import("../message.zig");
const net_mod = @import("simulated_net.zig");

// ---------------------------------------------------------------------------
// SimulatedIo -- a std.Io implementation for deterministic simulation.
//
// Implements time, random, and inter-replica networking through the std.Io
// vtable. Networking is routed through in-memory queues (SimulatedNetwork).
// Socket handles are fake: handle value = replica_id.
//
// The Replica and MessageBus use the Io vtable exclusively. No code outside
// this file knows it's running in simulation.
// ---------------------------------------------------------------------------

pub const SimulatedIo = struct {
    prng: *Prng,
    current_tick: *i64,
    network: *net_mod.SimulatedNetwork,
    replica_id: u8,

    pub fn init(
        prng: *Prng,
        current_tick: *i64,
        network: *net_mod.SimulatedNetwork,
        replica_id: u8,
    ) SimulatedIo {
        return .{
            .prng = prng,
            .current_tick = current_tick,
            .network = network,
            .replica_id = replica_id,
        };
    }

    pub fn io(self: *SimulatedIo) Io {
        return .{
            .userdata = self,
            .vtable = &vtable,
        };
    }

    // -- Time --

    fn now(userdata: ?*anyopaque, _: Io.Clock) Io.Timestamp {
        const self: *SimulatedIo = @ptrCast(@alignCast(userdata.?));
        // Each simulated tick = 10ms so that 200 ticks = 2s of wall-clock time.
        // This keeps VRR timeouts (HEARTBEAT_INTERVAL=500ms, VIEW_CHANGE_TIMEOUT=2000ms)
        // reachable within typical VOPR test durations of 200-1000 ticks.
        return .{ .nanoseconds = @as(i96, self.current_tick.*) * std.time.ns_per_ms * 10 };
    }

    fn clockResolution(_: ?*anyopaque, _: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
        return .{ .nanoseconds = std.time.ns_per_ms };
    }

    fn sleep(_: ?*anyopaque, _: Io.Timeout) Io.Cancelable!void {}

    // -- Random --

    fn random(userdata: ?*anyopaque, buffer: []u8) void {
        const self: *SimulatedIo = @ptrCast(@alignCast(userdata.?));
        for (buffer) |*b| {
            b.* = @truncate(self.prng.next());
        }
    }

    fn randomSecure(userdata: ?*anyopaque, buffer: []u8) Io.RandomSecureError!void {
        random(userdata, buffer);
    }

    // -- Networking --
    // Socket handles in simulation are fake: handle = replica_id.
    // netWrite enqueues into the target replica's in-memory queue.
    // netRead dequeues from the calling replica's queue.

    /// netRead: dequeue from own in-memory queue.
    /// Returns [1-byte from][message bytes]. The extra from byte lets
    /// the MessageBus know which replica sent the message.
    fn netRead(userdata: ?*anyopaque, _: net.Socket.Handle, data: [][]u8) net.Stream.Reader.Error!usize {
        const self: *SimulatedIo = @ptrCast(@alignCast(userdata.?));
        if (data.len == 0) return 0;
        const buf = data[0];
        if (buf.len < 2) return 0;

        // Read into buf[1..] so we can prefix with from
        const result = self.network.queues[self.replica_id].popReady(self.current_tick.*, buf[1..]) orelse return 0;
        buf[0] = result.from;
        return 1 + result.len;
    }

    /// netWrite: enqueue message to target replica's in-memory queue.
    /// header is a framed message: [4-byte LE len][1-byte from_id][VRR bytes].
    /// We extract the VRR payload and enqueue it with the from_id.
    fn netWrite(userdata: ?*anyopaque, dest: net.Socket.Handle, header: []const u8, _: []const []const u8, _: usize) net.Stream.Writer.Error!usize {
        const self: *SimulatedIo = @ptrCast(@alignCast(userdata.?));
        const to: u8 = @intCast(dest);

        if (header.len < 5) return header.len;
        const vrr_payload = header[5..]; // skip 4-byte len + 1-byte from_id
        self.network.enqueueSend(self.replica_id, to, vrr_payload);
        return header.len;
    }

    fn netClose(_: ?*anyopaque, _: []const net.Socket.Handle) void {}

    // -- Stubs --

    fn unimplemented(_: ?*anyopaque) noreturn {
        @panic("SimulatedIo: unimplemented vtable function called");
    }

    fn crashHandler(_: ?*anyopaque) void {}

    const vtable: Io.VTable = blk: {
        var vt: Io.VTable = undefined;
        const fields = @typeInfo(Io.VTable).@"struct".fields;
        for (fields) |field| {
            @field(vt, field.name) = @ptrCast(&unimplemented);
        }
        vt.now = &now;
        vt.clockResolution = &clockResolution;
        vt.sleep = &sleep;
        vt.random = &random;
        vt.randomSecure = &randomSecure;
        vt.crashHandler = &crashHandler;
        vt.netRead = &netRead;
        vt.netWrite = &netWrite;
        vt.netClose = &netClose;
        break :blk vt;
    };
};

// ---------------------------------------------------------------------------
// Helper: convert Io timestamp to tick (milliseconds)
// ---------------------------------------------------------------------------

pub fn nowTick(io_inst: Io) i64 {
    const ts = io_inst.vtable.now(io_inst.userdata, .real);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

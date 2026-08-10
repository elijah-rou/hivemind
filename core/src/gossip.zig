const std = @import("std");
const msg = @import("message.zig");
const replica_mod = @import("replica.zig");
const enc = @import("encryption.zig");

const libc = struct {
    extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
    extern "c" fn close(fd: c_int) c_int;
};

const MAGIC: u32 = 0x48564750; // "HVGP" (plaintext)
const MAGIC_ENC: u32 = 0x48564745; // "HVGE" (encrypted)
const BROADCAST_INTERVAL_MS: i64 = 5000;
pub const STALE_THRESHOLD_MS: i64 = 30000;
pub const MAX_GOSSIP_PEERS: usize = 16;
pub const GPU_TYPE_COUNT: usize = 9; // matches msg.GpuType enum count

pub const OriginIdentity = struct {
    origin_id: [32]u8 = std.mem.zeroes([32]u8),
    provider: [32]u8 = std.mem.zeroes([32]u8),
    region: [32]u8 = std.mem.zeroes([32]u8),
    locality: [32]u8 = std.mem.zeroes([32]u8),
    continent: [32]u8 = std.mem.zeroes([32]u8),
};

pub const GossipPeer = struct {
    origin_id: [32]u8 = std.mem.zeroes([32]u8),
    host: u32 = 0,
    port: u16 = 0,
    active: bool = false,
};

pub const PeerCapacity = struct {
    origin_id: [32]u8 = std.mem.zeroes([32]u8),
    provider: [32]u8 = std.mem.zeroes([32]u8),
    region: [32]u8 = std.mem.zeroes([32]u8),
    locality: [32]u8 = std.mem.zeroes([32]u8),
    continent: [32]u8 = std.mem.zeroes([32]u8),
    gpu_available: [GPU_TYPE_COUNT]u16 = std.mem.zeroes([GPU_TYPE_COUNT]u16),
    gpu_total: [GPU_TYPE_COUNT]u16 = std.mem.zeroes([GPU_TYPE_COUNT]u16),
    cpu_available_millicores: u32 = 0,
    cpu_total_millicores: u32 = 0,
    queue_depth: u32 = 0,
    active_deployments: u32 = 0,
    running_pods: u32 = 0,
    node_count: u32 = 0,
    last_seen_ms: i64 = 0,
};

pub const MESSAGE_SIZE: usize = 4 + (32 * 5) + (GPU_TYPE_COUNT * 4) + 4 + 4 + 4 + 4 + 4 + 4 + 8;

pub const GossipState = struct {
    fd: c_int,
    identity: OriginIdentity,
    peers: [MAX_GOSSIP_PEERS]GossipPeer,
    peer_count: usize,
    cache: [MAX_GOSSIP_PEERS]PeerCapacity,
    last_broadcast_ms: i64,
    replica: *replica_mod.Replica,
    encryption: ?*enc.EncryptionState,

    pub fn init(port: u16, identity: OriginIdentity, replica: *replica_mod.Replica) !GossipState {
        const fd = libc.socket(std.posix.AF.INET, std.posix.SOCK.DGRAM, 0);
        if (fd < 0) return error.SocketCreateFailed;

        // Set non-blocking
        const flags = std.c.fcntl(fd, std.posix.F.GETFL);
        const O_NONBLOCK: c_int = if (@import("builtin").os.tag == .macos) 0x0004 else 0x800;
        _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);

        // Bind to port
        const optval: u32 = 1;
        _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, @ptrCast(&optval), @sizeOf(u32));

        var addr: std.posix.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) != 0) {
            _ = libc.close(fd);
            return error.BindFailed;
        }

        return .{
            .fd = fd,
            .identity = identity,
            .peers = [_]GossipPeer{.{}} ** MAX_GOSSIP_PEERS,
            .peer_count = 0,
            .cache = [_]PeerCapacity{.{}} ** MAX_GOSSIP_PEERS,
            .last_broadcast_ms = 0,
            .replica = replica,
            .encryption = null,
        };
    }

    pub fn deinit(self: *GossipState) void {
        _ = libc.close(self.fd);
    }

    pub fn addPeer(self: *GossipState, origin_id: []const u8, host: u32, port: u16) void {
        if (self.peer_count >= MAX_GOSSIP_PEERS) return;
        var peer = &self.peers[self.peer_count];
        peer.active = true;
        peer.host = host;
        peer.port = port;
        const len = @min(origin_id.len, 32);
        @memcpy(peer.origin_id[0..len], origin_id[0..len]);
        self.peer_count += 1;
    }

    /// Called from main loop. Broadcasts capacity snapshot and receives incoming.
    pub fn tick(self: *GossipState, now_ms: i64) void {
        self.receive(now_ms);

        if (now_ms - self.last_broadcast_ms >= BROADCAST_INTERVAL_MS) {
            self.last_broadcast_ms = now_ms;
            self.broadcast(now_ms);
        }
    }

    /// Receive-only mode for followers (don't broadcast, just update cache).
    pub fn receiveOnly(self: *GossipState, now_ms: i64) void {
        self.receive(now_ms);
    }

    fn broadcast(self: *GossipState, now_ms: i64) void {
        var snapshot: [MESSAGE_SIZE]u8 = std.mem.zeroes([MESSAGE_SIZE]u8);
        self.buildSnapshot(&snapshot, now_ms);

        // Determine send buffer: encrypted or plaintext
        var send_buf: [4 + enc.NONCE_LEN + MESSAGE_SIZE + enc.TAG_LEN]u8 = undefined;
        var send_len: usize = 0;

        if (self.encryption != null and self.encryption.?.enabled) {
            // Encrypted: [4B magic_enc][24B nonce][encrypted payload][16B tag]
            @memcpy(send_buf[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, MAGIC_ENC)));
            const magic_aad = send_buf[0..4];
            const enc_len = enc.encryptGossip(&self.encryption.?.gossip_key, &snapshot, magic_aad, send_buf[4..]);
            send_len = 4 + enc_len;
        } else {
            // Plaintext: just the raw snapshot (already has MAGIC at offset 0)
            @memcpy(send_buf[0..MESSAGE_SIZE], &snapshot);
            send_len = MESSAGE_SIZE;
        }

        for (self.peers[0..self.peer_count]) |peer| {
            if (!peer.active) continue;
            var addr: std.posix.sockaddr.in = .{
                .port = std.mem.nativeToBig(u16, peer.port),
                .addr = peer.host,
            };
            _ = std.c.sendto(
                self.fd,
                &send_buf,
                send_len,
                0,
                @ptrCast(&addr),
                @sizeOf(std.posix.sockaddr.in),
            );
        }
    }

    fn buildSnapshot(self: *GossipState, buf: *[MESSAGE_SIZE]u8, now_ms: i64) void {
        const sm = self.replica.state_machine;
        var pos: usize = 0;

        // Magic
        @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, MAGIC)));
        pos += 4;

        @memcpy(buf[pos..][0..32], &self.identity.origin_id);
        pos += 32;
        @memcpy(buf[pos..][0..32], &self.identity.provider);
        pos += 32;
        @memcpy(buf[pos..][0..32], &self.identity.region);
        pos += 32;
        @memcpy(buf[pos..][0..32], &self.identity.locality);
        pos += 32;
        @memcpy(buf[pos..][0..32], &self.identity.continent);
        pos += 32;

        // GPU capacity by type
        for (0..GPU_TYPE_COUNT) |gpu_idx| {
            var available: u16 = 0;
            var total: u16 = 0;
            const gpu_type: msg.GpuType = @enumFromInt(gpu_idx);

            for (sm.nodes[0..sm.node_count]) |node| {
                if (!node.active) continue;
                if (node.gpu_type == gpu_type and node.gpu_count > 0) {
                    total += node.gpu_count;
                    available += node.allocatable_gpu;
                }
            }

            @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, available)));
            pos += 2;
            @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, total)));
            pos += 2;
        }

        var cpu_available_millicores: u32 = 0;
        var cpu_total_millicores: u32 = 0;
        for (sm.nodes[0..sm.node_count]) |node| {
            if (!node.active) continue;
            cpu_total_millicores +%= node.cpu_millicores;
            cpu_available_millicores +%= node.allocatable_cpu;
        }
        @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, cpu_available_millicores)));
        pos += 4;
        @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, cpu_total_millicores)));
        pos += 4;

        const queue_depth: u32 = @intCast(self.replica.state_machine.pod_count); // approximate
        @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, queue_depth)));
        pos += 4;

        // Active deployments
        @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(sm.deployment_count)))));
        pos += 4;

        // Running pods
        var running: u32 = 0;
        for (sm.pods[0..sm.pod_count]) |pod| {
            if (pod.active and pod.phase == .running) running += 1;
        }
        @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, running)));
        pos += 4;

        // Node count
        @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(sm.node_count)))));
        pos += 4;

        // Timestamp
        @memcpy(buf[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(i64, now_ms)));
    }

    fn receive(self: *GossipState, now_ms: i64) void {
        var buf: [256]u8 = undefined;
        var decrypt_buf: [MESSAGE_SIZE]u8 = undefined;
        while (true) {
            const n = std.c.recvfrom(self.fd, &buf, buf.len, 0, null, null);
            if (n <= 0) return;
            const len: usize = @intCast(n);

            // Check magic to determine plaintext vs encrypted
            if (len < 4) continue;
            const magic = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, buf[0..4]));

            if (magic == MAGIC_ENC) {
                // Encrypted gossip
                if (self.encryption == null or !self.encryption.?.enabled) continue;
                const enc_data = buf[4..len];
                const magic_aad = buf[0..4];
                const pt_len = enc.decryptGossip(&self.encryption.?.gossip_key, enc_data, magic_aad, &decrypt_buf) catch continue;
                if (pt_len < MESSAGE_SIZE) continue;
                self.handleMessage(&decrypt_buf, now_ms);
            } else if (magic == MAGIC) {
                // Plaintext gossip
                if (len < MESSAGE_SIZE) continue;
                self.handleMessage(buf[0..len], now_ms);
            }
            // Unknown magic: skip
        }
    }

    fn handleMessage(self: *GossipState, data: []const u8, now_ms: i64) void {
        // Validate magic (plaintext messages start with MAGIC)
        const magic = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[0..4]));
        if (magic != MAGIC) return;

        var pos: usize = 4;
        const origin_id = data[pos..][0..32];
        pos += 32;
        const provider = data[pos..][0..32];
        pos += 32;
        const region = data[pos..][0..32];
        pos += 32;
        const locality = data[pos..][0..32];
        pos += 32;
        const continent = data[pos..][0..32];
        pos += 32;

        var entry: ?*PeerCapacity = null;
        for (&self.cache) |*c| {
            if (std.mem.eql(u8, &c.origin_id, origin_id)) {
                entry = c;
                break;
            }
        }
        if (entry == null) {
            for (&self.cache) |*c| {
                if (c.last_seen_ms == 0) {
                    entry = c;
                    break;
                }
            }
        }

        const e = entry orelse return;
        e.origin_id = origin_id.*;
        e.provider = provider.*;
        e.region = region.*;
        e.locality = locality.*;
        e.continent = continent.*;

        // GPU capacity
        for (0..GPU_TYPE_COUNT) |i| {
            e.gpu_available[i] = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, data[pos..][0..2]));
            pos += 2;
            e.gpu_total[i] = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, data[pos..][0..2]));
            pos += 2;
        }

        e.cpu_available_millicores = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[pos..][0..4]));
        pos += 4;
        e.cpu_total_millicores = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[pos..][0..4]));
        pos += 4;
        e.queue_depth = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[pos..][0..4]));
        pos += 4;
        e.active_deployments = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[pos..][0..4]));
        pos += 4;
        e.running_pods = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[pos..][0..4]));
        pos += 4;
        e.node_count = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, data[pos..][0..4]));
        pos += 4;

        e.last_seen_ms = now_ms;
    }

    /// Get all non-stale peer capacities.
    pub fn activePeers(self: *const GossipState, now_ms: i64) []const PeerCapacity {
        _ = now_ms;
        return &self.cache;
    }

    /// Check if a specific origin's data is fresh.
    pub fn isOriginFresh(self: *const GossipState, origin_id: []const u8, now_ms: i64) bool {
        for (&self.cache) |*c| {
            if (c.last_seen_ms == 0) continue;
            const id = msg.fixedToSlice(&c.origin_id);
            if (std.mem.eql(u8, id, origin_id)) {
                return (now_ms - c.last_seen_ms) < STALE_THRESHOLD_MS;
            }
        }
        return false;
    }

    /// Build a gossip message into a buffer without sending (for testing).
    pub fn buildSnapshotPublic(self: *GossipState, buf: *[MESSAGE_SIZE]u8, now_ms: i64) void {
        self.buildSnapshot(buf, now_ms);
    }

    /// Process a gossip message from raw bytes (for testing).
    pub fn handleMessagePublic(self: *GossipState, data: []const u8, now_ms: i64) void {
        self.handleMessage(data, now_ms);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "gossip message round-trip" {
    // Hand-craft a gossip message and verify deserialization.
    // This covers origin identity, locality labels, CPU summaries, and GPU summaries.
    var buf: [MESSAGE_SIZE]u8 = std.mem.zeroes([MESSAGE_SIZE]u8);
    var pos: usize = 0;

    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, MAGIC)));
    pos += 4;

    const origin_id = "aws-us-east-1";
    @memcpy(buf[pos..][0..origin_id.len], origin_id);
    pos += 32;

    const provider = "aws";
    @memcpy(buf[pos..][0..provider.len], provider);
    pos += 32;

    const region_name = "us-east-1";
    @memcpy(buf[pos..][0..region_name.len], region_name);
    pos += 32;

    const locality = "us-east";
    @memcpy(buf[pos..][0..locality.len], locality);
    pos += 32;

    const continent = "na";
    @memcpy(buf[pos..][0..continent.len], continent);
    pos += 32;

    // GPU capacity: h100_sxm (index 3) has 6 available, 8 total.
    for (0..GPU_TYPE_COUNT) |i| {
        if (i == 3) {
            @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, 6)));
            pos += 2;
            @memcpy(buf[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, 8)));
            pos += 2;
        } else {
            pos += 4;
        }
    }

    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 24000)));
    pos += 4;
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 32000)));
    pos += 4;

    // queue_depth=3, deployments=5, running_pods=10, nodes=2
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 3)));
    pos += 4;
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 5)));
    pos += 4;
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 10)));
    pos += 4;
    @memcpy(buf[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 2)));
    pos += 4;

    @memcpy(buf[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(i64, 99000)));

    var receiver = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-eu-west-2"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "eu-west-2"),
            .locality = msg.strToFixed(32, "europe"),
            .continent = msg.strToFixed(32, "eu"),
        },
        .peers = [_]GossipPeer{.{}} ** MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = undefined,
        .encryption = null,
    };

    receiver.handleMessagePublic(&buf, 5000);

    try std.testing.expectEqualStrings("aws-us-east-1", msg.fixedToSlice(&receiver.cache[0].origin_id));
    try std.testing.expectEqualStrings("aws", msg.fixedToSlice(&receiver.cache[0].provider));
    try std.testing.expectEqualStrings("us-east-1", msg.fixedToSlice(&receiver.cache[0].region));
    try std.testing.expectEqualStrings("us-east", msg.fixedToSlice(&receiver.cache[0].locality));
    try std.testing.expectEqualStrings("na", msg.fixedToSlice(&receiver.cache[0].continent));
    try std.testing.expectEqual(@as(u32, 24000), receiver.cache[0].cpu_available_millicores);
    try std.testing.expectEqual(@as(u32, 32000), receiver.cache[0].cpu_total_millicores);
    try std.testing.expectEqual(@as(u32, 5), receiver.cache[0].active_deployments);
    try std.testing.expectEqual(@as(u32, 10), receiver.cache[0].running_pods);
    try std.testing.expectEqual(@as(u32, 2), receiver.cache[0].node_count);
    try std.testing.expectEqual(@as(u32, 3), receiver.cache[0].queue_depth);
    try std.testing.expectEqual(@as(u16, 6), receiver.cache[0].gpu_available[3]);
    try std.testing.expectEqual(@as(u16, 8), receiver.cache[0].gpu_total[3]);
    try std.testing.expectEqual(@as(i64, 5000), receiver.cache[0].last_seen_ms);
}

test "gossip stale detection keyed by origin" {
    var state = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-us-east-1"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]GossipPeer{.{}} ** MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = undefined,
        .encryption = null,
    };

    state.cache[0].origin_id = msg.strToFixed(32, "aws-eu-west-2");
    state.cache[0].region = msg.strToFixed(32, "eu-west-2");
    state.cache[0].last_seen_ms = 10000;
    state.cache[0].active_deployments = 5;

    try std.testing.expect(state.isOriginFresh("aws-eu-west-2", 39000));
    try std.testing.expect(!state.isOriginFresh("aws-eu-west-2", 41000));
    try std.testing.expect(!state.isOriginFresh("crusoe-us-east-1", 10000));
}

test "gossip invalid magic rejected" {
    var state = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-us-east-1"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]GossipPeer{.{}} ** MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = undefined,
        .encryption = null,
    };

    // Garbage data with wrong magic
    var buf: [MESSAGE_SIZE]u8 = std.mem.zeroes([MESSAGE_SIZE]u8);
    buf[0] = 0xFF;
    buf[1] = 0xFF;

    state.handleMessagePublic(&buf, 1000);

    // Cache should remain empty (no last_seen_ms set)
    try std.testing.expectEqual(@as(i64, 0), state.cache[0].last_seen_ms);
}

test "gossip peer add" {
    var state = GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-us-east-1"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]GossipPeer{.{}} ** MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]PeerCapacity{.{}} ** MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = undefined,
        .encryption = null,
    };

    state.addPeer("aws-eu-west-2", 0x0100007F, 9300);
    state.addPeer("crusoe-us-east-1", 0x0200007F, 9301);

    try std.testing.expectEqual(@as(usize, 2), state.peer_count);
    try std.testing.expect(state.peers[0].active);
    try std.testing.expectEqual(@as(u16, 9300), state.peers[0].port);
    try std.testing.expectEqual(@as(u16, 9301), state.peers[1].port);
}

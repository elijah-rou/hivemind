const std = @import("std");
const connection = @import("connection.zig");
const encryption = @import("encryption.zig");
const message = @import("message.zig");
const request_queue = @import("request_queue.zig");

const Encoding = struct {
    byte_order: []const u8,
    hex: []const u8,
    plaintext_frame: []const u8,
    encrypted_frame: []const u8,
    aad: []const u8,
    peer_body: []const u8,
};
const TestMaterial = struct { warning: []const u8, psk_hex: []const u8, nonce_hex: []const u8 };
const Status = struct { byte: u8, name: []const u8, origins: []const []const u8 };
const Vector = struct {
    id: []const u8,
    channel: []const u8,
    direction: []const u8,
    message: []const u8,
    flags: u8,
    tag: u8,
    key_purpose: ?[]const u8,
    payload_hex: []const u8,
    plaintext_hex: []const u8,
    frame_hex: []const u8,
    consumers: []const []const u8,
};
const Contract = struct {
    schema: []const u8,
    protocol_version: u16,
    encoding: Encoding,
    test_material: TestMaterial,
    statuses: []const Status,
    vectors: []const Vector,
};

fn hasConsumer(vector: Vector, expected: []const u8) bool {
    for (vector.consumers) |consumer| {
        if (std.mem.eql(u8, consumer, expected)) return true;
    }
    return false;
}

fn decodeHex(allocator: std.mem.Allocator, value: []const u8, max_bytes: usize) ![]u8 {
    if (value.len % 2 != 0) return error.InvalidHexLength;
    if (value.len / 2 > max_bytes) return error.HexValueTooLarge;
    const out = try allocator.alloc(u8, value.len / 2);
    errdefer allocator.free(out);
    _ = std.fmt.hexToBytes(out, value) catch return error.InvalidHex;
    return out;
}

fn keyForPurpose(state: *const encryption.EncryptionState, purpose: []const u8) !*const [encryption.KEY_LEN]u8 {
    if (std.mem.eql(u8, purpose, "worker")) return &state.worker_key;
    if (std.mem.eql(u8, purpose, "client")) return &state.client_key;
    if (std.mem.eql(u8, purpose, "peer")) return &state.peer_key;
    return error.InvalidKeyPurpose;
}

fn reencodeFrame(
    allocator: std.mem.Allocator,
    vector: Vector,
    plaintext: []const u8,
    nonce: [encryption.NONCE_LEN]u8,
    state: *const encryption.EncryptionState,
) ![]u8 {
    if (vector.flags == 0) {
        const out = try allocator.alloc(u8, 5 + plaintext.len);
        std.mem.writeInt(u32, out[0..4], @intCast(1 + plaintext.len), .little);
        out[4] = 0;
        @memcpy(out[5..], plaintext);
        return out;
    }
    if (vector.flags != 1) return error.InvalidFlags;
    const purpose = vector.key_purpose orelse return error.MissingKeyPurpose;
    const key = try keyForPurpose(state, purpose);
    const frame_len = 1 + encryption.NONCE_LEN + plaintext.len + encryption.TAG_LEN;
    const out = try allocator.alloc(u8, 4 + frame_len);
    std.mem.writeInt(u32, out[0..4], @intCast(frame_len), .little);
    out[4] = 1;
    @memcpy(out[5 .. 5 + encryption.NONCE_LEN], &nonce);
    var tag: [encryption.TAG_LEN]u8 = undefined;
    std.crypto.aead.chacha_poly.XChaCha20Poly1305.encrypt(
        out[5 + encryption.NONCE_LEN ..][0..plaintext.len],
        &tag,
        plaintext,
        out[0..5],
        nonce,
        key.*,
    );
    @memcpy(out[5 + encryption.NONCE_LEN + plaintext.len ..], &tag);
    return out;
}

fn validatePayload(vector: Vector, payload: []const u8) !void {
    if (std.mem.eql(u8, vector.message, "register")) {
        const decoded = connection.ConnectionManager.parseWorkerRegister(payload) orelse return error.InvalidRegister;
        var reencoded: [138]u8 = std.mem.zeroes([138]u8);
        @memcpy(reencoded[0..64], &decoded.hostname);
        std.mem.writeInt(u32, reencoded[64..68], decoded.cpu_millicores, .little);
        std.mem.writeInt(u32, reencoded[68..72], decoded.memory_megabytes, .little);
        reencoded[72] = @intFromEnum(decoded.gpu_type);
        reencoded[73] = decoded.gpu_count;
        @memcpy(reencoded[74..106], &decoded.provider);
        @memcpy(reencoded[106..138], &decoded.region);
        try std.testing.expectEqualSlices(u8, payload, &reencoded);
        return;
    }
    if (std.mem.eql(u8, vector.message, "heartbeat")) {
        const decoded = connection.ConnectionManager.parseWorkerHeartbeat(payload) orelse return error.InvalidHeartbeat;
        var reencoded: [23]u8 = undefined;
        std.mem.writeInt(u64, reencoded[0..8], decoded.timestamp, .little);
        reencoded[8] = decoded.cpu_usage_pct;
        std.mem.writeInt(u32, reencoded[9..13], decoded.memory_used_mb, .little);
        @memcpy(reencoded[13..21], &decoded.gpu_utilization);
        std.mem.writeInt(u16, reencoded[21..23], decoded.pods_running, .little);
        try std.testing.expectEqualSlices(u8, payload, &reencoded);
        return;
    }
    if (std.mem.eql(u8, vector.message, "pod-status")) {
        const decoded = connection.ConnectionManager.parseWorkerPodStatus(payload) orelse return error.InvalidPodStatus;
        var reencoded: [150]u8 = undefined;
        std.mem.writeInt(u64, reencoded[0..8], decoded.pod_id, .little);
        reencoded[8] = @intFromEnum(decoded.old_phase);
        reencoded[9] = @intFromEnum(decoded.new_phase);
        std.mem.writeInt(u64, reencoded[10..18], decoded.timestamp, .little);
        std.mem.writeInt(i32, reencoded[18..22], decoded.exit_code, .little);
        @memcpy(reencoded[22..150], &decoded.message);
        try std.testing.expectEqualSlices(u8, payload, &reencoded);
        return;
    }
    if (std.mem.eql(u8, vector.message, "start-pod")) {
        try std.testing.expectEqual(@as(usize, 797), payload.len);
        try std.testing.expectEqual(@as(u64, 42), std.mem.readInt(u64, payload[0..8], .little));
        try std.testing.expectEqual(@as(u64, 100), std.mem.readInt(u64, payload[8..16], .little));
        try std.testing.expectEqual(@as(u8, 0), payload[796]);
        return;
    }
    if (std.mem.eql(u8, vector.message, "run-request")) {
        const length_offset: usize = if (std.mem.eql(u8, vector.channel, "worker")) 16 else 72;
        const header_len = length_offset + 4;
        try std.testing.expect(payload.len >= header_len);
        try std.testing.expectEqual(payload.len - header_len, std.mem.readInt(u32, payload[length_offset..][0..4], .little));
        return;
    }
    if (std.mem.eql(u8, vector.message, "run-response")) {
        try std.testing.expect(payload.len >= 9);
        _ = try message.enumFromIntChecked(request_queue.RunStatus, payload[8]);
        if (std.mem.eql(u8, vector.channel, "client") and payload[8] == @intFromEnum(request_queue.RunStatus.ok)) {
            try std.testing.expect(payload.len >= 13);
            try std.testing.expectEqual(payload.len - 13, std.mem.readInt(u32, payload[9..13], .little));
        }
        return;
    }
    if (std.mem.eql(u8, vector.message, "leader-probe-request")) {
        try std.testing.expectEqual(@as(usize, 0), payload.len);
        return;
    }
    if (std.mem.eql(u8, vector.message, "leader-probe-response")) {
        const decoded = try message.LeaderProbeResponse.decode(payload);
        try std.testing.expectEqualSlices(u8, payload, &decoded.encode());
        return;
    }
    if (std.mem.eql(u8, vector.message, "peer-envelope")) {
        const decoded = try message.deserialize(payload);
        var reencoded: [256]u8 = undefined;
        const len = message.serialize(decoded, &reencoded);
        try std.testing.expectEqualSlices(u8, payload, reencoded[0..len]);
        return;
    }
    return error.UnknownFixtureMessage;
}

fn readContractFile(allocator: std.mem.Allocator) ![]u8 {
    const path = @import("wire_contract_options").wire_contract_path;
    const fd = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    defer _ = std.c.close(fd);
    const max_bytes = 256 * 1024;
    const buffer = try allocator.alloc(u8, max_bytes);
    errdefer allocator.free(buffer);
    var length: usize = 0;
    while (length < buffer.len) {
        const count = try std.posix.read(fd, buffer[length..]);
        if (count == 0) break;
        length += count;
    }
    if (length == 0) return error.EmptyContract;
    if (length == buffer.len) return error.ContractTooLarge;
    return allocator.realloc(buffer, length);
}

test "wire contract corpus is canonical and byte-identical" {
    const allocator = std.testing.allocator;
    const source = try readContractFile(allocator);
    defer allocator.free(source);
    var parsed = try std.json.parseFromSlice(Contract, allocator, source, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const contract = parsed.value;
    try std.testing.expectEqualStrings("hivemind-wire-contract-v1", contract.schema);
    try std.testing.expectEqual(connection.PROTOCOL_VERSION, contract.protocol_version);
    try std.testing.expect(contract.vectors.len <= 32);
    try std.testing.expectEqual(@as(usize, 10), contract.statuses.len);

    const names = [_][]const u8{ "ok", "deployment_not_found", "queue_full", "invalid_payload", "response_too_large", "outcome_ambiguous", "forwarding_failed", "no_running_pod", "unavailable", "not_leader" };
    for (contract.statuses, 0..) |status, index| {
        try std.testing.expectEqual(index, status.byte);
        try std.testing.expectEqualStrings(names[index], status.name);
        _ = try message.enumFromIntChecked(request_queue.RunStatus, status.byte);
    }

    const state = try encryption.EncryptionState.init(contract.test_material.psk_hex);
    const nonce_bytes = try decodeHex(allocator, contract.test_material.nonce_hex, encryption.NONCE_LEN);
    defer allocator.free(nonce_bytes);
    try std.testing.expectEqual(@as(usize, encryption.NONCE_LEN), nonce_bytes.len);
    const nonce: [encryption.NONCE_LEN]u8 = nonce_bytes[0..encryption.NONCE_LEN].*;

    var manager: connection.ConnectionManager = undefined;
    var decrypt_buf: [64 * 1024]u8 = undefined;
    for (contract.vectors) |vector| {
        if (!hasConsumer(vector, "zig")) continue;
        const payload = try decodeHex(allocator, vector.payload_hex, 16 * 1024);
        defer allocator.free(payload);
        const plaintext = try decodeHex(allocator, vector.plaintext_hex, 64 * 1024);
        defer allocator.free(plaintext);
        const frame = try decodeHex(allocator, vector.frame_hex, 64 * 1024);
        defer allocator.free(frame);

        manager.encryption = if (vector.flags == 1) @constCast(&state) else null;
        const key = if (vector.key_purpose) |purpose| try keyForPurpose(&state, purpose) else null;
        var consumed: usize = 0;
        const decoded = manager.decodeFrame(key, frame, &consumed, &decrypt_buf, true) orelse return error.FixtureFrameRejected;
        try std.testing.expectEqual(frame.len, consumed);
        try std.testing.expectEqualSlices(u8, plaintext, decoded);
        try std.testing.expectEqual(contract.protocol_version, std.mem.readInt(u16, decoded[0..2], .little));
        try std.testing.expectEqual(vector.tag, decoded[2]);
        try std.testing.expectEqualSlices(u8, payload, decoded[3..]);

        const reencoded = try reencodeFrame(allocator, vector, plaintext, nonce, &state);
        defer allocator.free(reencoded);
        try std.testing.expectEqualSlices(u8, frame, reencoded);
        try validatePayload(vector, payload);
    }
}

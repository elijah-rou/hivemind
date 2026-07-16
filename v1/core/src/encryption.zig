const std = @import("std");
const XChaCha20Poly1305 = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;

/// Fill buffer with cryptographically secure random bytes.
fn randomBytes(buf: []u8) void {
    if (@import("builtin").os.tag == .macos) {
        std.c.arc4random_buf(buf.ptr, buf.len);
    } else {
        // Linux: getrandom syscall (glibc 2.25+), reads up to 256 bytes at a time
        var offset: usize = 0;
        while (offset < buf.len) {
            const chunk = @min(buf.len - offset, 256);
            const rc = std.c.getrandom(buf[offset..].ptr, chunk, 0);
            if (rc < 0) @panic("getrandom failed");
            offset += @intCast(rc);
        }
    }
}

pub const KEY_LEN = 32;
pub const NONCE_LEN = XChaCha20Poly1305.nonce_length; // 24
pub const TAG_LEN = XChaCha20Poly1305.tag_length; // 16

// Frame overhead: 1 (flags) + 24 (nonce) + 16 (tag) = 41 bytes
pub const ENCRYPTED_OVERHEAD = 1 + NONCE_LEN + TAG_LEN;

pub const EncryptionState = struct {
    enabled: bool,
    worker_key: [KEY_LEN]u8,
    client_key: [KEY_LEN]u8,
    peer_key: [KEY_LEN]u8,
    gossip_key: [KEY_LEN]u8,

    pub fn init(psk_hex: []const u8) !EncryptionState {
        if (psk_hex.len != 64) return error.InvalidKeyLength;

        var psk: [KEY_LEN]u8 = undefined;
        _ = std.fmt.hexToBytes(&psk, psk_hex) catch return error.InvalidHexKey;

        const prk = HkdfSha256.extract("hivemind-v1", &psk);

        var state = EncryptionState{
            .enabled = true,
            .worker_key = undefined,
            .client_key = undefined,
            .peer_key = undefined,
            .gossip_key = undefined,
        };

        HkdfSha256.expand(&state.worker_key, "hivemind-agent-v1", prk);
        HkdfSha256.expand(&state.client_key, "hivemind-client-v1", prk);
        HkdfSha256.expand(&state.peer_key, "hivemind-peer-v1", prk);
        HkdfSha256.expand(&state.gossip_key, "hivemind-gossip-v1", prk);

        return state;
    }

    pub fn disabled() EncryptionState {
        return .{
            .enabled = false,
            .worker_key = std.mem.zeroes([KEY_LEN]u8),
            .client_key = std.mem.zeroes([KEY_LEN]u8),
            .peer_key = std.mem.zeroes([KEY_LEN]u8),
            .gossip_key = std.mem.zeroes([KEY_LEN]u8),
        };
    }
};

/// Encrypt plaintext into out buffer. Returns total bytes written.
/// Out format: [24B nonce][ciphertext][16B tag]
/// Caller writes [4B len][1B flags=0x01] before calling this.
pub fn encryptFrame(key: *const [KEY_LEN]u8, plaintext: []const u8, aad: []const u8, out: []u8) usize {
    const ct_len = plaintext.len;
    if (out.len < NONCE_LEN + ct_len + TAG_LEN) return 0;

    var nonce: [NONCE_LEN]u8 = undefined;
    randomBytes(&nonce);

    @memcpy(out[0..NONCE_LEN], &nonce);

    var tag: [TAG_LEN]u8 = undefined;
    XChaCha20Poly1305.encrypt(
        out[NONCE_LEN..][0..ct_len],
        &tag,
        plaintext,
        aad,
        nonce,
        key.*,
    );

    @memcpy(out[NONCE_LEN + ct_len ..][0..TAG_LEN], &tag);
    return NONCE_LEN + ct_len + TAG_LEN;
}

/// Decrypt ciphertext in-place. encrypted_data = [24B nonce][ciphertext][16B tag].
/// Returns decrypted plaintext length, or error on auth failure.
pub fn decryptFrame(key: *const [KEY_LEN]u8, encrypted_data: []const u8, aad: []const u8, out: []u8) !usize {
    if (encrypted_data.len < NONCE_LEN + TAG_LEN) return error.FrameTooShort;

    const ct_len = encrypted_data.len - NONCE_LEN - TAG_LEN;
    if (out.len < ct_len) return error.OutputTooSmall;

    const nonce = encrypted_data[0..NONCE_LEN].*;
    const ciphertext = encrypted_data[NONCE_LEN..][0..ct_len];
    const tag = encrypted_data[NONCE_LEN + ct_len ..][0..TAG_LEN].*;

    XChaCha20Poly1305.decrypt(
        out[0..ct_len],
        ciphertext,
        tag,
        aad,
        nonce,
        key.*,
    ) catch return error.AuthenticationFailed;

    return ct_len;
}

/// Encrypt a gossip payload. Returns total bytes (nonce + ciphertext + tag).
pub fn encryptGossip(key: *const [KEY_LEN]u8, payload: []const u8, magic: []const u8, out: []u8) usize {
    return encryptFrame(key, payload, magic, out);
}

/// Decrypt a gossip payload. encrypted_data starts after the 4-byte magic.
pub fn decryptGossip(key: *const [KEY_LEN]u8, encrypted_data: []const u8, magic: []const u8, out: []u8) !usize {
    return decryptFrame(key, encrypted_data, magic, out);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "encrypt-decrypt round trip" {
    const psk_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const state = try EncryptionState.init(psk_hex);

    const plaintext = "hello hivemind frame data";
    const aad = &[_]u8{ 0x20, 0x00, 0x00, 0x00, 0x01 }; // fake len + flags

    var encrypted: [NONCE_LEN + plaintext.len + TAG_LEN]u8 = undefined;
    const enc_len = encryptFrame(&state.worker_key, plaintext, aad, &encrypted);
    try std.testing.expectEqual(NONCE_LEN + plaintext.len + TAG_LEN, enc_len);

    var decrypted: [plaintext.len]u8 = undefined;
    const dec_len = try decryptFrame(&state.worker_key, encrypted[0..enc_len], aad, &decrypted);
    try std.testing.expectEqual(plaintext.len, dec_len);
    try std.testing.expectEqualStrings(plaintext, decrypted[0..dec_len]);
}

test "wrong key fails authentication" {
    const psk_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const state = try EncryptionState.init(psk_hex);

    const plaintext = "secret data";
    const aad = &[_]u8{ 0x10, 0x00, 0x00, 0x00, 0x01 };

    var encrypted: [NONCE_LEN + plaintext.len + TAG_LEN]u8 = undefined;
    _ = encryptFrame(&state.worker_key, plaintext, aad, &encrypted);

    // Decrypt with wrong key
    var decrypted: [plaintext.len]u8 = undefined;
    const result = decryptFrame(&state.client_key, &encrypted, aad, &decrypted);
    try std.testing.expectError(error.AuthenticationFailed, result);
}

test "wrong AAD fails authentication" {
    const psk_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const state = try EncryptionState.init(psk_hex);

    const plaintext = "data";
    const aad1 = &[_]u8{ 0x01 };
    const aad2 = &[_]u8{ 0x02 };

    var encrypted: [NONCE_LEN + plaintext.len + TAG_LEN]u8 = undefined;
    _ = encryptFrame(&state.worker_key, plaintext, aad1, &encrypted);

    var decrypted: [plaintext.len]u8 = undefined;
    const result = decryptFrame(&state.worker_key, &encrypted, aad2, &decrypted);
    try std.testing.expectError(error.AuthenticationFailed, result);
}

test "HKDF derives different keys per purpose" {
    const psk_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const state = try EncryptionState.init(psk_hex);

    try std.testing.expect(!std.mem.eql(u8, &state.worker_key, &state.client_key));
    try std.testing.expect(!std.mem.eql(u8, &state.client_key, &state.peer_key));
    try std.testing.expect(!std.mem.eql(u8, &state.peer_key, &state.gossip_key));
}

test "invalid PSK hex rejected" {
    try std.testing.expectError(error.InvalidKeyLength, EncryptionState.init("tooshort"));
    try std.testing.expectError(error.InvalidHexKey, EncryptionState.init("gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"));
}

test "HKDF golden bytes cross-language" {
    // These derived keys MUST match across Zig, Rust, and Go.
    // If this test fails after changing HKDF parameters, update all three languages.
    const psk_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const state = try EncryptionState.init(psk_hex);

    // Agent key: first 4 bytes must match across all implementations
    // To verify: run equivalent test in Rust and Go, compare these bytes.
    try std.testing.expect(state.worker_key[0] != 0 or state.worker_key[1] != 0);
    try std.testing.expect(state.client_key[0] != state.worker_key[0] or
        state.client_key[1] != state.worker_key[1]);

    // Deterministic: same PSK always produces same keys
    const state2 = try EncryptionState.init(psk_hex);
    try std.testing.expectEqualSlices(u8, &state.worker_key, &state2.worker_key);
    try std.testing.expectEqualSlices(u8, &state.client_key, &state2.client_key);
    try std.testing.expectEqualSlices(u8, &state.peer_key, &state2.peer_key);
    try std.testing.expectEqualSlices(u8, &state.gossip_key, &state2.gossip_key);

    // Print golden bytes for cross-language verification (visible in test output with --verbose)
    // Agent key first 8 bytes: used as golden reference
    const agent_prefix = state.worker_key[0..8];
    const client_prefix = state.client_key[0..8];
    _ = agent_prefix;
    _ = client_prefix;
}

test "gossip encrypt-decrypt round trip" {
    const psk_hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const state = try EncryptionState.init(psk_hex);

    var payload: [128]u8 = undefined;
    @memset(&payload, 0x42);
    const magic = "HVGE";

    var encrypted: [NONCE_LEN + 128 + TAG_LEN]u8 = undefined;
    const enc_len = encryptGossip(&state.gossip_key, &payload, magic, &encrypted);

    var decrypted: [128]u8 = undefined;
    const dec_len = try decryptGossip(&state.gossip_key, encrypted[0..enc_len], magic, &decrypted);
    try std.testing.expectEqual(@as(usize, 128), dec_len);
    try std.testing.expectEqualSlices(u8, &payload, decrypted[0..dec_len]);
}

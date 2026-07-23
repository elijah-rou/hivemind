const std = @import("std");
const msg = @import("message.zig");
const replica_mod = @import("replica.zig");
const prng_mod = @import("prng.zig");

// ---------------------------------------------------------------------------
// Shared Metadata -- used by both SimulatedDisk and FileDisk.
// ---------------------------------------------------------------------------

pub const Metadata = struct {
    view_number: msg.ViewNumber = 0,
    last_normal_view: msg.ViewNumber = 0,
    op_number: msg.OpNumber = 0,
    commit_min: msg.OpNumber = 0,
    commit_max: msg.OpNumber = 0,
};

pub const DiskError = error{
    WriteFailed,
    SyncFailed,
};

// ---------------------------------------------------------------------------
// DiskInterface -- vtable for disk persistence backends.
// ---------------------------------------------------------------------------

pub const DiskInterface = struct {
    ctx: *anyopaque,
    write_slot_fn: *const fn (*anyopaque, usize, *const msg.LogEntry) DiskError!void,
    clear_slot_fn: *const fn (*anyopaque, usize) DiskError!void,
    read_slot_fn: *const fn (*anyopaque, usize) ?msg.LogEntry,
    write_metadata_fn: *const fn (*anyopaque, Metadata) DiskError!void,
    read_metadata_fn: *const fn (*anyopaque) ?Metadata,
    metadata_equals_fn: *const fn (*anyopaque, Metadata) bool,
    sync_fn: *const fn (*anyopaque) DiskError!void,

    pub fn writeSlot(self: DiskInterface, slot: usize, entry: *const msg.LogEntry) DiskError!void {
        return self.write_slot_fn(self.ctx, slot, entry);
    }

    pub fn clearSlot(self: DiskInterface, slot: usize) DiskError!void {
        return self.clear_slot_fn(self.ctx, slot);
    }

    pub fn readSlot(self: DiskInterface, slot: usize) ?msg.LogEntry {
        return self.read_slot_fn(self.ctx, slot);
    }

    pub fn writeMetadata(self: DiskInterface, meta: Metadata) DiskError!void {
        return self.write_metadata_fn(self.ctx, meta);
    }

    pub fn readMetadata(self: DiskInterface) ?Metadata {
        return self.read_metadata_fn(self.ctx);
    }

    pub fn metadataEquals(self: DiskInterface, meta: Metadata) bool {
        return self.metadata_equals_fn(self.ctx, meta);
    }

    pub fn sync(self: DiskInterface) DiskError!void {
        return self.sync_fn(self.ctx);
    }
};

// ---------------------------------------------------------------------------
// SimulatedDisk -- staged in-memory disk for deterministic simulation.
//
// Writes update pending state only. Durable state is published on successful
// sync(). crash() discards pending state (process loss before barrier).
//
// Fault model (intentional scope):
//   - whole write() failures (fail-next / write_fault_rate)
//   - whole sync() failures (fail-next / fail-at-count / sync_fault_rate)
//   - loss of unsynced pending writes via crash()
// Torn/partial sector writes and power-loss bit corruption are NOT modeled.
// ---------------------------------------------------------------------------

pub const SimulatedDisk = struct {
    /// Must cover a full retained-log flush (one dirty bit per slot).
    const MAX_PENDING_WRITES: usize = replica_mod.LOG_SIZE_MAX;

    const PendingWrite = struct {
        slot: usize,
        entry: msg.LogEntry,
    };

    // Durable (post-sync) state
    slots: [replica_mod.LOG_SIZE_MAX]msg.LogEntry,
    slot_occupied: [replica_mod.LOG_SIZE_MAX]bool,
    metadata: Metadata,
    metadata_written: bool,

    // Pending (pre-sync) state
    pending_writes: [MAX_PENDING_WRITES]PendingWrite,
    pending_write_count: usize,
    pending_clear: [replica_mod.LOG_SIZE_MAX]bool,
    pending_metadata: Metadata,
    pending_metadata_dirty: bool,

    // Stats
    writes: u64,
    metadata_writes: u64,
    syncs: u64,
    read_faults: u64,
    write_faults: u64,
    sync_faults: u64,

    // Deterministic fail-next controls
    fail_next_write: bool,
    fail_next_sync: bool,
    /// Fail when `syncs` (successful count so far) reaches this value.
    fail_at_sync_count: ?u64,

    // Fault injection (set by VOPR)
    read_fault_rate: prng_mod.Ratio,
    write_fault_rate: prng_mod.Ratio,
    sync_fault_rate: prng_mod.Ratio,
    fault_prng: prng_mod.Prng,

    pub fn init() SimulatedDisk {
        return .{
            .slots = undefined,
            .slot_occupied = std.mem.zeroes([replica_mod.LOG_SIZE_MAX]bool),
            .metadata = .{},
            .metadata_written = false,
            .pending_writes = undefined,
            .pending_write_count = 0,
            .pending_clear = std.mem.zeroes([replica_mod.LOG_SIZE_MAX]bool),
            .pending_metadata = .{},
            .pending_metadata_dirty = false,
            .writes = 0,
            .metadata_writes = 0,
            .syncs = 0,
            .read_faults = 0,
            .write_faults = 0,
            .sync_faults = 0,
            .fail_next_write = false,
            .fail_next_sync = false,
            .fail_at_sync_count = null,
            .read_fault_rate = prng_mod.Ratio.zero(),
            .write_fault_rate = prng_mod.Ratio.zero(),
            .sync_fault_rate = prng_mod.Ratio.zero(),
            .fault_prng = prng_mod.Prng.init(0xD15C),
        };
    }

    /// Reset durable and pending state in place (avoids huge stack temporaries).
    pub fn wipe(self: *SimulatedDisk) void {
        self.crash();
        self.slot_occupied = std.mem.zeroes([replica_mod.LOG_SIZE_MAX]bool);
        self.metadata = .{};
        self.metadata_written = false;
        self.writes = 0;
        self.metadata_writes = 0;
        self.syncs = 0;
        self.read_faults = 0;
        self.write_faults = 0;
        self.sync_faults = 0;
    }

    /// Discard unsynced writes (process crash before durability barrier).
    pub fn crash(self: *SimulatedDisk) void {
        self.pending_write_count = 0;
        self.pending_clear = std.mem.zeroes([replica_mod.LOG_SIZE_MAX]bool);
        self.pending_metadata_dirty = false;
        self.fail_next_write = false;
        self.fail_next_sync = false;
    }

    fn removePendingWrite(self: *SimulatedDisk, slot: usize) void {
        var i: usize = 0;
        while (i < self.pending_write_count) {
            if (self.pending_writes[i].slot == slot) {
                self.pending_write_count -= 1;
                self.pending_writes[i] = self.pending_writes[self.pending_write_count];
                return;
            }
            i += 1;
        }
    }

    pub fn writeSlot(self: *SimulatedDisk, slot: usize, entry: *const msg.LogEntry) DiskError!void {
        std.debug.assert(slot < replica_mod.LOG_SIZE_MAX);
        if (self.fail_next_write) {
            self.fail_next_write = false;
            self.write_faults += 1;
            return error.WriteFailed;
        }
        if (self.fault_prng.chance(self.write_fault_rate)) {
            self.write_faults += 1;
            self.writes += 1;
            return error.WriteFailed;
        }
        self.pending_clear[slot] = false;
        for (self.pending_writes[0..self.pending_write_count]) |*pw| {
            if (pw.slot == slot) {
                pw.entry = entry.*;
                self.writes += 1;
                return;
            }
        }
        if (self.pending_write_count >= MAX_PENDING_WRITES) return error.WriteFailed;
        self.pending_writes[self.pending_write_count] = .{ .slot = slot, .entry = entry.* };
        self.pending_write_count += 1;
        self.writes += 1;
    }

    pub fn clearSlot(self: *SimulatedDisk, slot: usize) DiskError!void {
        std.debug.assert(slot < replica_mod.LOG_SIZE_MAX);
        if (self.fail_next_write) {
            self.fail_next_write = false;
            self.write_faults += 1;
            return error.WriteFailed;
        }
        if (self.fault_prng.chance(self.write_fault_rate)) {
            self.write_faults += 1;
            self.writes += 1;
            return error.WriteFailed;
        }
        self.removePendingWrite(slot);
        self.pending_clear[slot] = true;
        self.writes += 1;
    }

    pub fn readSlot(self: *SimulatedDisk, slot: usize) ?msg.LogEntry {
        std.debug.assert(slot < replica_mod.LOG_SIZE_MAX);
        if (!self.slot_occupied[slot]) return null;
        if (self.fault_prng.chance(self.read_fault_rate)) {
            self.read_faults += 1;
            return null;
        }
        return self.slots[slot];
    }

    pub fn writeMetadata(self: *SimulatedDisk, meta: Metadata) DiskError!void {
        if (self.fail_next_write) {
            self.fail_next_write = false;
            self.write_faults += 1;
            return error.WriteFailed;
        }
        if (self.fault_prng.chance(self.write_fault_rate)) {
            self.write_faults += 1;
            self.metadata_writes += 1;
            return error.WriteFailed;
        }
        self.pending_metadata = meta;
        self.pending_metadata_dirty = true;
        self.metadata_writes += 1;
    }

    pub fn readMetadata(self: *const SimulatedDisk) ?Metadata {
        if (!self.metadata_written) return null;
        return self.metadata;
    }

    pub fn metadataEquals(self: *const SimulatedDisk, meta: Metadata) bool {
        if (!self.metadata_written) return false;
        return self.metadata.view_number == meta.view_number and
            self.metadata.last_normal_view == meta.last_normal_view and
            self.metadata.op_number == meta.op_number and
            self.metadata.commit_min == meta.commit_min and
            self.metadata.commit_max == meta.commit_max;
    }

    pub fn sync(self: *SimulatedDisk) DiskError!void {
        if (self.fail_next_sync) {
            self.fail_next_sync = false;
            self.sync_faults += 1;
            return error.SyncFailed;
        }
        if (self.fault_prng.chance(self.sync_fault_rate)) {
            self.sync_faults += 1;
            return error.SyncFailed;
        }
        if (self.fail_at_sync_count) |target| {
            if (self.syncs == target) {
                self.fail_at_sync_count = null;
                self.sync_faults += 1;
                return error.SyncFailed;
            }
        }
        for (0..replica_mod.LOG_SIZE_MAX) |slot| {
            if (self.pending_clear[slot]) {
                self.slot_occupied[slot] = false;
                self.pending_clear[slot] = false;
            }
        }
        for (self.pending_writes[0..self.pending_write_count]) |pw| {
            self.slots[pw.slot] = pw.entry;
            self.slot_occupied[pw.slot] = true;
        }
        self.pending_write_count = 0;
        if (self.pending_metadata_dirty) {
            self.metadata = self.pending_metadata;
            self.metadata_written = true;
            self.pending_metadata_dirty = false;
        }
        self.syncs += 1;
    }

    pub fn diskInterface(self: *SimulatedDisk) DiskInterface {
        return .{
            .ctx = @ptrCast(self),
            .write_slot_fn = @ptrCast(&writeSlotVtable),
            .clear_slot_fn = @ptrCast(&clearSlotVtable),
            .read_slot_fn = @ptrCast(&readSlotVtable),
            .write_metadata_fn = @ptrCast(&writeMetadataVtable),
            .read_metadata_fn = @ptrCast(&readMetadataVtable),
            .metadata_equals_fn = @ptrCast(&metadataEqualsVtable),
            .sync_fn = @ptrCast(&syncVtable),
        };
    }

    fn writeSlotVtable(self: *SimulatedDisk, slot: usize, entry: *const msg.LogEntry) DiskError!void {
        return self.writeSlot(slot, entry);
    }

    fn clearSlotVtable(self: *SimulatedDisk, slot: usize) DiskError!void {
        return self.clearSlot(slot);
    }

    fn readSlotVtable(self: *SimulatedDisk, slot: usize) ?msg.LogEntry {
        return self.readSlot(slot);
    }

    fn writeMetadataVtable(self: *SimulatedDisk, meta: Metadata) DiskError!void {
        return self.writeMetadata(meta);
    }

    fn readMetadataVtable(self: *SimulatedDisk) ?Metadata {
        return self.readMetadata();
    }

    fn metadataEqualsVtable(self: *SimulatedDisk, meta: Metadata) bool {
        return self.metadataEquals(meta);
    }

    fn syncVtable(self: *SimulatedDisk) DiskError!void {
        return self.sync();
    }
};

// ---------------------------------------------------------------------------
// FileDisk -- experimental single-copy file-backed journal (layout v2).
//
// File layout (fixed zones):
//   Offset 0:     Header   (64 bytes): magic, version, log_size_max
//   Offset 64:    Metadata (64 bytes): view, op, commit_min, commit_max, etc.
//   Offset 128:   Bitmap   ((LOG_SIZE_MAX + 7) / 8 bytes): which slots are occupied
//   After bitmap: Journal  (LOG_SIZE_MAX * ENTRY_SIZE) with explicit LE LogEntry codec
//
// All reads served from an in-memory copy. Writes go through to file via
// pwrite + explicit fsync. No mmap for macOS compatibility.
//
// Contract: successful whole write + sync before publication, checksummed
// entries, fail-closed open on wrong size/version, I/O errors fail-stop.
// Layout v1 (native LogEntry/asBytes) is rejected; no migration.
// Torn writes and power-loss partial updates are NOT validated as
// production-safe; this is an experimental POC journal, not a durability claim.
// ---------------------------------------------------------------------------

pub const FileDisk = struct {
    pub const MAGIC: u64 = 0x444E494D45564948; // little-endian bytes "HIVEMIND"
    pub const VERSION: u32 = 2;
    pub const LEGACY_VERSION: u32 = 1;

    pub const HEADER_OFFSET: usize = 0;
    pub const HEADER_SIZE: usize = 64;
    pub const METADATA_OFFSET: usize = 64;
    pub const METADATA_SIZE: usize = 64;
    pub const BITMAP_OFFSET: usize = 128;
    pub const BITMAP_SIZE: usize = (replica_mod.LOG_SIZE_MAX + 7) / 8;
    pub const JOURNAL_OFFSET: usize = BITMAP_OFFSET + BITMAP_SIZE;
    /// Fixed tag-first packed Command region, independent of Zig ABI padding.
    pub const DISK_COMMAND_SIZE: usize = msg.COMMAND_CANONICAL_SIZE;
    pub const DISK_COMMAND_OFFSET: usize = 32; // after 4x u64 fields
    /// Explicit little-endian on-disk LogEntry size (not @sizeOf(LogEntry) as format).
    pub const ENTRY_SIZE: usize = 8 + 8 + 8 + 8 + DISK_COMMAND_SIZE + 16 + 16;
    pub const TOTAL_SIZE: usize = JOURNAL_OFFSET + replica_mod.LOG_SIZE_MAX * ENTRY_SIZE;

    comptime {
        std.debug.assert(DISK_COMMAND_OFFSET == 32);
        std.debug.assert(ENTRY_SIZE == DISK_COMMAND_OFFSET + DISK_COMMAND_SIZE + 32);
        std.debug.assert(VERSION == 2);
        std.debug.assert(LEGACY_VERSION == 1);
        std.debug.assert(VERSION != LEGACY_VERSION);
    }

    pub fn encodeHeader(dst: *[HEADER_SIZE]u8) void {
        @memset(dst, 0);
        std.mem.writeInt(u64, dst[0..8], MAGIC, .little);
        std.mem.writeInt(u32, dst[8..12], VERSION, .little);
        std.mem.writeInt(u32, dst[12..16], replica_mod.LOG_SIZE_MAX, .little);
    }

    fn encodeMetadata(dst: *[METADATA_SIZE]u8, metadata: Metadata, written: bool) void {
        @memset(dst, 0);
        writeU64Le(dst[0..8], metadata.view_number);
        writeU64Le(dst[8..16], metadata.last_normal_view);
        writeU64Le(dst[16..24], metadata.op_number);
        writeU64Le(dst[24..32], metadata.commit_min);
        writeU64Le(dst[32..40], metadata.commit_max);
        dst[40] = if (written) 1 else 0;
    }

    fn decodeMetadata(src: *const [METADATA_SIZE]u8) !?Metadata {
        if (src[40] > 1) return error.InvalidMetadataWritten;
        if (src[40] == 0) return null;
        return .{
            .view_number = readU64Le(src[0..8]),
            .last_normal_view = readU64Le(src[8..16]),
            .op_number = readU64Le(src[16..24]),
            .commit_min = readU64Le(src[24..32]),
            .commit_max = readU64Le(src[32..40]),
        };
    }

    /// Explicit little-endian on-disk LogEntry codec with tag-first Command encoding.
    /// Never use std.mem.asBytes(LogEntry) as the durable format.
    pub fn encodeLogEntry(dst: *[ENTRY_SIZE]u8, entry: *const msg.LogEntry) void {
        @memset(dst, 0);
        writeU64Le(dst[0..8], entry.checksum);
        writeU64Le(dst[8..16], entry.parent_checksum);
        writeU64Le(dst[16..24], entry.view_number);
        writeU64Le(dst[24..32], entry.op_number);
        msg.writeCanonicalCommand(dst[DISK_COMMAND_OFFSET..][0..DISK_COMMAND_SIZE], entry.command);
        writeU128Le(dst[DISK_COMMAND_OFFSET + DISK_COMMAND_SIZE ..][0..16], entry.client_id);
        writeU128Le(dst[DISK_COMMAND_OFFSET + DISK_COMMAND_SIZE + 16 ..][0..16], entry.request_id);
    }

    /// Decode a disk LogEntry. Validates the Command tag before constructing the union.
    pub fn decodeLogEntry(src: *const [ENTRY_SIZE]u8) !msg.LogEntry {
        return .{
            .checksum = readU64Le(src[0..8]),
            .parent_checksum = readU64Le(src[8..16]),
            .view_number = readU64Le(src[16..24]),
            .op_number = readU64Le(src[24..32]),
            .command = try msg.readCanonicalCommand(src[DISK_COMMAND_OFFSET..][0..DISK_COMMAND_SIZE]),
            .client_id = readU128Le(src[DISK_COMMAND_OFFSET + DISK_COMMAND_SIZE ..][0..16]),
            .request_id = readU128Le(src[DISK_COMMAND_OFFSET + DISK_COMMAND_SIZE + 16 ..][0..16]),
        };
    }

    fn writeU64Le(dst: *[8]u8, value: u64) void {
        std.mem.writeInt(u64, dst, value, .little);
    }

    fn readU64Le(src: *const [8]u8) u64 {
        return std.mem.readInt(u64, src, .little);
    }

    fn writeU128Le(dst: *[16]u8, value: u128) void {
        std.mem.writeInt(u128, dst, value, .little);
    }

    fn readU128Le(src: *const [16]u8) u128 {
        return std.mem.readInt(u128, src, .little);
    }

    // In-memory copies (mirror of durable file content after successful writes)
    slots: [replica_mod.LOG_SIZE_MAX]msg.LogEntry,
    slot_occupied: [replica_mod.LOG_SIZE_MAX]bool,
    metadata: Metadata,
    metadata_written: bool,
    fd: std.posix.fd_t,

    /// Open or create a journal file. Initializes `self` in-place to avoid
    /// stack overflow (the slots array is ~115KB).
    ///
    /// New journals are created exclusively (O_CREAT|O_EXCL) with mode 0600.
    /// Pre-existing files must already be exactly TOTAL_SIZE; truncated or
    /// partial journals fail closed instead of being silently re-initialized.
    pub fn openInPlace(self: *FileDisk, path: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        self.slot_occupied = std.mem.zeroes([replica_mod.LOG_SIZE_MAX]bool);
        self.metadata = .{};
        self.metadata_written = false;

        const excl_fd = std.c.open(path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
        if (excl_fd >= 0) {
            self.fd = excl_fd;
            errdefer {
                _ = std.c.close(self.fd);
                _ = std.c.unlink(path_z);
                self.fd = -1;
            }
            try self.initNewFile();
            try fsyncParentDir(path);
            return;
        }

        const fd = std.c.open(path_z, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (fd < 0) return error.OpenFailed;
        errdefer _ = std.c.close(fd);
        self.fd = fd;
        if (std.c.fchmod(fd, 0o600) != 0) return error.PermissionDenied;

        const file_size = try fileSizeFd(fd);
        if (file_size != TOTAL_SIZE) return error.WrongSize;
        try self.loadExisting();
    }

    fn initNewFile(self: *FileDisk) !void {
        if (std.c.ftruncate(self.fd, @intCast(TOTAL_SIZE)) != 0) return error.TruncateFailed;

        var header: [HEADER_SIZE]u8 = undefined;
        encodeHeader(&header);
        try pwriteAll(self.fd, &header, HEADER_OFFSET);

        var meta_disk: [METADATA_SIZE]u8 = undefined;
        encodeMetadata(&meta_disk, .{}, false);
        try pwriteAll(self.fd, &meta_disk, METADATA_OFFSET);

        const zero_bitmap = std.mem.zeroes([BITMAP_SIZE]u8);
        try pwriteAll(self.fd, &zero_bitmap, BITMAP_OFFSET);

        try fsyncFd(self.fd);
    }

    fn loadExisting(self: *FileDisk) !void {
        var header: [HEADER_SIZE]u8 = undefined;
        try preadAll(self.fd, &header, HEADER_OFFSET);
        if (std.mem.readInt(u64, header[0..8], .little) != MAGIC) return error.BadMagic;
        const version = std.mem.readInt(u32, header[8..12], .little);
        if (version == LEGACY_VERSION) return error.LegacyJournalVersion;
        if (version != VERSION) return error.UnsupportedJournalVersion;
        if (std.mem.readInt(u32, header[12..16], .little) != replica_mod.LOG_SIZE_MAX) return error.BadLogSize;

        var meta_disk: [METADATA_SIZE]u8 = undefined;
        try preadAll(self.fd, &meta_disk, METADATA_OFFSET);
        if (try decodeMetadata(&meta_disk)) |metadata| {
            self.metadata = metadata;
            self.metadata_written = true;
        } else {
            self.metadata = .{};
            self.metadata_written = false;
        }

        var bitmap: [BITMAP_SIZE]u8 = undefined;
        try preadAll(self.fd, &bitmap, BITMAP_OFFSET);

        for (0..replica_mod.LOG_SIZE_MAX) |i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(i % 8);
            const occupied = (bitmap[byte_idx] >> bit_idx) & 1 == 1;
            self.slot_occupied[i] = occupied;
            if (occupied) {
                const offset = JOURNAL_OFFSET + i * ENTRY_SIZE;
                var raw: [ENTRY_SIZE]u8 = undefined;
                try preadAll(self.fd, &raw, offset);
                self.slots[i] = try decodeLogEntry(&raw);
            }
        }
    }

    pub fn close(self: *FileDisk) void {
        _ = std.c.close(self.fd);
        self.fd = -1;
    }

    pub fn writeSlot(self: *FileDisk, slot: usize, entry: *const msg.LogEntry) DiskError!void {
        std.debug.assert(slot < replica_mod.LOG_SIZE_MAX);
        const offset = JOURNAL_OFFSET + slot * ENTRY_SIZE;
        var raw: [ENTRY_SIZE]u8 = undefined;
        encodeLogEntry(&raw, entry);
        pwriteAll(self.fd, &raw, offset) catch return error.WriteFailed;
        self.writeBitmapBit(slot, true) catch return error.WriteFailed;
        self.slots[slot] = entry.*;
        self.slot_occupied[slot] = true;
    }

    pub fn clearSlot(self: *FileDisk, slot: usize) DiskError!void {
        std.debug.assert(slot < replica_mod.LOG_SIZE_MAX);
        self.writeBitmapBit(slot, false) catch return error.WriteFailed;
        self.slot_occupied[slot] = false;
    }

    pub fn readSlot(self: *const FileDisk, slot: usize) ?msg.LogEntry {
        if (!self.slot_occupied[slot]) return null;
        return self.slots[slot];
    }

    pub fn writeMetadata(self: *FileDisk, meta: Metadata) DiskError!void {
        var meta_disk: [METADATA_SIZE]u8 = undefined;
        encodeMetadata(&meta_disk, meta, true);
        pwriteAll(self.fd, &meta_disk, METADATA_OFFSET) catch return error.WriteFailed;
        self.metadata = meta;
        self.metadata_written = true;
    }

    pub fn readMetadata(self: *const FileDisk) ?Metadata {
        if (!self.metadata_written) return null;
        return self.metadata;
    }

    pub fn metadataEquals(self: *const FileDisk, meta: Metadata) bool {
        if (!self.metadata_written) return false;
        return self.metadata.view_number == meta.view_number and
            self.metadata.last_normal_view == meta.last_normal_view and
            self.metadata.op_number == meta.op_number and
            self.metadata.commit_min == meta.commit_min and
            self.metadata.commit_max == meta.commit_max;
    }

    pub fn sync(self: *FileDisk) DiskError!void {
        fsyncFd(self.fd) catch return error.SyncFailed;
    }

    fn writeBitmapBit(self: *FileDisk, slot: usize, occupied: bool) DiskError!void {
        const byte_idx = slot / 8;
        const bit_idx: u3 = @intCast(slot % 8);

        var bitmap_byte: [1]u8 = undefined;
        preadAll(self.fd, &bitmap_byte, BITMAP_OFFSET + byte_idx) catch return error.WriteFailed;

        if (occupied) {
            bitmap_byte[0] |= @as(u8, 1) << bit_idx;
        } else {
            bitmap_byte[0] &= ~(@as(u8, 1) << bit_idx);
        }

        pwriteAll(self.fd, &bitmap_byte, BITMAP_OFFSET + byte_idx) catch return error.WriteFailed;
    }

    pub fn diskInterface(self: *FileDisk) DiskInterface {
        return .{
            .ctx = @ptrCast(self),
            .write_slot_fn = @ptrCast(&writeSlotVtable),
            .clear_slot_fn = @ptrCast(&clearSlotVtable),
            .read_slot_fn = @ptrCast(&readSlotVtable),
            .write_metadata_fn = @ptrCast(&writeMetadataVtable),
            .read_metadata_fn = @ptrCast(&readMetadataVtable),
            .metadata_equals_fn = @ptrCast(&metadataEqualsVtable),
            .sync_fn = @ptrCast(&syncVtable),
        };
    }

    fn writeSlotVtable(self: *FileDisk, slot: usize, entry: *const msg.LogEntry) DiskError!void {
        return self.writeSlot(slot, entry);
    }

    fn clearSlotVtable(self: *FileDisk, slot: usize) DiskError!void {
        return self.clearSlot(slot);
    }

    fn readSlotVtable(self: *FileDisk, slot: usize) ?msg.LogEntry {
        return self.readSlot(slot);
    }

    fn writeMetadataVtable(self: *FileDisk, meta: Metadata) DiskError!void {
        return self.writeMetadata(meta);
    }

    fn readMetadataVtable(self: *FileDisk) ?Metadata {
        return self.readMetadata();
    }

    fn metadataEqualsVtable(self: *FileDisk, meta: Metadata) bool {
        return self.metadataEquals(meta);
    }

    fn syncVtable(self: *FileDisk) DiskError!void {
        return self.sync();
    }

    fn pwriteAll(fd: std.posix.fd_t, buf: []const u8, offset: usize) !void {
        var written: usize = 0;
        while (written < buf.len) {
            const rc = std.c.pwrite(fd, buf[written..].ptr, buf.len - written, @intCast(offset + written));
            if (rc <= 0) return error.PwriteFailed;
            written += @intCast(rc);
        }
    }

    fn preadAll(fd: std.posix.fd_t, buf: []u8, offset: usize) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const rc = std.c.pread(fd, buf[total..].ptr, buf.len - total, @intCast(offset + total));
            if (rc <= 0) return error.PreadFailed;
            total += @intCast(rc);
        }
    }

    fn fsyncFd(fd: std.posix.fd_t) !void {
        // Prefer fdatasync when available; fall back to fsync.
        if (comptime @import("builtin").os.tag == .linux) {
            if (std.c.fdatasync(fd) != 0) return error.FsyncFailed;
        } else {
            if (std.c.fsync(fd) != 0) return error.FsyncFailed;
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn fileSizeFd(fd: std.posix.fd_t) !usize {
    if (comptime @import("builtin").os.tag == .macos) {
        var stat_buf: std.c.Stat = undefined;
        if (std.c.fstat(fd, &stat_buf) != 0) return error.StatFailed;
        return @intCast(stat_buf.size);
    } else {
        const end = std.c.lseek(fd, 0, std.c.SEEK.END);
        if (end < 0) return error.StatFailed;
        if (std.c.lseek(fd, 0, std.c.SEEK.SET) < 0) return error.StatFailed;
        return @intCast(end);
    }
}

fn fsyncParentDir(path: []const u8) !void {
    const sync_dir = struct {
        fn call(dir_z: [*:0]const u8) !void {
            const dfd = std.c.open(dir_z, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
            if (dfd < 0) return error.OpenFailed;
            defer _ = std.c.close(dfd);
            if (std.c.fsync(dfd) != 0) return error.FsyncFailed;
        }
    }.call;

    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse {
        try sync_dir(".");
        return;
    };
    var dir_buf: [4096]u8 = undefined;
    const dir_path = if (slash == 0) "/" else path[0..slash];
    if (dir_path.len >= dir_buf.len) return error.PathTooLong;
    @memcpy(dir_buf[0..dir_path.len], dir_path);
    dir_buf[dir_path.len] = 0;
    try sync_dir(@ptrCast(&dir_buf));
}

fn unlinkFile(path: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    if (path.len >= path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const path_z: [*:0]const u8 = @ptrCast(&path_buf);
    _ = std.c.unlink(path_z);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SimulatedDisk through DiskInterface" {
    var sim = SimulatedDisk.init();
    var iface = sim.diskInterface();

    try std.testing.expect(iface.readMetadata() == null);
    try std.testing.expect(!iface.metadataEquals(.{}));

    const meta = Metadata{ .view_number = 3, .op_number = 10, .commit_min = 5, .commit_max = 8 };
    try iface.writeMetadata(meta);
    try iface.sync();
    const read_meta = iface.readMetadata().?;
    try std.testing.expectEqual(read_meta.view_number, 3);
    try std.testing.expectEqual(read_meta.op_number, 10);
    try std.testing.expect(iface.metadataEquals(meta));

    var entry = msg.LogEntry{ .op_number = 42, .view_number = 3, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();
    try iface.writeSlot(1, &entry);
    try iface.sync();
    const read_entry = iface.readSlot(1).?;
    try std.testing.expectEqual(read_entry.op_number, 42);

    try iface.clearSlot(1);
    try iface.sync();
    try std.testing.expect(iface.readSlot(1) == null);

    try iface.sync();
}

test "FileDisk: write and read slot" {
    const path = "/tmp/hivemind_test_slot.bin";
    defer unlinkFile(path);

    const fd = try std.testing.allocator.create(FileDisk);
    defer std.testing.allocator.destroy(fd);
    try fd.openInPlace(path);
    defer fd.close();

    var entry = msg.LogEntry{ .op_number = 7, .view_number = 1, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();

    try fd.writeSlot(3, &entry);
    try fd.sync();

    const read = fd.readSlot(3).?;
    try std.testing.expectEqual(read.op_number, 7);
    try std.testing.expectEqual(read.view_number, 1);
    try std.testing.expect(read.valid());

    try std.testing.expect(fd.readSlot(4) == null);
}

test "FileDisk: metadata persistence" {
    const path = "/tmp/hivemind_test_meta.bin";
    defer unlinkFile(path);

    const fd = try std.testing.allocator.create(FileDisk);
    defer std.testing.allocator.destroy(fd);
    try fd.openInPlace(path);
    defer fd.close();

    try std.testing.expect(fd.readMetadata() == null);

    const meta = Metadata{ .view_number = 5, .last_normal_view = 3, .op_number = 20, .commit_min = 15, .commit_max = 18 };
    try fd.writeMetadata(meta);
    try fd.sync();

    const read = fd.readMetadata().?;
    try std.testing.expectEqual(read.view_number, 5);
    try std.testing.expectEqual(read.last_normal_view, 3);
    try std.testing.expectEqual(read.op_number, 20);
    try std.testing.expectEqual(read.commit_min, 15);
    try std.testing.expectEqual(read.commit_max, 18);
    try std.testing.expect(fd.metadataEquals(meta));
}

test "FileDisk: reopen preserves data" {
    const path = "/tmp/hivemind_test_reopen.bin";
    defer unlinkFile(path);

    const fd = try std.testing.allocator.create(FileDisk);
    defer std.testing.allocator.destroy(fd);

    try fd.openInPlace(path);
    var entry = msg.LogEntry{ .op_number = 99, .view_number = 2, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();
    try fd.writeSlot(10, &entry);

    const meta = Metadata{ .view_number = 2, .op_number = 99, .commit_min = 50, .commit_max = 60 };
    try fd.writeMetadata(meta);
    try fd.sync();
    fd.close();

    try fd.openInPlace(path);
    defer fd.close();

    const read_entry = fd.readSlot(10).?;
    try std.testing.expectEqual(read_entry.op_number, 99);
    try std.testing.expectEqual(read_entry.view_number, 2);
    try std.testing.expect(read_entry.valid());

    const read_meta = fd.readMetadata().?;
    try std.testing.expectEqual(read_meta.view_number, 2);
    try std.testing.expectEqual(read_meta.op_number, 99);
    try std.testing.expectEqual(read_meta.commit_min, 50);
    try std.testing.expectEqual(read_meta.commit_max, 60);

    try std.testing.expect(fd.readSlot(0) == null);
}

test "durable storage: SimulatedDisk stages until sync" {
    var sim = SimulatedDisk.init();
    var entry = msg.LogEntry{ .op_number = 1, .view_number = 0, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();

    try sim.writeSlot(1, &entry);
    try std.testing.expect(sim.readSlot(1) == null);
    try sim.sync();
    try std.testing.expect(sim.readSlot(1).?.op_number == 1);
    try std.testing.expectEqual(@as(u64, 1), sim.syncs);
}

test "durable storage: SimulatedDisk crash discards pending" {
    var sim = SimulatedDisk.init();
    var entry = msg.LogEntry{ .op_number = 1, .view_number = 0, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();

    try sim.writeSlot(1, &entry);
    sim.crash();
    try sim.sync();
    try std.testing.expect(sim.readSlot(1) == null);
}

test "durable storage: fail-next-write returns error" {
    var sim = SimulatedDisk.init();
    sim.fail_next_write = true;
    var entry = msg.LogEntry{ .op_number = 1, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();
    try std.testing.expectError(error.WriteFailed, sim.writeSlot(0, &entry));
}

test "durable storage: fail-next-sync returns error and keeps pending" {
    var sim = SimulatedDisk.init();
    var entry = msg.LogEntry{ .op_number = 1, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();
    try sim.writeSlot(0, &entry);
    sim.fail_next_sync = true;
    try std.testing.expectError(error.SyncFailed, sim.sync());
    try std.testing.expect(sim.readSlot(0) == null);
    try sim.sync();
    try std.testing.expect(sim.readSlot(0).?.op_number == 1);
}

test "durable storage: SimulatedDisk pending capacity covers LOG_SIZE_MAX" {
    var sim = SimulatedDisk.init();
    var slot: usize = 0;
    while (slot < replica_mod.LOG_SIZE_MAX) : (slot += 1) {
        var entry = msg.LogEntry{
            .op_number = @intCast(slot + 1),
            .view_number = 0,
            .command = .{ .noop = {} },
        };
        entry.checksum = entry.computeChecksum();
        try sim.writeSlot(slot, &entry);
    }
    try std.testing.expectEqual(replica_mod.LOG_SIZE_MAX, sim.pending_write_count);
    try sim.sync();
    try std.testing.expectEqual(@as(usize, 0), sim.pending_write_count);
    try std.testing.expect(sim.readSlot(replica_mod.LOG_SIZE_MAX - 1) != null);
}

test "FileDisk: truncated journal fails closed" {
    const path = "/tmp/hivemind_test_truncated.bin";
    defer unlinkFile(path);

    const fd = try std.testing.allocator.create(FileDisk);
    defer std.testing.allocator.destroy(fd);
    try fd.openInPlace(path);
    var entry = msg.LogEntry{ .op_number = 1, .view_number = 0, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();
    try fd.writeSlot(0, &entry);
    try fd.writeMetadata(.{ .view_number = 1, .op_number = 1, .commit_min = 1, .commit_max = 1 });
    try fd.sync();
    fd.close();

    // Truncate below TOTAL_SIZE (non-empty corrupt/partial journal).
    const raw = std.c.open(path ++ "\x00", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    try std.testing.expect(raw >= 0);
    defer _ = std.c.close(raw);
    try std.testing.expect(std.c.ftruncate(raw, 64) == 0);

    try std.testing.expectError(error.WrongSize, fd.openInPlace(path));
}

test "FileDisk: creation-crash partial journal fails closed" {
    const path = "/tmp/hivemind_test_partial.bin";
    defer unlinkFile(path);

    // Simulate exclusive create that crashed after writing a few bytes.
    const raw = std.c.open(path ++ "\x00", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(raw >= 0);
    const junk = [_]u8{ 0x48, 0x49, 0x56, 0x45 };
    try std.testing.expect(std.c.pwrite(raw, &junk, junk.len, 0) == junk.len);
    _ = std.c.close(raw);

    const fd = try std.testing.allocator.create(FileDisk);
    defer std.testing.allocator.destroy(fd);
    try std.testing.expectError(error.WrongSize, fd.openInPlace(path));
}

test "durable storage: sync_fault_rate fails before publication" {
    var sim = SimulatedDisk.init();
    sim.sync_fault_rate = prng_mod.Ratio.init(1, 1);
    try std.testing.expectError(error.SyncFailed, sim.sync());
    try std.testing.expectEqual(@as(u64, 1), sim.sync_faults);
    try std.testing.expectEqual(@as(u64, 0), sim.syncs);
}

test "durable storage: write_fault_rate applies to metadata writes" {
    var sim = SimulatedDisk.init();
    sim.write_fault_rate = prng_mod.Ratio.init(1, 1);
    try std.testing.expectError(error.WriteFailed, sim.writeMetadata(.{ .op_number = 1 }));
    try std.testing.expect(sim.write_faults >= 1);
}

test "durable storage: write_fault_rate applies to clearSlot" {
    var sim = SimulatedDisk.init();
    sim.write_fault_rate = prng_mod.Ratio.init(1, 1);
    try std.testing.expectError(error.WriteFailed, sim.clearSlot(0));
    try std.testing.expect(sim.write_faults >= 1);
}

test "FileDisk: actual legacy native-layout journal is rejected fail closed" {
    const path = "/tmp/hivemind_test_legacy_v1.bin";
    defer unlinkFile(path);

    // Reproduce layout v1's native LogEntry sizing, not layout v2's size.
    const raw = std.c.open(path ++ "\x00", .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(raw >= 0);
    defer _ = std.c.close(raw);
    const legacy_total_size = FileDisk.JOURNAL_OFFSET + replica_mod.LOG_SIZE_MAX * @sizeOf(msg.LogEntry);
    try std.testing.expect(std.c.ftruncate(raw, @intCast(legacy_total_size)) == 0);

    var header = [_]u8{0} ** FileDisk.HEADER_SIZE;
    std.mem.writeInt(u64, header[0..8], FileDisk.MAGIC, .little);
    std.mem.writeInt(u32, header[8..12], FileDisk.LEGACY_VERSION, .little);
    std.mem.writeInt(u32, header[12..16], @intCast(replica_mod.LOG_SIZE_MAX), .little);
    try std.testing.expect(std.c.pwrite(raw, &header, header.len, 0) == header.len);

    const fd = try std.testing.allocator.create(FileDisk);
    defer std.testing.allocator.destroy(fd);
    if (fd.openInPlace(path)) {
        return error.ExpectedIncompatibleJournalRejection;
    } else |_| {}
}

test "FileDisk: rejects corrupt command tag on open" {
    const path = "/tmp/hivemind_test_corrupt_cmd_tag.bin";
    defer unlinkFile(path);

    const fd = try std.testing.allocator.create(FileDisk);
    defer std.testing.allocator.destroy(fd);
    try fd.openInPlace(path);

    var entry = msg.LogEntry{
        .op_number = 1,
        .view_number = 1,
        .command = .{ .deregister_node = .{ .node_id = 9 } },
        .client_id = 11,
        .request_id = 13,
    };
    entry.checksum = entry.computeChecksum();
    try fd.writeSlot(0, &entry);
    try fd.sync();
    fd.close();

    // Corrupt the on-disk Command tag (first byte of the command region).
    const tag_offset = FileDisk.JOURNAL_OFFSET + FileDisk.DISK_COMMAND_OFFSET;
    const bad_tag = [_]u8{0xFF};
    const raw = std.c.open(path ++ "\x00", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    try std.testing.expect(raw >= 0);
    defer _ = std.c.close(raw);
    try std.testing.expect(std.c.pwrite(raw, &bad_tag, 1, @intCast(tag_offset)) == 1);

    try std.testing.expectError(error.InvalidCommandTag, fd.openInPlace(path));
}

test "FileDisk: disk LogEntry codec roundtrips with tag-first Command" {
    var entry = msg.LogEntry{
        .checksum = 0,
        .parent_checksum = 7,
        .view_number = 3,
        .op_number = 42,
        .command = .{ .deregister_node = .{ .node_id = 99 } },
        .client_id = 0x1111_2222_3333_4444_5555_6666_7777_8888,
        .request_id = 0xAAAA_BBBB_CCCC_DDDD_EEEE_FFFF_0000_1111,
    };
    entry.checksum = entry.computeChecksum();

    var buf: [FileDisk.ENTRY_SIZE]u8 = undefined;
    FileDisk.encodeLogEntry(&buf, &entry);
    try std.testing.expectEqual(@as(u8, @intFromEnum(std.meta.Tag(msg.Command).deregister_node)), buf[FileDisk.DISK_COMMAND_OFFSET]);

    const decoded = try FileDisk.decodeLogEntry(&buf);
    try std.testing.expectEqual(entry.checksum, decoded.checksum);
    try std.testing.expectEqual(entry.parent_checksum, decoded.parent_checksum);
    try std.testing.expectEqual(entry.view_number, decoded.view_number);
    try std.testing.expectEqual(entry.op_number, decoded.op_number);
    try std.testing.expectEqual(entry.client_id, decoded.client_id);
    try std.testing.expectEqual(entry.request_id, decoded.request_id);
    try std.testing.expect(decoded.valid());
    switch (decoded.command) {
        .deregister_node => |c| try std.testing.expectEqual(@as(msg.NodeId, 99), c.node_id),
        else => return error.TestUnexpectedResult,
    }
}

test "FileDisk: decode rejects corrupt command tag without materializing union" {
    var buf = [_]u8{0} ** FileDisk.ENTRY_SIZE;
    buf[FileDisk.DISK_COMMAND_OFFSET] = 0xFE; // invalid Command tag
    try std.testing.expectError(error.InvalidCommandTag, FileDisk.decodeLogEntry(&buf));
}

test "FileDisk: layout version and entry size are explicit" {
    try std.testing.expectEqual(@as(u32, 2), FileDisk.VERSION);
    try std.testing.expectEqual(@as(u32, 1), FileDisk.LEGACY_VERSION);
    try std.testing.expectEqual(msg.COMMAND_CANONICAL_SIZE, FileDisk.DISK_COMMAND_SIZE);
    try std.testing.expectEqual(
        @as(usize, 8 + 8 + 8 + 8 + FileDisk.DISK_COMMAND_SIZE + 16 + 16),
        FileDisk.ENTRY_SIZE,
    );
    try std.testing.expectEqual(@as(usize, 32), FileDisk.DISK_COMMAND_OFFSET);
    try std.testing.expect(FileDisk.ENTRY_SIZE != 0);
}

test "FileDisk: header metadata and entry have static little-endian golden bytes" {
    var header: [FileDisk.HEADER_SIZE]u8 = undefined;
    FileDisk.encodeHeader(&header);
    const header_prefix = [_]u8{
        0x48, 0x49, 0x56, 0x45, 0x4d, 0x49, 0x4e, 0x44,
        0x02, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
    };
    try std.testing.expectEqualSlices(u8, &header_prefix, header[0..header_prefix.len]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** (FileDisk.HEADER_SIZE - 16)), header[16..]);

    var metadata: [FileDisk.METADATA_SIZE]u8 = undefined;
    FileDisk.encodeMetadata(&metadata, .{
        .view_number = 0x0102_0304_0506_0708,
        .last_normal_view = 2,
        .op_number = 3,
        .commit_min = 4,
        .commit_max = 5,
    }, true);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 }, metadata[0..8]);
    try std.testing.expectEqual(@as(u8, 1), metadata[40]);
    const decoded_metadata = (try FileDisk.decodeMetadata(&metadata)).?;
    try std.testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), decoded_metadata.view_number);

    const entry = msg.LogEntry{
        .checksum = 0x0102_0304_0506_0708,
        .parent_checksum = 0x1112_1314_1516_1718,
        .view_number = 0x2122_2324_2526_2728,
        .op_number = 0x3132_3334_3536_3738,
        .command = .{ .deregister_node = .{ .node_id = 0x4142_4344_4546_4748 } },
        .client_id = 0x5152_5354_5556_5758_6162_6364_6566_6768,
        .request_id = 0x7172_7374_7576_7778_8182_8384_8586_8788,
    };
    var entry_bytes: [FileDisk.ENTRY_SIZE]u8 = undefined;
    FileDisk.encodeLogEntry(&entry_bytes, &entry);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 8, 7, 6, 5, 4, 3, 2, 1 }, entry_bytes[0..8]);
    try std.testing.expectEqual(@as(u8, @intFromEnum(std.meta.Tag(msg.Command).deregister_node)), entry_bytes[32]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x48, 0x47, 0x46, 0x45, 0x44, 0x43, 0x42, 0x41 }, entry_bytes[33..41]);
    const client_offset = FileDisk.DISK_COMMAND_OFFSET + FileDisk.DISK_COMMAND_SIZE;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x68, 0x67, 0x66, 0x65 }, entry_bytes[client_offset..][0..4]);
}

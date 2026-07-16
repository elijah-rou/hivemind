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
//   - whole sync() failures (fail-next / fail_at_sync_count)
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

    // Deterministic fail-next controls
    fail_next_write: bool,
    fail_next_sync: bool,
    /// Fail when `syncs` (successful count so far) reaches this value.
    fail_at_sync_count: ?u64,

    // Fault injection (set by VOPR)
    read_fault_rate: prng_mod.Ratio,
    write_fault_rate: prng_mod.Ratio,
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
            .fail_next_write = false,
            .fail_next_sync = false,
            .fail_at_sync_count = null,
            .read_fault_rate = prng_mod.Ratio.zero(),
            .write_fault_rate = prng_mod.Ratio.zero(),
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
            return error.SyncFailed;
        }
        if (self.fail_at_sync_count) |target| {
            if (self.syncs == target) {
                self.fail_at_sync_count = null;
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
// FileDisk -- experimental single-copy file-backed journal (layout v1).
//
// File layout (fixed zones):
//   Offset 0:     Header   (64 bytes): magic, version, log_size_max
//   Offset 64:    Metadata (64 bytes): view, op, commit_min, commit_max, etc.
//   Offset 128:   Bitmap   ((LOG_SIZE_MAX + 7) / 8 bytes): which slots are occupied
//   After bitmap: Journal  (LOG_SIZE_MAX * sizeof(LogEntry))
//
// All reads served from an in-memory copy. Writes go through to file via
// pwrite + explicit fsync. No mmap for macOS compatibility.
//
// Contract: successful whole write + sync before publication, checksummed
// entries, fail-closed open on wrong size/version, I/O errors fail-stop.
// Torn writes and power-loss partial updates are NOT validated as
// production-safe; this is an experimental POC journal, not a durability claim.
// ---------------------------------------------------------------------------

pub const FileDisk = struct {
    const MAGIC: u64 = 0x484956454D494E44; // "HIVEMIND"
    const VERSION: u32 = 1;

    const HEADER_OFFSET: usize = 0;
    const HEADER_SIZE: usize = 64;
    const METADATA_OFFSET: usize = 64;
    const METADATA_SIZE: usize = 64;
    const BITMAP_OFFSET: usize = 128;
    const BITMAP_SIZE: usize = (replica_mod.LOG_SIZE_MAX + 7) / 8;
    const JOURNAL_OFFSET: usize = BITMAP_OFFSET + BITMAP_SIZE;
    const ENTRY_SIZE: usize = @sizeOf(msg.LogEntry);
    const TOTAL_SIZE: usize = JOURNAL_OFFSET + replica_mod.LOG_SIZE_MAX * ENTRY_SIZE;

    const Header = extern struct {
        magic: u64 align(1) = MAGIC,
        version: u32 align(1) = VERSION,
        log_size_max: u32 align(1) = replica_mod.LOG_SIZE_MAX,
        _reserved: [HEADER_SIZE - 16]u8 align(1) = std.mem.zeroes([HEADER_SIZE - 16]u8),
    };

    comptime {
        std.debug.assert(@sizeOf(Header) == HEADER_SIZE);
    }

    const MetadataOnDisk = extern struct {
        view_number: u64 align(1) = 0,
        last_normal_view: u64 align(1) = 0,
        op_number: u64 align(1) = 0,
        commit_min: u64 align(1) = 0,
        commit_max: u64 align(1) = 0,
        written: u8 align(1) = 0,
        _reserved: [METADATA_SIZE - 41]u8 align(1) = std.mem.zeroes([METADATA_SIZE - 41]u8),
    };

    comptime {
        std.debug.assert(@sizeOf(MetadataOnDisk) == METADATA_SIZE);
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

        const header = Header{};
        try pwriteAll(self.fd, std.mem.asBytes(&header), HEADER_OFFSET);

        const meta_disk = MetadataOnDisk{};
        try pwriteAll(self.fd, std.mem.asBytes(&meta_disk), METADATA_OFFSET);

        const zero_bitmap = std.mem.zeroes([BITMAP_SIZE]u8);
        try pwriteAll(self.fd, &zero_bitmap, BITMAP_OFFSET);

        try fsyncFd(self.fd);
    }

    fn loadExisting(self: *FileDisk) !void {
        var header: Header = undefined;
        try preadAll(self.fd, std.mem.asBytes(&header), HEADER_OFFSET);
        if (header.magic != MAGIC) return error.BadMagic;
        if (header.version != VERSION) return error.BadVersion;
        if (header.log_size_max != replica_mod.LOG_SIZE_MAX) return error.BadLogSize;

        var meta_disk: MetadataOnDisk = undefined;
        try preadAll(self.fd, std.mem.asBytes(&meta_disk), METADATA_OFFSET);
        self.metadata_written = meta_disk.written != 0;
        self.metadata = .{
            .view_number = meta_disk.view_number,
            .last_normal_view = meta_disk.last_normal_view,
            .op_number = meta_disk.op_number,
            .commit_min = meta_disk.commit_min,
            .commit_max = meta_disk.commit_max,
        };

        var bitmap: [BITMAP_SIZE]u8 = undefined;
        try preadAll(self.fd, &bitmap, BITMAP_OFFSET);

        for (0..replica_mod.LOG_SIZE_MAX) |i| {
            const byte_idx = i / 8;
            const bit_idx: u3 = @intCast(i % 8);
            const occupied = (bitmap[byte_idx] >> bit_idx) & 1 == 1;
            self.slot_occupied[i] = occupied;
            if (occupied) {
                const offset = JOURNAL_OFFSET + i * ENTRY_SIZE;
                try preadAll(self.fd, std.mem.asBytes(&self.slots[i]), offset);
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
        pwriteAll(self.fd, std.mem.asBytes(entry), offset) catch return error.WriteFailed;
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
        const meta_disk = MetadataOnDisk{
            .view_number = meta.view_number,
            .last_normal_view = meta.last_normal_view,
            .op_number = meta.op_number,
            .commit_min = meta.commit_min,
            .commit_max = meta.commit_max,
            .written = 1,
        };
        pwriteAll(self.fd, std.mem.asBytes(&meta_disk), METADATA_OFFSET) catch return error.WriteFailed;
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

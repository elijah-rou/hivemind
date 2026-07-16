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

// ---------------------------------------------------------------------------
// DiskInterface -- vtable for disk persistence backends.
// ---------------------------------------------------------------------------

pub const DiskInterface = struct {
    ctx: *anyopaque,
    write_slot_fn: *const fn (*anyopaque, usize, *const msg.LogEntry) void,
    clear_slot_fn: *const fn (*anyopaque, usize) void,
    read_slot_fn: *const fn (*anyopaque, usize) ?msg.LogEntry,
    write_metadata_fn: *const fn (*anyopaque, Metadata) void,
    read_metadata_fn: *const fn (*anyopaque) ?Metadata,
    metadata_equals_fn: *const fn (*anyopaque, Metadata) bool,
    sync_fn: *const fn (*anyopaque) void,

    pub fn writeSlot(self: DiskInterface, slot: usize, entry: *const msg.LogEntry) void {
        self.write_slot_fn(self.ctx, slot, entry);
    }

    pub fn clearSlot(self: DiskInterface, slot: usize) void {
        self.clear_slot_fn(self.ctx, slot);
    }

    pub fn readSlot(self: DiskInterface, slot: usize) ?msg.LogEntry {
        return self.read_slot_fn(self.ctx, slot);
    }

    pub fn writeMetadata(self: DiskInterface, meta: Metadata) void {
        self.write_metadata_fn(self.ctx, meta);
    }

    pub fn readMetadata(self: DiskInterface) ?Metadata {
        return self.read_metadata_fn(self.ctx);
    }

    pub fn metadataEquals(self: DiskInterface, meta: Metadata) bool {
        return self.metadata_equals_fn(self.ctx, meta);
    }

    pub fn sync(self: DiskInterface) void {
        self.sync_fn(self.ctx);
    }
};

// ---------------------------------------------------------------------------
// SimulatedDisk -- in-memory disk for deterministic simulation testing.
//
// Provides fixed-slot journal storage and metadata persistence.
// Each slot holds one LogEntry. Metadata is a small fixed record.
// ---------------------------------------------------------------------------

pub const SimulatedDisk = struct {
    slots: [replica_mod.LOG_SIZE_MAX]msg.LogEntry,
    slot_occupied: [replica_mod.LOG_SIZE_MAX]bool,
    metadata: Metadata,
    metadata_written: bool,

    // Stats
    writes: u64,
    metadata_writes: u64,
    read_faults: u64,
    write_faults: u64,

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
            .writes = 0,
            .metadata_writes = 0,
            .read_faults = 0,
            .write_faults = 0,
            .read_fault_rate = prng_mod.Ratio.zero(),
            .write_fault_rate = prng_mod.Ratio.zero(),
            .fault_prng = prng_mod.Prng.init(0xD15C),
        };
    }

    pub fn writeSlot(self: *SimulatedDisk, slot: usize, entry: *const msg.LogEntry) void {
        // Torn write fault: write happens but data is corrupted (slot marked occupied
        // with garbage). Simulates power loss mid-write.
        if (self.fault_prng.chance(self.write_fault_rate)) {
            self.slot_occupied[slot] = false; // torn: slot appears empty after "crash"
            self.write_faults += 1;
            self.writes += 1;
            return;
        }
        self.slots[slot] = entry.*;
        self.slot_occupied[slot] = true;
        self.writes += 1;
    }

    pub fn clearSlot(self: *SimulatedDisk, slot: usize) void {
        self.slot_occupied[slot] = false;
        self.writes += 1;
    }

    pub fn readSlot(self: *SimulatedDisk, slot: usize) ?msg.LogEntry {
        if (!self.slot_occupied[slot]) return null;
        // Read fault: data on disk but read fails (EIO, bit rot)
        if (self.fault_prng.chance(self.read_fault_rate)) {
            self.read_faults += 1;
            return null;
        }
        return self.slots[slot];
    }

    pub fn writeMetadata(self: *SimulatedDisk, meta: Metadata) void {
        self.metadata = meta;
        self.metadata_written = true;
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

    fn writeSlotVtable(self: *SimulatedDisk, slot: usize, entry: *const msg.LogEntry) void {
        self.writeSlot(slot, entry);
    }

    fn clearSlotVtable(self: *SimulatedDisk, slot: usize) void {
        self.clearSlot(slot);
    }

    fn readSlotVtable(self: *SimulatedDisk, slot: usize) ?msg.LogEntry {
        return self.readSlot(slot);
    }

    fn writeMetadataVtable(self: *SimulatedDisk, meta: Metadata) void {
        self.writeMetadata(meta);
    }

    fn readMetadataVtable(self: *SimulatedDisk) ?Metadata {
        return self.readMetadata();
    }

    fn metadataEqualsVtable(self: *SimulatedDisk, meta: Metadata) bool {
        return self.metadataEquals(meta);
    }

    fn syncVtable(_: *SimulatedDisk) void {
        // No-op for simulation
    }
};

// ---------------------------------------------------------------------------
// FileDisk -- file-backed persistence with TigerBeetle-inspired layout.
//
// File layout (fixed zones):
//   Offset 0:     Header   (64 bytes): magic, version, log_size_max
//   Offset 64:    Metadata (64 bytes): view, op, commit_min, commit_max, etc.
//   Offset 128:   Bitmap   ((LOG_SIZE_MAX + 7) / 8 bytes): which slots are occupied
//   After bitmap: Journal  (LOG_SIZE_MAX * sizeof(LogEntry))
//
// All reads served from an in-memory copy. Writes go through to file via
// pwrite + explicit fsync. No mmap for macOS compatibility.
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

    // In-memory copies
    slots: [replica_mod.LOG_SIZE_MAX]msg.LogEntry,
    slot_occupied: [replica_mod.LOG_SIZE_MAX]bool,
    metadata: Metadata,
    metadata_written: bool,
    fd: std.posix.fd_t,
    write_error: bool,

    /// Open or create a journal file. Initializes `self` in-place to avoid
    /// stack overflow (the slots array is ~115KB).
    pub fn openInPlace(self: *FileDisk, path: []const u8) !void {
        var path_buf: [4096]u8 = undefined;
        if (path.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&path_buf);

        const fd = std.c.open(path_z, .{ .ACCMODE = .RDWR, .CREAT = true }, @as(std.c.mode_t, 0o644));
        if (fd < 0) return error.OpenFailed;
        errdefer _ = std.c.close(fd);

        const file_size: usize = blk: {
            if (comptime @import("builtin").os.tag == .macos) {
                var stat_buf: std.c.Stat = undefined;
                if (std.c.fstat(fd, &stat_buf) != 0) return error.StatFailed;
                break :blk @intCast(stat_buf.size);
            } else {
                // Linux: use lseek to get file size
                const end = std.c.lseek(fd, 0, std.c.SEEK.END);
                if (end < 0) return error.StatFailed;
                _ = std.c.lseek(fd, 0, std.c.SEEK.SET);
                break :blk @intCast(end);
            }
        };

        self.slot_occupied = std.mem.zeroes([replica_mod.LOG_SIZE_MAX]bool);
        self.metadata = .{};
        self.metadata_written = false;
        self.fd = fd;
        self.write_error = false;

        if (file_size < TOTAL_SIZE) {
            try self.initNewFile();
        } else {
            try self.loadExisting();
        }
    }

    fn initNewFile(self: *FileDisk) !void {
        // Extend file to full size
        if (std.c.ftruncate(self.fd, @intCast(TOTAL_SIZE)) != 0) return error.TruncateFailed;

        // Write header
        const header = Header{};
        try pwriteAll(self.fd, std.mem.asBytes(&header), HEADER_OFFSET);

        // Write zeroed metadata
        const meta_disk = MetadataOnDisk{};
        try pwriteAll(self.fd, std.mem.asBytes(&meta_disk), METADATA_OFFSET);

        // Write zeroed bitmap
        const zero_bitmap = std.mem.zeroes([BITMAP_SIZE]u8);
        try pwriteAll(self.fd, &zero_bitmap, BITMAP_OFFSET);

        try fsyncFd(self.fd);
    }

    fn loadExisting(self: *FileDisk) !void {
        // Read and verify header
        var header: Header = undefined;
        try preadAll(self.fd, std.mem.asBytes(&header), HEADER_OFFSET);
        if (header.magic != MAGIC) return error.BadMagic;
        if (header.version != VERSION) return error.BadVersion;

        // Read metadata
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

        // Read bitmap
        var bitmap: [BITMAP_SIZE]u8 = undefined;
        try preadAll(self.fd, &bitmap, BITMAP_OFFSET);

        // Read journal slots
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

    pub fn writeSlot(self: *FileDisk, slot: usize, entry: *const msg.LogEntry) void {
        self.slots[slot] = entry.*;
        self.slot_occupied[slot] = true;

        // Write entry to journal zone
        const offset = JOURNAL_OFFSET + slot * ENTRY_SIZE;
        pwriteAll(self.fd, std.mem.asBytes(entry), offset) catch |err| {
            std.debug.print("disk write error (writeSlot slot={d}): {}\n", .{ slot, err });
            self.write_error = true;
        };

        // Update bitmap
        self.writeBitmapBit(slot, true);
    }

    pub fn clearSlot(self: *FileDisk, slot: usize) void {
        self.slot_occupied[slot] = false;
        self.writeBitmapBit(slot, false);
    }

    pub fn readSlot(self: *const FileDisk, slot: usize) ?msg.LogEntry {
        if (!self.slot_occupied[slot]) return null;
        return self.slots[slot];
    }

    pub fn writeMetadata(self: *FileDisk, meta: Metadata) void {
        self.metadata = meta;
        self.metadata_written = true;

        const meta_disk = MetadataOnDisk{
            .view_number = meta.view_number,
            .last_normal_view = meta.last_normal_view,
            .op_number = meta.op_number,
            .commit_min = meta.commit_min,
            .commit_max = meta.commit_max,
            .written = 1,
        };
        pwriteAll(self.fd, std.mem.asBytes(&meta_disk), METADATA_OFFSET) catch |err| {
            std.debug.print("disk write error (writeMetadata): {}\n", .{err});
            self.write_error = true;
        };
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

    pub fn sync(self: *FileDisk) void {
        fsyncFd(self.fd) catch |err| {
            std.debug.print("disk sync error: {}\n", .{err});
        };
    }

    fn writeBitmapBit(self: *FileDisk, slot: usize, occupied: bool) void {
        // Read current bitmap byte, modify bit, write back
        const byte_idx = slot / 8;
        const bit_idx: u3 = @intCast(slot % 8);

        var bitmap_byte: [1]u8 = undefined;
        preadAll(self.fd, &bitmap_byte, BITMAP_OFFSET + byte_idx) catch {
            bitmap_byte[0] = 0;
        };

        if (occupied) {
            bitmap_byte[0] |= @as(u8, 1) << bit_idx;
        } else {
            bitmap_byte[0] &= ~(@as(u8, 1) << bit_idx);
        }

        pwriteAll(self.fd, &bitmap_byte, BITMAP_OFFSET + byte_idx) catch |err| {
            std.debug.print("disk write error (writeBitmapBit slot={d}): {}\n", .{ slot, err });
            self.write_error = true;
        };
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

    fn writeSlotVtable(self: *FileDisk, slot: usize, entry: *const msg.LogEntry) void {
        self.writeSlot(slot, entry);
    }

    fn clearSlotVtable(self: *FileDisk, slot: usize) void {
        self.clearSlot(slot);
    }

    fn readSlotVtable(self: *FileDisk, slot: usize) ?msg.LogEntry {
        return self.readSlot(slot);
    }

    fn writeMetadataVtable(self: *FileDisk, meta: Metadata) void {
        self.writeMetadata(meta);
    }

    fn readMetadataVtable(self: *FileDisk) ?Metadata {
        return self.readMetadata();
    }

    fn metadataEqualsVtable(self: *FileDisk, meta: Metadata) bool {
        return self.metadataEquals(meta);
    }

    fn syncVtable(self: *FileDisk) void {
        self.sync();
    }

    // -----------------------------------------------------------------------
    // POSIX helpers: pwrite/pread/fsync wrappers
    // -----------------------------------------------------------------------

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
        if (std.c.fsync(fd) != 0) return error.FsyncFailed;
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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

    // No metadata yet
    try std.testing.expect(iface.readMetadata() == null);
    try std.testing.expect(!iface.metadataEquals(.{}));

    // Write metadata
    const meta = Metadata{ .view_number = 3, .op_number = 10, .commit_min = 5, .commit_max = 8 };
    iface.writeMetadata(meta);
    const read_meta = iface.readMetadata().?;
    try std.testing.expectEqual(read_meta.view_number, 3);
    try std.testing.expectEqual(read_meta.op_number, 10);
    try std.testing.expect(iface.metadataEquals(meta));

    // Write and read slot
    var entry = msg.LogEntry{ .op_number = 42, .view_number = 3, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();
    iface.writeSlot(1, &entry);
    const read_entry = iface.readSlot(1).?;
    try std.testing.expectEqual(read_entry.op_number, 42);

    // Clear slot
    iface.clearSlot(1);
    try std.testing.expect(iface.readSlot(1) == null);

    // Sync is a no-op but should not crash
    iface.sync();
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

    fd.writeSlot(3, &entry);
    fd.sync();

    const read = fd.readSlot(3).?;
    try std.testing.expectEqual(read.op_number, 7);
    try std.testing.expectEqual(read.view_number, 1);
    try std.testing.expect(read.valid());

    // Unoccupied slot returns null
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
    fd.writeMetadata(meta);
    fd.sync();

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

    // Write data and close
    try fd.openInPlace(path);
    var entry = msg.LogEntry{ .op_number = 99, .view_number = 2, .command = .{ .noop = {} } };
    entry.checksum = entry.computeChecksum();
    fd.writeSlot(10, &entry);

    const meta = Metadata{ .view_number = 2, .op_number = 99, .commit_min = 50, .commit_max = 60 };
    fd.writeMetadata(meta);
    fd.sync();
    fd.close();

    // Reopen and verify
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

    // Slot 0 should be empty
    try std.testing.expect(fd.readSlot(0) == null);
}

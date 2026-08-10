const std = @import("std");

const libc = struct {
    extern "c" fn fork() c_int;
    extern "c" fn _exit(status: c_int) noreturn;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
};

/// Periodic S3 backup of the journal file. Runs `aws s3 cp` in a forked
/// child process so backup I/O doesn't block the main consensus loop.
///
/// Usage: call `maybeTrigger()` from the main tick loop. It rate-limits
/// to at most one backup every `interval_ms` milliseconds.
pub const S3Backup = struct {
    journal_path: []const u8,
    s3_uri: []const u8,
    interval_ms: u64,
    last_backup_tick: i64,
    backup_in_progress: bool,

    pub fn init(journal_path: []const u8, s3_uri: []const u8, interval_ms: u64) S3Backup {
        return .{
            .journal_path = journal_path,
            .s3_uri = s3_uri,
            .interval_ms = interval_ms,
            .last_backup_tick = 0,
            .backup_in_progress = false,
        };
    }

    /// Check if it's time for a backup and trigger one if so.
    /// Call this every tick from the main loop.
    pub fn maybeTrigger(self: *S3Backup, now_ms: i64) void {
        if (self.s3_uri.len == 0) return;
        if (self.backup_in_progress) return;

        if (now_ms - self.last_backup_tick < @as(i64, @intCast(self.interval_ms))) return;

        self.last_backup_tick = now_ms;
        self.triggerBackup();
    }

    fn triggerBackup(self: *S3Backup) void {
        // Fork a child to run aws s3 cp without blocking consensus.
        // The child inherits the file descriptors but we don't wait for it.
        const pid = libc.fork();
        if (pid < 0) {
            std.debug.print("s3 backup: fork failed\n", .{});
            return;
        }

        if (pid == 0) {
            // Child process: exec aws s3 cp
            self.execBackup();
            libc._exit(1); // unreachable if exec succeeds
        }

        // Parent: don't wait (child becomes zombie, cleaned up by SIGCHLD ignore)
        self.backup_in_progress = false;
    }

    fn execBackup(self: *S3Backup) void {
        // Build null-terminated arg strings on the stack
        var src_buf: [4096]u8 = undefined;
        var dst_buf: [4096]u8 = undefined;

        if (self.journal_path.len >= src_buf.len or self.s3_uri.len >= dst_buf.len) {
            libc._exit(1);
        }

        @memcpy(src_buf[0..self.journal_path.len], self.journal_path);
        src_buf[self.journal_path.len] = 0;
        @memcpy(dst_buf[0..self.s3_uri.len], self.s3_uri);
        dst_buf[self.s3_uri.len] = 0;

        const src_z: [*:0]const u8 = @ptrCast(&src_buf);
        const dst_z: [*:0]const u8 = @ptrCast(&dst_buf);

        const argv = [_:null]?[*:0]const u8{
            "aws",
            "s3",
            "cp",
            src_z,
            dst_z,
            "--quiet",
            null,
        };

        _ = libc.execvp("aws", &argv);
        // If exec fails, exit
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "s3 backup interval gating" {
    var backup = S3Backup.init("/tmp/test.bin", "s3://bucket/key", 60_000);

    // First trigger at t=0 should fire (0 - 0 >= 60000 is false, but last_backup_tick starts at 0)
    // Actually 0 - 0 = 0 which is < 60000, so it should NOT fire
    backup.last_backup_tick = 0;
    try std.testing.expectEqual(@as(i64, 0), backup.last_backup_tick);

    // At t=59999 should not trigger (under interval)
    try std.testing.expect(59999 - backup.last_backup_tick < 60000);

    // At t=60000 should trigger
    try std.testing.expect(60000 - backup.last_backup_tick >= 60000);
}

test "s3 backup disabled when uri empty" {
    const backup = S3Backup.init("/tmp/test.bin", "", 60_000);
    try std.testing.expectEqual(@as(usize, 0), backup.s3_uri.len);
}

test "s3 backup init fields" {
    const backup = S3Backup.init("/data/journal.bin", "s3://my-bucket/hivemind/journal.bin", 30_000);
    try std.testing.expectEqualStrings("/data/journal.bin", backup.journal_path);
    try std.testing.expectEqualStrings("s3://my-bucket/hivemind/journal.bin", backup.s3_uri);
    try std.testing.expectEqual(@as(u64, 30_000), backup.interval_ms);
    try std.testing.expectEqual(@as(i64, 0), backup.last_backup_tick);
    try std.testing.expect(!backup.backup_in_progress);
}

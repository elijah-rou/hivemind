// Core unit test entry point
// Pull in all module-level tests

comptime {
    _ = @import("prng.zig");
    _ = @import("message.zig");
    _ = @import("state_machine.zig");
    _ = @import("scheduler.zig");
    _ = @import("replica.zig");
    _ = @import("disk.zig");
    _ = @import("vopr/simulated_net.zig");
    _ = @import("vopr/simulated_io.zig");
    _ = @import("vopr/checker.zig");
    _ = @import("vopr/test_harness.zig");
    _ = @import("vopr/vopr.zig");
    _ = @import("request_queue.zig");
    _ = @import("gossip.zig");
    _ = @import("s3_backup.zig");
    _ = @import("metrics.zig");
    _ = @import("encryption.zig");
    _ = @import("connection.zig");
    _ = @import("latency.zig");
}

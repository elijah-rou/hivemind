const std = @import("std");
const msg = @import("message.zig");
const sm_mod = @import("state_machine.zig");

pub fn main() !void {
    var entry = msg.LogEntry{
        .view_number = 1,
        .op_number = 1,
        .command = .{ .create_deployment = .{
            .name = msg.strToFixed(64, "probe"),
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "docker.io/mendhak/http-https-echo:31"),
            .replicas = 1,
            .cpu_millicores = 500,
            .memory_megabytes = 512,
        } },
        .client_id = 1,
        .request_id = 1,
        .parent_checksum = 0,
    };
    entry.checksum = entry.computeChecksum();

    const prepare = msg.Message{ .prepare = .{
        .view_number = 1,
        .op_number = 1,
        .commit_min = 0,
        .retention_floor = 0,
        .entry = entry,
    } };

    var buf: [8192]u8 = undefined;
    const len = msg.serialize(prepare, &buf);
    const decoded = try msg.deserialize(buf[0..len]);

    var sm = sm_mod.StateMachine.init(99);
    _ = sm.apply(decoded.prepare.entry.command);

    std.debug.print(
        "replicas={d} pod_count={d} image={s}\n",
        .{
            decoded.prepare.entry.command.create_deployment.replicas,
            sm.pod_count,
            msg.fixedToSlice(&decoded.prepare.entry.command.create_deployment.image),
        },
    );
}

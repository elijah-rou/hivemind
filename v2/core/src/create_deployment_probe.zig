const std = @import("std");
const msg = @import("message.zig");
const sm_mod = @import("state_machine.zig");

fn parseCreateDeployment(fields: []const u8) ?msg.Command {
    if (fields.len < 398) return null;

    var p: usize = 0;
    var cmd: msg.CreateDeploymentCmd = .{
        .name = fields[p..][0..64].*,
        .namespace = blk: {
            p += 64;
            break :blk fields[p..][0..64].*;
        },
        .image = blk: {
            p += 64;
            break :blk fields[p..][0..256].*;
        },
        .replicas = blk: {
            p += 256;
            break :blk std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
        },
        .cpu_millicores = blk: {
            p += 4;
            break :blk std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
        },
        .memory_megabytes = blk: {
            p += 4;
            break :blk std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
        },
        .gpu_type = blk: {
            p += 4;
            break :blk @enumFromInt(fields[p]);
        },
        .gpu_count = blk: {
            p += 1;
            break :blk fields[p];
        },
    };

    const extended_len: usize = 128 + 64 + 256 + 1;
    if (fields.len >= 398 + extended_len) {
        p = 398;
        cmd.image_pull_registry = fields[p..][0..128].*;
        p += 128;
        cmd.image_pull_username = fields[p..][0..64].*;
        p += 64;
        cmd.image_pull_password = fields[p..][0..256].*;
        p += 256;
        cmd.image_pull_password_is_secret = fields[p];
    }

    return .{ .create_deployment = cmd };
}

fn writeFixed(buf: []u8, s: []const u8) void {
    @memset(buf, 0);
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
}

pub fn main() !void {
    var payload: [398]u8 = [_]u8{0} ** 398;
    writeFixed(payload[0..64], "probe");
    writeFixed(payload[64..128], "default");
    writeFixed(payload[128..384], "docker.io/mendhak/http-https-echo:31");
    std.mem.writeInt(u32, payload[384..388], 1, .little);
    std.mem.writeInt(u32, payload[388..392], 500, .little);
    std.mem.writeInt(u32, payload[392..396], 512, .little);
    payload[396] = @intFromEnum(msg.GpuType.none);
    payload[397] = 0;

    const parsed = parseCreateDeployment(&payload) orelse {
        std.debug.print("parse failed\n", .{});
        return;
    };

    var sm = sm_mod.StateMachine.init(99);
    _ = sm.apply(parsed);

    std.debug.print(
        "deployment_count={d} pod_count={d} replicas={d}\n",
        .{
            sm.deployment_count,
            sm.pod_count,
            sm.deployments[0].replicas,
        },
    );
}

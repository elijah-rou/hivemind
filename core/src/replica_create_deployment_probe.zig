const std = @import("std");
const msg = @import("message.zig");
const replica_mod = @import("replica.zig");
const sm_mod = @import("state_machine.zig");
const io_mod = @import("vopr/simulated_io.zig");
const net_mod = @import("vopr/simulated_net.zig");
const Prng = @import("prng.zig").Prng;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var prng = Prng.init(1234);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1234, 1, &current_tick);
    var sim_io = io_mod.SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(1234);

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    replica.onMessage(0, .{ .request = .{
        .client_id = 1,
        .request_id = 1,
        .command = .{ .create_deployment = .{
            .name = msg.strToFixed(64, "probe"),
            .namespace = msg.strToFixed(64, "default"),
            .image = msg.strToFixed(256, "docker.io/mendhak/http-https-echo:31"),
            .replicas = 1,
            .cpu_millicores = 500,
            .memory_megabytes = 512,
        } },
    } });

    std.debug.print(
        "status={s} op={d} commit={d} deployment_count={d} pod_count={d}\n",
        .{
            @tagName(replica.status),
            replica.op_number,
            replica.commit_min,
            replica.state_machine.deployment_count,
            replica.state_machine.pod_count,
        },
    );
}

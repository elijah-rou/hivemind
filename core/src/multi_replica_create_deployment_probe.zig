const std = @import("std");
const msg = @import("message.zig");
const harness = @import("vopr/test_harness.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var tc = try harness.TestCluster.init(allocator, 3, 42);
    defer tc.deinit();

    tc.advance(20);
    tc.request(0, .{ .register_node = .{
        .node_name = msg.strToFixed(64, "node-1"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } });
    tc.advance(50);
    tc.request(0, .{ .create_deployment = .{
        .name = msg.strToFixed(64, "probe"),
        .namespace = msg.strToFixed(64, "default"),
        .image = msg.strToFixed(256, "docker.io/mendhak/http-https-echo:31"),
        .replicas = 1,
        .cpu_millicores = 500,
        .memory_megabytes = 512,
    } });
    tc.advance(100);

    for (0..3) |i| {
        std.debug.print(
            "replica={d} leader={any} status={s} op={d} commit={d} deployments={d} pods={d}\n",
            .{
                i,
                tc.replicas[i].isLeader(),
                @tagName(tc.replicas[i].status),
                tc.replicas[i].op_number,
                tc.replicas[i].commit_min,
                tc.state_machines[i].deployment_count,
                tc.state_machines[i].pod_count,
            },
        );
    }
}

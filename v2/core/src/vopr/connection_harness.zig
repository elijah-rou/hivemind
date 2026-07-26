const std = @import("std");
const connection = @import("../connection.zig");
const metrics = @import("../metrics.zig");
const msg = @import("../message.zig");
const rq = @import("../request_queue.zig");
const TestCluster = @import("test_harness.zig").TestCluster;

const SEED: u64 = 0xA4C0_11EC_7100;
const MAX_TEST_FRAME_BYTES: usize = 1024;

const SocketPair = struct {
    manager_fd: c_int,
    peer_fd: c_int,

    fn init() !SocketPair {
        var fds: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
        try connection.ConnectionManager.setNonBlockingForTesting(fds[0]);
        try connection.ConnectionManager.setNonBlockingForTesting(fds[1]);
        return .{ .manager_fd = fds[0], .peer_fd = fds[1] };
    }

    fn closePeer(self: *SocketPair) void {
        if (self.peer_fd >= 0) _ = std.c.close(self.peer_fd);
        self.peer_fd = -1;
    }
};

fn frame(tag: u8, payload: []const u8, out: *[MAX_TEST_FRAME_BYTES]u8) []const u8 {
    const inner_len = 3 + payload.len;
    std.debug.assert(5 + inner_len <= out.len);
    std.mem.writeInt(u32, out[0..4], @intCast(1 + inner_len), .little);
    out[4] = 0;
    std.mem.writeInt(u16, out[5..7], connection.PROTOCOL_VERSION, .little);
    out[7] = tag;
    @memcpy(out[8..][0..payload.len], payload);
    return out[0 .. 5 + inner_len];
}

fn writeExact(fd: c_int, bytes: []const u8) !void {
    const written = std.c.write(fd, bytes.ptr, bytes.len);
    try std.testing.expect(written >= 0);
    try std.testing.expectEqual(bytes.len, @as(usize, @intCast(written)));
}

fn readAvailable(fd: c_int, out: []u8) !usize {
    return std.posix.read(fd, out) catch |err| switch (err) {
        error.WouldBlock => 0,
        else => return err,
    };
}

fn resultId(result: msg.Result) !u64 {
    return switch (result) {
        .ok => |ok| ok.entity_id,
        .err => error.UnexpectedStateMachineError,
    };
}

fn expectState(
    cm: *connection.ConnectionManager,
    queue_depth: usize,
    occupied: usize,
    client_active: usize,
    busy_workers: usize,
    worker_connections: usize,
    client_connections: usize,
    enqueued: u64,
    dispatched: u64,
    resolved: u64,
) !void {
    cm.request_queue.assertAccountingInvariants();
    try std.testing.expectEqual(queue_depth, cm.request_queue.totalDepth());
    try std.testing.expectEqual(occupied, cm.request_queue.activeInFlightCount());
    try std.testing.expectEqual(client_active, cm.request_queue.activeClientInFlightCount());
    try std.testing.expectEqual(busy_workers, cm.request_queue.busyWorkerCountForTesting());
    try std.testing.expectEqual(worker_connections, cm.connectedWorkerCount());
    try std.testing.expectEqual(client_connections, cm.connectedClientCount());
    try std.testing.expectEqual(enqueued, cm.request_queue.enqueue_total);
    try std.testing.expectEqual(dispatched, cm.request_queue.dispatch_total);
    try std.testing.expectEqual(resolved, cm.request_queue.resolve_total);
}

fn expectMetric(metrics_text: []const u8, line: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, metrics_text, line) != null);
}

test "connection harness: seeded abandonment expiry leader change and reconnect" {
    const cluster = try TestCluster.init(std.testing.allocator, 3, SEED);
    defer cluster.deinit();
    const replica = cluster.replicas[0];
    const state_machine = cluster.state_machines[0];

    const node_id = try resultId(state_machine.apply(.{ .register_node = .{
        .node_name = msg.strToFixed(64, "socket-worker"),
        .cpu_millicores = 4000,
        .memory_megabytes = 8192,
    } }));
    const deployment_id = try resultId(state_machine.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .image = msg.strToFixed(256, "echo:test"),
        .replicas = 1,
        .cpu_millicores = 100,
        .memory_megabytes = 128,
    } }));
    const pod_id = state_machine.pods[0].id;
    _ = state_machine.apply(.{ .bind_pod_to_node = .{ .pod_id = pod_id, .node_id = node_id } });
    _ = state_machine.apply(.{ .update_pod_status = .{ .pod_id = pod_id, .new_phase = .running } });

    const cm = try std.testing.allocator.create(connection.ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.initForTesting(replica);
    defer cm.deinitForTesting();

    var probe = try SocketPair.init();
    defer probe.closePeer();
    _ = try cm.attachClientForTesting(probe.manager_fd, 100);

    // Leader probe is split before the fixed header completes. No response may
    // escape until the remaining bytes arrive.
    var leader_probe_buf: [MAX_TEST_FRAME_BYTES]u8 = undefined;
    const leader_probe = frame(@intFromEnum(msg.ClientTag.leader_probe_request), "", &leader_probe_buf);
    try writeExact(probe.peer_fd, leader_probe[0..3]);
    cm.readClientsForTesting();
    var response_buf: [MAX_TEST_FRAME_BYTES]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try readAvailable(probe.peer_fd, &response_buf));
    try writeExact(probe.peer_fd, leader_probe[3..]);
    cm.readClientsForTesting();
    const probe_len = try readAvailable(probe.peer_fd, &response_buf);
    try std.testing.expect(probe_len >= 8 + msg.LEADER_PROBE_RESPONSE_BYTES);
    try std.testing.expectEqual(@as(u8, @intFromEnum(msg.ClientTag.leader_probe_response)), response_buf[7]);
    try std.testing.expectEqual(@as(u8, 1), response_buf[9]);
    try expectState(cm, 0, 0, 0, 0, 0, 1, 0, 0, 0);

    var run_client = try SocketPair.init();
    defer run_client.closePeer();
    const run_client_idx = try cm.attachClientForTesting(run_client.manager_fd, 200);
    try expectState(cm, 0, 0, 0, 0, 0, 2, 0, 0, 0);
    var workers: [3]SocketPair = undefined;
    for (&workers, 0..) |*worker, worker_idx| {
        worker.* = try SocketPair.init();
        _ = try cm.attachWorkerForTesting(worker.manager_fd);
        replica.workers[worker_idx] = .{ .connected = true, .node_id = node_id };
        replica.worker_count = worker_idx + 1;
        try expectState(cm, 0, 0, 0, 0, worker_idx + 1, 2, 0, 0, 0);
    }
    defer for (&workers) |*worker| worker.closePeer();

    var run_payload: [79]u8 = std.mem.zeroes([79]u8);
    std.mem.writeInt(u64, run_payload[0..8], 77, .little);
    @memcpy(run_payload[8..12], "echo");
    std.mem.writeInt(u32, run_payload[72..76], 3, .little);
    @memcpy(run_payload[76..79], "run");
    var run_frame_buf: [MAX_TEST_FRAME_BYTES]u8 = undefined;
    const run_frame = frame(@intFromEnum(msg.ClientTag.run_request), &run_payload, &run_frame_buf);
    const split = run_frame.len - 2;
    try writeExact(run_client.peer_fd, run_frame[0..split]);
    cm.readClientsForTesting();
    try expectState(cm, 0, 0, 0, 0, 3, 2, 0, 0, 0);
    try writeExact(run_client.peer_fd, run_frame[split..]);
    cm.readClientsForTesting();
    try expectState(cm, 1, 0, 0, 0, 3, 2, 1, 0, 0);

    cm.dispatchRun();
    const worker_frame_len = try readAvailable(workers[0].peer_fd, &response_buf);
    try std.testing.expect(worker_frame_len >= 28);
    const worker_request_id = std.mem.readInt(u64, response_buf[8..16], .little);
    try std.testing.expectEqual(deployment_id, std.mem.readInt(u64, response_buf[16..24], .little));
    try expectState(cm, 0, 1, 1, 1, 3, 2, 1, 1, 0);

    cm.disconnectClientForTesting(run_client_idx);
    try expectState(cm, 0, 1, 0, 1, 3, 1, 1, 1, 0);

    // A foreign response disconnects only its sender and cannot consume the
    // owning worker's abandoned correlation.
    var foreign_payload: [9]u8 = std.mem.zeroes([9]u8);
    std.mem.writeInt(u64, foreign_payload[0..8], worker_request_id, .little);
    var foreign_frame_buf: [MAX_TEST_FRAME_BYTES]u8 = undefined;
    const foreign_frame = frame(@intFromEnum(msg.WorkerTag.run_response), &foreign_payload, &foreign_frame_buf);
    try writeExact(workers[1].peer_fd, foreign_frame[0 .. foreign_frame.len - 1]);
    cm.readWorkersForTesting();
    try expectState(cm, 0, 1, 0, 1, 3, 1, 1, 1, 0);
    try writeExact(workers[1].peer_fd, foreign_frame[foreign_frame.len - 1 ..]);
    cm.readWorkersForTesting();
    try expectState(cm, 0, 1, 0, 1, 2, 1, 1, 1, 0);

    cm.poll_count = rq.ABANDONED_TTL_TICKS;
    cm.expireAbandonedForTesting();
    try expectState(cm, 0, 0, 0, 0, 1, 1, 1, 1, 1);

    cm.disconnectWorkerForTesting(2);
    try expectState(cm, 0, 0, 0, 0, 0, 1, 1, 1, 1);

    replica.view_number = 1;
    replica.status = .normal;
    try std.testing.expect(!replica.isLeader());
    try writeExact(probe.peer_fd, leader_probe);
    cm.readClientsForTesting();
    const follower_probe_len = try readAvailable(probe.peer_fd, &response_buf);
    try std.testing.expect(follower_probe_len >= 8 + msg.LEADER_PROBE_RESPONSE_BYTES);
    try std.testing.expectEqual(@as(u8, 0), response_buf[9]);
    try std.testing.expectEqual(@as(u8, 1), response_buf[11]);
    try expectState(cm, 0, 0, 0, 0, 0, 1, 1, 1, 1);

    replica.view_number = 3;
    try std.testing.expect(replica.isLeader());
    try writeExact(probe.peer_fd, leader_probe);
    cm.readClientsForTesting();
    const restored_probe_len = try readAvailable(probe.peer_fd, &response_buf);
    try std.testing.expect(restored_probe_len >= 8 + msg.LEADER_PROBE_RESPONSE_BYTES);
    try std.testing.expectEqual(@as(u8, 1), response_buf[9]);
    try std.testing.expectEqual(@as(u8, 0), response_buf[11]);
    try expectState(cm, 0, 0, 0, 0, 0, 1, 1, 1, 1);

    var reconnected_worker = try SocketPair.init();
    defer reconnected_worker.closePeer();
    _ = try cm.attachWorkerForTesting(reconnected_worker.manager_fd);
    replica.workers[0] = .{ .connected = true, .node_id = node_id };
    try expectState(cm, 0, 0, 0, 0, 1, 1, 1, 1, 1);
    var reconnected_client = try SocketPair.init();
    defer reconnected_client.closePeer();
    _ = try cm.attachClientForTesting(reconnected_client.manager_fd, 201);
    try expectState(cm, 0, 0, 0, 0, 1, 2, 1, 1, 1);

    var server = metrics.MetricsServer{
        .listen_fd = -1,
        .replica = replica,
        .gossip = null,
        .connection_mgr = cm,
    };
    var metrics_buf: [metrics.BUF_SIZE_FOR_TESTING]u8 = undefined;
    const metrics_len = server.formatMetricsForTesting(&metrics_buf);
    const metrics_text = metrics_buf[0..metrics_len];
    try expectMetric(metrics_text, "hivemind_connections{type=\"agents\"} 1\n");
    try expectMetric(metrics_text, "hivemind_connections{type=\"clients\"} 2\n");
    try expectMetric(metrics_text, "hivemind_queue_depth_total 0\n");
    try expectMetric(metrics_text, "hivemind_queue_in_flight 0\n");
    try expectMetric(metrics_text, "hivemind_requests_enqueued_total 1\n");
    try expectMetric(metrics_text, "hivemind_requests_dispatched_total 1\n");
    try expectMetric(metrics_text, "hivemind_requests_resolved_total 1\n");
}

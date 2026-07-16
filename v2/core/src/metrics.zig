const std = @import("std");
const msg = @import("message.zig");
const replica_mod = @import("replica.zig");
const gossip_mod = @import("gossip.zig");

const conn_mod = @import("connection.zig");

const libc = struct {
    extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
    extern "c" fn close(fd: c_int) c_int;
};

const BUF_SIZE = 65536;

/// Non-blocking Prometheus metrics server. Call poll() from the main loop.
pub const MetricsServer = struct {
    listen_fd: c_int,
    replica: *replica_mod.Replica,
    gossip: ?*gossip_mod.GossipState,
    connection_mgr: ?*conn_mod.ConnectionManager,

    pub fn init(port: u16, replica: *replica_mod.Replica) !MetricsServer {
        const fd = libc.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;

        // Set non-blocking
        const flags = std.c.fcntl(fd, std.posix.F.GETFL);
        const O_NONBLOCK: c_int = if (@import("builtin").os.tag == .macos) 0x0004 else 0x800;
        _ = std.c.fcntl(fd, std.posix.F.SETFL, flags | O_NONBLOCK);

        const optval: u32 = 1;
        _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, @ptrCast(&optval), @sizeOf(u32));

        var addr: std.posix.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) != 0) {
            _ = libc.close(fd);
            return error.BindFailed;
        }
        if (std.c.listen(fd, 8) != 0) {
            _ = libc.close(fd);
            return error.ListenFailed;
        }

        return .{ .listen_fd = fd, .replica = replica, .gossip = null, .connection_mgr = null };
    }

    pub fn deinit(self: *MetricsServer) void {
        _ = libc.close(self.listen_fd);
    }

    /// Accept one connection, write metrics, close. Non-blocking.
    pub fn poll(self: *MetricsServer) void {
        const client_fd = std.c.accept(self.listen_fd, null, null);
        if (client_fd < 0) return;
        defer _ = libc.close(client_fd);

        var req_buf: [1024]u8 = undefined;
        const req_len_raw = std.c.read(client_fd, &req_buf, req_buf.len);
        const req_len: usize = if (req_len_raw > 0) @intCast(req_len_raw) else 0;
        const path = requestPath(req_buf[0..req_len]);

        var body: [BUF_SIZE]u8 = undefined;
        var content_type: []const u8 = "text/plain; version=0.0.4";
        var body_len: usize = 0;

        if (std.mem.eql(u8, path, "/v1/internal/federation")) {
            content_type = "application/json";
            const io_inst = self.replica.io;
            const now = @import("vopr/simulated_io.zig").nowTick(io_inst);
            body_len = self.formatFederationJson(&body, now);
        } else {
            body_len = self.formatMetrics(&body);
        }

        var resp: [BUF_SIZE + 256]u8 = undefined;
        const header = std.fmt.bufPrint(&resp, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ content_type, body_len }) catch return;
        writeAll(client_fd, header);
        writeAll(client_fd, body[0..body_len]);
    }

    fn formatMetrics(self: *MetricsServer, buf: *[BUF_SIZE]u8) usize {
        const sm = self.replica.state_machine;
        var pos: usize = 0;

        // -- State machine --

        pos += write(buf, pos, "# HELP hivemind_deployments_total Active deployments\n");
        pos += write(buf, pos, "# TYPE hivemind_deployments_total gauge\n");
        pos += writeFmt(buf, pos, "hivemind_deployments_total {d}\n", .{sm.deployment_count});

        var running: u32 = 0;
        var pending: u32 = 0;
        var failed: u32 = 0;
        for (sm.pods[0..sm.pod_count]) |pod| {
            if (!pod.active) continue;
            switch (pod.phase) {
                .running => running += 1,
                .pending, .scheduled => pending += 1,
                .failed => failed += 1,
                else => {},
            }
        }

        pos += write(buf, pos, "# HELP hivemind_pods Number of pods by phase\n");
        pos += write(buf, pos, "# TYPE hivemind_pods gauge\n");
        pos += writeFmt(buf, pos, "hivemind_pods{{phase=\"running\"}} {d}\n", .{running});
        pos += writeFmt(buf, pos, "hivemind_pods{{phase=\"pending\"}} {d}\n", .{pending});
        pos += writeFmt(buf, pos, "hivemind_pods{{phase=\"failed\"}} {d}\n", .{failed});

        var ready: u32 = 0;
        var unhealthy: u32 = 0;
        for (sm.nodes[0..sm.node_count]) |node| {
            if (!node.active) continue;
            switch (node.status) {
                .ready => ready += 1,
                .unhealthy => unhealthy += 1,
                else => {},
            }
        }

        pos += write(buf, pos, "# HELP hivemind_nodes Number of nodes by status\n");
        pos += write(buf, pos, "# TYPE hivemind_nodes gauge\n");
        pos += writeFmt(buf, pos, "hivemind_nodes{{status=\"ready\"}} {d}\n", .{ready});
        pos += writeFmt(buf, pos, "hivemind_nodes{{status=\"unhealthy\"}} {d}\n", .{unhealthy});

        // -- Consensus --

        pos += write(buf, pos, "# HELP hivemind_consensus_view Current VRR view number\n");
        pos += write(buf, pos, "# TYPE hivemind_consensus_view gauge\n");
        pos += writeFmt(buf, pos, "hivemind_consensus_view {d}\n", .{self.replica.view_number});

        pos += write(buf, pos, "# HELP hivemind_consensus_commit Committed operation number\n");
        pos += write(buf, pos, "# TYPE hivemind_consensus_commit gauge\n");
        pos += writeFmt(buf, pos, "hivemind_consensus_commit {d}\n", .{self.replica.commit_min});

        pos += write(buf, pos, "# HELP hivemind_consensus_op Latest operation number\n");
        pos += write(buf, pos, "# TYPE hivemind_consensus_op gauge\n");
        pos += writeFmt(buf, pos, "hivemind_consensus_op {d}\n", .{self.replica.op_number});

        pos += write(buf, pos, "# HELP hivemind_consensus_pipeline_guard_drops_total Requests dropped by the VRR pipeline guard\n");
        pos += write(buf, pos, "# TYPE hivemind_consensus_pipeline_guard_drops_total counter\n");
        pos += writeFmt(buf, pos, "hivemind_consensus_pipeline_guard_drops_total {d}\n", .{self.replica.pipeline_guard_drops});

        const is_leader: u8 = if (self.replica.isLeader() and self.replica.status == .normal) 1 else 0;
        pos += write(buf, pos, "# HELP hivemind_is_leader Whether this replica is the leader\n");
        pos += write(buf, pos, "# TYPE hivemind_is_leader gauge\n");
        pos += writeFmt(buf, pos, "hivemind_is_leader {d}\n", .{is_leader});

        // Leader ID: which replica is currently leader (view_number % replica_count)
        const leader_id = self.replica.view_number % self.replica.replica_count;
        pos += write(buf, pos, "# HELP hivemind_leader_id Current leader replica ID\n");
        pos += write(buf, pos, "# TYPE hivemind_leader_id gauge\n");
        pos += writeFmt(buf, pos, "hivemind_leader_id {d}\n", .{leader_id});

        pos += write(buf, pos, "# HELP hivemind_replica_status Replica status (0=normal,1=view_change,2=recovering)\n");
        pos += write(buf, pos, "# TYPE hivemind_replica_status gauge\n");
        pos += writeFmt(buf, pos, "hivemind_replica_status {d}\n", .{@intFromEnum(self.replica.status)});

        pos += write(buf, pos, "# HELP hivemind_view_change_votes Current view-change vote counters\n");
        pos += write(buf, pos, "# TYPE hivemind_view_change_votes gauge\n");
        pos += writeFmt(buf, pos, "hivemind_view_change_votes{{type=\"start\"}} {d}\n", .{self.replica.start_vc_total});
        pos += writeFmt(buf, pos, "hivemind_view_change_votes{{type=\"do\"}} {d}\n", .{self.replica.do_vc_total});
        pos += writeFmt(buf, pos, "hivemind_repair_pending {d}\n", .{if (self.replica.repair_pending) @as(u8, 1) else 0});

        // -- Connections & queue --

        if (self.connection_mgr) |cm| {
            pos += write(buf, pos, "# HELP hivemind_connections Connected sockets by type\n");
            pos += write(buf, pos, "# TYPE hivemind_connections gauge\n");
            pos += writeFmt(buf, pos, "hivemind_connections{{type=\"agents\"}} {d}\n", .{cm.worker_count});
            pos += writeFmt(buf, pos, "hivemind_connections{{type=\"clients\"}} {d}\n", .{cm.client_count});
            pos += writeFmt(buf, pos, "hivemind_connections{{type=\"peers\"}} {d}\n", .{cm.peer_count});
            var identified_peers: usize = 0;
            for (cm.peers[0..cm.peer_count]) |peer| {
                if (peer.connected and peer.peer_id_known) identified_peers += 1;
            }
            pos += writeFmt(buf, pos, "hivemind_connections{{type=\"identified_peers\"}} {d}\n", .{identified_peers});

            pos += write(buf, pos, "# HELP hivemind_poll_cycles_total Main loop poll cycles\n");
            pos += write(buf, pos, "# TYPE hivemind_poll_cycles_total counter\n");
            pos += writeFmt(buf, pos, "hivemind_poll_cycles_total {d}\n", .{cm.poll_count});

            const queue = &cm.request_queue;
            pos += write(buf, pos, "# HELP hivemind_queue_depth_total Total pending run requests\n");
            pos += write(buf, pos, "# TYPE hivemind_queue_depth_total gauge\n");
            pos += writeFmt(buf, pos, "hivemind_queue_depth_total {d}\n", .{queue.totalDepth()});

            pos += write(buf, pos, "# HELP hivemind_queue_in_flight Run requests awaiting response\n");
            pos += write(buf, pos, "# TYPE hivemind_queue_in_flight gauge\n");
            pos += writeFmt(buf, pos, "hivemind_queue_in_flight {d}\n", .{queue.activeInFlightCount()});

            pos += write(buf, pos, "# HELP hivemind_requests_enqueued_total Lifetime run requests enqueued\n");
            pos += write(buf, pos, "# TYPE hivemind_requests_enqueued_total counter\n");
            pos += writeFmt(buf, pos, "hivemind_requests_enqueued_total {d}\n", .{queue.enqueue_total});

            pos += write(buf, pos, "# HELP hivemind_requests_dispatched_total Lifetime run requests dispatched\n");
            pos += write(buf, pos, "# TYPE hivemind_requests_dispatched_total counter\n");
            pos += writeFmt(buf, pos, "hivemind_requests_dispatched_total {d}\n", .{queue.dispatch_total});

            pos += write(buf, pos, "# HELP hivemind_requests_resolved_total Lifetime run requests resolved\n");
            pos += write(buf, pos, "# TYPE hivemind_requests_resolved_total counter\n");
            pos += writeFmt(buf, pos, "hivemind_requests_resolved_total {d}\n", .{queue.resolve_total});
        }

        // -- Worker heartbeat health --

        const io_inst = self.replica.io;
        const now = @import("vopr/simulated_io.zig").nowTick(io_inst);

        if (self.replica.worker_count > 0) {
            pos += write(buf, pos, "# HELP hivemind_worker_heartbeat_age_ms Milliseconds since last agent heartbeat\n");
            pos += write(buf, pos, "# TYPE hivemind_worker_heartbeat_age_ms gauge\n");
            pos += write(buf, pos, "# HELP hivemind_worker_connected Whether agent TCP connection is active\n");
            pos += write(buf, pos, "# TYPE hivemind_worker_connected gauge\n");

            for (self.replica.workers[0..self.replica.worker_count]) |agent| {
                const hostname = msg.fixedToSlice(&agent.hostname);
                if (hostname.len == 0) continue;
                const age = if (agent.last_heartbeat_tick > 0) now - agent.last_heartbeat_tick else 0;
                const connected: u8 = if (agent.connected) 1 else 0;
                pos += writeFmt(buf, pos, "hivemind_worker_heartbeat_age_ms{{hostname=\"{s}\"}} {d}\n", .{ hostname, age });
                pos += writeFmt(buf, pos, "hivemind_worker_connected{{hostname=\"{s}\"}} {d}\n", .{ hostname, connected });
            }
        }

        // -- Gossip peer capacities --

        if (self.gossip) |g| {
            pos += write(buf, pos, "# HELP hivemind_peer_deployments Peer origin active deployments\n");
            pos += write(buf, pos, "# TYPE hivemind_peer_deployments gauge\n");
            pos += write(buf, pos, "# HELP hivemind_peer_queue_depth Peer origin advisory queue depth\n");
            pos += write(buf, pos, "# TYPE hivemind_peer_queue_depth gauge\n");

            for (&g.cache) |*peer| {
                if (peer.last_seen_ms == 0) continue;
                const origin_id = msg.fixedToSlice(&peer.origin_id);
                const provider = msg.fixedToSlice(&peer.provider);
                const region = msg.fixedToSlice(&peer.region);
                const locality = msg.fixedToSlice(&peer.locality);
                const continent = msg.fixedToSlice(&peer.continent);
                const age_s = @divFloor(now - peer.last_seen_ms, 1000);
                const labels = .{ origin_id, provider, region, locality, continent };

                pos += writeFmt(buf, pos, "hivemind_peer_deployments{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\"}} {d}\n", labels ++ .{peer.active_deployments});
                pos += writeFmt(buf, pos, "hivemind_peer_running_pods{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\"}} {d}\n", labels ++ .{peer.running_pods});
                pos += writeFmt(buf, pos, "hivemind_peer_nodes{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\"}} {d}\n", labels ++ .{peer.node_count});
                pos += writeFmt(buf, pos, "hivemind_peer_last_seen_seconds{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\"}} {d}\n", labels ++ .{age_s});
                pos += writeFmt(buf, pos, "hivemind_peer_queue_depth{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\"}} {d}\n", labels ++ .{peer.queue_depth});
                pos += writeFmt(buf, pos, "hivemind_peer_cpu_available_millicores{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\"}} {d}\n", labels ++ .{peer.cpu_available_millicores});
                pos += writeFmt(buf, pos, "hivemind_peer_cpu_total_millicores{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\"}} {d}\n", labels ++ .{peer.cpu_total_millicores});

                for (0..gossip_mod.GPU_TYPE_COUNT) |gpu_idx| {
                    if (peer.gpu_total[gpu_idx] > 0) {
                        const gpu_name = @tagName(@as(msg.GpuType, @enumFromInt(gpu_idx)));
                        pos += writeFmt(buf, pos, "hivemind_peer_gpu_available{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\",gpu_type=\"{s}\"}} {d}\n", labels ++ .{ gpu_name, peer.gpu_available[gpu_idx] });
                        pos += writeFmt(buf, pos, "hivemind_peer_gpu_total{{origin_id=\"{s}\",provider=\"{s}\",region=\"{s}\",locality=\"{s}\",continent=\"{s}\",gpu_type=\"{s}\"}} {d}\n", labels ++ .{ gpu_name, peer.gpu_total[gpu_idx] });
                    }
                }
            }
        }

        return pos;
    }

    const CapacitySummary = struct {
        gpu_available: [gossip_mod.GPU_TYPE_COUNT]u16 = std.mem.zeroes([gossip_mod.GPU_TYPE_COUNT]u16),
        gpu_total: [gossip_mod.GPU_TYPE_COUNT]u16 = std.mem.zeroes([gossip_mod.GPU_TYPE_COUNT]u16),
        cpu_available_millicores: u32 = 0,
        cpu_total_millicores: u32 = 0,
        queue_depth: u32 = 0,
        active_deployments: u32 = 0,
        running_pods: u32 = 0,
        node_count: u32 = 0,
    };

    fn requestPath(request: []const u8) []const u8 {
        const first_line_end = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
        const first_line = request[0..first_line_end];
        const method_end = std.mem.indexOfScalar(u8, first_line, ' ') orelse return "/";
        const rest = first_line[method_end + 1 ..];
        const path_end = std.mem.indexOfScalar(u8, rest, ' ') orelse return "/";
        return rest[0..path_end];
    }

    fn localCapacity(self: *MetricsServer) CapacitySummary {
        const sm = self.replica.state_machine;
        var cap = CapacitySummary{};

        for (0..gossip_mod.GPU_TYPE_COUNT) |gpu_idx| {
            const gpu_type: msg.GpuType = @enumFromInt(gpu_idx);
            for (sm.nodes[0..sm.node_count]) |node| {
                if (!node.active) continue;
                if (node.gpu_type == gpu_type and node.gpu_count > 0) {
                    cap.gpu_total[gpu_idx] += node.gpu_count;
                    cap.gpu_available[gpu_idx] += node.allocatable_gpu;
                }
            }
        }

        for (sm.nodes[0..sm.node_count]) |node| {
            if (!node.active) continue;
            cap.node_count += 1;
            cap.cpu_total_millicores +%= node.cpu_millicores;
            cap.cpu_available_millicores +%= node.allocatable_cpu;
        }

        if (self.connection_mgr) |cm| {
            cap.queue_depth = @intCast(@min(cm.request_queue.totalDepth(), std.math.maxInt(u32)));
        }

        cap.active_deployments = @intCast(@min(sm.deployment_count, std.math.maxInt(u32)));
        for (sm.pods[0..sm.pod_count]) |pod| {
            if (pod.active and pod.phase == .running) cap.running_pods += 1;
        }

        return cap;
    }

    fn formatFederationJson(self: *MetricsServer, buf: *[BUF_SIZE]u8, now_ms: i64) usize {
        var pos: usize = 0;
        pos += write(buf, pos, "{\"origin\":");

        const local = self.localCapacity();
        const identity = if (self.gossip) |g| g.identity else gossip_mod.OriginIdentity{};
        pos += writeOriginJson(buf, pos, .{
            .origin_id = msg.fixedToSlice(&identity.origin_id),
            .provider = msg.fixedToSlice(&identity.provider),
            .region = msg.fixedToSlice(&identity.region),
            .locality = msg.fixedToSlice(&identity.locality),
            .continent = msg.fixedToSlice(&identity.continent),
            .active = true,
            .stale = false,
            .last_seen_seconds = 0,
            .capacity = local,
        });

        pos += write(buf, pos, ",\"peers\":[");
        if (self.gossip) |g| {
            var first = true;
            for (&g.cache) |*peer| {
                if (peer.last_seen_ms == 0) continue;
                if (!first) pos += write(buf, pos, ",");
                first = false;
                const age_ms = @max(now_ms - peer.last_seen_ms, 0);
                const stale = age_ms >= gossip_mod.STALE_THRESHOLD_MS;
                pos += writeOriginJson(buf, pos, .{
                    .origin_id = msg.fixedToSlice(&peer.origin_id),
                    .provider = msg.fixedToSlice(&peer.provider),
                    .region = msg.fixedToSlice(&peer.region),
                    .locality = msg.fixedToSlice(&peer.locality),
                    .continent = msg.fixedToSlice(&peer.continent),
                    .active = !stale,
                    .stale = stale,
                    .last_seen_seconds = @intCast(@divFloor(age_ms, 1000)),
                    .capacity = .{
                        .gpu_available = peer.gpu_available,
                        .gpu_total = peer.gpu_total,
                        .cpu_available_millicores = peer.cpu_available_millicores,
                        .cpu_total_millicores = peer.cpu_total_millicores,
                        .queue_depth = peer.queue_depth,
                        .active_deployments = peer.active_deployments,
                        .running_pods = peer.running_pods,
                        .node_count = peer.node_count,
                    },
                });
            }
        }
        pos += write(buf, pos, "]}\n");
        return pos;
    }

    const OriginJson = struct {
        origin_id: []const u8,
        provider: []const u8,
        region: []const u8,
        locality: []const u8,
        continent: []const u8,
        active: bool,
        stale: bool,
        last_seen_seconds: u64,
        capacity: CapacitySummary,
    };

    fn writeOriginJson(buf: *[BUF_SIZE]u8, pos_start: usize, origin: OriginJson) usize {
        var pos = pos_start;
        pos += write(buf, pos, "{");
        pos += writeJsonStringField(buf, pos, "origin_id", origin.origin_id);
        pos += write(buf, pos, ",");
        pos += writeJsonStringField(buf, pos, "provider", origin.provider);
        pos += write(buf, pos, ",");
        pos += writeJsonStringField(buf, pos, "region", origin.region);
        pos += write(buf, pos, ",");
        pos += writeJsonStringField(buf, pos, "locality", origin.locality);
        pos += write(buf, pos, ",");
        pos += writeJsonStringField(buf, pos, "continent", origin.continent);
        pos += write(buf, pos, ",");
        pos += writeFmt(buf, pos, "\"active\":{},\"stale\":{},\"last_seen_seconds\":{d},", .{ origin.active, origin.stale, origin.last_seen_seconds });
        pos += writeFmt(buf, pos, "\"cpu_available_millicores\":{d},\"cpu_total_millicores\":{d},", .{ origin.capacity.cpu_available_millicores, origin.capacity.cpu_total_millicores });
        pos += writeFmt(buf, pos, "\"queue_depth\":{d},\"active_deployments\":{d},\"running_pods\":{d},\"node_count\":{d},", .{ origin.capacity.queue_depth, origin.capacity.active_deployments, origin.capacity.running_pods, origin.capacity.node_count });
        pos += write(buf, pos, "\"gpu\":[");
        var first_gpu = true;
        for (0..gossip_mod.GPU_TYPE_COUNT) |gpu_idx| {
            if (origin.capacity.gpu_total[gpu_idx] == 0) continue;
            if (!first_gpu) pos += write(buf, pos, ",");
            first_gpu = false;
            const gpu_name = @tagName(@as(msg.GpuType, @enumFromInt(gpu_idx)));
            pos += write(buf, pos, "{");
            pos += writeJsonStringField(buf, pos, "type", gpu_name);
            pos += writeFmt(buf, pos, ",\"available\":{d},\"total\":{d}}}", .{ origin.capacity.gpu_available[gpu_idx], origin.capacity.gpu_total[gpu_idx] });
        }
        pos += write(buf, pos, "]}");
        return pos - pos_start;
    }

    fn writeJsonStringField(buf: *[BUF_SIZE]u8, pos_start: usize, comptime key: []const u8, value: []const u8) usize {
        var pos = pos_start;
        pos += writeFmt(buf, pos, "\"{s}\":", .{key});
        pos += writeJsonString(buf, pos, value);
        return pos - pos_start;
    }

    fn writeJsonString(buf: *[BUF_SIZE]u8, pos_start: usize, value: []const u8) usize {
        var written: usize = 0;
        written += write(buf, pos_start + written, "\"");
        for (value) |ch| {
            switch (ch) {
                '"' => written += write(buf, pos_start + written, "\\\""),
                '\\' => written += write(buf, pos_start + written, "\\\\"),
                '\n' => written += write(buf, pos_start + written, "\\n"),
                '\r' => written += write(buf, pos_start + written, "\\r"),
                '\t' => written += write(buf, pos_start + written, "\\t"),
                else => {
                    if (ch < 0x20) {
                        written += writeFmt(buf, pos_start + written, "\\u{x:0>4}", .{ch});
                    } else if (pos_start + written < buf.len) {
                        buf[pos_start + written] = ch;
                        written += 1;
                    }
                },
            }
        }
        written += write(buf, pos_start + written, "\"");
        return written;
    }

    fn write(buf: *[BUF_SIZE]u8, pos: usize, data: []const u8) usize {
        const len = @min(data.len, buf.len - pos);
        @memcpy(buf[pos..][0..len], data[0..len]);
        return len;
    }

    fn writeFmt(buf: *[BUF_SIZE]u8, pos: usize, comptime fmt: []const u8, args: anytype) usize {
        const remaining = buf[pos..];
        const result = std.fmt.bufPrint(remaining, fmt, args) catch return 0;
        return result.len;
    }

    fn writeAll(fd: c_int, data: []const u8) void {
        var written: usize = 0;
        while (written < data.len) {
            const rc = std.c.write(fd, data[written..].ptr, data.len - written);
            if (rc <= 0) return;
            written += @intCast(rc);
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "metrics write helper" {
    var buf: [BUF_SIZE]u8 = undefined;
    const len = MetricsServer.write(&buf, 0, "test_metric 42\n");
    try std.testing.expectEqual(@as(usize, 15), len);
    try std.testing.expectEqualStrings("test_metric 42\n", buf[0..15]);
}

test "metrics writeFmt helper" {
    var buf: [BUF_SIZE]u8 = undefined;
    const len = MetricsServer.writeFmt(&buf, 0, "gauge{{label=\"{s}\"}} {d}\n", .{ "foo", 42 });
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "42") != null);
}

test "metrics include origin-aware gossip labels and cpu summaries" {
    const TestCluster = @import("vopr/test_harness.zig").TestCluster;

    const tc = try TestCluster.init(std.testing.allocator, 1, 7);
    defer tc.deinit();

    var gossip = gossip_mod.GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-eu-west-2"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "eu-west-2"),
            .locality = msg.strToFixed(32, "europe"),
            .continent = msg.strToFixed(32, "eu"),
        },
        .peers = [_]gossip_mod.GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]gossip_mod.PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = tc.replicas[0],
        .encryption = null,
    };
    gossip.cache[0].origin_id = msg.strToFixed(32, "aws-us-east-1");
    gossip.cache[0].provider = msg.strToFixed(32, "aws");
    gossip.cache[0].region = msg.strToFixed(32, "us-east-1");
    gossip.cache[0].locality = msg.strToFixed(32, "us-east");
    gossip.cache[0].continent = msg.strToFixed(32, "na");
    gossip.cache[0].cpu_available_millicores = 24000;
    gossip.cache[0].cpu_total_millicores = 32000;
    gossip.cache[0].gpu_available[8] = 1; // t4
    gossip.cache[0].gpu_total[8] = 2;
    gossip.cache[0].active_deployments = 3;
    gossip.cache[0].running_pods = 4;
    gossip.cache[0].node_count = 2;
    gossip.cache[0].queue_depth = 7;
    gossip.cache[0].last_seen_ms = 10;

    var server = MetricsServer{
        .listen_fd = -1,
        .replica = tc.replicas[0],
        .gossip = &gossip,
        .connection_mgr = null,
    };

    var buf: [BUF_SIZE]u8 = undefined;
    const len = server.formatMetrics(&buf);
    const out = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, out, "origin_id=\"aws-us-east-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "locality=\"us-east\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "continent=\"na\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hivemind_consensus_pipeline_guard_drops_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hivemind_peer_queue_depth") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hivemind_peer_cpu_available_millicores") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hivemind_peer_cpu_total_millicores") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "gpu_type=\"t4\"") != null);
}

test "federation json includes origin peer capacity and stale flag" {
    const TestCluster = @import("vopr/test_harness.zig").TestCluster;

    const tc = try TestCluster.init(std.testing.allocator, 1, 11);
    defer tc.deinit();

    var gossip = gossip_mod.GossipState{
        .fd = -1,
        .identity = .{
            .origin_id = msg.strToFixed(32, "aws-us-east-1"),
            .provider = msg.strToFixed(32, "aws"),
            .region = msg.strToFixed(32, "us-east-1"),
            .locality = msg.strToFixed(32, "us-east"),
            .continent = msg.strToFixed(32, "na"),
        },
        .peers = [_]gossip_mod.GossipPeer{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .peer_count = 0,
        .cache = [_]gossip_mod.PeerCapacity{.{}} ** gossip_mod.MAX_GOSSIP_PEERS,
        .last_broadcast_ms = 0,
        .replica = tc.replicas[0],
        .encryption = null,
    };
    gossip.cache[0].origin_id = msg.strToFixed(32, "crusoe-texas");
    gossip.cache[0].provider = msg.strToFixed(32, "crusoe");
    gossip.cache[0].region = msg.strToFixed(32, "texas");
    gossip.cache[0].locality = msg.strToFixed(32, "us-central");
    gossip.cache[0].continent = msg.strToFixed(32, "na");
    gossip.cache[0].cpu_available_millicores = 8000;
    gossip.cache[0].cpu_total_millicores = 16000;
    gossip.cache[0].queue_depth = 2;
    gossip.cache[0].active_deployments = 4;
    gossip.cache[0].running_pods = 5;
    gossip.cache[0].node_count = 1;
    gossip.cache[0].last_seen_ms = 1000;

    var server = MetricsServer{
        .listen_fd = -1,
        .replica = tc.replicas[0],
        .gossip = &gossip,
        .connection_mgr = null,
    };

    var buf: [BUF_SIZE]u8 = undefined;
    const len = server.formatFederationJson(&buf, 32000);
    const out = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, out, "\"origin_id\":\"aws-us-east-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"origin_id\":\"crusoe-texas\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"locality\":\"us-central\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"queue_depth\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"last_seen_seconds\":31") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stale\":true") != null);
}

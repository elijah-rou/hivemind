const std = @import("std");
const msg = @import("message.zig");
const replica_mod = @import("replica.zig");
const sm_mod = @import("state_machine.zig");
const rq = @import("request_queue.zig");
const net_mod = @import("vopr/simulated_net.zig");
const enc = @import("encryption.zig");
const latency = @import("latency.zig");

const MAX_WORKERS: usize = replica_mod.MAX_WORKERS;
const MAX_CLIENTS: usize = 64;
const MAX_FRAME_BYTES: usize = 64 * 1024;
/// Worker frame payload is bounded at 16 KiB; run metadata consumes 9 bytes.
pub const MAX_RUN_RESPONSE_BODY: usize = 16 * 1024 - 9;
const RunStatus = rq.RunStatus;
const MAX_PEER_CONNECTIONS: usize = @as(usize, msg.REPLICA_COUNT_MAX) * 2;
const PEER_CONNECT_TIMEOUT_TICKS: u64 = 2_000;
const PEER_IDENTITY_TIMEOUT_TICKS: u64 = 2_000;
const PEER_RETRY_INTERVAL_TICKS: u64 = 2_000;

// Wire protocol version. Included in every client and agent frame.
// Frame format: [4B LE len][2B LE version][1B tag][payload...]
// len = 2 (version) + 1 (tag) + payload_len
pub const PROTOCOL_VERSION: u16 = 4;
pub const FRAME_HEADER: usize = 4 + 2 + 1; // len + version + tag

const libc = struct {
    extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn pipe(pipe_fds: *[2]c_int) c_int;
};

const FcntlOps = struct {
    get_flags: *const fn (c_int) c_int,
    set_flags: *const fn (c_int, c_int) c_int,

    fn systemGetFlags(fd: c_int) c_int {
        return std.c.fcntl(fd, std.posix.F.GETFL);
    }

    fn systemSetFlags(fd: c_int, flags: c_int) c_int {
        return std.c.fcntl(fd, std.posix.F.SETFL, flags);
    }

    const system = FcntlOps{
        .get_flags = systemGetFlags,
        .set_flags = systemSetFlags,
    };
};

// ---------------------------------------------------------------------------
// Per-connection state
// ---------------------------------------------------------------------------

const PeerDirection = enum { inbound, outbound };

const Conn = struct {
    fd: c_int = -1,
    frame_buf: [MAX_FRAME_BYTES]u8 = undefined,
    frame_pos: usize = 0,
    connected: bool = false,
    peer_direction: PeerDirection = .inbound,
    connect_pending: bool = false,
    peer_deadline_tick: u64 = 0,
    configured_peer_id: u8 = 0,
    configured_peer_id_known: bool = false,

    // For workers: the agent index in the replica's agent table
    worker_idx: usize = 0,
    // For peers: whether worker_idx contains a learned replica ID.
    peer_id_known: bool = false,
    // For clients: the client_id for reply routing
    client_id: u128 = 0,
};

// ---------------------------------------------------------------------------
// ConnectionManager -- unified TCP handler for agents and clients
//
// Workers connect inbound. Bidirectional: Hivemind pushes StartPod and
// run requests over the same connection the agent registered on.
// Clients connect inbound for submitting deployments and queries.
// ---------------------------------------------------------------------------

const PeerTarget = struct {
    peer_id: u8 = 0,
    host: u32 = 0,
    port: u16 = 0,
};

pub const ConnectionManager = struct {
    worker_listen_fd: c_int,
    client_listen_fd: c_int,

    workers: [MAX_WORKERS]Conn,
    worker_count: usize,

    clients: [MAX_CLIENTS]Conn,
    client_count: usize,

    replica: *replica_mod.Replica,
    request_queue: rq.RequestQueue,

    // Peer-to-peer VRR networking
    peer_listen_fd: c_int,
    peers: [MAX_PEER_CONNECTIONS]Conn,
    peer_count: usize,
    replica_id: u8,

    // Peer targets for connection retry
    peer_targets: [msg.REPLICA_COUNT_MAX]PeerTarget,
    peer_target_count: usize,
    last_retry_tick: u64,
    poll_count: u64,

    // Pre-allocated buffer for cluster state responses (read-only queries)
    state_response_buf: [131072]u8,

    // Frame encryption (optional, PSK-based)
    encryption: ?*enc.EncryptionState,
    fcntl_ops: FcntlOps,

    pub fn init(replica: *replica_mod.Replica, worker_port: u16, client_port: u16, peer_port: u16) !ConnectionManager {
        const agent_fd = try listenOn(worker_port);
        errdefer _ = libc.close(agent_fd);

        const client_fd = try listenOn(client_port);
        errdefer _ = libc.close(client_fd);

        var peer_fd: c_int = -1;
        if (peer_port > 0) {
            peer_fd = try listenOn(peer_port);
        }

        return .{
            .worker_listen_fd = agent_fd,
            .client_listen_fd = client_fd,
            .workers = [_]Conn{.{}} ** MAX_WORKERS,
            .worker_count = 0,
            .clients = [_]Conn{.{}} ** MAX_CLIENTS,
            .client_count = 0,
            .replica = replica,
            .request_queue = rq.RequestQueue.init(),
            .peer_listen_fd = peer_fd,
            .peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS,
            .peer_count = 0,
            .replica_id = replica.replica_id,
            .peer_targets = [_]PeerTarget{.{}} ** msg.REPLICA_COUNT_MAX,
            .peer_target_count = 0,
            .last_retry_tick = 0,
            .poll_count = 0,
            .encryption = null,
            .fcntl_ops = FcntlOps.system,
        };
    }

    /// Initialize in-place on a heap-allocated pointer to avoid stack overflow.
    pub fn initInPlace(self: *ConnectionManager, replica: *replica_mod.Replica, worker_port: u16, client_port: u16, peer_port: u16) !void {
        const agent_fd = try listenOn(worker_port);
        errdefer _ = libc.close(agent_fd);

        const client_fd = try listenOn(client_port);
        errdefer _ = libc.close(client_fd);

        var peer_fd: c_int = -1;
        if (peer_port > 0) {
            peer_fd = try listenOn(peer_port);
        }

        self.worker_listen_fd = agent_fd;
        self.client_listen_fd = client_fd;
        self.workers = [_]Conn{.{}} ** MAX_WORKERS;
        self.worker_count = 0;
        self.clients = [_]Conn{.{}} ** MAX_CLIENTS;
        self.client_count = 0;
        self.replica = replica;
        self.request_queue = rq.RequestQueue.init();
        self.peer_listen_fd = peer_fd;
        self.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
        self.peer_count = 0;
        self.replica_id = replica.replica_id;
        self.peer_targets = [_]PeerTarget{.{}} ** msg.REPLICA_COUNT_MAX;
        self.peer_target_count = 0;
        self.last_retry_tick = 0;
        self.poll_count = 0;
        self.state_response_buf = std.mem.zeroes([131072]u8);
        self.encryption = null;
        self.fcntl_ops = FcntlOps.system;
    }

    pub fn deinit(self: *ConnectionManager) void {
        for (&self.workers) |*worker| self.disconnectWorker(worker);
        for (&self.clients) |*client| self.disconnectClient(client);
        for (&self.peers) |*peer| disconnectPeer(peer);
        _ = libc.close(self.worker_listen_fd);
        _ = libc.close(self.client_listen_fd);
        if (self.peer_listen_fd >= 0) _ = libc.close(self.peer_listen_fd);
    }

    /// Poll all connections: accept new, read messages, dispatch.
    pub fn poll(self: *ConnectionManager) void {
        self.poll_count += 1;
        self.acceptWorkers();
        self.acceptClients();
        self.acceptPeers();
        self.completePeerConnections(self.poll_count);
        self.readWorkers();
        self.readClients();
        self.readPeers();
        self.retryPeerConnections(self.poll_count);
    }

    // -- Worker connections --

    fn acceptWorkers(self: *ConnectionManager) void {
        while (true) {
            const fd = std.c.accept(self.worker_listen_fd, null, null);
            if (fd < 0) return;
            setNonBlockingWith(fd, self.fcntl_ops) catch {
                _ = libc.close(fd);
                continue;
            };

            var slot: ?usize = null;
            for (0..self.worker_count) |i| {
                if (!self.workers[i].connected and self.workers[i].fd < 0) {
                    slot = i;
                    break;
                }
            }

            const idx: usize = slot orelse blk: {
                if (self.worker_count >= MAX_WORKERS) {
                    _ = libc.close(fd);
                    return;
                }
                const i = self.worker_count;
                self.worker_count += 1;
                break :blk i;
            };

            self.workers[idx] = .{
                .fd = fd,
                .frame_pos = 0,
                .connected = true,
                .worker_idx = idx,
            };
        }
    }

    fn readWorkers(self: *ConnectionManager) void {
        for (self.workers[0..self.worker_count]) |*wk| {
            if (!wk.connected) continue;
            if (!self.acceptsWorkerTraffic()) {
                self.disconnectWorker(wk);
                continue;
            }
            readConn(wk) catch {
                self.disconnectWorker(wk);
                continue;
            };
            self.processWorkerFrames(wk);
        }
    }

    fn acceptsWorkerTraffic(self: *const ConnectionManager) bool {
        return self.replica.isLeader() and self.replica.status == .normal and !self.replica.repair_pending;
    }

    fn processWorkerFrames(self: *ConnectionManager, worker: *Conn) void {
        var consumed: usize = 0;
        const data = worker.frame_buf[0..worker.frame_pos];
        var decrypt_buf: [MAX_FRAME_BYTES]u8 = undefined;

        const worker_key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.worker_key else null;

        while (consumed + 5 <= data.len) {
            var frame_consumed: usize = 0;
            const frame_payload = self.decodeFrame(worker_key, data[consumed..], &frame_consumed, &decrypt_buf, true) orelse {
                if (frame_consumed == 0) break;
                self.disconnectWorker(worker);
                return;
            };
            consumed += frame_consumed;

            if (frame_payload.len < 3) {
                self.disconnectWorker(worker);
                return;
            }
            const tag_byte = frame_payload[2]; // version(2) + tag(1)
            const payload = frame_payload[3..];
            self.dispatchWorkerMessage(worker, tag_byte, payload);
            if (!worker.connected) break;
        }

        shiftBuffer(&worker.frame_buf, &worker.frame_pos, consumed);
    }

    fn dispatchWorkerMessage(self: *ConnectionManager, worker: *Conn, tag_byte: u8, payload: []const u8) void {
        switch (tag_byte) {
            @intFromEnum(msg.WorkerTag.register) => {
                const register = parseWorkerRegister(payload) orelse {
                    self.disconnectWorker(worker);
                    return;
                };
                self.replica.onWorkerRegister(worker.worker_idx, register);
            },
            @intFromEnum(msg.WorkerTag.heartbeat) => {
                const heartbeat = parseWorkerHeartbeat(payload) orelse {
                    self.disconnectWorker(worker);
                    return;
                };
                self.replica.onWorkerHeartbeat(worker.worker_idx, heartbeat);
            },
            @intFromEnum(msg.WorkerTag.pod_status) => {
                const status = parseWorkerPodStatus(payload) orelse {
                    self.disconnectWorker(worker);
                    return;
                };
                self.replica.onWorkerPodStatus(worker.worker_idx, status);
            },
            @intFromEnum(msg.WorkerTag.run_response) => {
                self.handleRunResponse(worker, payload);
            },
            else => {},
        }
    }

    fn handleRunResponse(self: *ConnectionManager, worker: *Conn, payload: []const u8) void {
        std.debug.assert(worker.worker_idx < self.worker_count);
        std.debug.assert(worker.connected);

        // Payload: request_id(u64) + status(u8) + response data. Any malformed,
        // unknown, or foreign correlation is a worker protocol failure. Closing
        // only the sender deterministically releases all correlations it owns.
        if (payload.len < 9) {
            self.disconnectWorker(worker);
            return;
        }
        const worker_request_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[0..8]));
        const status = msg.enumFromIntChecked(RunStatus, payload[8]) catch {
            self.disconnectWorker(worker);
            return;
        };
        const response_data = payload[9..];
        if (response_data.len > MAX_RUN_RESPONSE_BODY) {
            self.disconnectWorker(worker);
            return;
        }

        const resolved = self.request_queue.resolveResponseForWorker(worker_request_id, worker.worker_idx) orelse {
            self.disconnectWorker(worker);
            return;
        };

        for (self.clients[0..self.client_count]) |*client| {
            if (!client.connected or client.client_id != resolved.client_id) continue;

            // Build inner payload: [version(2)][tag(1)][request_id(8)][status(1)][len(4)][data...]
            var inner: [3 + 8 + 1 + 4 + MAX_RUN_RESPONSE_BODY]u8 = undefined;
            @memcpy(inner[0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, PROTOCOL_VERSION)));
            inner[2] = 0x23; // ClientTag.run_response
            var pos: usize = 3;
            @memcpy(inner[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, resolved.client_request_id)));
            pos += 8;
            inner[pos] = @intFromEnum(status);
            pos += 1;
            @memcpy(inner[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(response_data.len)))));
            pos += 4;
            @memcpy(inner[pos..][0..response_data.len], response_data);
            pos += response_data.len;

            const key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.client_key else null;
            self.sendFrame(client.fd, key, inner[0..pos]) catch {
                self.disconnectClient(client);
            };
            return;
        }
    }

    fn handleRunRequest(self: *ConnectionManager, client: *Conn, payload: []const u8) void {
        // Payload: request_id(u64) + deployment_name(64 bytes) + payload_len(u32) + payload_data
        // Contract: declared length must exactly match trailing body bytes (no clamp/truncation),
        // and body must be <= rq.MAX_PAYLOAD. Overflow-safe via body.len comparison.
        if (payload.len < 76) return;

        const now = @import("vopr/simulated_io.zig").nowTick(self.replica.io);
        const request_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[0..8]));
        const dep_name = msg.fixedToSlice(payload[8..72]);
        const declared_len = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, payload[72..76]));
        const body = payload[76..];
        if (declared_len > rq.MAX_PAYLOAD or body.len != @as(usize, declared_len)) {
            self.sendRunError(client, request_id, .invalid_payload);
            return;
        }
        const req_payload = body;
        latency.record(.{ .phase = "core_run_request_receive", .op = "run_request", .name = dep_name, .start_ms = now, .end_ms = now, .source = "core/src/connection.zig" });

        // Look up deployment by name
        const dep = self.replica.state_machine.findDeploymentByName(dep_name) orelse {
            // Deployment not found -- send error response
            self.sendRunError(client, request_id, .deployment_not_found);
            return;
        };

        // Enqueue for dispatch
        if (!self.request_queue.enqueue(dep.id, request_id, client.client_id, req_payload)) {
            self.sendRunError(client, request_id, .queue_full);
        }
    }

    fn sendRunError(self: *ConnectionManager, client: *Conn, request_id: u64, status: RunStatus) void {
        // Same framing as successful run replies: flags byte via sendFrame.
        var inner: [12]u8 = undefined;
        @memcpy(inner[0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, PROTOCOL_VERSION)));
        inner[2] = 0x23; // ClientTag.run_response
        @memcpy(inner[3..11], &std.mem.toBytes(std.mem.nativeToLittle(u64, request_id)));
        inner[11] = @intFromEnum(status);
        const key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.client_key else null;
        self.sendFrame(client.fd, key, inner[0..12]) catch {
            self.disconnectClient(client);
        };
    }

    /// Dispatch queued run requests to agents. Called every tick from main.
    pub fn dispatchRun(self: *ConnectionManager) void {
        if (!self.acceptsWorkerTraffic()) return;

        const sm = self.replica.state_machine;

        for (0..self.request_queue.queue_count) |qi| {
            if (!self.request_queue.queues[qi].active) continue;
            if (self.request_queue.queues[qi].count == 0) continue;

            const dep_id = self.request_queue.queues[qi].deployment_id;
            const sm_const: *const sm_mod.StateMachine = sm;

            var backends_buf: [sm_mod.MAX_BACKENDS]sm_mod.Backend = undefined;
            const backend_count = sm_const.getBackends(dep_id, &backends_buf);

            if (backend_count == 0) {
                // Wake-from-zero: if deployment is scaled to zero, submit scale-up
                if (!self.request_queue.queues[qi].wake_pending) {
                    if (sm_const.findDeployment(dep_id)) |dep| {
                        if (dep.replicas == 0 and dep.active and !dep.paused) {
                            const target = @max(dep.min_replicas, 1);
                            const scale_client_id: u128 = 0x5CA1_E0_00_0000_0000 | @as(u128, dep_id);
                            self.replica.onMessage(self.replica.replica_id, .{ .request = .{
                                .client_id = scale_client_id,
                                .request_id = @as(u128, dep_id),
                                .command = .{ .scale_deployment = .{
                                    .deployment_id = dep_id,
                                    .desired_replicas = target,
                                } },
                            } });
                            self.request_queue.queues[qi].wake_pending = true;
                        }
                    }
                }
                continue;
            }

            // Backends available: clear wake_pending
            self.request_queue.queues[qi].wake_pending = false;

            var batch: usize = 0;
            while (batch < 16) : (batch += 1) {
                // Never dequeue work unless a connected worker can accept it and
                // the correlation table can track the accepted dispatch.
                if (self.request_queue.activeInFlightCount() >= rq.MAX_IN_FLIGHT) break;
                const worker_idx = self.selectConnectedWorker(qi, backends_buf[0..backend_count]) orelse break;
                const req_opt = self.request_queue.queues[qi].dequeue();
                const req = req_opt orelse break;

                // Update last_request_tick on the deployment (leader-local)
                if (sm.findDeploymentMut(dep_id)) |dep_mut| {
                    const io_mod = @import("vopr/simulated_io.zig");
                    const now: u64 = @intCast(@max(0, io_mod.nowTick(self.replica.io)));
                    dep_mut.last_request_tick = now;
                }

                // Translate the client-supplied ID to a gateway-unique worker correlation.
                const worker_request_id = self.request_queue.trackInFlightForWorker(req.request_id, req.client_id, worker_idx) orelse unreachable;

                const dispatch_now = @import("vopr/simulated_io.zig").nowTick(self.replica.io);
                latency.record(.{ .phase = "dispatch_send", .op = "run_request", .deployment_id = req.deployment_id, .start_ms = dispatch_now, .end_ms = dispatch_now, .source = "core/src/connection.zig" });

                // Build run request frame for agent
                // Payload: request_id(u64) + deployment_id(u64) + payload_len(u32) + payload
                var agent_payload: [rq.MAX_PAYLOAD + 20]u8 = undefined;
                var pos: usize = 0;
                @memcpy(agent_payload[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, worker_request_id)));
                pos += 8;
                @memcpy(agent_payload[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, req.deployment_id)));
                pos += 8;
                @memcpy(agent_payload[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, @as(u32, @intCast(req.payload_len)))));
                pos += 4;
                @memcpy(agent_payload[pos..][0..req.payload_len], req.payload[0..req.payload_len]);
                pos += req.payload_len;

                self.sendToWorker(worker_idx, .run_request, agent_payload[0..pos]) catch {
                    // The write outcome is known failed. Do not requeue because a
                    // partial write could have been accepted by the worker.
                    self.disconnectWorker(&self.workers[worker_idx]);
                };
            }
        }
    }

    fn selectConnectedWorker(self: *ConnectionManager, queue_idx: usize, backends: []const sm_mod.Backend) ?usize {
        std.debug.assert(queue_idx < self.request_queue.queue_count);
        if (backends.len == 0) return null;
        const start = self.request_queue.dispatch_idx[queue_idx] % backends.len;
        for (0..backends.len) |offset| {
            const backend_idx = (start + offset) % backends.len;
            const worker_idx = self.replica.findWorkerForNode(backends[backend_idx].node_id) orelse continue;
            if (worker_idx >= self.worker_count) continue;
            if (!self.workers[worker_idx].connected) continue;
            self.request_queue.dispatch_idx[queue_idx] = backend_idx + 1;
            return worker_idx;
        }
        return null;
    }

    /// Send a replica-owned StartPod/StopPod frame. The callback retains no
    /// connection ownership; a failed synchronous write disconnects exactly once.
    pub fn sendReplicaWorkerFrame(self: *ConnectionManager, worker_idx: usize, data: []const u8) void {
        if (worker_idx >= self.worker_count) return;
        const worker = &self.workers[worker_idx];
        if (!worker.connected) return;

        const frame_header: usize = 4;
        if (data.len <= frame_header) return;
        const inner = data[frame_header..];
        const key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.worker_key else null;
        self.sendFrame(worker.fd, key, inner) catch self.disconnectWorker(worker);
    }

    /// Send a framed message to a connected worker with explicit outcome.
    pub fn sendToWorker(self: *ConnectionManager, worker_idx: usize, tag: msg.WorkerTag, payload: []const u8) !void {
        if (worker_idx >= self.worker_count) return error.WorkerUnavailable;
        const worker = &self.workers[worker_idx];
        if (!worker.connected) return error.WorkerUnavailable;

        // Build inner payload: [version(2)][tag(1)][payload...]
        var inner: [8192]u8 = undefined;
        @memcpy(inner[0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, PROTOCOL_VERSION)));
        inner[2] = @intFromEnum(tag);
        @memcpy(inner[3..][0..payload.len], payload);
        const inner_len = 3 + payload.len;

        const key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.worker_key else null;
        try self.sendFrame(worker.fd, key, inner[0..inner_len]);
    }

    fn disconnectWorker(self: *ConnectionManager, worker: *Conn) void {
        if (!worker.connected) return;
        const worker_idx = worker.worker_idx;
        std.debug.assert(worker_idx < self.worker_count);
        const fd = worker.fd;
        worker.fd = -1;
        worker.connected = false;
        worker.frame_pos = 0;
        if (fd >= 0) _ = libc.close(fd);
        self.replica.onWorkerDisconnect(worker_idx);

        var released: [rq.MAX_IN_FLIGHT]rq.ResolvedRequest = undefined;
        const released_count = self.request_queue.releaseWorker(worker_idx, &released);
        for (released[0..released_count]) |request| {
            self.sendRunErrorToClientId(request.client_id, request.client_request_id, .outcome_ambiguous);
        }
    }

    fn sendRunErrorToClientId(self: *ConnectionManager, client_id: u128, request_id: u64, status: RunStatus) void {
        for (self.clients[0..self.client_count]) |*client| {
            if (!client.connected or client.client_id != client_id) continue;
            self.sendRunError(client, request_id, status);
            return;
        }
    }

    // -- Client connections --

    fn acceptClients(self: *ConnectionManager) void {
        while (true) {
            const fd = std.c.accept(self.client_listen_fd, null, null);
            if (fd < 0) return;
            setNonBlockingWith(fd, self.fcntl_ops) catch {
                _ = libc.close(fd);
                continue;
            };

            var slot: ?usize = null;
            for (0..self.client_count) |i| {
                if (!self.clients[i].connected and self.clients[i].fd < 0) {
                    slot = i;
                    break;
                }
            }

            const idx: usize = slot orelse blk: {
                if (self.client_count >= MAX_CLIENTS) {
                    _ = libc.close(fd);
                    return;
                }
                const i = self.client_count;
                self.client_count += 1;
                break :blk i;
            };

            self.clients[idx] = .{
                .fd = fd,
                .frame_pos = 0,
                .connected = true,
                .client_id = @as(u128, idx),
            };
        }
    }

    fn readClients(self: *ConnectionManager) void {
        for (self.clients[0..self.client_count]) |*client| {
            if (!client.connected) continue;
            readConn(client) catch {
                self.disconnectClient(client);
                continue;
            };
            self.processClientFrames(client);
        }
    }

    fn processClientFrames(self: *ConnectionManager, client: *Conn) void {
        var consumed: usize = 0;
        const data = client.frame_buf[0..client.frame_pos];
        var decrypt_buf: [MAX_FRAME_BYTES]u8 = undefined;

        const client_key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.client_key else null;

        while (consumed + 5 <= data.len) { // min: len(4) + flags(1)
            var frame_consumed: usize = 0;
            const frame_payload = self.decodeFrame(client_key, data[consumed..], &frame_consumed, &decrypt_buf, true) orelse {
                if (frame_consumed == 0) break; // incomplete
                consumed += frame_consumed; // skip bad frame
                continue;
            };
            consumed += frame_consumed;

            // frame_payload = [version(2)][tag(1)][payload...]
            if (frame_payload.len < 3) continue;
            const tag_byte = frame_payload[2];
            const payload = frame_payload[3..];

            if (tag_byte == 0x20) { // ClientTag.request (consensus)
                self.handleClientRequest(client, payload);
            } else if (tag_byte == 0x22) { // ClientTag.run_request (no consensus)
                self.handleRunRequest(client, payload);
            } else if (tag_byte == 0x24) { // ClientTag.cluster_state_request (read-only)
                self.handleClusterStateRequest(client);
            }
        }

        shiftBuffer(&client.frame_buf, &client.frame_pos, consumed);
    }

    fn handleClientRequest(self: *ConnectionManager, client: *Conn, payload: []const u8) void {
        // Packed: client_id(u64=8) + request_id(u64=8) + cmd_tag(u8=1) + cmd_fields
        if (payload.len < 17) return;

        const receive_ms = @import("vopr/simulated_io.zig").nowTick(self.replica.io);
        const client_id_lo = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[0..8]));
        const request_id_lo = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[8..16]));
        const cmd_tag = payload[16];
        const cmd_fields = payload[17..];

        // Reject if not leader
        if (!self.replica.isLeader() or self.replica.status != .normal) {
            self.sendClientReply(client, request_id_lo, .{ .err = .not_leader });
            return;
        }

        const command = parseClientCommand(cmd_tag, cmd_fields) orelse return;
        latency.record(.{ .phase = "core_request_receive", .op = latency.commandName(command), .deployment_id = latency.deploymentId(command), .pod_id = latency.podId(command), .name = latency.commandNameField(command), .start_ms = receive_ms, .end_ms = @import("vopr/simulated_io.zig").nowTick(self.replica.io), .source = "core/src/connection.zig" });
        const client_id: u128 = client_id_lo;
        const request_id: u128 = request_id_lo;

        client.client_id = client_id;

        self.replica.onMessage(self.replica.replica_id, .{ .request = .{
            .client_id = client_id,
            .request_id = request_id,
            .command = command,
        } });
    }

    /// Send a reply to a connected client.
    pub fn sendClientReply(self: *ConnectionManager, client: *Conn, request_id: u64, result: msg.Result) void {
        // Build payload: [version(2)][tag(1)][request_id(8)][result...]
        var payload: [32]u8 = undefined;
        var pos: usize = 0;

        @memcpy(payload[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, PROTOCOL_VERSION)));
        pos += 2;
        payload[pos] = 0x21; // ClientTag.reply
        pos += 1;

        @memcpy(payload[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, request_id)));
        pos += 8;

        switch (result) {
            .ok => |r| {
                payload[pos] = 0;
                pos += 1;
                @memcpy(payload[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, r.entity_id)));
                pos += 8;
            },
            .err => |e| {
                payload[pos] = 1;
                pos += 1;
                payload[pos] = @intFromEnum(e);
                pos += 1;
            },
        }

        const key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.client_key else null;
        self.sendFrame(client.fd, key, payload[0..pos]) catch {
            self.disconnectClient(client);
        };
    }

    /// Find a client connection by client_id and send a reply.
    pub fn sendReplyToClientId(self: *ConnectionManager, client_id: u128, request_id: u128, result: msg.Result) void {
        for (self.clients[0..self.client_count]) |*client| {
            if (!client.connected) continue;
            if (client.client_id == client_id) {
                self.sendClientReply(client, @intCast(request_id & 0xFFFFFFFFFFFFFFFF), result);
                return;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Cluster state query (read-only, no consensus)
    // -----------------------------------------------------------------------

    fn handleClusterStateRequest(self: *ConnectionManager, client: *Conn) void {
        var buf = &self.state_response_buf;
        var pos: usize = 0;

        const sm = self.replica.state_machine;
        const replica = self.replica;

        // Header
        buf[pos] = 0x01; // query_type: full snapshot
        pos += 1;
        writeLE64(buf, &pos, replica.view_number);
        writeLE64(buf, &pos, replica.commit_min);
        writeLE64(buf, &pos, replica.op_number);
        buf[pos] = @intFromEnum(replica.status);
        pos += 1;
        buf[pos] = if (replica.isLeader() and replica.status == .normal) 1 else 0;
        pos += 1;

        // Nodes
        var node_count: u16 = 0;
        for (sm.nodes[0..sm.node_count]) |n| {
            if (n.active) node_count += 1;
        }
        writeLE16(buf, &pos, node_count);
        for (sm.nodes[0..sm.node_count]) |n| {
            if (!n.active) continue;
            writeLE64(buf, &pos, n.id);
            @memcpy(buf[pos..][0..64], &n.name);
            pos += 64;
            buf[pos] = @intFromEnum(n.status);
            pos += 1;
            buf[pos] = @intFromEnum(n.gpu_type);
            pos += 1;
            buf[pos] = n.gpu_count;
            pos += 1;
            buf[pos] = n.allocatable_gpu;
            pos += 1;
            writeLE32(buf, &pos, n.cpu_millicores);
            writeLE32(buf, &pos, n.memory_megabytes);
            @memcpy(buf[pos..][0..32], &n.region);
            pos += 32;
            @memcpy(buf[pos..][0..32], &n.provider);
            pos += 32;
        }

        // Deployments
        var dep_count: u16 = 0;
        for (sm.deployments[0..sm.deployment_count]) |d| {
            if (d.active) dep_count += 1;
        }
        writeLE16(buf, &pos, dep_count);
        for (sm.deployments[0..sm.deployment_count]) |d| {
            if (!d.active) continue;
            writeLE64(buf, &pos, d.id);
            @memcpy(buf[pos..][0..64], &d.name);
            pos += 64;
            @memcpy(buf[pos..][0..128], d.image[0..128]); // first 128 bytes of image
            pos += 128;
            writeLE32(buf, &pos, d.replicas);
            writeLE32(buf, &pos, d.ready_replicas);
            buf[pos] = if (d.paused) 1 else 0;
            pos += 1;
            writeLE32(buf, &pos, d.version);
            buf[pos] = @intFromEnum(d.gpu_type);
            pos += 1;
            buf[pos] = d.gpu_count;
            pos += 1;
        }

        // Pods
        var pod_count: u16 = 0;
        for (sm.pods[0..sm.pod_count]) |p| {
            if (p.active) pod_count += 1;
        }
        writeLE16(buf, &pos, pod_count);
        for (sm.pods[0..sm.pod_count]) |p| {
            if (!p.active) continue;
            writeLE64(buf, &pos, p.id);
            writeLE64(buf, &pos, p.deployment_id);
            writeLE64(buf, &pos, p.node_id);
            buf[pos] = @intFromEnum(p.phase);
            pos += 1;
        }

        // Agents
        const worker_count: u16 = @intCast(replica.worker_count);
        writeLE16(buf, &pos, worker_count);
        for (replica.workers[0..replica.worker_count]) |agent| {
            @memcpy(buf[pos..][0..64], &agent.hostname);
            pos += 64;
            writeLE64(buf, &pos, agent.node_id);
            buf[pos] = if (agent.connected) 1 else 0;
            pos += 1;
            writeLE64i(buf, &pos, agent.last_heartbeat_tick);
            buf[pos] = @intFromEnum(agent.gpu_type);
            pos += 1;
            buf[pos] = agent.gpu_count;
            pos += 1;
        }

        // Queue stats
        const queue = &self.request_queue;
        writeLE64(buf, &pos, @as(u64, @intCast(queue.totalDepth())));
        writeLE64(buf, &pos, @as(u64, @intCast(queue.activeInFlightCount())));
        writeLE64(buf, &pos, queue.enqueue_total);
        writeLE64(buf, &pos, queue.dispatch_total);
        writeLE64(buf, &pos, queue.resolve_total);

        // Wrap in [version][tag] + state data
        var inner: [131072 + 3]u8 = undefined;
        @memcpy(inner[0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, PROTOCOL_VERSION)));
        inner[2] = 0x25; // cluster_state_response
        @memcpy(inner[3..][0..pos], buf[0..pos]);

        const key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.client_key else null;
        self.sendFrame(client.fd, key, inner[0 .. 3 + pos]) catch {
            self.disconnectClient(client);
        };
    }

    fn writeLE64(buf: []u8, pos: *usize, val: u64) void {
        @memcpy(buf[pos.*..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, val)));
        pos.* += 8;
    }

    fn writeLE64i(buf: []u8, pos: *usize, val: i64) void {
        @memcpy(buf[pos.*..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(i64, val)));
        pos.* += 8;
    }

    fn writeLE32(buf: []u8, pos: *usize, val: u32) void {
        @memcpy(buf[pos.*..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, val)));
        pos.* += 4;
    }

    fn writeLE16(buf: []u8, pos: *usize, val: u16) void {
        @memcpy(buf[pos.*..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, val)));
        pos.* += 2;
    }

    // -----------------------------------------------------------------------
    // Encrypted frame send/receive helpers
    // -----------------------------------------------------------------------

    /// Send a frame, encrypting if key is provided. Frame format:
    ///   Plaintext: [4B len][1B flags=0x00][payload...]
    ///   Encrypted: [4B len][1B flags=0x01][24B nonce][encrypted payload][16B tag]
    pub fn sendFrame(self: *ConnectionManager, fd: c_int, key: ?*const [enc.KEY_LEN]u8, payload: []const u8) !void {
        if (key != null and self.encryption != null and self.encryption.?.enabled) {
            // Encrypted frame
            var header: [5]u8 = undefined; // len(4) + flags(1), used as AAD
            const enc_payload_len = enc.NONCE_LEN + payload.len + enc.TAG_LEN;
            const frame_len: u32 = @intCast(1 + enc_payload_len); // flags + encrypted
            @memcpy(header[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, frame_len)));
            header[4] = 0x01; // encrypted

            var enc_buf: [MAX_FRAME_BYTES + enc.ENCRYPTED_OVERHEAD]u8 = undefined;
            const enc_len = enc.encryptFrame(key.?, payload, &header, &enc_buf);
            if (enc_len == 0) return error.EncryptionFailed;

            try writeAll(fd, &header);
            try writeAll(fd, enc_buf[0..enc_len]);
        } else {
            // Plaintext frame
            var header: [5]u8 = undefined;
            const frame_len: u32 = @intCast(1 + payload.len); // flags + payload
            @memcpy(header[0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, frame_len)));
            header[4] = 0x00; // plaintext

            try writeAll(fd, &header);
            try writeAll(fd, payload);
        }
    }

    /// Decode one bounded frame. Client/worker payloads are versioned; peer payloads are not.
    fn decodeFrame(self: *ConnectionManager, key: ?*const [enc.KEY_LEN]u8, data: []const u8, consumed: *usize, decrypt_buf: []u8, versioned: bool) ?[]const u8 {
        if (data.len < 5) return null;

        const frame_len = std.mem.readInt(u32, data[0..4], .little);
        if (frame_len > MAX_FRAME_BYTES - 4) {
            consumed.* = data.len;
            return null;
        }

        const flags = data[4];
        if (flags != 0x00 and flags != 0x01) {
            consumed.* = @min(data.len, 4 + @as(usize, frame_len));
            return null;
        }
        const key_configured = self.encryption != null and self.encryption.?.enabled;
        if ((flags == 0x01) != key_configured) {
            consumed.* = @min(data.len, 4 + @as(usize, frame_len));
            return null;
        }
        if (flags == 0x01 and key == null) {
            consumed.* = @min(data.len, 4 + @as(usize, frame_len));
            return null;
        }

        const inner_min: usize = if (versioned) 3 else 1;
        const payload_min = if (flags == 0x01) enc.NONCE_LEN + enc.TAG_LEN + inner_min else inner_min;
        if (frame_len < 1 + payload_min) {
            consumed.* = @min(data.len, 4 + @as(usize, frame_len));
            return null;
        }

        const total = 4 + @as(usize, frame_len);
        if (data.len < total) return null;
        consumed.* = total;

        const plaintext = if (flags == 0x01) blk: {
            const encrypted_data = data[5..total];
            const pt_len = enc.decryptFrame(key.?, encrypted_data, data[0..5], decrypt_buf) catch return null;
            if (pt_len < inner_min) return null;
            break :blk decrypt_buf[0..pt_len];
        } else data[5..total];

        if (versioned) {
            if (plaintext.len < 3) return null;
            const version = std.mem.readInt(u16, plaintext[0..2], .little);
            if (version != PROTOCOL_VERSION) return null;
        }
        return plaintext;
    }

    fn disconnectClient(self: *ConnectionManager, client: *Conn) void {
        if (!client.connected) return;
        const client_id = client.client_id;
        const fd = client.fd;
        client.fd = -1;
        client.connected = false;
        client.frame_pos = 0;
        self.request_queue.cancelClient(client_id);
        if (fd >= 0) _ = libc.close(fd);
    }

    // -- Peer connections (VRR inter-replica TCP) --

    fn acceptPeers(self: *ConnectionManager) void {
        if (self.peer_listen_fd < 0) return;
        while (true) {
            const fd = std.c.accept(self.peer_listen_fd, null, null);
            if (fd < 0) return;
            setNonBlockingWith(fd, self.fcntl_ops) catch {
                _ = libc.close(fd);
                continue;
            };

            const slot = self.acquirePeerSlot() orelse {
                _ = libc.close(fd);
                return;
            };
            // Inbound peer: we don't know their ID yet, will learn from first frame
            self.peers[slot] = .{
                .fd = fd,
                .frame_pos = 0,
                .connected = true,
                .peer_id_known = false,
                .peer_deadline_tick = self.poll_count +| PEER_IDENTITY_TIMEOUT_TICKS,
            };
        }
    }

    fn readPeers(self: *ConnectionManager) void {
        for (0..self.peer_count) |peer_idx| {
            const peer = &self.peers[peer_idx];
            if (!peer.connected or peer.connect_pending) continue;
            readConn(peer) catch {
                disconnectPeer(peer);
                continue;
            };
            self.processPeerFrames(peer_idx);
        }
    }

    fn processPeerFrames(self: *ConnectionManager, peer_idx: usize) void {
        const peer = &self.peers[peer_idx];
        var consumed: usize = 0;
        const data = peer.frame_buf[0..peer.frame_pos];
        var decrypt_buf: [MAX_FRAME_BYTES]u8 = undefined;

        const peer_key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.peer_key else null;

        // Frame format (plaintext): [4B len][1B flags=0x00][1B from_id][VRR bytes]
        // Frame format (encrypted): [4B len][1B flags=0x01][24B nonce][encrypted(from_id + VRR)][16B tag]
        while (consumed + 5 <= data.len) {
            var frame_consumed: usize = 0;
            const frame_payload = self.decodeFrame(peer_key, data[consumed..], &frame_consumed, &decrypt_buf, false) orelse {
                if (frame_consumed == 0) break;
                consumed += frame_consumed;
                continue;
            };
            consumed += frame_consumed;

            if (frame_payload.len < 2) continue;
            const from_id = frame_payload[0];
            if (from_id >= self.replica.replica_count) continue;
            const vrr_data = frame_payload[1..];

            // Deserialize and identity-check before any peer bind/replace so a
            // malformed spoof frame cannot evict a healthy bound socket.
            const message = msg.deserialize(vrr_data) catch continue;
            if (!peerFrameIdentityValid(from_id, message)) continue;
            if (!replica_mod.peerMessageSemanticsValid(message)) continue;
            if (!self.identifyPeerConnection(peer_idx, from_id)) {
                if (!peer.connected) break;
                continue;
            }

            self.replica.onMessage(from_id, message);
        }

        shiftBuffer(&peer.frame_buf, &peer.frame_pos, consumed);
    }

    /// Messages that carry replica_id must agree with the frame from_id before bind.
    fn peerFrameIdentityValid(from_id: u8, message: msg.Message) bool {
        return switch (message) {
            .prepare_ok => |m| m.replica_id == from_id,
            .start_view_change => |m| m.replica_id == from_id,
            .do_view_change => |m| m.replica_id == from_id,
            else => true,
        };
    }

    /// Send a framed VRR message to a peer. `data` is pre-framed:
    /// [4-byte LE len][1-byte from_id][VRR message bytes]
    /// We re-frame with encryption if enabled.
    pub fn sendToPeer(self: *ConnectionManager, to: u8, data: []const u8) void {
        if (data.len < 5) return;

        // Extract inner payload (from_id + VRR bytes, skip the 4-byte length prefix)
        const inner = data[4..];
        const key = if (self.encryption != null and self.encryption.?.enabled) &self.encryption.?.peer_key else null;

        for (self.peers[0..self.peer_count]) |*peer| {
            if (!peer.connected or peer.connect_pending) continue;
            const validated_match = peer.peer_id_known and peer.worker_idx == to;
            const configured_match = !peer.peer_id_known and
                peer.peer_direction == .outbound and
                peer.configured_peer_id_known and
                peer.configured_peer_id == to;
            if (validated_match or configured_match) {
                self.sendFrame(peer.fd, key, inner) catch {
                    disconnectPeer(peer);
                };
                return;
            }
        }
    }

    /// Initiate an outbound TCP connection to a peer replica.
    /// Records the target for retry if the connection fails.
    pub fn connectToPeer(self: *ConnectionManager, peer_id: u8, host: u32, port: u16) void {
        if (peer_id == self.replica_id) return;

        // Retain configured membership for observability/validation, but only
        // the lower replica ID initiates. The higher side accepts inbound.
        self.recordPeerTarget(peer_id, host, port);
        if (!self.shouldInitiatePeerConnection(peer_id)) return;

        self.connectToPeerInner(peer_id, host, port);
    }

    fn shouldInitiatePeerConnection(self: *const ConnectionManager, peer_id: u8) bool {
        return self.replica_id < peer_id;
    }

    fn recordPeerTarget(self: *ConnectionManager, peer_id: u8, host: u32, port: u16) void {
        // Avoid duplicates
        for (self.peer_targets[0..self.peer_target_count]) |*t| {
            if (t.peer_id == peer_id) {
                t.host = host;
                t.port = port;
                return;
            }
        }
        if (self.peer_target_count < msg.REPLICA_COUNT_MAX) {
            self.peer_targets[self.peer_target_count] = .{
                .peer_id = peer_id,
                .host = host,
                .port = port,
            };
            self.peer_target_count += 1;
        }
    }

    fn hasPeerConnection(self: *const ConnectionManager, peer_id: u8) bool {
        for (self.peers[0..self.peer_count]) |*peer| {
            if (peer.connected and peer.peer_id_known and peer.worker_idx == peer_id) return true;
        }
        return false;
    }

    fn identifyPeerConnection(self: *ConnectionManager, peer_idx: usize, from_id: u8) bool {
        if (peer_idx >= self.peer_count) return false;

        const peer = &self.peers[peer_idx];
        if (!peer.connected) return false;

        // Bound socket identity is immutable: reject spoof/rebind attempts.
        if (peer.peer_id_known) return peer.worker_idx == from_id;
        if (peer.configured_peer_id_known and peer.configured_peer_id != from_id) {
            disconnectPeer(peer);
            return false;
        }

        const preferred_direction: PeerDirection = if (self.replica_id < from_id) .outbound else .inbound;
        if (peer.peer_direction != preferred_direction) {
            disconnectPeer(peer);
            return false;
        }

        for (0..self.peer_count) |other_idx| {
            if (other_idx == peer_idx) continue;
            const other = &self.peers[other_idx];
            if (!other.connected or !other.peer_id_known) continue;
            if (other.worker_idx != from_id) continue;

            // A validated binding is never evicted by a later candidate.
            disconnectPeer(peer);
            return false;
        }

        peer.worker_idx = from_id;
        peer.peer_id_known = true;
        peer.peer_deadline_tick = 0;
        return true;
    }

    /// Retry connections to peers that aren't connected. Called from poll().
    pub fn retryPeerConnections(self: *ConnectionManager, now_tick: u64) void {
        if (self.peer_target_count == 0) return;

        self.completePeerConnections(now_tick);

        if (now_tick > 0 and now_tick - self.last_retry_tick < PEER_RETRY_INTERVAL_TICKS) return;
        self.last_retry_tick = now_tick;

        for (self.peer_targets[0..self.peer_target_count]) |target| {
            if (self.peerNeedsRetry(target.peer_id)) {
                self.connectToPeerInner(target.peer_id, target.host, target.port);
            }
        }
    }

    fn hasPeerCandidate(self: *const ConnectionManager, peer_id: u8) bool {
        for (self.peers[0..self.peer_count]) |peer| {
            if (!peer.connected or peer.peer_id_known) continue;
            if (peer.configured_peer_id_known and peer.configured_peer_id == peer_id) return true;
        }
        return false;
    }

    fn peerNeedsRetry(self: *const ConnectionManager, peer_id: u8) bool {
        return self.shouldInitiatePeerConnection(peer_id) and
            !self.hasPeerConnection(peer_id) and
            !self.hasPeerCandidate(peer_id);
    }

    fn completePeerConnections(self: *ConnectionManager, now_tick: u64) void {
        for (self.peers[0..self.peer_count]) |*peer| {
            if (!peer.connected or peer.peer_id_known) continue;
            if (now_tick >= peer.peer_deadline_tick) {
                disconnectPeer(peer);
                continue;
            }
            if (!peer.connect_pending) continue;

            var poll_fds = [_]std.posix.pollfd{.{
                .fd = peer.fd,
                .events = std.posix.POLL.OUT | std.posix.POLL.ERR | std.posix.POLL.HUP,
                .revents = 0,
            }};
            const ready = std.posix.poll(&poll_fds, 0) catch {
                disconnectPeer(peer);
                continue;
            };
            if (ready == 0) continue;

            var socket_error: c_int = 0;
            var socket_error_len: std.posix.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(peer.fd, std.posix.SOL.SOCKET, std.posix.SO.ERROR, @ptrCast(&socket_error), &socket_error_len) != 0 or socket_error != 0) {
                disconnectPeer(peer);
                continue;
            }
            peer.connect_pending = false;
            peer.peer_deadline_tick = now_tick +| PEER_IDENTITY_TIMEOUT_TICKS;
            std.debug.print("hivemind core: peer {d} TCP connected, awaiting identity\n", .{peer.configured_peer_id});
        }
    }

    fn connectToPeerInner(self: *ConnectionManager, peer_id: u8, host: u32, port: u16) void {
        const fd = libc.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return;
        setNonBlockingWith(fd, self.fcntl_ops) catch {
            _ = libc.close(fd);
            return;
        };

        var addr: std.posix.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = host,
        };
        const rc = std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in));
        const pending = if (rc == 0) false else switch (std.posix.errno(rc)) {
            .INPROGRESS => true,
            else => {
                _ = libc.close(fd);
                return;
            },
        };

        const slot = self.acquirePeerSlot() orelse {
            _ = libc.close(fd);
            return;
        };
        self.peers[slot] = .{
            .fd = fd,
            .frame_pos = 0,
            .connected = true,
            .peer_direction = .outbound,
            .connect_pending = pending,
            .peer_deadline_tick = self.poll_count +| PEER_CONNECT_TIMEOUT_TICKS,
            .configured_peer_id = peer_id,
            .configured_peer_id_known = true,
            .peer_id_known = false,
        };
        if (!pending) {
            self.peers[slot].peer_deadline_tick = self.poll_count +| PEER_IDENTITY_TIMEOUT_TICKS;
        }
    }

    // -- Helpers --

    fn listenOn(port: u16) !c_int {
        const fd = libc.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketCreateFailed;
        errdefer _ = libc.close(fd);

        try setNonBlockingWith(fd, FcntlOps.system);

        const optval: u32 = 1;
        _ = std.c.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, @ptrCast(&optval), @sizeOf(u32));

        var addr: std.posix.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0,
        };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) != 0) return error.BindFailed;
        if (std.c.listen(fd, 128) != 0) return error.ListenFailed;

        return fd;
    }

    fn setNonBlocking(fd: c_int) !void {
        return setNonBlockingWith(fd, FcntlOps.system);
    }

    fn setNonBlockingWith(fd: c_int, ops: FcntlOps) !void {
        std.debug.assert(fd >= 0);
        const flags = ops.get_flags(fd);
        if (flags < 0) return error.GetFlagsFailed;
        const O_NONBLOCK: c_int = if (@import("builtin").os.tag == .macos) 0x0004 else 0x800;
        if (ops.set_flags(fd, flags | O_NONBLOCK) != 0) return error.SetFlagsFailed;
    }

    fn acquirePeerSlot(self: *ConnectionManager) ?usize {
        for (0..self.peer_count) |i| {
            if (!self.peers[i].connected and self.peers[i].fd < 0) return i;
        }
        if (self.peer_count >= MAX_PEER_CONNECTIONS) return null;
        const slot = self.peer_count;
        self.peer_count += 1;
        return slot;
    }

    fn readConn(conn: *Conn) !void {
        const space = conn.frame_buf[conn.frame_pos..];
        if (space.len == 0) return error.BufferOverflow;
        const rc = std.c.read(conn.fd, space.ptr, space.len);
        if (rc == 0) return error.Disconnected;
        if (rc < 0) {
            switch (std.posix.errno(rc)) {
                .INTR, .AGAIN => return,
                else => return error.ReadFailed,
            }
        }
        conn.frame_pos += @intCast(rc);
    }

    pub fn writeAll(fd: c_int, data: []const u8) !void {
        var written: usize = 0;
        var again_retries: u8 = 0;
        while (written < data.len) {
            const rc = std.c.write(fd, data[written..].ptr, data.len - written);
            if (rc < 0) {
                switch (std.posix.errno(rc)) {
                    .INTR => continue,
                    .AGAIN => {
                        if (again_retries >= 16) return error.WouldBlock;
                        again_retries += 1;
                        const ts = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
                        _ = std.c.nanosleep(&ts, null);
                        continue;
                    },
                    else => return error.WriteFailed,
                }
            }
            if (rc == 0) return error.WriteFailed;
            again_retries = 0;
            written += @intCast(rc);
        }
    }

    fn shiftBuffer(buf: *[MAX_FRAME_BYTES]u8, pos: *usize, consumed: usize) void {
        if (consumed > 0) {
            if (consumed >= pos.*) {
                pos.* = 0;
                return;
            }
            const remaining = pos.* - consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, buf[0..remaining], buf[consumed..pos.*]);
            }
            pos.* = remaining;
        }
    }

    fn parseWorkerRegister(payload: []const u8) ?msg.WorkerRegisterMsg {
        // Wire size is 138 (packed), not @sizeOf which includes alignment padding
        if (payload.len != 138) return null;
        const gpu_type = msg.enumFromIntChecked(msg.GpuType, payload[72]) catch return null;
        var register = msg.WorkerRegisterMsg{};
        register.hostname = payload[0..64].*;
        register.cpu_millicores = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, payload[64..68]));
        register.memory_megabytes = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, payload[68..72]));
        register.gpu_type = gpu_type;
        register.gpu_count = payload[73];
        register.provider = payload[74..106].*;
        register.region = payload[106..138].*;
        return register;
    }

    fn parseWorkerHeartbeat(payload: []const u8) ?msg.WorkerHeartbeatMsg {
        if (payload.len != 23) return null;
        var heartbeat = msg.WorkerHeartbeatMsg{};
        heartbeat.timestamp = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[0..8]));
        heartbeat.cpu_usage_pct = payload[8];
        heartbeat.memory_used_mb = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, payload[9..13]));
        heartbeat.gpu_utilization = payload[13..21].*;
        heartbeat.pods_running = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, payload[21..23]));
        return heartbeat;
    }

    fn parseWorkerPodStatus(payload: []const u8) ?msg.WorkerPodStatusMsg {
        if (payload.len != 150) return null;
        const old_phase = msg.enumFromIntChecked(msg.PodPhase, payload[8]) catch return null;
        const new_phase = msg.enumFromIntChecked(msg.PodPhase, payload[9]) catch return null;
        var status = msg.WorkerPodStatusMsg{};
        status.pod_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[0..8]));
        status.old_phase = old_phase;
        status.new_phase = new_phase;
        status.timestamp = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, payload[10..18]));
        status.exit_code = std.mem.littleToNative(i32, std.mem.bytesToValue(i32, payload[18..22]));
        status.message = payload[22..150].*;
        return status;
    }

    fn parseClientCommand(tag: u8, fields: []const u8) ?msg.Command {
        const command: msg.Command = switch (tag) {
            0 => blk: { // register_node
                if (fields.len < 138) return null;
                const gpu_type = msg.enumFromIntChecked(msg.GpuType, fields[72]) catch return null;
                break :blk .{ .register_node = .{
                    .node_name = fields[0..64].*,
                    .cpu_millicores = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[64..68])),
                    .memory_megabytes = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[68..72])),
                    .gpu_type = gpu_type,
                    .gpu_count = fields[73],
                    .provider = fields[74..106].*,
                    .region = fields[106..138].*,
                } };
            },
            3 => blk: { // create_deployment
                if (fields.len < 398) return null;
                var p: usize = 0;
                var cmd: msg.CreateDeploymentCmd = .{
                    .name = fields[p..][0..64].*,
                    .namespace = blk2: {
                        p += 64;
                        break :blk2 fields[p..][0..64].*;
                    },
                    .image = blk3: {
                        p += 64;
                        break :blk3 fields[p..][0..256].*;
                    },
                    .replicas = blk4: {
                        p += 256;
                        break :blk4 std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
                    },
                    .cpu_millicores = blk5: {
                        p += 4;
                        break :blk5 std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
                    },
                    .memory_megabytes = blk6: {
                        p += 4;
                        break :blk6 std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
                    },
                    .gpu_type = blk7: {
                        p += 4;
                        break :blk7 msg.enumFromIntChecked(msg.GpuType, fields[p]) catch return null;
                    },
                    .gpu_count = blk8: {
                        p += 1;
                        break :blk8 fields[p];
                    },
                };
                // Optional extended payload (image pull credentials) — see docs/FINDINGS_AND_ISSUES.md
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
                break :blk .{ .create_deployment = cmd };
            },
            6 => blk: { // scale_deployment
                if (fields.len < 12) return null;
                break :blk .{ .scale_deployment = .{
                    .deployment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, fields[0..8])),
                    .desired_replicas = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[8..12])),
                } };
            },
            10 => blk: { // update_deployment
                if (fields.len < 532) return null;
                var p: usize = 0;
                const deployment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, fields[p..][0..8]));
                p += 8;
                const image = fields[p..][0..256].*;
                p += 256;
                const entrypoint = fields[p..][0..256].*;
                p += 256;
                const port = std.mem.littleToNative(u16, std.mem.bytesToValue(u16, fields[p..][0..2]));
                p += 2;
                const cpu_millicores = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
                p += 4;
                const memory_megabytes = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[p..][0..4]));
                p += 4;
                const gpu_type = msg.enumFromIntChecked(msg.GpuType, fields[p]) catch return null;
                p += 1;
                const gpu_count = fields[p];
                break :blk .{ .update_deployment = .{
                    .deployment_id = deployment_id,
                    .image = image,
                    .entrypoint = entrypoint,
                    .port = port,
                    .cpu_millicores = cpu_millicores,
                    .memory_megabytes = memory_megabytes,
                    .gpu_type = gpu_type,
                    .gpu_count = gpu_count,
                } };
            },
            11 => blk: { // set_traffic_split
                if (fields.len < 29) return null;
                var rules: [4]msg.TrafficRule = [_]msg.TrafficRule{.{}} ** 4;
                var off: usize = 8;
                for (0..4) |i| {
                    rules[i] = .{
                        .version = std.mem.littleToNative(u32, std.mem.bytesToValue(u32, fields[off..][0..4])),
                        .weight = fields[off + 4],
                    };
                    off += 5;
                }
                break :blk .{ .set_traffic_split = .{
                    .deployment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, fields[0..8])),
                    .rules = rules,
                    .rule_count = fields[28],
                } };
            },
            12 => blk: { // rollback_deployment
                if (fields.len < 8) return null;
                break :blk .{ .rollback_deployment = .{
                    .deployment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, fields[0..8])),
                } };
            },
            13 => blk: { // delete_deployment
                if (fields.len < 8) return null;
                break :blk .{ .delete_deployment = .{
                    .deployment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, fields[0..8])),
                } };
            },
            14 => blk: { // pause_deployment
                if (fields.len < 8) return null;
                break :blk .{ .pause_deployment = .{
                    .deployment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, fields[0..8])),
                } };
            },
            15 => blk: { // resume_deployment
                if (fields.len < 8) return null;
                break :blk .{ .resume_deployment = .{
                    .deployment_id = std.mem.littleToNative(u64, std.mem.bytesToValue(u64, fields[0..8])),
                } };
            },
            else => return null,
        };
        msg.validateCommand(command) catch return null;
        return command;
    }
};

fn disconnectPeer(peer: *Conn) void {
    if (peer.fd >= 0) _ = libc.close(peer.fd);
    peer.fd = -1;
    peer.connected = false;
    peer.frame_pos = 0;
    peer.connect_pending = false;
    peer.peer_deadline_tick = 0;
    peer.configured_peer_id = 0;
    peer.configured_peer_id_known = false;
    peer.worker_idx = 0;
    peer.peer_id_known = false;
}

fn readSocketUntilBytes(fd: c_int, total: usize) !void {
    const initial_sleep = std.c.timespec{ .sec = 0, .nsec = 10 * 1_000_000 };
    _ = std.c.nanosleep(&initial_sleep, null);

    var buf: [8192]u8 = undefined;
    var received: usize = 0;
    while (received < total) {
        const rc = std.c.read(fd, &buf, @min(buf.len, total - received));
        if (rc < 0) {
            switch (std.posix.errno(rc)) {
                .INTR => continue,
                .AGAIN => {
                    const retry_sleep = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
                    _ = std.c.nanosleep(&retry_sleep, null);
                    continue;
                },
                else => return error.ReadFailed,
            }
        }
        if (rc == 0) return error.UnexpectedEof;
        received += @intCast(rc);
    }
}

test "parse update deployment client command" {
    var fields: [532]u8 = std.mem.zeroes([532]u8);
    var pos: usize = 0;
    @memcpy(fields[pos..][0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, 42)));
    pos += 8;
    const image = "registry.example.com/poc:cpu-v2";
    @memcpy(fields[pos..][0..image.len], image);
    pos += 256;
    const entrypoint = "/app/server";
    @memcpy(fields[pos..][0..entrypoint.len], entrypoint);
    pos += 256;
    @memcpy(fields[pos..][0..2], &std.mem.toBytes(std.mem.nativeToLittle(u16, 8080)));
    pos += 2;
    @memcpy(fields[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 750)));
    pos += 4;
    @memcpy(fields[pos..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, 1024)));
    pos += 4;
    fields[pos] = @intFromEnum(msg.GpuType.t4);
    pos += 1;
    fields[pos] = 1;

    const command = ConnectionManager.parseClientCommand(10, &fields) orelse return error.ExpectedCommand;
    switch (command) {
        .update_deployment => |cmd| {
            try std.testing.expectEqual(@as(u64, 42), cmd.deployment_id);
            try std.testing.expectEqualStrings(image, msg.fixedToSlice(&cmd.image));
            try std.testing.expectEqualStrings(entrypoint, msg.fixedToSlice(&cmd.entrypoint));
            try std.testing.expectEqual(@as(u16, 8080), cmd.port);
            try std.testing.expectEqual(@as(u32, 750), cmd.cpu_millicores);
            try std.testing.expectEqual(@as(u32, 1024), cmd.memory_megabytes);
            try std.testing.expectEqual(msg.GpuType.t4, cmd.gpu_type);
            try std.testing.expectEqual(@as(u8, 1), cmd.gpu_count);
        },
        else => return error.WrongCommand,
    }
}

test "parseClientCommand rejects invalid GpuType on register_node" {
    var fields: [138]u8 = std.mem.zeroes([138]u8);
    fields[72] = 0xFF; // invalid GpuType
    try std.testing.expect(ConnectionManager.parseClientCommand(0, &fields) == null);
}

test "parseClientCommand rejects invalid GpuType on create_deployment" {
    var fields: [398]u8 = std.mem.zeroes([398]u8);
    // gpu_type is at offset 64+64+256+4+4+4 = 396
    fields[396] = 0xFE;
    try std.testing.expect(ConnectionManager.parseClientCommand(3, &fields) == null);
}

test "parseClientCommand rejects invalid GpuType on update_deployment" {
    var fields: [532]u8 = std.mem.zeroes([532]u8);
    // gpu_type is at offset 8+256+256+2+4+4 = 530
    fields[530] = 0xFD;
    try std.testing.expect(ConnectionManager.parseClientCommand(10, &fields) == null);
}

test "parseClientCommand rejects invalid traffic rule_count" {
    var fields: [29]u8 = std.mem.zeroes([29]u8);
    fields[28] = 5; // > rules.len (4)
    try std.testing.expect(ConnectionManager.parseClientCommand(11, &fields) == null);
}

test "parseWorkerRegister rejects invalid GpuType" {
    var payload: [138]u8 = std.mem.zeroes([138]u8);
    payload[72] = 0xFF;
    try std.testing.expect(ConnectionManager.parseWorkerRegister(&payload) == null);
}

test "parseWorkerRegister accepts valid GpuType" {
    var payload: [138]u8 = std.mem.zeroes([138]u8);
    payload[72] = @intFromEnum(msg.GpuType.t4);
    payload[73] = 2;
    const register = ConnectionManager.parseWorkerRegister(&payload) orelse return error.ExpectedRegister;
    try std.testing.expectEqual(msg.GpuType.t4, register.gpu_type);
    try std.testing.expectEqual(@as(u8, 2), register.gpu_count);
}

test "parseWorkerPodStatus rejects invalid PodPhase" {
    var payload: [150]u8 = std.mem.zeroes([150]u8);
    payload[8] = 0xFF; // old_phase
    payload[9] = @intFromEnum(msg.PodPhase.running);
    try std.testing.expect(ConnectionManager.parseWorkerPodStatus(&payload) == null);

    payload[8] = @intFromEnum(msg.PodPhase.pending);
    payload[9] = 0xFE; // new_phase
    try std.testing.expect(ConnectionManager.parseWorkerPodStatus(&payload) == null);
}

test "parseWorkerPodStatus accepts valid PodPhase" {
    var payload: [150]u8 = std.mem.zeroes([150]u8);
    payload[8] = @intFromEnum(msg.PodPhase.pending);
    payload[9] = @intFromEnum(msg.PodPhase.running);
    const status = ConnectionManager.parseWorkerPodStatus(&payload) orelse return error.ExpectedStatus;
    try std.testing.expectEqual(msg.PodPhase.pending, status.old_phase);
    try std.testing.expectEqual(msg.PodPhase.running, status.new_phase);
}

test "writeAll retries when nonblocking peer writes hit EAGAIN" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);

    try ConnectionManager.setNonBlocking(fds[0]);

    const send_buf: c_int = 4096;
    _ = std.c.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, @ptrCast(&send_buf), @sizeOf(c_int));

    const payload = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    const reader = try std.Thread.spawn(.{}, readSocketUntilBytes, .{ fds[1], payload.len });
    defer reader.join();

    try ConnectionManager.writeAll(fds[0], payload);
}

test "writeAll returns WouldBlock after bounded EAGAIN retries" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);

    try ConnectionManager.setNonBlocking(fds[0]);

    const send_buf: c_int = 4096;
    _ = std.c.setsockopt(fds[0], std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, @ptrCast(&send_buf), @sizeOf(c_int));

    const payload = try std.testing.allocator.alloc(u8, 8 << 20);
    defer std.testing.allocator.free(payload);
    @memset(payload, 0x5a);

    try std.testing.expectError(error.WouldBlock, ConnectionManager.writeAll(fds[0], payload));
}

test "readConn ignores EAGAIN on nonblocking sockets" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);

    try ConnectionManager.setNonBlocking(fds[0]);

    var conn = Conn{
        .fd = fds[0],
        .frame_pos = 0,
        .connected = true,
    };

    try ConnectionManager.readConn(&conn);
    try std.testing.expectEqual(@as(usize, 0), conn.frame_pos);
}

test "readConn surfaces real read failures" {
    var conn = Conn{
        .fd = -1,
        .frame_pos = 0,
        .connected = true,
    };

    try std.testing.expectError(error.ReadFailed, ConnectionManager.readConn(&conn));
}

test "disconnectPeer releases peer slot state" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[1]);

    var peer = Conn{
        .fd = fds[0],
        .connected = true,
        .worker_idx = 3,
        .peer_id_known = true,
    };

    disconnectPeer(&peer);

    try std.testing.expectEqual(@as(c_int, -1), peer.fd);
    try std.testing.expect(!peer.connected);
    try std.testing.expectEqual(@as(usize, 0), peer.worker_idx);
    try std.testing.expect(!peer.peer_id_known);
}

test "hasPeerConnection recognizes identified inbound peers" {
    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    cm.peer_count = 1;
    cm.peers[0] = .{
        .fd = 42,
        .connected = true,
        .worker_idx = 4,
        .peer_id_known = true,
    };

    try std.testing.expect(cm.hasPeerConnection(4));
    try std.testing.expect(!cm.hasPeerConnection(3));
}

test "only lower replica records and initiates configured peer target" {
    const higher = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(higher);
    higher.replica_id = 4;
    higher.peer_targets = [_]PeerTarget{.{}} ** msg.REPLICA_COUNT_MAX;
    higher.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    higher.peer_target_count = 0;
    higher.peer_count = 0;

    higher.connectToPeer(2, 0, 9102);

    try std.testing.expectEqual(@as(usize, 1), higher.peer_target_count);
    try std.testing.expect(!higher.shouldInitiatePeerConnection(2));
    try std.testing.expectEqual(@as(usize, 0), higher.peer_count);
}

test "connectToPeer ignores self target" {
    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.replica_id = 2;
    cm.peer_targets = [_]PeerTarget{.{}} ** msg.REPLICA_COUNT_MAX;
    cm.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    cm.peer_target_count = 0;
    cm.peer_count = 0;

    cm.connectToPeer(2, 0, 9102);

    try std.testing.expectEqual(@as(usize, 0), cm.peer_target_count);
    try std.testing.expectEqual(@as(usize, 0), cm.peer_count);
}

test "pending peer connect and silent endpoint expire then become retryable" {
    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.replica_id = 0;
    cm.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    cm.peer_count = 1;

    var black_hole_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &black_hole_fds));
    defer _ = libc.close(black_hole_fds[1]);
    cm.peers[0] = .{
        .fd = black_hole_fds[0],
        .connected = true,
        .peer_direction = .outbound,
        .connect_pending = true,
        .peer_deadline_tick = PEER_CONNECT_TIMEOUT_TICKS,
        .configured_peer_id = 1,
        .configured_peer_id_known = true,
    };
    try std.testing.expect(!cm.peerNeedsRetry(1));
    cm.completePeerConnections(PEER_CONNECT_TIMEOUT_TICKS);
    try std.testing.expect(!cm.peers[0].connected);
    try std.testing.expect(cm.peerNeedsRetry(1));

    var silent_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &silent_fds));
    defer _ = libc.close(silent_fds[1]);
    cm.peers[0] = .{
        .fd = silent_fds[0],
        .connected = true,
        .peer_direction = .outbound,
        .peer_deadline_tick = PEER_IDENTITY_TIMEOUT_TICKS,
        .configured_peer_id = 1,
        .configured_peer_id_known = true,
    };
    try std.testing.expect(!cm.hasPeerConnection(1));
    try std.testing.expect(!cm.peerNeedsRetry(1));
    cm.completePeerConnections(PEER_IDENTITY_TIMEOUT_TICKS);
    try std.testing.expect(!cm.peers[0].connected);
    try std.testing.expect(cm.peerNeedsRetry(1));
}

test "valid peer handshake separates configured target from validated identity" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[1]);

    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.replica_id = 0;
    cm.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    cm.peer_count = 1;
    cm.peers[0] = .{
        .fd = fds[0],
        .connected = true,
        .peer_direction = .outbound,
        .peer_deadline_tick = PEER_IDENTITY_TIMEOUT_TICKS,
        .configured_peer_id = 1,
        .configured_peer_id_known = true,
    };

    try std.testing.expect(!cm.hasPeerConnection(1));
    try std.testing.expect(cm.identifyPeerConnection(0, 1));
    try std.testing.expect(cm.hasPeerConnection(1));
    try std.testing.expectEqual(@as(usize, 1), cm.peers[0].worker_idx);
    try std.testing.expectEqual(@as(u64, 0), cm.peers[0].peer_deadline_tick);
}

fn buildTestProtocolFrame(flags: u8, version: u16, state: ?*const enc.EncryptionState) ![]u8 {
    var inner = [_]u8{ 0, 0, 0x42 };
    std.mem.writeInt(u16, inner[0..2], version, .little);

    if (flags == 0x01) {
        const encryption = state orelse return error.MissingTestKey;
        const frame_len = 1 + enc.NONCE_LEN + inner.len + enc.TAG_LEN;
        const frame = try std.testing.allocator.alloc(u8, 4 + frame_len);
        std.mem.writeInt(u32, frame[0..4], @intCast(frame_len), .little);
        frame[4] = flags;
        const encrypted_len = enc.encryptFrame(&encryption.client_key, &inner, frame[0..5], frame[5..]);
        std.debug.assert(encrypted_len == frame_len - 1);
        return frame;
    }

    const frame = try std.testing.allocator.alloc(u8, 5 + inner.len);
    std.mem.writeInt(u32, frame[0..4], @intCast(1 + inner.len), .little);
    frame[4] = flags;
    @memcpy(frame[5..], &inner);
    return frame;
}

test "client and worker frame contract table" {
    var state = try enc.EncryptionState.init("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
    const Case = struct {
        name: []const u8,
        flags: u8,
        version: u16,
        encrypted_frame: bool,
        key_configured: bool,
        valid: bool,
    };
    const cases = [_]Case{
        .{ .name = "unknown flags", .flags = 0x02, .version = PROTOCOL_VERSION, .encrypted_frame = false, .key_configured = false, .valid = false },
        .{ .name = "bad plaintext version", .flags = 0x00, .version = PROTOCOL_VERSION + 1, .encrypted_frame = false, .key_configured = false, .valid = false },
        .{ .name = "bad encrypted version", .flags = 0x01, .version = PROTOCOL_VERSION + 1, .encrypted_frame = true, .key_configured = true, .valid = false },
        .{ .name = "plaintext while key configured", .flags = 0x00, .version = PROTOCOL_VERSION, .encrypted_frame = false, .key_configured = true, .valid = false },
        .{ .name = "encrypted without key", .flags = 0x01, .version = PROTOCOL_VERSION, .encrypted_frame = true, .key_configured = false, .valid = false },
        .{ .name = "valid plaintext minimum", .flags = 0x00, .version = PROTOCOL_VERSION, .encrypted_frame = false, .key_configured = false, .valid = true },
        .{ .name = "valid encrypted minimum", .flags = 0x01, .version = PROTOCOL_VERSION, .encrypted_frame = true, .key_configured = true, .valid = true },
    };

    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    var decrypt_buf: [MAX_FRAME_BYTES]u8 = undefined;
    for (cases) |tc| {
        const frame = try buildTestProtocolFrame(tc.flags, tc.version, if (tc.encrypted_frame) &state else null);
        defer std.testing.allocator.free(frame);
        cm.encryption = if (tc.key_configured) &state else null;
        const key = if (tc.key_configured) &state.client_key else null;
        var consumed: usize = 0;
        const decoded = cm.decodeFrame(key, frame, &consumed, &decrypt_buf, true);
        try std.testing.expectEqual(tc.valid, decoded != null);
        try std.testing.expectEqual(frame.len, consumed);
        if (decoded) |payload| {
            try std.testing.expectEqual(PROTOCOL_VERSION, std.mem.readInt(u16, payload[0..2], .little));
            try std.testing.expectEqual(@as(u8, 0x42), payload[2]);
        } else {
            _ = tc.name;
        }
    }
}

test "frame contract rejects short and oversize declarations before slicing" {
    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.encryption = null;
    var decrypt_buf: [MAX_FRAME_BYTES]u8 = undefined;

    const cases = [_][]const u8{
        &[_]u8{ 1, 0, 0, 0, 0x00 },
        &[_]u8{ 1, 0, 0, 0, 0x01 },
        &[_]u8{ 0x00, 0x00, 0x01, 0x00, 0x00 },
    };
    for (cases) |frame| {
        var consumed: usize = 0;
        try std.testing.expect(cm.decodeFrame(null, frame, &consumed, &decrypt_buf, true) == null);
        try std.testing.expectEqual(frame.len, consumed);
    }
}

test "frame decoder accepts exact receive-buffer boundary" {
    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.encryption = null;
    const frame = try std.testing.allocator.alloc(u8, MAX_FRAME_BYTES);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0x5a);
    std.mem.writeInt(u32, frame[0..4], MAX_FRAME_BYTES - 4, .little);
    frame[4] = 0x00;
    std.mem.writeInt(u16, frame[5..7], PROTOCOL_VERSION, .little);
    frame[7] = 0x42;

    var decrypt_buf: [MAX_FRAME_BYTES]u8 = undefined;
    var consumed: usize = 0;
    const decoded = cm.decodeFrame(null, frame, &consumed, &decrypt_buf, true) orelse
        return error.ExpectedBoundaryFrame;
    try std.testing.expectEqual(MAX_FRAME_BYTES, consumed);
    try std.testing.expectEqual(MAX_FRAME_BYTES - 8, decoded[3..].len);
}

test "frame decoder leaves trailing frame bytes unconsumed" {
    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.encryption = null;
    const first = try buildTestProtocolFrame(0x00, PROTOCOL_VERSION, null);
    defer std.testing.allocator.free(first);
    const second = try buildTestProtocolFrame(0x00, PROTOCOL_VERSION, null);
    defer std.testing.allocator.free(second);
    const stream = try std.testing.allocator.alloc(u8, first.len + second.len);
    defer std.testing.allocator.free(stream);
    @memcpy(stream[0..first.len], first);
    @memcpy(stream[first.len..], second);

    var decrypt_buf: [MAX_FRAME_BYTES]u8 = undefined;
    var consumed: usize = 0;
    try std.testing.expect(cm.decodeFrame(null, stream, &consumed, &decrypt_buf, true) != null);
    try std.testing.expectEqual(first.len, consumed);
}

fn initTestConnectionManager(cm: *ConnectionManager, replica: *replica_mod.Replica) void {
    cm.worker_listen_fd = -1;
    cm.client_listen_fd = -1;
    cm.workers = [_]Conn{.{}} ** MAX_WORKERS;
    cm.worker_count = 0;
    cm.clients = [_]Conn{.{}} ** MAX_CLIENTS;
    cm.client_count = 0;
    cm.replica = replica;
    cm.request_queue = rq.RequestQueue.init();
    cm.peer_listen_fd = -1;
    cm.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    cm.peer_count = 0;
    cm.replica_id = replica.replica_id;
    cm.peer_targets = [_]PeerTarget{.{}} ** msg.REPLICA_COUNT_MAX;
    cm.peer_target_count = 0;
    cm.last_retry_tick = 0;
    cm.poll_count = 0;
    cm.state_response_buf = undefined;
    cm.encryption = null;
    cm.fcntl_ops = FcntlOps.system;
}

fn fcntlGetFails(_: c_int) c_int {
    return -1;
}

fn fcntlGetSucceeds(_: c_int) c_int {
    return 0;
}

fn fcntlSetFails(_: c_int, _: c_int) c_int {
    return -1;
}

fn fcntlSetSucceeds(_: c_int, _: c_int) c_int {
    return 0;
}

test "setNonBlocking reports both fcntl failure boundaries" {
    const get_failure = FcntlOps{ .get_flags = fcntlGetFails, .set_flags = fcntlSetSucceeds };
    try std.testing.expectError(error.GetFlagsFailed, ConnectionManager.setNonBlockingWith(1, get_failure));
    const set_failure = FcntlOps{ .get_flags = fcntlGetSucceeds, .set_flags = fcntlSetFails };
    try std.testing.expectError(error.SetFlagsFailed, ConnectionManager.setNonBlockingWith(1, set_failure));
}

test "peer connect never registers a socket when nonblocking setup fails" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7000);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7000, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);
    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7000);
    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{ .replica_id = 0, .replica_count = 1, .io = sim_io.io(), .state_machine = sm });
    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.fcntl_ops = .{ .get_flags = fcntlGetFails, .set_flags = fcntlSetSucceeds };

    cm.connectToPeerInner(1, 0, 1);
    try std.testing.expectEqual(@as(usize, 0), cm.peer_count);
}

test "worker side-effect and client error write failures clean all owned state and permit slot reuse" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7001);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7001, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7001);
    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{ .replica_id = 0, .replica_count = 1, .io = sim_io.io(), .state_machine = sm });
    replica.worker_count = 1;
    replica.workers[0].connected = true;

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.worker_count = 1;
    cm.client_count = 1;
    var failed_worker_pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), libc.pipe(&failed_worker_pipe));
    defer _ = libc.close(failed_worker_pipe[1]);
    var failed_client_pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), libc.pipe(&failed_client_pipe));
    defer _ = libc.close(failed_client_pipe[1]);
    cm.workers[0] = .{ .fd = failed_worker_pipe[0], .connected = true, .worker_idx = 0 };
    cm.clients[0] = .{ .fd = failed_client_pipe[0], .connected = true, .client_id = 71 };
    try std.testing.expect(cm.request_queue.enqueue(1, 10, 71, "queued"));
    _ = cm.request_queue.trackInFlightForWorker(11, 71, 0).?;

    const start_pod_frame = [_]u8{ 3, 0, 0, 0, 1, 0, @intFromEnum(msg.WorkerTag.start_pod) };
    cm.sendReplicaWorkerFrame(0, &start_pod_frame);

    try std.testing.expectEqual(@as(c_int, -1), cm.workers[0].fd);
    try std.testing.expect(!cm.workers[0].connected);
    try std.testing.expect(!replica.workers[0].connected);
    try std.testing.expectEqual(@as(c_int, -1), libc.close(failed_worker_pipe[0]));
    try std.testing.expectEqual(@as(c_int, -1), cm.clients[0].fd);
    try std.testing.expect(!cm.clients[0].connected);
    try std.testing.expectEqual(@as(c_int, -1), libc.close(failed_client_pipe[0]));
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.totalDepth());
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());

    var replacement_worker: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &replacement_worker));
    defer _ = libc.close(replacement_worker[0]);
    defer _ = libc.close(replacement_worker[1]);
    cm.workers[0] = .{ .fd = replacement_worker[0], .connected = true, .worker_idx = 0 };
    replica.workers[0].connected = true;
    cm.sendReplicaWorkerFrame(0, &start_pod_frame);
    var worker_buf: [32]u8 = undefined;
    const worker_bytes = try std.posix.read(replacement_worker[1], &worker_buf);
    try std.testing.expect(worker_bytes >= 8);
    try std.testing.expect(cm.workers[0].connected);
    try std.testing.expect(replica.workers[0].connected);
}

test "consensus reply write failure cleans client-owned run state and permits slot reuse" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(7002);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(7002, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(7002);
    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{ .replica_id = 0, .replica_count = 1, .io = sim_io.io(), .state_machine = sm });
    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.client_count = 1;
    var failed_client_pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), libc.pipe(&failed_client_pipe));
    defer _ = libc.close(failed_client_pipe[1]);
    cm.clients[0] = .{ .fd = failed_client_pipe[0], .connected = true, .client_id = 72 };
    try std.testing.expect(cm.request_queue.enqueue(1, 20, 72, "queued"));
    _ = cm.request_queue.trackInFlightForWorker(21, 72, 0).?;

    cm.sendClientReply(&cm.clients[0], 22, .{ .ok = .{ .entity_id = 9 } });

    try std.testing.expectEqual(@as(c_int, -1), cm.clients[0].fd);
    try std.testing.expect(!cm.clients[0].connected);
    try std.testing.expectEqual(@as(c_int, -1), libc.close(failed_client_pipe[0]));
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.totalDepth());
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());

    var replacement_client: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &replacement_client));
    defer _ = libc.close(replacement_client[0]);
    defer _ = libc.close(replacement_client[1]);
    cm.clients[0] = .{ .fd = replacement_client[0], .connected = true, .client_id = 73 };
    cm.sendClientReply(&cm.clients[0], 23, .{ .ok = .{ .entity_id = 10 } });
    var client_buf: [32]u8 = undefined;
    const client_bytes = try std.posix.read(replacement_client[1], &client_buf);
    try std.testing.expect(client_bytes >= 17);
    try std.testing.expect(cm.clients[0].connected);
}

test "readWorkers disconnects agents from non-leader replicas" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(5678);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(5678, 3, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 1);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(5678);

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 1,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .normal;
    replica.view_number = 0;

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.worker_count = 1;

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[1]);

    cm.workers[0] = .{ .fd = fds[0], .connected = true, .worker_idx = 0 };
    cm.readWorkers();

    try std.testing.expectEqual(@as(c_int, -1), cm.workers[0].fd);
    try std.testing.expect(!cm.workers[0].connected);
}

test "handleRunResponse resolves in-flight request and replies to client" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(1234);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(1234, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

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

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.client_count = 1;
    cm.worker_count = 1;
    cm.workers[0] = .{ .fd = -1, .connected = true, .worker_idx = 0 };

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);

    cm.clients[0] = .{ .fd = fds[0], .connected = true, .client_id = 1234 };
    const worker_request_id = cm.request_queue.trackInFlight(77, 1234).?;

    var payload: [32]u8 = undefined;
    @memcpy(payload[0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, worker_request_id)));
    payload[8] = 0;
    @memcpy(payload[9..13], "pong");
    cm.handleRunResponse(&cm.workers[0], payload[0..13]);

    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());

    var buf: [64]u8 = undefined;
    const n = try std.posix.read(fds[1], &buf);
    try std.testing.expect(n >= 5 + 2 + 1 + 13);
    try std.testing.expectEqual(@as(u8, 0x00), buf[4]);
    try std.testing.expectEqual(PROTOCOL_VERSION, std.mem.littleToNative(u16, std.mem.bytesToValue(u16, buf[5..7])));
    try std.testing.expectEqual(@as(u8, 0x23), buf[7]);
    try std.testing.expectEqual(@as(u64, 77), std.mem.littleToNative(u64, std.mem.bytesToValue(u64, buf[8..16])));
    try std.testing.expectEqual(@as(u8, 0), buf[16]);
    try std.testing.expectEqual(@as(u32, 4), std.mem.littleToNative(u32, std.mem.bytesToValue(u32, buf[17..21])));
    try std.testing.expect(std.mem.eql(u8, buf[21..25], "pong"));
}

test "malformed and foreign run responses disconnect only sender and release owned saturated slots" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(2468);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(2468, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(2468);
    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{ .replica_id = 0, .replica_count = 1, .io = sim_io.io(), .state_machine = sm });
    replica.worker_count = 2;
    replica.workers[0].connected = true;
    replica.workers[1].connected = true;

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.worker_count = 2;
    cm.workers[0] = .{ .fd = -1, .connected = true, .worker_idx = 0 };
    cm.workers[1] = .{ .fd = -1, .connected = true, .worker_idx = 1 };

    var worker_ids: [2][rq.MAX_IN_FLIGHT / 2]u64 = undefined;
    for (0..rq.MAX_IN_FLIGHT) |i| {
        const owner = i % 2;
        worker_ids[owner][i / 2] = cm.request_queue.trackInFlightForWorker(@intCast(i + 1), @intCast(i + 100), owner).?;
    }
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT, cm.request_queue.activeInFlightCount());

    // An oversized response carrying worker 0's known ID fails the connection
    // and releases every worker-0 correlation, while worker 1 remains intact.
    var oversized: [10 + MAX_RUN_RESPONSE_BODY]u8 = undefined;
    std.mem.writeInt(u64, oversized[0..8], worker_ids[0][0], .little);
    oversized[8] = 0;
    @memset(oversized[9..], 0xaa);
    cm.handleRunResponse(&cm.workers[0], &oversized);
    try std.testing.expect(!cm.workers[0].connected);
    try std.testing.expect(cm.workers[1].connected);
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT / 2, cm.request_queue.activeInFlightCount());

    // Reusing every released slot restores saturation without disturbing worker 1.
    cm.workers[0] = .{ .fd = -1, .connected = true, .worker_idx = 0 };
    replica.workers[0].connected = true;
    for (0..rq.MAX_IN_FLIGHT / 2) |i| {
        worker_ids[0][i] = cm.request_queue.trackInFlightForWorker(@intCast(10_000 + i), @intCast(20_000 + i), 0).?;
    }
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT, cm.request_queue.activeInFlightCount());

    // Worker 1 cannot resolve worker 0's correlation. Only worker 1 is failed,
    // and all worker-0 entries remain available for their real owner.
    var foreign = std.mem.zeroes([9]u8);
    std.mem.writeInt(u64, foreign[0..8], worker_ids[0][0], .little);
    cm.handleRunResponse(&cm.workers[1], &foreign);
    try std.testing.expect(!cm.workers[1].connected);
    try std.testing.expect(cm.workers[0].connected);
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT / 2, cm.request_queue.activeInFlightCount());

    // Exact maximum-size and ordinary responses from the owner remain valid.
    var exact: [9 + MAX_RUN_RESPONSE_BODY]u8 = undefined;
    std.mem.writeInt(u64, exact[0..8], worker_ids[0][0], .little);
    exact[8] = 0;
    @memset(exact[9..], 0x5a);
    cm.handleRunResponse(&cm.workers[0], &exact);
    try std.testing.expect(cm.workers[0].connected);
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT / 2 - 1, cm.request_queue.activeInFlightCount());

    var valid = std.mem.zeroes([11]u8);
    std.mem.writeInt(u64, valid[0..8], worker_ids[0][1], .little);
    @memcpy(valid[9..11], "ok");
    cm.handleRunResponse(&cm.workers[0], &valid);
    try std.testing.expect(cm.workers[0].connected);
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT / 2 - 2, cm.request_queue.activeInFlightCount());

    // An unknown correlation fails only its sender and cannot release worker 0.
    cm.workers[1] = .{ .fd = -1, .connected = true, .worker_idx = 1 };
    replica.workers[1].connected = true;
    _ = cm.request_queue.trackInFlightForWorker(30_000, 40_000, 1).?;
    var unknown = std.mem.zeroes([9]u8);
    std.mem.writeInt(u64, unknown[0..8], std.math.maxInt(u64), .little);
    cm.handleRunResponse(&cm.workers[1], &unknown);
    try std.testing.expect(!cm.workers[1].connected);
    try std.testing.expect(cm.workers[0].connected);
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT / 2 - 2, cm.request_queue.activeInFlightCount());

    // A structurally short response also releases only its sender's entries.
    cm.workers[1] = .{ .fd = -1, .connected = true, .worker_idx = 1 };
    replica.workers[1].connected = true;
    _ = cm.request_queue.trackInFlightForWorker(50_000, 60_000, 1).?;
    cm.handleRunResponse(&cm.workers[1], &[_]u8{0} ** 8);
    try std.testing.expect(!cm.workers[1].connected);
    try std.testing.expect(cm.workers[0].connected);
    try std.testing.expectEqual(rq.MAX_IN_FLIGHT / 2 - 2, cm.request_queue.activeInFlightCount());
}

test "dispatchRun preserves queued work without worker and fails accepted work on send or disconnect" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(9876);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(9876, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(9876);
    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .image = msg.strToFixed(256, "img:v1"),
        .replicas = 1,
        .cpu_millicores = 100,
        .memory_megabytes = 128,
    } });
    const dep_id = sm.deployments[0].id;
    sm.pods[0].node_id = 99;
    sm.pods[0].phase = .running;

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{ .replica_id = 0, .replica_count = 1, .io = sim_io.io(), .state_machine = sm });
    replica.worker_count = 1;
    replica.workers[0].node_id = 99;
    replica.workers[0].connected = true;

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.worker_count = 1;
    cm.client_count = 1;

    var client_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &client_fds));
    defer _ = libc.close(client_fds[1]);
    cm.clients[0] = .{ .fd = client_fds[0], .connected = true, .client_id = 55 };

    // No connected worker: request remains queued and no correlation is allocated.
    try std.testing.expect(cm.request_queue.enqueue(dep_id, 1, 55, "one"));
    cm.dispatchRun();
    try std.testing.expectEqual(@as(usize, 1), cm.request_queue.totalDepth());
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());

    // A write attempt may have been accepted before failure, so replay is unsafe.
    cm.workers[0] = .{ .fd = -1, .connected = true, .worker_idx = 0 };
    cm.dispatchRun();
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.totalDepth());
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());
    var client_buf: [128]u8 = undefined;
    var n = try std.posix.read(client_fds[1], &client_buf);
    try std.testing.expect(n >= 17);
    try std.testing.expectEqual(@intFromEnum(RunStatus.outcome_ambiguous), client_buf[16]);

    // Accepted dispatch followed by disconnect releases its owned correlation.
    var worker_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &worker_fds));
    defer _ = libc.close(worker_fds[1]);
    replica.workers[0].connected = true;
    cm.workers[0] = .{ .fd = worker_fds[0], .connected = true, .worker_idx = 0 };
    try std.testing.expect(cm.request_queue.enqueue(dep_id, 2, 55, "two"));
    cm.dispatchRun();
    try std.testing.expectEqual(@as(usize, 1), cm.request_queue.activeInFlightCount());
    cm.disconnectWorker(&cm.workers[0]);
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());
    n = try std.posix.read(client_fds[1], &client_buf);
    try std.testing.expect(n >= 17);
    try std.testing.expectEqual(@intFromEnum(RunStatus.outcome_ambiguous), client_buf[16]);

    // A replacement connection reuses the released slot and completes normally.
    var success_worker_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &success_worker_fds));
    defer _ = libc.close(success_worker_fds[0]);
    defer _ = libc.close(success_worker_fds[1]);
    replica.workers[0].connected = true;
    cm.workers[0] = .{ .fd = success_worker_fds[0], .connected = true, .worker_idx = 0 };
    try std.testing.expect(cm.request_queue.enqueue(dep_id, 3, 55, "three"));
    cm.dispatchRun();
    var worker_buf: [128]u8 = undefined;
    const worker_n = try std.posix.read(success_worker_fds[1], &worker_buf);
    try std.testing.expect(worker_n >= 28);
    const worker_request_id = std.mem.readInt(u64, worker_buf[8..16], .little);
    var response: [11]u8 = undefined;
    std.mem.writeInt(u64, response[0..8], worker_request_id, .little);
    response[8] = 0;
    @memcpy(response[9..11], "ok");
    cm.handleRunResponse(&cm.workers[0], &response);
    try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());
    n = try std.posix.read(client_fds[1], &client_buf);
    try std.testing.expect(n >= 23);
    try std.testing.expectEqual(@as(u8, 0), client_buf[16]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, client_buf[17..21], .little));
    try std.testing.expect(std.mem.eql(u8, client_buf[21..23], "ok"));
}

test "disconnectClient clears abandoned queued and in-flight run requests" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(4321);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(4321, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(4321);

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.client_count = 1;

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[1]);

    cm.clients[0] = .{ .fd = fds[0], .connected = true, .client_id = 999 };
    try std.testing.expect(cm.request_queue.enqueue(7, 10, 999, "queued"));
    const disconnected_worker_id = cm.request_queue.trackInFlight(11, 999).?;
    try std.testing.expect(cm.request_queue.enqueue(7, 12, 555, "keep"));
    const kept_worker_id = cm.request_queue.trackInFlight(13, 555).?;

    cm.disconnectClient(&cm.clients[0]);

    try std.testing.expectEqual(@as(c_int, -1), cm.clients[0].fd);
    try std.testing.expect(!cm.clients[0].connected);
    try std.testing.expectEqual(@as(usize, 1), cm.request_queue.totalDepth());
    try std.testing.expectEqual(@as(usize, 1), cm.request_queue.activeInFlightCount());
    try std.testing.expect(cm.request_queue.resolveResponseForWorker(disconnected_worker_id, 0) == null);
    try std.testing.expectEqual(@as(u128, 555), cm.request_queue.resolveResponseForWorker(kept_worker_id, 0).?.client_id);
}

test "identifyPeerConnection rejects rebind to different replica id" {
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[1]);

    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    cm.peer_count = 1;
    cm.peers[0] = .{
        .fd = fds[0],
        .connected = true,
        .worker_idx = 1,
        .peer_id_known = true,
    };

    try std.testing.expect(!cm.identifyPeerConnection(0, 2));
    try std.testing.expectEqual(@as(usize, 1), cm.peers[0].worker_idx);
    try std.testing.expect(cm.peers[0].peer_id_known);
    try std.testing.expect(cm.peers[0].connected);
    try std.testing.expectEqual(fds[0], cm.peers[0].fd);

    try std.testing.expect(cm.identifyPeerConnection(0, 1));
    try std.testing.expectEqual(@as(usize, 1), cm.peers[0].worker_idx);
}

test "identifyPeerConnection enforces direction without evicting established sockets" {
    var lower_outbound_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &lower_outbound_fds));
    defer _ = libc.close(lower_outbound_fds[1]);

    var lower_inbound_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &lower_inbound_fds));
    defer _ = libc.close(lower_inbound_fds[1]);

    const lower = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(lower);
    lower.replica_id = 1;
    lower.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    lower.peer_count = 2;
    lower.peers[0] = .{
        .fd = lower_outbound_fds[0],
        .connected = true,
        .worker_idx = 2,
        .peer_id_known = true,
        .peer_direction = .outbound,
    };
    lower.peers[1] = .{
        .fd = lower_inbound_fds[0],
        .connected = true,
        .peer_direction = .inbound,
    };

    try std.testing.expect(!lower.identifyPeerConnection(1, 2));
    try std.testing.expect(lower.peers[0].connected);
    try std.testing.expectEqual(lower_outbound_fds[0], lower.peers[0].fd);
    try std.testing.expect(!lower.peers[1].connected);
    try std.testing.expectEqual(@as(c_int, -1), lower.peers[1].fd);

    var higher_outbound_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &higher_outbound_fds));
    defer _ = libc.close(higher_outbound_fds[1]);

    var higher_inbound_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &higher_inbound_fds));
    defer _ = libc.close(higher_inbound_fds[1]);

    const higher = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(higher);
    higher.replica_id = 2;
    higher.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    higher.peer_count = 2;
    higher.peers[0] = .{
        .fd = higher_inbound_fds[0],
        .connected = true,
        .worker_idx = 1,
        .peer_id_known = true,
        .peer_direction = .inbound,
    };
    higher.peers[1] = .{
        .fd = higher_outbound_fds[0],
        .connected = true,
        .peer_direction = .outbound,
    };

    try std.testing.expect(!higher.identifyPeerConnection(1, 1));
    try std.testing.expect(higher.peers[0].connected);
    try std.testing.expectEqual(higher_inbound_fds[0], higher.peers[0].fd);
    try std.testing.expect(!higher.peers[1].connected);
    try std.testing.expectEqual(@as(c_int, -1), higher.peers[1].fd);
}

test "identifyPeerConnection preserves established duplicate peer socket" {
    var duplicate_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &duplicate_fds));
    defer _ = libc.close(duplicate_fds[1]);

    var live_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &live_fds));
    defer _ = libc.close(live_fds[1]);

    const cm = try std.testing.allocator.create(ConnectionManager);
    defer std.testing.allocator.destroy(cm);
    cm.replica_id = 5;
    cm.peers = [_]Conn{.{}} ** MAX_PEER_CONNECTIONS;
    cm.peer_count = 2;
    cm.peers[0] = .{
        .fd = duplicate_fds[0],
        .connected = true,
        .worker_idx = 4,
        .peer_id_known = true,
    };
    cm.peers[1] = .{
        .fd = live_fds[0],
        .connected = true,
    };

    try std.testing.expect(!cm.identifyPeerConnection(1, 4));
    try std.testing.expectEqual(duplicate_fds[0], cm.peers[0].fd);
    try std.testing.expect(cm.peers[0].connected);
    try std.testing.expect(!cm.peers[1].peer_id_known);
}

fn sendTestPeerMessage(cm: *ConnectionManager, to: u8, message: msg.Message) void {
    var frame: [MAX_FRAME_BYTES]u8 = undefined;
    const message_len = msg.serialize(message, frame[5..]);
    std.mem.writeInt(u32, frame[0..4], @intCast(1 + message_len), .little);
    frame[4] = cm.replica_id;
    cm.sendToPeer(to, frame[0 .. 5 + message_len]);
}

fn disconnectTestPeers(cm: *ConnectionManager) void {
    for (cm.peers[0..cm.peer_count]) |*peer| {
        if (peer.fd >= 0) disconnectPeer(peer);
    }
}

test "simultaneous reciprocal sockets converge and carry bidirectional VRR traffic" {
    const allocator = std.testing.allocator;
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(9191, 2, &current_tick);

    var lower_prng = @import("prng.zig").Prng.init(9192);
    var lower_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&lower_prng, &current_tick, network, 0);
    const lower_sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(lower_sm);
    lower_sm.initInPlace(9192);
    const lower_replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(lower_replica);
    lower_replica.initInPlace(.{ .replica_id = 0, .replica_count = 2, .io = lower_io.io(), .state_machine = lower_sm });
    lower_replica.status = .normal;

    var higher_prng = @import("prng.zig").Prng.init(9193);
    var higher_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&higher_prng, &current_tick, network, 1);
    const higher_sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(higher_sm);
    higher_sm.initInPlace(9193);
    const higher_replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(higher_replica);
    higher_replica.initInPlace(.{ .replica_id = 1, .replica_count = 2, .io = higher_io.io(), .state_machine = higher_sm });
    higher_replica.status = .normal;

    const lower = try allocator.create(ConnectionManager);
    defer allocator.destroy(lower);
    initTestConnectionManager(lower, lower_replica);
    defer disconnectTestPeers(lower);
    const higher = try allocator.create(ConnectionManager);
    defer allocator.destroy(higher);
    initTestConnectionManager(higher, higher_replica);
    defer disconnectTestPeers(higher);

    // Socket A is lower outbound / higher inbound. Socket B is the reciprocal.
    var socket_a: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &socket_a));
    var socket_b: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &socket_b));
    try ConnectionManager.setNonBlocking(socket_a[0]);
    try ConnectionManager.setNonBlocking(socket_a[1]);
    try ConnectionManager.setNonBlocking(socket_b[0]);
    try ConnectionManager.setNonBlocking(socket_b[1]);

    lower.peer_count = 2;
    lower.peers[0] = .{ .fd = socket_a[0], .connected = true, .peer_direction = .outbound, .configured_peer_id = 1, .configured_peer_id_known = true, .peer_deadline_tick = PEER_IDENTITY_TIMEOUT_TICKS };
    lower.peers[1] = .{ .fd = socket_b[1], .connected = true, .peer_direction = .inbound, .peer_deadline_tick = PEER_IDENTITY_TIMEOUT_TICKS };
    higher.peer_count = 2;
    higher.peers[0] = .{ .fd = socket_b[0], .connected = true, .peer_direction = .outbound, .configured_peer_id = 0, .configured_peer_id_known = true, .peer_deadline_tick = PEER_IDENTITY_TIMEOUT_TICKS };
    higher.peers[1] = .{ .fd = socket_a[1], .connected = true, .peer_direction = .inbound, .peer_deadline_tick = PEER_IDENTITY_TIMEOUT_TICKS };

    // Both replicas send before either polls, reproducing symmetric startup.
    sendTestPeerMessage(lower, 1, .{ .start_view_change = .{ .view_number = 1, .replica_id = 0 } });
    sendTestPeerMessage(higher, 0, .{ .start_view_change = .{ .view_number = 1, .replica_id = 1 } });
    lower.readPeers();
    higher.readPeers();

    try std.testing.expect(lower.peers[0].connected);
    try std.testing.expect(!lower.peers[1].connected);
    try std.testing.expect(!higher.peers[0].connected);
    try std.testing.expect(higher.peers[1].connected);
    try std.testing.expect(higher_replica.start_vc_total > 0);

    sendTestPeerMessage(lower, 1, .{ .start_view_change = .{ .view_number = 2, .replica_id = 0 } });
    sendTestPeerMessage(higher, 0, .{ .start_view_change = .{ .view_number = 2, .replica_id = 1 } });
    lower.readPeers();
    higher.readPeers();

    try std.testing.expectEqual(@as(usize, 0), lower.peers[0].frame_pos);
    try std.testing.expectEqual(@as(usize, 0), higher.peers[1].frame_pos);
    try std.testing.expect(lower.hasPeerConnection(1));
    try std.testing.expect(higher.hasPeerConnection(0));
}

test "peer frame buffer fits largest VRR view-change frame" {
    const largest_plain_payload = 1 + @sizeOf(msg.DoViewChangeMsg); // from_id + serialized VRR message
    const largest_plain_frame = 5 + largest_plain_payload; // len + flags + payload
    const largest_encrypted_frame = 5 + enc.NONCE_LEN + largest_plain_payload + enc.TAG_LEN;

    try std.testing.expect(largest_plain_frame <= MAX_FRAME_BYTES);
    try std.testing.expect(largest_encrypted_frame <= MAX_FRAME_BYTES);
}

test "shiftBuffer saturates when consumed exceeds current position" {
    var buf = std.mem.zeroes([MAX_FRAME_BYTES]u8);
    var pos: usize = 3;
    buf[0] = 'a';
    buf[1] = 'b';
    buf[2] = 'c';

    ConnectionManager.shiftBuffer(&buf, &pos, 8);

    try std.testing.expectEqual(@as(usize, 0), pos);
}

test "processPeerFrames drops malformed VRR plaintext without trapping" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(4242);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(4242, 3, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(4242);

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .normal;
    replica.view_number = 0;

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.peer_count = 1;
    cm.peers[0] = .{ .connected = true, .frame_pos = 0 };

    // Frame: [4B len][flags=0][from_id=1][tag=0xFF] — invalid VRR tag.
    const inner_len: u32 = 1 + 1; // from_id + bad tag
    std.mem.writeInt(u32, cm.peers[0].frame_buf[0..4], 1 + inner_len, .little);
    cm.peers[0].frame_buf[4] = 0x00;
    cm.peers[0].frame_buf[5] = 1;
    cm.peers[0].frame_buf[6] = 0xFF;
    cm.peers[0].frame_pos = 5 + inner_len;

    cm.processPeerFrames(0);
    try std.testing.expectEqual(@as(usize, 0), cm.peers[0].frame_pos);
    try std.testing.expect(cm.peers[0].connected);
}

test "processPeerFrames drops spoofed from_id on bound peer socket" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(4244);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(4244, 3, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(4244);

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .normal;
    replica.view_number = 0;

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.peer_count = 1;
    cm.peers[0] = .{
        .connected = true,
        .worker_idx = 1,
        .peer_id_known = true,
    };

    var vrr_buf: [64]u8 = undefined;
    const vrr_len = msg.serialize(.{ .start_view_change = .{
        .view_number = 1,
        .replica_id = 2,
    } }, &vrr_buf);
    const inner_len: u32 = @intCast(1 + vrr_len);
    std.mem.writeInt(u32, cm.peers[0].frame_buf[0..4], 1 + inner_len, .little);
    cm.peers[0].frame_buf[4] = 0x00;
    cm.peers[0].frame_buf[5] = 2; // spoof: claim replica 2 on socket bound to 1
    @memcpy(cm.peers[0].frame_buf[6 .. 6 + vrr_len], vrr_buf[0..vrr_len]);
    cm.peers[0].frame_pos = 5 + inner_len;

    cm.processPeerFrames(0);
    try std.testing.expectEqual(@as(usize, 1), cm.peers[0].worker_idx);
    try std.testing.expect(cm.peers[0].peer_id_known);
    try std.testing.expectEqual(@as(u8, 0), replica.start_vc_total);
}

test "processPeerFrames drops out-of-range from_id" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(4243);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(4243, 3, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(4243);

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.peer_count = 1;
    cm.peers[0] = .{ .connected = true };

    var vrr_buf: [64]u8 = undefined;
    const vrr_len = msg.serialize(.{ .start_view_change = .{
        .view_number = 1,
        .replica_id = 99,
    } }, &vrr_buf);
    const inner_len: u32 = @intCast(1 + vrr_len);
    std.mem.writeInt(u32, cm.peers[0].frame_buf[0..4], 1 + inner_len, .little);
    cm.peers[0].frame_buf[4] = 0x00;
    cm.peers[0].frame_buf[5] = 99; // from_id >= replica_count
    @memcpy(cm.peers[0].frame_buf[6 .. 6 + vrr_len], vrr_buf[0..vrr_len]);
    cm.peers[0].frame_pos = 5 + inner_len;

    cm.processPeerFrames(0);
    try std.testing.expect(!cm.peers[0].peer_id_known);
    try std.testing.expectEqual(@as(u8, 0), replica.start_vc_total);
}

test "invalid Prepare Commit and StartView cannot evict healthy peer socket" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(4245);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(4245, 3, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(4245);

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 3,
        .io = sim_io.io(),
        .state_machine = sm,
    });
    replica.status = .normal;
    replica.view_number = 0;

    var healthy_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &healthy_fds));
    defer _ = libc.close(healthy_fds[1]);

    var spoof_fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &spoof_fds));
    defer _ = libc.close(spoof_fds[1]);

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.peer_count = 2;
    cm.peers[0] = .{
        .fd = healthy_fds[0],
        .connected = true,
        .worker_idx = 1,
        .peer_id_known = true,
    };
    cm.peers[1] = .{
        .fd = spoof_fds[0],
        .connected = true,
        .frame_pos = 0,
    };

    const invalid_messages = [_]msg.Message{
        .{ .prepare = .{} }, // op_number zero
        .{ .commit = .{ .commit_min = 1, .op_number = 0 } },
        .{ .start_view = .{ .op_number = replica_mod.LOG_SIZE_MAX + 1 } },
    };
    for (invalid_messages) |invalid_message| {
        var vrr_buf: [MAX_FRAME_BYTES - 6]u8 = undefined;
        const vrr_len = msg.serialize(invalid_message, &vrr_buf);
        const inner_len: u32 = @intCast(1 + vrr_len);
        std.mem.writeInt(u32, cm.peers[1].frame_buf[0..4], 1 + inner_len, .little);
        cm.peers[1].frame_buf[4] = 0x00;
        cm.peers[1].frame_buf[5] = 1;
        @memcpy(cm.peers[1].frame_buf[6 .. 6 + vrr_len], vrr_buf[0..vrr_len]);
        cm.peers[1].frame_pos = 5 + inner_len;

        cm.processPeerFrames(1);
        try std.testing.expect(cm.peers[0].connected);
        try std.testing.expect(cm.peers[0].peer_id_known);
        try std.testing.expectEqual(@as(usize, 1), cm.peers[0].worker_idx);
        try std.testing.expectEqual(healthy_fds[0], cm.peers[0].fd);
        try std.testing.expect(cm.peers[1].connected);
        try std.testing.expect(!cm.peers[1].peer_id_known);
        try std.testing.expectEqual(@as(usize, 0), cm.peers[1].frame_pos);
    }
}

fn buildClientRunRequestPayload(request_id: u64, dep_name: []const u8, declared_len: u32, body: []const u8) []u8 {
    const total = 76 + body.len;
    const buf = std.testing.allocator.alloc(u8, total) catch unreachable;
    @memset(buf, 0);
    @memcpy(buf[0..8], &std.mem.toBytes(std.mem.nativeToLittle(u64, request_id)));
    const name_copy_len = @min(dep_name.len, 64);
    @memcpy(buf[8..][0..name_copy_len], dep_name[0..name_copy_len]);
    @memcpy(buf[72..76], &std.mem.toBytes(std.mem.nativeToLittle(u32, declared_len)));
    if (body.len > 0) @memcpy(buf[76..][0..body.len], body);
    return buf;
}

test "handleRunRequest enforces exact declared payload length" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(4242);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(4242, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);

    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(4242);
    _ = sm.apply(.{ .create_deployment = .{
        .name = msg.strToFixed(64, "echo"),
        .image = msg.strToFixed(256, "img:v1"),
        .replicas = 1,
        .cpu_millicores = 100,
        .memory_megabytes = 128,
    } });

    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{
        .replica_id = 0,
        .replica_count = 1,
        .io = sim_io.io(),
        .state_machine = sm,
    });

    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.client_count = 1;

    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));
    defer _ = libc.close(fds[0]);
    defer _ = libc.close(fds[1]);
    try ConnectionManager.setNonBlocking(fds[1]);
    cm.clients[0] = .{ .fd = fds[0], .connected = true, .client_id = 55 };

    const Case = struct {
        name: []const u8,
        declared: u32,
        body_len: usize,
        expect_queued: bool,
        expect_status: ?u8,
    };

    const cases = [_]Case{
        .{ .name = "exact zero", .declared = 0, .body_len = 0, .expect_queued = true, .expect_status = null },
        .{ .name = "exact max", .declared = rq.MAX_PAYLOAD, .body_len = rq.MAX_PAYLOAD, .expect_queued = true, .expect_status = null },
        .{ .name = "declared short", .declared = 8, .body_len = 4, .expect_queued = false, .expect_status = 3 },
        .{ .name = "declared long / trailing", .declared = 2, .body_len = 4, .expect_queued = false, .expect_status = 3 },
        .{ .name = "513 byte payload", .declared = rq.MAX_PAYLOAD + 1, .body_len = rq.MAX_PAYLOAD + 1, .expect_queued = false, .expect_status = 3 },
        .{ .name = "integer overflow size", .declared = std.math.maxInt(u32), .body_len = 4, .expect_queued = false, .expect_status = 3 },
    };

    for (cases, 0..) |tc, i| {
        _ = tc.name;
        // Drain any prior error frame.
        var drain: [256]u8 = undefined;
        _ = std.posix.read(fds[1], &drain) catch {};

        var body_buf: [rq.MAX_PAYLOAD + 1]u8 = undefined;
        @memset(body_buf[0..tc.body_len], 0x11);
        const payload = buildClientRunRequestPayload(@intCast(1000 + i), "echo", tc.declared, body_buf[0..tc.body_len]);
        defer allocator.free(payload);

        const depth_before = cm.request_queue.totalDepth();
        cm.handleRunRequest(&cm.clients[0], payload);

        if (tc.expect_queued) {
            try std.testing.expectEqual(depth_before + 1, cm.request_queue.totalDepth());
            var err_buf: [64]u8 = undefined;
            const n = std.posix.read(fds[1], &err_buf) catch |err| switch (err) {
                error.WouldBlock => @as(usize, 0),
                else => return err,
            };
            try std.testing.expectEqual(@as(usize, 0), n);
        } else {
            try std.testing.expectEqual(depth_before, cm.request_queue.totalDepth());
            var err_buf: [64]u8 = undefined;
            const n = try std.posix.read(fds[1], &err_buf);
            try std.testing.expect(n >= 17);
            try std.testing.expectEqual(@as(u8, 0x23), err_buf[7]);
            try std.testing.expectEqual(tc.expect_status.?, err_buf[16]);
        }
    }
}

test "fixed worker payload parsers reject trailing bytes and accept exact frames" {
    var register: [138]u8 = std.mem.zeroes([138]u8);
    register[72] = @intFromEnum(msg.GpuType.none);
    try std.testing.expect(ConnectionManager.parseWorkerRegister(&register) != null);
    var register_trailing: [139]u8 = std.mem.zeroes([139]u8);
    register_trailing[72] = @intFromEnum(msg.GpuType.none);
    try std.testing.expect(ConnectionManager.parseWorkerRegister(&register_trailing) == null);

    var heartbeat: [23]u8 = std.mem.zeroes([23]u8);
    try std.testing.expect(ConnectionManager.parseWorkerHeartbeat(&heartbeat) != null);
    var heartbeat_trailing: [24]u8 = std.mem.zeroes([24]u8);
    try std.testing.expect(ConnectionManager.parseWorkerHeartbeat(&heartbeat_trailing) == null);

    var pod_status: [150]u8 = std.mem.zeroes([150]u8);
    pod_status[8] = @intFromEnum(msg.PodPhase.pending);
    pod_status[9] = @intFromEnum(msg.PodPhase.running);
    try std.testing.expect(ConnectionManager.parseWorkerPodStatus(&pod_status) != null);
    var pod_status_trailing: [151]u8 = std.mem.zeroes([151]u8);
    pod_status_trailing[8] = @intFromEnum(msg.PodPhase.pending);
    pod_status_trailing[9] = @intFromEnum(msg.PodPhase.running);
    try std.testing.expect(ConnectionManager.parseWorkerPodStatus(&pod_status_trailing) == null);
}

test "trailing fixed worker frames disconnect sender and release correlations" {
    const allocator = std.testing.allocator;
    var prng = @import("prng.zig").Prng.init(97531);
    var current_tick: i64 = 0;
    const network = try allocator.create(net_mod.SimulatedNetwork);
    defer allocator.destroy(network);
    network.initInPlace(97531, 1, &current_tick);
    var sim_io = @import("vopr/simulated_io.zig").SimulatedIo.init(&prng, &current_tick, network, 0);
    const sm = try allocator.create(sm_mod.StateMachine);
    defer allocator.destroy(sm);
    sm.initInPlace(97531);
    const replica = try allocator.create(replica_mod.Replica);
    defer allocator.destroy(replica);
    replica.initInPlace(.{ .replica_id = 0, .replica_count = 1, .io = sim_io.io(), .state_machine = sm });
    replica.worker_count = 1;
    const cm = try allocator.create(ConnectionManager);
    defer allocator.destroy(cm);
    initTestConnectionManager(cm, replica);
    cm.worker_count = 1;

    var register: [139]u8 = std.mem.zeroes([139]u8);
    register[72] = @intFromEnum(msg.GpuType.none);
    var heartbeat: [24]u8 = std.mem.zeroes([24]u8);
    var pod_status: [151]u8 = std.mem.zeroes([151]u8);
    pod_status[8] = @intFromEnum(msg.PodPhase.pending);
    pod_status[9] = @intFromEnum(msg.PodPhase.running);
    const cases = [_]struct { tag: msg.WorkerTag, payload: []const u8 }{
        .{ .tag = .register, .payload = &register },
        .{ .tag = .heartbeat, .payload = &heartbeat },
        .{ .tag = .pod_status, .payload = &pod_status },
    };
    for (cases, 0..) |case, index| {
        cm.workers[0] = .{ .fd = -1, .connected = true, .worker_idx = 0 };
        replica.workers[0].connected = true;
        _ = cm.request_queue.trackInFlightForWorker(@intCast(index + 1), 77, 0).?;
        cm.dispatchWorkerMessage(&cm.workers[0], @intFromEnum(case.tag), case.payload);
        try std.testing.expect(!cm.workers[0].connected);
        try std.testing.expectEqual(@as(usize, 0), cm.request_queue.activeInFlightCount());
    }
}

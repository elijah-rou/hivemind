const std = @import("std");
const msg = @import("message.zig");
/// Shared run-request body bound (Go MaxRunPayload, Rust MAX_RUN_PAYLOAD). Reject oversize; never clamp.
pub const MAX_PAYLOAD: usize = 512;
pub const MAX_QUEUE_DEPTH: usize = 64;
pub const MAX_QUEUES: usize = 16;
pub const MAX_IN_FLIGHT: usize = 1024;
/// Must match replica.MAX_WORKERS; kept here to avoid a request-queue/replica import cycle.
pub const MAX_WORKERS: usize = 128;
/// Production loop tick is fixed at 1ms. Worker hard /run deadline is 25s;
/// retain ownership for an additional 5s before terminating that worker session.
pub const WORKER_RUN_DEADLINE_TICKS: u64 = 25_000;
pub const ABANDONED_TTL_TICKS: u64 = 30_000;

/// Cross-language /run outcome contract. Values are stable wire bytes.
pub const RunStatus = enum(u8) {
    ok = 0,
    deployment_not_found = 1,
    queue_full = 2,
    invalid_payload = 3,
    response_too_large = 4,
    outcome_ambiguous = 5,
    forwarding_failed = 6,
    no_running_pod = 7,
    unavailable = 8,
    not_leader = 9,
};

comptime {
    std.debug.assert(@intFromEnum(RunStatus.ok) == 0);
    std.debug.assert(@intFromEnum(RunStatus.not_leader) == 9);
    std.debug.assert(ABANDONED_TTL_TICKS > WORKER_RUN_DEADLINE_TICKS);
    std.debug.assert(MAX_WORKERS <= MAX_IN_FLIGHT);
    std.debug.assert(MAX_WORKERS <= std.math.maxInt(u8));
}

// ---------------------------------------------------------------------------
// Per-request state
// ---------------------------------------------------------------------------

pub const PendingRequest = struct {
    request_id: u64 = 0,
    client_id: u128 = 0,
    deployment_id: msg.DeploymentId = 0,
    payload: [MAX_PAYLOAD]u8 = undefined,
    payload_len: usize = 0,
    active: bool = false,
};

// ---------------------------------------------------------------------------
// Ring buffer per deployment
// ---------------------------------------------------------------------------

pub const DeploymentQueue = struct {
    items: [MAX_QUEUE_DEPTH]PendingRequest,
    head: usize,
    tail: usize,
    count: usize,
    deployment_id: msg.DeploymentId,
    active: bool,
    wake_pending: bool,

    fn init(deployment_id: msg.DeploymentId) DeploymentQueue {
        return .{
            .items = [_]PendingRequest{.{}} ** MAX_QUEUE_DEPTH,
            .head = 0,
            .tail = 0,
            .count = 0,
            .deployment_id = deployment_id,
            .active = true,
            .wake_pending = false,
        };
    }

    fn enqueue(self: *DeploymentQueue, req: PendingRequest) bool {
        if (self.count >= MAX_QUEUE_DEPTH) return false;
        self.items[self.tail] = req;
        self.tail = (self.tail + 1) % MAX_QUEUE_DEPTH;
        self.count += 1;
        return true;
    }

    pub fn dequeue(self: *DeploymentQueue) ?PendingRequest {
        if (self.count == 0) return null;
        const req = self.items[self.head];
        self.head = (self.head + 1) % MAX_QUEUE_DEPTH;
        self.count -= 1;
        return req;
    }
};

// ---------------------------------------------------------------------------
// In-flight tracking: gateway correlation ID → original client request
// ---------------------------------------------------------------------------

pub const ResolvedRequest = struct {
    client_id: u128,
    client_request_id: u64,
};

pub const ResponseResolution = union(enum) {
    deliver: ResolvedRequest,
    abandoned,
    foreign,
    unknown,
};

const InFlightEntry = struct {
    worker_request_id: u64 = 0,
    client_request_id: u64 = 0,
    client_id: u128 = 0,
    worker_idx: usize = 0,
    abandoned: bool = false,
    expires_at_tick: u64 = 0,
    active: bool = false,
};

// ---------------------------------------------------------------------------
// Request queue: manages all deployment queues + dispatch + response routing
// ---------------------------------------------------------------------------

pub const RequestQueue = struct {
    queues: [MAX_QUEUES]DeploymentQueue,
    queue_count: usize,

    in_flight: [MAX_IN_FLIGHT]InFlightEntry,
    next_worker_request_id: u64,
    /// Occupied correlation slots, including abandoned tombstones.
    occupied_count: usize,
    /// Occupied correlations still attached to a connected client.
    active_count: usize,
    /// Owned correlations per configured worker. Values are currently 0 or 1.
    worker_owned_count: [MAX_WORKERS]u8,
    worker_abandoned_expires_at: [MAX_WORKERS]u64,
    /// Instrumentation for proving worker-busy selection remains O(1).
    worker_busy_checks: u64,

    enqueue_total: u64,
    dispatch_total: u64,
    resolve_total: u64,

    // Round-robin dispatch index per deployment queue
    dispatch_idx: [MAX_QUEUES]usize,

    pub fn init() RequestQueue {
        return .{
            .queues = undefined,
            .queue_count = 0,
            .in_flight = [_]InFlightEntry{.{}} ** MAX_IN_FLIGHT,
            .next_worker_request_id = 1,
            .occupied_count = 0,
            .active_count = 0,
            .worker_owned_count = std.mem.zeroes([MAX_WORKERS]u8),
            .worker_abandoned_expires_at = std.mem.zeroes([MAX_WORKERS]u64),
            .worker_busy_checks = 0,
            .enqueue_total = 0,
            .dispatch_total = 0,
            .resolve_total = 0,
            .dispatch_idx = std.mem.zeroes([MAX_QUEUES]usize),
        };
    }

    /// Queue an run request for a deployment.
    pub fn enqueue(
        self: *RequestQueue,
        deployment_id: msg.DeploymentId,
        request_id: u64,
        client_id: u128,
        payload: []const u8,
    ) bool {
        const q = self.getOrCreateQueue(deployment_id) orelse return false;
        if (payload.len > MAX_PAYLOAD) return false;
        var req = PendingRequest{
            .request_id = request_id,
            .client_id = client_id,
            .deployment_id = deployment_id,
            .payload_len = payload.len,
            .active = true,
        };
        @memcpy(req.payload[0..req.payload_len], payload[0..req.payload_len]);
        const ok = q.enqueue(req);
        if (ok) self.enqueue_total += 1;
        return ok;
    }

    /// Resolve only when one active entry atomically matches both the opaque
    /// correlation and the worker connection that owns it.
    pub fn classifyResponseForWorker(self: *RequestQueue, worker_request_id: u64, worker_idx: usize) ResponseResolution {
        for (&self.in_flight) |*entry| {
            if (!entry.active) continue;
            if (entry.worker_request_id != worker_request_id) continue;
            if (entry.worker_idx != worker_idx) return .foreign;

            const abandoned = entry.abandoned;
            const resolved = ResolvedRequest{
                .client_id = entry.client_id,
                .client_request_id = entry.client_request_id,
            };
            self.removeEntry(entry);
            self.resolve_total += 1;
            return if (abandoned) .abandoned else .{ .deliver = resolved };
        }
        return .unknown;
    }

    pub fn resolveResponseForWorker(self: *RequestQueue, worker_request_id: u64, worker_idx: usize) ?ResolvedRequest {
        return switch (self.classifyResponseForWorker(worker_request_id, worker_idx)) {
            .deliver => |resolved| resolved,
            .abandoned, .foreign, .unknown => null,
        };
    }

    fn releaseInFlight(self: *RequestQueue, worker_request_id: u64) ?ResolvedRequest {
        for (&self.in_flight) |*entry| {
            if (!entry.active or entry.worker_request_id != worker_request_id) continue;
            const resolved = ResolvedRequest{
                .client_id = entry.client_id,
                .client_request_id = entry.client_request_id,
            };
            self.removeEntry(entry);
            self.resolve_total += 1;
            return resolved;
        }
        return null;
    }

    /// Atomically release every correlation owned by one worker connection.
    /// Abandoned tombstones are released silently and omitted from client errors.
    pub fn releaseWorker(self: *RequestQueue, worker_idx: usize, released: *[MAX_IN_FLIGHT]ResolvedRequest) usize {
        var released_count: usize = 0;
        for (&self.in_flight) |*entry| {
            if (!entry.active or entry.worker_idx != worker_idx) continue;
            if (!entry.abandoned) {
                std.debug.assert(released_count < released.len);
                released[released_count] = .{
                    .client_id = entry.client_id,
                    .client_request_id = entry.client_request_id,
                };
                released_count += 1;
            }
            self.removeEntry(entry);
            self.resolve_total += 1;
        }
        return released_count;
    }

    /// Drop all queued and in-flight requests owned by a disconnected client.
    /// This prevents abandoned /run requests from leaking queue state across
    /// client reconnects after the caller has already timed out locally.
    pub fn cancelClient(self: *RequestQueue, client_id: u128, now_tick: u64) void {
        for (self.queues[0..self.queue_count]) |*queue| {
            if (!queue.active or queue.count == 0) continue;

            var kept = [_]PendingRequest{.{}} ** MAX_QUEUE_DEPTH;
            var kept_count: usize = 0;
            var idx = queue.head;
            var scanned: usize = 0;
            while (scanned < queue.count) : (scanned += 1) {
                const req = queue.items[idx];
                if (!req.active or req.client_id != client_id) {
                    kept[kept_count] = req;
                    kept_count += 1;
                }
                idx = (idx + 1) % MAX_QUEUE_DEPTH;
            }

            queue.items = kept;
            queue.head = 0;
            queue.tail = kept_count % MAX_QUEUE_DEPTH;
            queue.count = kept_count;
        }

        for (&self.in_flight) |*entry| {
            if (!entry.active or entry.client_id != client_id) continue;
            if (!entry.abandoned) {
                std.debug.assert(self.active_count > 0);
                self.active_count -= 1;
                entry.abandoned = true;
            }
            entry.expires_at_tick = now_tick +| ABANDONED_TTL_TICKS;
            std.debug.assert(entry.worker_idx < MAX_WORKERS);
            self.worker_abandoned_expires_at[entry.worker_idx] = entry.expires_at_tick;
        }
    }

    /// Report unique worker sessions whose abandoned ownership expired.
    /// Callers must terminate each session before releasing its correlations.
    pub fn expiredAbandonedWorkers(self: *const RequestQueue, now_tick: u64, workers: *[MAX_IN_FLIGHT]usize) usize {
        var count: usize = 0;
        for (self.worker_abandoned_expires_at, 0..) |expires_at, worker_idx| {
            if (expires_at == 0 or now_tick < expires_at) continue;
            std.debug.assert(self.worker_owned_count[worker_idx] == 1);
            std.debug.assert(count < MAX_WORKERS);
            workers[count] = worker_idx;
            count += 1;
        }
        return count;
    }

    /// Total queued requests across all deployments.
    pub fn totalDepth(self: *const RequestQueue) usize {
        var total: usize = 0;
        for (self.queues[0..self.queue_count]) |q| {
            if (q.active) total += q.count;
        }
        return total;
    }

    /// Queue depth for a specific deployment.
    pub fn depthFor(self: *const RequestQueue, deployment_id: msg.DeploymentId) usize {
        for (self.queues[0..self.queue_count]) |q| {
            if (q.active and q.deployment_id == deployment_id) return q.count;
        }
        return 0;
    }

    /// Total owned correlation slots, including abandoned tombstones.
    pub fn activeInFlightCount(self: *const RequestQueue) usize {
        return self.occupied_count;
    }

    pub fn activeClientInFlightCount(self: *const RequestQueue) usize {
        return self.active_count;
    }

    pub fn workerHasInFlight(self: *RequestQueue, worker_idx: usize) bool {
        std.debug.assert(worker_idx < MAX_WORKERS);
        self.worker_busy_checks +%= 1;
        return self.worker_owned_count[worker_idx] != 0;
    }

    pub fn abandonedInFlightCount(self: *const RequestQueue) usize {
        std.debug.assert(self.active_count <= self.occupied_count);
        return self.occupied_count - self.active_count;
    }

    pub fn reset(self: *RequestQueue) void {
        self.* = RequestQueue.init();
    }

    /// Debug/test-only full scan. Never call from the control loop.
    pub fn assertAccountingInvariants(self: *const RequestQueue) void {
        var occupied: usize = 0;
        var active: usize = 0;
        var workers = std.mem.zeroes([MAX_WORKERS]u8);
        var expiries = std.mem.zeroes([MAX_WORKERS]u64);
        for (self.in_flight) |entry| {
            if (!entry.active) continue;
            std.debug.assert(entry.worker_idx < MAX_WORKERS);
            occupied += 1;
            if (!entry.abandoned) {
                active += 1;
            } else {
                std.debug.assert(entry.expires_at_tick != 0);
                expiries[entry.worker_idx] = entry.expires_at_tick;
            }
            std.debug.assert(workers[entry.worker_idx] < std.math.maxInt(u8));
            workers[entry.worker_idx] += 1;
        }
        std.debug.assert(occupied == self.occupied_count);
        std.debug.assert(active == self.active_count);
        std.debug.assert(std.mem.eql(u8, &workers, &self.worker_owned_count));
        std.debug.assert(std.mem.eql(u64, &expiries, &self.worker_abandoned_expires_at));
        std.debug.assert(self.active_count <= self.occupied_count);
        std.debug.assert(self.occupied_count <= MAX_IN_FLIGHT);
    }

    // -- Internal --

    fn getOrCreateQueue(self: *RequestQueue, deployment_id: msg.DeploymentId) ?*DeploymentQueue {
        for (self.queues[0..self.queue_count]) |*q| {
            if (q.active and q.deployment_id == deployment_id) return q;
        }
        if (self.queue_count >= MAX_QUEUES) return null;
        self.queues[self.queue_count] = DeploymentQueue.init(deployment_id);
        self.queue_count += 1;
        return &self.queues[self.queue_count - 1];
    }

    /// Reserve a unique worker correlation ID. Returns null without mutation when full.
    pub fn trackInFlight(self: *RequestQueue, client_request_id: u64, client_id: u128) ?u64 {
        return self.trackInFlightForWorker(client_request_id, client_id, 0);
    }

    pub fn trackInFlightForWorker(self: *RequestQueue, client_request_id: u64, client_id: u128, worker_idx: usize) ?u64 {
        if (worker_idx >= MAX_WORKERS) return null;
        if (self.workerHasInFlight(worker_idx)) return null;
        if (self.occupied_count >= MAX_IN_FLIGHT) return null;

        for (&self.in_flight) |*entry| {
            if (entry.active) continue;

            const worker_request_id = self.allocateWorkerRequestId();
            entry.* = .{
                .worker_request_id = worker_request_id,
                .client_request_id = client_request_id,
                .client_id = client_id,
                .worker_idx = worker_idx,
                .abandoned = false,
                .expires_at_tick = 0,
                .active = true,
            };
            std.debug.assert(self.occupied_count < MAX_IN_FLIGHT);
            std.debug.assert(self.active_count < MAX_IN_FLIGHT);
            std.debug.assert(self.worker_owned_count[worker_idx] == 0);
            self.occupied_count += 1;
            self.active_count += 1;
            self.worker_owned_count[worker_idx] += 1;
            self.dispatch_total += 1;
            return worker_request_id;
        }
        unreachable;
    }

    fn removeEntry(self: *RequestQueue, entry: *InFlightEntry) void {
        std.debug.assert(entry.active);
        std.debug.assert(entry.worker_idx < MAX_WORKERS);
        std.debug.assert(self.occupied_count > 0);
        std.debug.assert(self.worker_owned_count[entry.worker_idx] > 0);
        self.occupied_count -= 1;
        self.worker_owned_count[entry.worker_idx] -= 1;
        self.worker_abandoned_expires_at[entry.worker_idx] = 0;
        if (!entry.abandoned) {
            std.debug.assert(self.active_count > 0);
            self.active_count -= 1;
        }
        entry.* = .{};
    }

    fn allocateWorkerRequestId(self: *RequestQueue) u64 {
        var attempts: usize = 0;
        while (attempts <= MAX_IN_FLIGHT) : (attempts += 1) {
            const candidate = self.next_worker_request_id;
            self.next_worker_request_id +%= 1;
            if (self.next_worker_request_id == 0) self.next_worker_request_id = 1;

            var active = false;
            for (self.in_flight) |entry| {
                if (entry.active and entry.worker_request_id == candidate) {
                    active = true;
                    break;
                }
            }
            if (!active) return candidate;
        }
        unreachable;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "run status wire golden" {
    const statuses = [_]RunStatus{
        .ok,
        .deployment_not_found,
        .queue_full,
        .invalid_payload,
        .response_too_large,
        .outcome_ambiguous,
        .forwarding_failed,
        .no_running_pod,
        .unavailable,
        .not_leader,
    };
    for (statuses, 0..) |status, wire| {
        try std.testing.expectEqual(@as(u8, @intCast(wire)), @intFromEnum(status));
    }
}

test "request queue: enqueue and dequeue" {
    var rq = RequestQueue.init();
    const ok = rq.enqueue(42, 1, 100, "hello");
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, 1), rq.totalDepth());
    try std.testing.expectEqual(@as(usize, 1), rq.depthFor(42));
}

test "request queue: overflow returns false" {
    var rq = RequestQueue.init();
    for (0..MAX_QUEUE_DEPTH) |i| {
        try std.testing.expect(rq.enqueue(1, @intCast(i), 100, "x"));
    }
    try std.testing.expect(!rq.enqueue(1, 999, 100, "x"));
}

test "request queue: resolve response restores original client identity" {
    var rq = RequestQueue.init();
    const worker_request_id = rq.trackInFlight(42, 0xABCD).?;
    try std.testing.expectEqual(@as(usize, 1), rq.activeInFlightCount());
    const resolved = rq.resolveResponseForWorker(worker_request_id, 0).?;
    try std.testing.expectEqual(@as(u128, 0xABCD), resolved.client_id);
    try std.testing.expectEqual(@as(u64, 42), resolved.client_request_id);
    try std.testing.expectEqual(@as(usize, 0), rq.activeInFlightCount());
    try std.testing.expectEqual(@as(u64, 1), rq.dispatch_total);
    try std.testing.expectEqual(@as(u64, 1), rq.resolve_total);
    try std.testing.expect(rq.resolveResponseForWorker(worker_request_id, 0) == null);
}

test "request queue: response ownership requires correlation and worker match atomically" {
    var rq = RequestQueue.init();
    const worker_request_id = rq.trackInFlightForWorker(42, 0xABCD, 3).?;

    try std.testing.expect(rq.resolveResponseForWorker(worker_request_id, 4) == null);
    try std.testing.expectEqual(@as(usize, 1), rq.activeInFlightCount());
    const resolved = rq.resolveResponseForWorker(worker_request_id, 3).?;
    try std.testing.expectEqual(@as(u128, 0xABCD), resolved.client_id);
    try std.testing.expectEqual(@as(u64, 42), resolved.client_request_id);
    try std.testing.expectEqual(@as(usize, 0), rq.activeInFlightCount());
}

test "request queue: one active or abandoned correlation per worker" {
    var rq = RequestQueue.init();
    const first = rq.trackInFlightForWorker(1, 100, 3).?;
    try std.testing.expect(rq.workerHasInFlight(3));
    try std.testing.expect(rq.trackInFlightForWorker(2, 200, 3) == null);
    rq.cancelClient(100, 10);
    try std.testing.expect(rq.trackInFlightForWorker(3, 300, 3) == null);
    try std.testing.expectEqual(ResponseResolution.abandoned, rq.classifyResponseForWorker(first, 3));
    try std.testing.expect(rq.trackInFlightForWorker(4, 400, 3) != null);
}

test "request queue: accounting invariants cover every correlation transition" {
    var rq = RequestQueue.init();
    rq.assertAccountingInvariants();

    const live = rq.trackInFlightForWorker(1, 10, 0).?;
    const tombstone = rq.trackInFlightForWorker(2, 20, 1).?;
    rq.assertAccountingInvariants();
    try std.testing.expectEqual(@as(usize, 2), rq.activeClientInFlightCount());

    rq.cancelClient(20, 100);
    rq.assertAccountingInvariants();
    try std.testing.expectEqual(@as(usize, 1), rq.activeClientInFlightCount());
    try std.testing.expectEqual(@as(usize, 1), rq.abandonedInFlightCount());

    try std.testing.expectEqual(ResponseResolution.abandoned, rq.classifyResponseForWorker(tombstone, 1));
    rq.assertAccountingInvariants();
    _ = rq.resolveResponseForWorker(live, 0).?;
    rq.assertAccountingInvariants();

    _ = rq.trackInFlightForWorker(3, 30, 2).?;
    var released: [MAX_IN_FLIGHT]ResolvedRequest = undefined;
    try std.testing.expectEqual(@as(usize, 1), rq.releaseWorker(2, &released));
    rq.assertAccountingInvariants();

    _ = rq.trackInFlightForWorker(4, 40, 3).?;
    rq.cancelClient(40, 200);
    var expired: [MAX_IN_FLIGHT]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), rq.expiredAbandonedWorkers(200 + ABANDONED_TTL_TICKS, &expired));
    _ = rq.releaseWorker(expired[0], &released);
    rq.assertAccountingInvariants();

    rq.reset();
    rq.assertAccountingInvariants();
    try std.testing.expectEqual(@as(usize, 0), rq.activeInFlightCount());
}

test "request queue: worker busy control-loop lookup is constant per backend" {
    var rq = RequestQueue.init();
    _ = rq.trackInFlightForWorker(1, 10, 0).?;
    const checks_before = rq.worker_busy_checks;
    for (0..MAX_WORKERS) |worker_idx| _ = rq.workerHasInFlight(worker_idx);
    try std.testing.expectEqual(@as(u64, MAX_WORKERS), rq.worker_busy_checks - checks_before);
    rq.assertAccountingInvariants();
}

test "request queue: same client request id receives unique worker correlations" {
    var rq = RequestQueue.init();
    const first = rq.trackInFlightForWorker(1, 100, 0).?;
    const second = rq.trackInFlightForWorker(1, 200, 1).?;
    try std.testing.expect(first != second);

    const second_resolved = rq.resolveResponseForWorker(second, 1).?;
    const first_resolved = rq.resolveResponseForWorker(first, 0).?;
    try std.testing.expectEqual(@as(u128, 200), second_resolved.client_id);
    try std.testing.expectEqual(@as(u64, 1), second_resolved.client_request_id);
    try std.testing.expectEqual(@as(u128, 100), first_resolved.client_id);
    try std.testing.expectEqual(@as(u64, 1), first_resolved.client_request_id);
}

test "request queue: wrapped correlation skips an active id" {
    var rq = RequestQueue.init();
    const first = rq.trackInFlightForWorker(1, 100, 0).?;
    try std.testing.expectEqual(@as(u64, 1), first);
    rq.next_worker_request_id = 1;
    const second = rq.trackInFlightForWorker(2, 200, 1).?;
    try std.testing.expectEqual(@as(u64, 2), second);
}

test "request queue: all worker slots reject without eviction" {
    var rq = RequestQueue.init();
    for (0..MAX_WORKERS) |i| {
        try std.testing.expect(rq.trackInFlightForWorker(@intCast(i), @intCast(i + 1), i) != null);
    }
    try std.testing.expect(rq.trackInFlight(9999, 9999) == null);
    try std.testing.expectEqual(@as(usize, MAX_WORKERS), rq.activeInFlightCount());
    try std.testing.expectEqual(@as(u64, MAX_WORKERS), rq.dispatch_total);

    for (0..MAX_WORKERS) |i| {
        const resolved = rq.resolveResponseForWorker(@intCast(i + 1), i).?;
        try std.testing.expectEqual(@as(u64, @intCast(i)), resolved.client_request_id);
    }
}

test "request queue: per-deployment isolation" {
    var rq = RequestQueue.init();
    _ = rq.enqueue(1, 10, 100, "a");
    _ = rq.enqueue(2, 20, 200, "b");
    _ = rq.enqueue(1, 11, 100, "c");
    try std.testing.expectEqual(@as(usize, 2), rq.depthFor(1));
    try std.testing.expectEqual(@as(usize, 1), rq.depthFor(2));
    try std.testing.expectEqual(@as(usize, 3), rq.totalDepth());
    try std.testing.expectEqual(@as(u64, 3), rq.enqueue_total);
}

test "request queue: cancel client clears queued and in-flight requests only for that client" {
    var rq = RequestQueue.init();
    try std.testing.expect(rq.enqueue(1, 10, 100, "a"));
    try std.testing.expect(rq.enqueue(1, 11, 200, "b"));
    try std.testing.expect(rq.enqueue(2, 20, 100, "c"));
    const first_worker_id = rq.trackInFlightForWorker(30, 100, 0).?;
    const second_worker_id = rq.trackInFlightForWorker(31, 200, 1).?;

    rq.cancelClient(100, 10);

    try std.testing.expectEqual(@as(usize, 1), rq.depthFor(1));
    try std.testing.expectEqual(@as(usize, 0), rq.depthFor(2));
    try std.testing.expectEqual(@as(usize, 1), rq.totalDepth());
    try std.testing.expectEqual(@as(usize, 2), rq.activeInFlightCount());
    try std.testing.expectEqual(@as(usize, 1), rq.abandonedInFlightCount());
    try std.testing.expectEqual(@as(u128, 200), rq.resolveResponseForWorker(second_worker_id, 1).?.client_id);
    try std.testing.expect(rq.resolveResponseForWorker(first_worker_id, 0) == null);
    try std.testing.expectEqual(@as(u64, 2), rq.resolve_total);

    const remaining = rq.queues[0].dequeue().?;
    try std.testing.expectEqual(@as(u64, 11), remaining.request_id);
    try std.testing.expectEqual(@as(u128, 200), remaining.client_id);
}

test "request queue: abandoned worker-owned response consumes silently without touching unrelated" {
    var rq = RequestQueue.init();
    const abandoned = rq.trackInFlightForWorker(30, 100, 3).?;
    const unrelated = rq.trackInFlightForWorker(31, 200, 4).?;
    rq.cancelClient(100, 50);

    try std.testing.expectEqual(@as(usize, 2), rq.activeInFlightCount());
    try std.testing.expectEqual(@as(usize, 1), rq.abandonedInFlightCount());
    try std.testing.expectEqual(ResponseResolution.abandoned, rq.classifyResponseForWorker(abandoned, 3));
    try std.testing.expectEqual(@as(usize, 1), rq.activeInFlightCount());
    const delivered = rq.classifyResponseForWorker(unrelated, 4).deliver;
    try std.testing.expectEqual(@as(u128, 200), delivered.client_id);
    try std.testing.expectEqual(@as(usize, 0), rq.activeInFlightCount());
}

test "request queue: abandoned worker saturation expires and reuses every slot" {
    var rq = RequestQueue.init();
    for (0..MAX_WORKERS) |i| {
        _ = rq.trackInFlightForWorker(@intCast(i), 777, i).?;
    }
    rq.cancelClient(777, 100);
    try std.testing.expectEqual(MAX_WORKERS, rq.activeInFlightCount());
    try std.testing.expectEqual(MAX_WORKERS, rq.abandonedInFlightCount());
    try std.testing.expect(rq.trackInFlight(9999, 1) == null);
    var expired_workers: [MAX_IN_FLIGHT]usize = undefined;
    try std.testing.expectEqual(@as(usize, 0), rq.expiredAbandonedWorkers(100 + ABANDONED_TTL_TICKS - 1, &expired_workers));
    try std.testing.expectEqual(MAX_WORKERS, rq.expiredAbandonedWorkers(100 + ABANDONED_TTL_TICKS, &expired_workers));
    var released: [MAX_IN_FLIGHT]ResolvedRequest = undefined;
    for (expired_workers[0..MAX_WORKERS]) |worker_idx| _ = rq.releaseWorker(worker_idx, &released);
    try std.testing.expectEqual(@as(usize, 0), rq.activeInFlightCount());
    for (0..MAX_WORKERS) |i| try std.testing.expect(rq.trackInFlightForWorker(@intCast(i), 1, i) != null);
}

test "request queue: worker disconnect releases tombstones without client errors" {
    var rq = RequestQueue.init();
    _ = rq.trackInFlightForWorker(10, 100, 3).?;
    const live = rq.trackInFlightForWorker(11, 200, 4).?;
    rq.cancelClient(100, 1);
    var released: [MAX_IN_FLIGHT]ResolvedRequest = undefined;
    try std.testing.expectEqual(@as(usize, 0), rq.releaseWorker(3, &released));
    try std.testing.expectEqual(@as(usize, 1), rq.activeInFlightCount());
    try std.testing.expectEqual(@as(u128, 200), rq.classifyResponseForWorker(live, 4).deliver.client_id);
}

test "request queue: worker failure releases owned correlations and reuses slots" {
    var rq = RequestQueue.init();
    const failed = rq.trackInFlightForWorker(10, 100, 3).?;
    const kept = rq.trackInFlightForWorker(11, 200, 4).?;

    var released: [MAX_IN_FLIGHT]ResolvedRequest = undefined;
    const released_count = rq.releaseWorker(3, &released);
    try std.testing.expectEqual(@as(usize, 1), released_count);
    try std.testing.expectEqual(@as(u128, 100), released[0].client_id);
    try std.testing.expect(rq.resolveResponseForWorker(failed, 3) == null);
    try std.testing.expectEqual(@as(usize, 1), rq.activeInFlightCount());

    const reused = rq.trackInFlightForWorker(12, 300, 3).?;
    try std.testing.expect(reused != kept);
    try std.testing.expectEqual(@as(usize, 2), rq.activeInFlightCount());
}

test "request queue: explicit release returns original request once" {
    var rq = RequestQueue.init();
    const worker_request_id = rq.trackInFlightForWorker(42, 123, 7).?;
    const released = rq.releaseInFlight(worker_request_id).?;
    try std.testing.expectEqual(@as(u64, 42), released.client_request_id);
    try std.testing.expectEqual(@as(u128, 123), released.client_id);
    try std.testing.expect(rq.releaseInFlight(worker_request_id) == null);
}

test "request queue: rejects oversized payload instead of clamping" {
    var queue = RequestQueue.init();
    var over: [MAX_PAYLOAD + 1]u8 = undefined;
    @memset(&over, 0xab);
    try std.testing.expect(!queue.enqueue(1, 1, 100, &over));
    try std.testing.expectEqual(@as(usize, 0), queue.totalDepth());
    try std.testing.expectEqual(@as(u64, 0), queue.enqueue_total);
}

test "request queue: accepts zero and max payload boundaries" {
    var queue = RequestQueue.init();
    try std.testing.expect(queue.enqueue(1, 1, 100, ""));
    var max_buf: [MAX_PAYLOAD]u8 = undefined;
    @memset(&max_buf, 0xcd);
    try std.testing.expect(queue.enqueue(1, 2, 100, &max_buf));
    try std.testing.expectEqual(@as(usize, 2), queue.totalDepth());

    const zero = queue.queues[0].dequeue().?;
    try std.testing.expectEqual(@as(usize, 0), zero.payload_len);
    const max_req = queue.queues[0].dequeue().?;
    try std.testing.expectEqual(@as(usize, MAX_PAYLOAD), max_req.payload_len);
    try std.testing.expect(std.mem.eql(u8, max_req.payload[0..MAX_PAYLOAD], &max_buf));
}

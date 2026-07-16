const std = @import("std");
const msg = @import("message.zig");
/// Shared run-request body bound (Go MaxRunPayload, Rust MAX_RUN_PAYLOAD). Reject oversize; never clamp.
pub const MAX_PAYLOAD: usize = 512;
pub const MAX_QUEUE_DEPTH: usize = 64;
pub const MAX_QUEUES: usize = 16;
pub const MAX_IN_FLIGHT: usize = 1024;

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

const InFlightEntry = struct {
    worker_request_id: u64 = 0,
    client_request_id: u64 = 0,
    client_id: u128 = 0,
    worker_idx: usize = 0,
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
    pub fn resolveResponseForWorker(self: *RequestQueue, worker_request_id: u64, worker_idx: usize) ?ResolvedRequest {
        for (&self.in_flight) |*entry| {
            if (!entry.active) continue;
            if (entry.worker_request_id != worker_request_id) continue;
            if (entry.worker_idx != worker_idx) return null;

            entry.active = false;
            self.resolve_total += 1;
            return .{
                .client_id = entry.client_id,
                .client_request_id = entry.client_request_id,
            };
        }
        return null;
    }

    fn releaseInFlight(self: *RequestQueue, worker_request_id: u64) ?ResolvedRequest {
        for (&self.in_flight) |*entry| {
            if (!entry.active or entry.worker_request_id != worker_request_id) continue;
            entry.active = false;
            self.resolve_total += 1;
            return .{
                .client_id = entry.client_id,
                .client_request_id = entry.client_request_id,
            };
        }
        return null;
    }

    /// Atomically release every correlation owned by one worker connection.
    pub fn releaseWorker(self: *RequestQueue, worker_idx: usize, released: *[MAX_IN_FLIGHT]ResolvedRequest) usize {
        var released_count: usize = 0;
        for (&self.in_flight) |*entry| {
            if (!entry.active or entry.worker_idx != worker_idx) continue;
            std.debug.assert(released_count < released.len);
            released[released_count] = .{
                .client_id = entry.client_id,
                .client_request_id = entry.client_request_id,
            };
            released_count += 1;
            entry.active = false;
            self.resolve_total += 1;
        }
        return released_count;
    }

    /// Drop all queued and in-flight requests owned by a disconnected client.
    /// This prevents abandoned /run requests from leaking queue state across
    /// client reconnects after the caller has already timed out locally.
    pub fn cancelClient(self: *RequestQueue, client_id: u128) void {
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
            entry.active = false;
            self.resolve_total += 1;
        }
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

    pub fn activeInFlightCount(self: *const RequestQueue) usize {
        var count: usize = 0;
        for (self.in_flight) |entry| {
            if (entry.active) count += 1;
        }
        return count;
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
        if (self.activeInFlightCount() >= MAX_IN_FLIGHT) return null;

        for (&self.in_flight) |*entry| {
            if (entry.active) continue;

            const worker_request_id = self.allocateWorkerRequestId();
            entry.* = .{
                .worker_request_id = worker_request_id,
                .client_request_id = client_request_id,
                .client_id = client_id,
                .worker_idx = worker_idx,
                .active = true,
            };
            self.dispatch_total += 1;
            return worker_request_id;
        }
        unreachable;
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

test "request queue: same client request id receives unique worker correlations" {
    var rq = RequestQueue.init();
    const first = rq.trackInFlight(1, 100).?;
    const second = rq.trackInFlight(1, 200).?;
    try std.testing.expect(first != second);

    const second_resolved = rq.resolveResponseForWorker(second, 0).?;
    const first_resolved = rq.resolveResponseForWorker(first, 0).?;
    try std.testing.expectEqual(@as(u128, 200), second_resolved.client_id);
    try std.testing.expectEqual(@as(u64, 1), second_resolved.client_request_id);
    try std.testing.expectEqual(@as(u128, 100), first_resolved.client_id);
    try std.testing.expectEqual(@as(u64, 1), first_resolved.client_request_id);
}

test "request queue: wrapped correlation skips an active id" {
    var rq = RequestQueue.init();
    const first = rq.trackInFlight(1, 100).?;
    try std.testing.expectEqual(@as(u64, 1), first);
    rq.next_worker_request_id = 1;
    const second = rq.trackInFlight(2, 200).?;
    try std.testing.expectEqual(@as(u64, 2), second);
}

test "request queue: full in-flight table rejects without eviction" {
    var rq = RequestQueue.init();
    for (0..MAX_IN_FLIGHT) |i| {
        try std.testing.expect(rq.trackInFlight(@intCast(i), @intCast(i + 1)) != null);
    }
    try std.testing.expect(rq.trackInFlight(9999, 9999) == null);
    try std.testing.expectEqual(@as(usize, MAX_IN_FLIGHT), rq.activeInFlightCount());
    try std.testing.expectEqual(@as(u64, MAX_IN_FLIGHT), rq.dispatch_total);

    for (0..MAX_IN_FLIGHT) |i| {
        const resolved = rq.resolveResponseForWorker(@intCast(i + 1), 0).?;
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
    const first_worker_id = rq.trackInFlight(30, 100).?;
    const second_worker_id = rq.trackInFlight(31, 200).?;

    rq.cancelClient(100);

    try std.testing.expectEqual(@as(usize, 1), rq.depthFor(1));
    try std.testing.expectEqual(@as(usize, 0), rq.depthFor(2));
    try std.testing.expectEqual(@as(usize, 1), rq.totalDepth());
    try std.testing.expectEqual(@as(usize, 1), rq.activeInFlightCount());
    try std.testing.expectEqual(@as(u128, 200), rq.resolveResponseForWorker(second_worker_id, 0).?.client_id);
    try std.testing.expect(rq.resolveResponseForWorker(first_worker_id, 0) == null);
    try std.testing.expectEqual(@as(u64, 2), rq.resolve_total);

    const remaining = rq.queues[0].dequeue().?;
    try std.testing.expectEqual(@as(u64, 11), remaining.request_id);
    try std.testing.expectEqual(@as(u128, 200), remaining.client_id);
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

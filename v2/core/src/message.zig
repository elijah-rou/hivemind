const std = @import("std");

// ---------------------------------------------------------------------------
// VRR identifiers
// ---------------------------------------------------------------------------

pub const ViewNumber = u64;
pub const OpNumber = u64;
pub const RequestId = u128;
pub const NodeId = u64;
pub const DeploymentId = u64;
pub const PodId = u64;

pub const REPLICA_COUNT_MAX: u8 = 11;

pub const Status = enum(u8) {
    normal,
    view_change,
    recovering,
};

// ---------------------------------------------------------------------------
// Hardware types
// ---------------------------------------------------------------------------

pub const GpuType = enum(u8) {
    none,
    a100_40,
    a100_80,
    h100_sxm,
    h100_pcie,
    h200,
    l40s,
    a10g,
    t4,
};

pub const NodeStatus = enum(u8) {
    provisioning,
    starting,
    ready,
    unhealthy,
    draining,
    terminating,
    terminated,
};

pub const PodPhase = enum(u8) {
    pending,
    scheduled,
    running,
    succeeded,
    failed,
    terminating,
};

// ---------------------------------------------------------------------------
// Shared sub-types for deployment specs
// ---------------------------------------------------------------------------

pub const EnvEntry = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    value: [256]u8 = std.mem.zeroes([256]u8),
    is_secret_ref: bool = false,
};

pub const TrafficRule = struct {
    version: u32 = 0,
    weight: u8 = 0,
};

pub const ProbeConfig = struct {
    path: [64]u8 = std.mem.zeroes([64]u8),
    interval_ms: u32 = 10000,
    timeout_ms: u32 = 5000,
    enabled: bool = false,
};

// ---------------------------------------------------------------------------
// State machine commands -- replicated through VRR consensus
// ---------------------------------------------------------------------------

pub const Command = union(enum(u8)) {
    register_node: RegisterNodeCmd,
    deregister_node: DeregisterNodeCmd,
    update_node_status: UpdateNodeStatusCmd,
    create_deployment: CreateDeploymentCmd,
    bind_pod_to_node: BindPodToNodeCmd,
    update_pod_status: UpdatePodStatusCmd,
    scale_deployment: ScaleDeploymentCmd,
    unbind_pod: UnbindPodCmd,
    set_killswitch: SetKillswitchCmd,
    noop: void,
    update_deployment: UpdateDeploymentCmd,
    set_traffic_split: SetTrafficSplitCmd,
    rollback_deployment: RollbackDeploymentCmd,
    delete_deployment: DeleteDeploymentCmd,
    pause_deployment: PauseDeploymentCmd,
    resume_deployment: ResumeDeploymentCmd,
    bind_pods_to_nodes: BindPodsToNodesCmd,
};

pub const RegisterNodeCmd = struct {
    node_name: [64]u8 = std.mem.zeroes([64]u8),
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    provider: [32]u8 = std.mem.zeroes([32]u8),
    region: [32]u8 = std.mem.zeroes([32]u8),
};

pub const DeregisterNodeCmd = struct {
    node_id: NodeId = 0,
};

pub const UpdateNodeStatusCmd = struct {
    node_id: NodeId = 0,
    new_status: NodeStatus = .provisioning,
};

pub const CreateDeploymentCmd = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    namespace: [64]u8 = std.mem.zeroes([64]u8),
    image: [256]u8 = std.mem.zeroes([256]u8),
    entrypoint: [256]u8 = std.mem.zeroes([256]u8),
    port: u16 = 8080,
    replicas: u32 = 1,
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    min_replicas: u32 = 0,
    max_replicas: u32 = 10,
    scale_to_zero_after_ms: u64 = 0,
    target_queue_depth: u32 = 1,
    liveness: ProbeConfig = .{},
    readiness: ProbeConfig = .{},
    startup_timeout_ms: u32 = 30000,
    juicefs_path: [128]u8 = std.mem.zeroes([128]u8),
    env_vars: [16]EnvEntry = [_]EnvEntry{.{}} ** 16,
    env_count: u8 = 0,
    /// Optional registry host hint (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com). Image should still be fully qualified for pulls.
    image_pull_registry: [128]u8 = std.mem.zeroes([128]u8),
    image_pull_username: [64]u8 = std.mem.zeroes([64]u8),
    image_pull_password: [256]u8 = std.mem.zeroes([256]u8),
    /// When set, `image_pull_password` holds a Doppler secret name (resolved on the agent).
    image_pull_password_is_secret: u8 = 0,
};

pub const BindPodToNodeCmd = struct {
    pod_id: PodId = 0,
    node_id: NodeId = 0,
};

pub const BIND_BATCH_MAX: usize = 64;

pub const PodBinding = struct {
    pod_id: PodId = 0,
    node_id: NodeId = 0,
};

pub const BindPodsToNodesCmd = struct {
    bindings: [BIND_BATCH_MAX]PodBinding = [_]PodBinding{.{}} ** BIND_BATCH_MAX,
    count: u8 = 0,
};

pub const UpdatePodStatusCmd = struct {
    pod_id: PodId = 0,
    new_phase: PodPhase = .pending,
};

pub const ScaleDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
    desired_replicas: u32 = 0,
};

pub const UnbindPodCmd = struct {
    pod_id: PodId = 0,
};

pub const SetKillswitchCmd = struct {
    node_id: NodeId = 0,
    deployment_id: DeploymentId = 0,
    active: bool = false,
};

pub const UpdateDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
    image: [256]u8 = std.mem.zeroes([256]u8),
    entrypoint: [256]u8 = std.mem.zeroes([256]u8),
    port: u16 = 0,
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    env_vars: [16]EnvEntry = [_]EnvEntry{.{}} ** 16,
    env_count: u8 = 0,
};

pub const SetTrafficSplitCmd = struct {
    deployment_id: DeploymentId = 0,
    rules: [4]TrafficRule = [_]TrafficRule{.{}} ** 4,
    rule_count: u8 = 0,
};

pub const RollbackDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

pub const DeleteDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

pub const PauseDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

pub const ResumeDeploymentCmd = struct {
    deployment_id: DeploymentId = 0,
};

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

pub const ErrorCode = enum(u8) {
    ok,
    not_found,
    already_exists,
    capacity_exceeded,
    invalid_transition,
    not_leader,
    /// Retained log is full; no snapshot floor exists to truncate committed ops.
    log_full,
};

pub const ResultData = struct {
    entity_id: u64 = 0,
};

pub const Result = union(enum(u8)) {
    ok: ResultData,
    err: ErrorCode,
};

// ---------------------------------------------------------------------------
// VRR protocol messages
// ---------------------------------------------------------------------------

pub const LogEntry = struct {
    checksum: u64 = 0,
    parent_checksum: u64 = 0,
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    command: Command = .{ .noop = {} },
    client_id: u128 = 0,
    request_id: RequestId = 0,

    pub fn computeChecksum(self: *const LogEntry) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(std.mem.asBytes(&self.parent_checksum));
        hasher.update(std.mem.asBytes(&self.view_number));
        hasher.update(std.mem.asBytes(&self.op_number));
        hasher.update(std.mem.asBytes(&self.command));
        hasher.update(std.mem.asBytes(&self.client_id));
        hasher.update(std.mem.asBytes(&self.request_id));
        return hasher.final();
    }

    pub fn valid(self: *const LogEntry) bool {
        return self.checksum == self.computeChecksum();
    }
};

pub const RequestMsg = struct {
    client_id: u128 = 0,
    request_id: RequestId = 0,
    command: Command = .{ .noop = {} },
};

pub const PrepareMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_min: OpNumber = 0,
    retention_floor: OpNumber = 0,
    entry: LogEntry = .{},
};

pub const PrepareOkMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    replica_id: u8 = 0,
    commit_min: OpNumber = 0,
};

pub const CommitMsg = struct {
    view_number: ViewNumber = 0,
    commit_min: OpNumber = 0,
    commit_max: OpNumber = 0,
    op_number: OpNumber = 0,
    retention_floor: OpNumber = 0,
    commit_checksum: u64 = 0,
};

pub const ReplyMsg = struct {
    view_number: ViewNumber = 0,
    request_id: RequestId = 0,
    result: Result = .{ .ok = .{} },
};

pub const StartViewChangeMsg = struct {
    view_number: ViewNumber = 0,
    replica_id: u8 = 0,
};

pub const DVC_LOG_MAX: usize = 8;
pub const LOG_BITSET_WORDS: usize = 16;
pub const LOG_BITSET_BITS: usize = LOG_BITSET_WORDS * 64;

pub const DoViewChangeMsg = struct {
    view_number: ViewNumber = 0,
    replica_id: u8 = 0,
    last_normal_view: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_min: OpNumber = 0,
    retention_floor: OpNumber = 0,
    log_entries: [DVC_LOG_MAX]LogEntry = [_]LogEntry{.{}} ** DVC_LOG_MAX,
    log_entry_count: u8 = 0,
    present_bitset: [LOG_BITSET_WORDS]u64 = std.mem.zeroes([LOG_BITSET_WORDS]u64),
    nack_bitset: [LOG_BITSET_WORDS]u64 = std.mem.zeroes([LOG_BITSET_WORDS]u64),
};

pub const SV_LOG_MAX: usize = 8;

pub const StartViewMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_min: OpNumber = 0,
    retention_floor: OpNumber = 0,
    log_entries: [SV_LOG_MAX]LogEntry = [_]LogEntry{.{}} ** SV_LOG_MAX,
    log_entry_count: u8 = 0,
};

pub const RequestPrepareMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
};

pub const SendPrepareMsg = struct {
    view_number: ViewNumber = 0,
    entry: LogEntry = .{},
};

pub const RequestStatusMsg = struct {
    view_number: ViewNumber = 0,
};

pub const SendStatusMsg = struct {
    view_number: ViewNumber = 0,
    op_number: OpNumber = 0,
    commit_min: OpNumber = 0,
};

pub const Tag = enum(u8) {
    request,
    prepare,
    prepare_ok,
    commit,
    reply,
    start_view_change,
    do_view_change,
    start_view,
    request_prepare,
    send_prepare,
    request_status,
    send_status,
};

pub const Message = union(Tag) {
    request: RequestMsg,
    prepare: PrepareMsg,
    prepare_ok: PrepareOkMsg,
    commit: CommitMsg,
    reply: ReplyMsg,
    start_view_change: StartViewChangeMsg,
    do_view_change: DoViewChangeMsg,
    start_view: StartViewMsg,
    request_prepare: RequestPrepareMsg,
    send_prepare: SendPrepareMsg,
    request_status: RequestStatusMsg,
    send_status: SendStatusMsg,
};

// ---------------------------------------------------------------------------
// Client protocol tags
// ---------------------------------------------------------------------------

pub const ClientTag = enum(u8) {
    request = 0x20, // client → hivemind: consensus command
    reply = 0x21, // hivemind → client: consensus reply
    run_request = 0x22, // client → hivemind: run (no consensus)
    run_response = 0x23, // hivemind → client: run response
    cluster_state_request = 0x24, // client → hivemind: read-only state query
    cluster_state_response = 0x25, // hivemind → client: state snapshot
};

// ---------------------------------------------------------------------------
// Worker protocol messages (bidirectional over worker-initiated TCP)
// ---------------------------------------------------------------------------

pub const WorkerTag = enum(u8) {
    // Hivemind -> Worker
    register_ack = 0x01,
    start_pod = 0x02,
    stop_pod = 0x03,
    run_request = 0x04,

    // Worker -> Hivemind
    register = 0x10,
    heartbeat = 0x11,
    pod_status = 0x12,
    run_response = 0x13,
};

pub const WorkerRegisterMsg = struct {
    hostname: [64]u8 = std.mem.zeroes([64]u8),
    cpu_millicores: u32 = 0,
    memory_megabytes: u32 = 0,
    gpu_type: GpuType = .none,
    gpu_count: u8 = 0,
    provider: [32]u8 = std.mem.zeroes([32]u8),
    region: [32]u8 = std.mem.zeroes([32]u8),
};

pub const WorkerHeartbeatMsg = struct {
    timestamp: u64 = 0,
    cpu_usage_pct: u8 = 0,
    memory_used_mb: u32 = 0,
    gpu_utilization: [8]u8 = std.mem.zeroes([8]u8),
    pods_running: u16 = 0,
};

pub const WorkerPodStatusMsg = struct {
    pod_id: u64 = 0,
    old_phase: PodPhase = .pending,
    new_phase: PodPhase = .pending,
    timestamp: u64 = 0,
    exit_code: i32 = 0,
    message: [128]u8 = std.mem.zeroes([128]u8),
};

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

pub fn serialize(msg: Message, buf: []u8) usize {
    const tag_byte: u8 = @intFromEnum(std.meta.activeTag(msg));
    buf[0] = tag_byte;
    // Field-by-field copy into zeroed buffer to eliminate undefined
    // struct padding that corrupts deserialization in release builds.
    const payload_len = serializePayload(msg, buf[1..]);
    return 1 + payload_len;
}

fn enumFromIntChecked(comptime E: type, value: @typeInfo(E).@"enum".tag_type) !E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (value == field.value) return @enumFromInt(value);
    }
    return error.InvalidEnumTag;
}

pub fn deserialize(buf: []const u8) !Message {
    if (buf.len < 1) return error.MessageTooShort;
    const tag = enumFromIntChecked(Tag, buf[0]) catch return error.InvalidMessageTag;
    const data = buf[1..];
    const decoded: Message = switch (tag) {
        .request => .{ .request = try bytesAs(RequestMsg, data) },
        .prepare => .{ .prepare = try bytesAs(PrepareMsg, data) },
        .prepare_ok => .{ .prepare_ok = try bytesAs(PrepareOkMsg, data) },
        .commit => .{ .commit = try bytesAs(CommitMsg, data) },
        .reply => .{ .reply = try bytesAs(ReplyMsg, data) },
        .start_view_change => .{ .start_view_change = try bytesAs(StartViewChangeMsg, data) },
        .do_view_change => .{ .do_view_change = try bytesAs(DoViewChangeMsg, data) },
        .start_view => .{ .start_view = try bytesAs(StartViewMsg, data) },
        .request_prepare => .{ .request_prepare = try bytesAs(RequestPrepareMsg, data) },
        .send_prepare => .{ .send_prepare = try bytesAs(SendPrepareMsg, data) },
        .request_status => .{ .request_status = try bytesAs(RequestStatusMsg, data) },
        .send_status => .{ .send_status = try bytesAs(SendStatusMsg, data) },
    };
    try validateDecodedMessage(decoded);
    return decoded;
}

fn validateDecodedMessage(decoded: Message) !void {
    // Nested Command/Result tags are not at a stable asBytes offset in Zig's
    // large tagged-union layout, so peer handlers must keep rejecting via
    // LogEntry.valid() / apply-time checks. Here we only enforce counts that
    // would otherwise OOB-slice message-local arrays.
    switch (decoded) {
        .do_view_change => |m| {
            if (m.log_entry_count > DVC_LOG_MAX) return error.InvalidLogEntryCount;
        },
        .start_view => |m| {
            if (m.log_entry_count > SV_LOG_MAX) return error.InvalidLogEntryCount;
        },
        else => {},
    }
}

fn payloadBytes(msg: Message) []const u8 {
    return switch (msg) {
        inline else => |payload| std.mem.asBytes(&payload),
    };
}

/// Serialize with zeroed padding. Creates a zeroed copy of the payload
/// to eliminate undefined struct padding in release builds.
fn serializePayload(msg: Message, dst: []u8) usize {
    switch (msg) {
        inline else => |payload| {
            const T = @TypeOf(payload);
            const size = @sizeOf(T);
            @memset(dst[0..size], 0);
            inline for (std.meta.fields(T)) |field| {
                const offset = @offsetOf(T, field.name);
                const field_size = @sizeOf(field.type);
                const val = @field(payload, field.name);
                @memcpy(dst[offset..][0..field_size], std.mem.asBytes(&val));
            }
            return size;
        },
    }
}

fn bytesAs(comptime T: type, data: []const u8) !T {
    if (data.len < @sizeOf(T)) return error.MessageTooShort;
    return std.mem.bytesToValue(T, data[0..@sizeOf(T)]);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn strToFixed(comptime N: usize, s: []const u8) [N]u8 {
    var buf: [N]u8 = std.mem.zeroes([N]u8);
    const len = @min(s.len, N);
    @memcpy(buf[0..len], s[0..len]);
    return buf;
}

pub fn fixedToSlice(buf: []const u8) []const u8 {
    return std.mem.sliceTo(buf, 0);
}

pub fn bitsetSet(bs: *[LOG_BITSET_WORDS]u64, bit: usize) void {
    std.debug.assert(bit < LOG_BITSET_BITS);
    bs[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
}

pub fn bitsetGet(bs: *const [LOG_BITSET_WORDS]u64, bit: usize) bool {
    std.debug.assert(bit < LOG_BITSET_BITS);
    return (bs[bit / 64] >> @intCast(bit % 64)) & 1 == 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "serialize/deserialize round-trip" {
    var buf: [4096]u8 = undefined;
    const msg = Message{ .prepare_ok = .{
        .view_number = 7,
        .op_number = 42,
        .replica_id = 2,
        .commit_min = 11,
    } };
    const len = serialize(msg, &buf);
    const decoded = try deserialize(buf[0..len]);
    try std.testing.expectEqual(decoded.prepare_ok.view_number, 7);
    try std.testing.expectEqual(decoded.prepare_ok.op_number, 42);
    try std.testing.expectEqual(decoded.prepare_ok.replica_id, 2);
    try std.testing.expectEqual(decoded.prepare_ok.commit_min, 11);
}

test "deserialize rejects unknown tag" {
    const buf = [_]u8{0xFF};
    try std.testing.expectError(error.InvalidMessageTag, deserialize(&buf));
}

test "deserialize rejects truncated prepare_ok" {
    var buf: [8]u8 = undefined;
    buf[0] = @intFromEnum(Tag.prepare_ok);
    @memset(buf[1..], 0);
    try std.testing.expectError(error.MessageTooShort, deserialize(&buf));
}

test "deserialize rejects oversized DVC log_entry_count" {
    var buf: [1 + @sizeOf(DoViewChangeMsg)]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = @intFromEnum(Tag.do_view_change);
    const count_off = 1 + @offsetOf(DoViewChangeMsg, "log_entry_count");
    buf[count_off] = @as(u8, DVC_LOG_MAX) + 1;
    try std.testing.expectError(error.InvalidLogEntryCount, deserialize(&buf));
}

test "deserialize round-trip preserves prepare entry validity" {
    var buf: [16384]u8 = undefined;
    var entry = LogEntry{
        .view_number = 1,
        .op_number = 1,
        .command = .{ .noop = {} },
        .client_id = 9,
        .request_id = 3,
    };
    entry.checksum = entry.computeChecksum();
    try std.testing.expect(entry.valid());

    const prep = Message{ .prepare = .{
        .view_number = 1,
        .op_number = 1,
        .entry = entry,
    } };
    const plen = serialize(prep, &buf);
    const pd = try deserialize(buf[0..plen]);
    try std.testing.expect(pd.prepare.entry.valid());
}

test "strToFixed" {
    const fixed = strToFixed(64, "worker-01");
    try std.testing.expectEqualStrings("worker-01", fixedToSlice(&fixed));
}

test "worker tags stay wire compatible with rust agent" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(WorkerTag.register_ack));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(WorkerTag.start_pod));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(WorkerTag.stop_pod));
    try std.testing.expectEqual(@as(u8, 0x04), @intFromEnum(WorkerTag.run_request));
}

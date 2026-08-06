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
        var u64_wire: [8]u8 = undefined;
        var u128_wire: [16]u8 = undefined;
        std.mem.writeInt(u64, &u64_wire, self.parent_checksum, .little);
        hasher.update(&u64_wire);
        std.mem.writeInt(u64, &u64_wire, self.view_number, .little);
        hasher.update(&u64_wire);
        std.mem.writeInt(u64, &u64_wire, self.op_number, .little);
        hasher.update(&u64_wire);
        var cmd_wire: [COMMAND_CANONICAL_SIZE]u8 = undefined;
        writeCanonicalCommand(&cmd_wire, self.command);
        hasher.update(&cmd_wire);
        std.mem.writeInt(u128, &u128_wire, self.client_id, .little);
        hasher.update(&u128_wire);
        std.mem.writeInt(u128, &u128_wire, self.request_id, .little);
        hasher.update(&u128_wire);
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

fn canonicalSize(comptime T: type) usize {
    if (T == void) return 0;
    if (T == bool) return 1;
    return switch (@typeInfo(T)) {
        .int, .float, .@"enum" => @sizeOf(T),
        .array => |array| array.len * canonicalSize(array.child),
        .@"struct" => blk: {
            var size: usize = 0;
            inline for (std.meta.fields(T)) |field| size += canonicalSize(field.type);
            break :blk size;
        },
        else => @compileError("unsupported canonical command field type"),
    };
}

/// Stable tag-first little-endian Command size, independent of struct padding/ABI.
pub const COMMAND_CANONICAL_SIZE: usize = blk: {
    var max: usize = 0;
    for (@typeInfo(Command).@"union".fields) |field| {
        max = @max(max, canonicalSize(field.type));
    }
    break :blk 1 + max;
};

fn enumFromIntChecked(comptime E: type, value: @typeInfo(E).@"enum".tag_type) !E {
    inline for (@typeInfo(E).@"enum".fields) |field| {
        if (value == field.value) return @enumFromInt(value);
    }
    return error.InvalidEnumTag;
}

fn writeCanonicalValue(comptime T: type, dst: []u8, value: T) usize {
    const size = canonicalSize(T);
    std.debug.assert(dst.len >= size);
    if (T == void) return 0;
    if (T == bool) {
        dst[0] = if (value) 1 else 0;
        return 1;
    }
    switch (@typeInfo(T)) {
        .int => std.mem.writeInt(T, dst[0..@sizeOf(T)], value, .little),
        .float => {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            std.mem.writeInt(Int, dst[0..@sizeOf(T)], @bitCast(value), .little);
        },
        .@"enum" => {
            const TagInt = @typeInfo(T).@"enum".tag_type;
            std.mem.writeInt(TagInt, dst[0..@sizeOf(TagInt)], @intFromEnum(value), .little);
        },
        .array => |array| {
            var pos: usize = 0;
            for (value) |element| pos += writeCanonicalValue(array.child, dst[pos..], element);
            std.debug.assert(pos == size);
        },
        .@"struct" => {
            var pos: usize = 0;
            inline for (std.meta.fields(T)) |field| {
                pos += writeCanonicalValue(field.type, dst[pos..], @field(value, field.name));
            }
            std.debug.assert(pos == size);
        },
        else => unreachable,
    }
    return size;
}

fn readCanonicalValue(comptime T: type, src: []const u8) !T {
    const size = canonicalSize(T);
    if (src.len < size) return error.MessageTooShort;
    if (T == void) return {};
    if (T == bool) {
        return switch (src[0]) {
            0 => false,
            1 => true,
            else => error.InvalidBool,
        };
    }
    return switch (@typeInfo(T)) {
        .int => std.mem.readInt(T, src[0..@sizeOf(T)], .little),
        .float => blk: {
            const Int = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(std.mem.readInt(Int, src[0..@sizeOf(Int)], .little));
        },
        .@"enum" => blk: {
            const TagInt = @typeInfo(T).@"enum".tag_type;
            const raw = std.mem.readInt(TagInt, src[0..@sizeOf(TagInt)], .little);
            break :blk try enumFromIntChecked(T, raw);
        },
        .array => |array| blk: {
            var out: T = undefined;
            var pos: usize = 0;
            for (&out) |*element| {
                element.* = try readCanonicalValue(array.child, src[pos..]);
                pos += canonicalSize(array.child);
            }
            break :blk out;
        },
        .@"struct" => blk: {
            var out: T = undefined;
            var pos: usize = 0;
            inline for (std.meta.fields(T)) |field| {
                @field(out, field.name) = try readCanonicalValue(field.type, src[pos..]);
                pos += canonicalSize(field.type);
            }
            break :blk out;
        },
        else => unreachable,
    };
}

pub fn writeCanonicalCommand(dst: []u8, command: Command) void {
    std.debug.assert(dst.len >= COMMAND_CANONICAL_SIZE);
    @memset(dst[0..COMMAND_CANONICAL_SIZE], 0);
    dst[0] = @intFromEnum(std.meta.activeTag(command));
    switch (command) {
        .noop => {},
        inline else => |payload| {
            const written = writeCanonicalValue(@TypeOf(payload), dst[1..], payload);
            std.debug.assert(written <= COMMAND_CANONICAL_SIZE - 1);
        },
    }
}

pub fn readCanonicalCommand(src: []const u8) !Command {
    if (src.len < COMMAND_CANONICAL_SIZE) return error.MessageTooShort;
    const tag = enumFromIntChecked(std.meta.Tag(Command), src[0]) catch return error.InvalidCommandTag;
    switch (tag) {
        inline else => |active_tag| {
            const name = @tagName(active_tag);
            inline for (std.meta.fields(Command)) |field| {
                if (std.mem.eql(u8, field.name, name)) {
                    const payload = try readCanonicalValue(field.type, src[1..]);
                    return @unionInit(Command, field.name, payload);
                }
            }
            return error.InvalidCommandTag;
        },
    }
}

pub fn serialize(msg: Message, buf: []u8) usize {
    const tag_byte: u8 = @intFromEnum(std.meta.activeTag(msg));
    buf[0] = tag_byte;
    // Field-by-field copy into zeroed buffer to eliminate undefined
    // struct padding that corrupts deserialization in release builds.
    const payload_len = serializePayload(msg, buf[1..]);
    return 1 + payload_len;
}

pub fn deserialize(buf: []const u8) !Message {
    if (buf.len < 1) return error.MessageTooShort;
    const tag: Tag = @enumFromInt(buf[0]);
    const data = buf[1..];
    return switch (tag) {
        .request => .{ .request = bytesAs(RequestMsg, data) },
        .prepare => .{ .prepare = bytesAs(PrepareMsg, data) },
        .prepare_ok => .{ .prepare_ok = bytesAs(PrepareOkMsg, data) },
        .commit => .{ .commit = bytesAs(CommitMsg, data) },
        .reply => .{ .reply = bytesAs(ReplyMsg, data) },
        .start_view_change => .{ .start_view_change = bytesAs(StartViewChangeMsg, data) },
        .do_view_change => .{ .do_view_change = bytesAs(DoViewChangeMsg, data) },
        .start_view => .{ .start_view = bytesAs(StartViewMsg, data) },
        .request_prepare => .{ .request_prepare = bytesAs(RequestPrepareMsg, data) },
        .send_prepare => .{ .send_prepare = bytesAs(SendPrepareMsg, data) },
        .request_status => .{ .request_status = bytesAs(RequestStatusMsg, data) },
        .send_status => .{ .send_status = bytesAs(SendStatusMsg, data) },
    };
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

fn bytesAs(comptime T: type, data: []const u8) T {
    std.debug.assert(data.len >= @sizeOf(T));
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

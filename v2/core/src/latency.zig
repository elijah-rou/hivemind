const std = @import("std");
const builtin = @import("builtin");
const msg = @import("message.zig");

pub const Span = struct {
    component: []const u8 = "core",
    run_id: []const u8 = "",
    scenario: []const u8 = "",
    entity: []const u8 = "",
    deployment_id: u64 = 0,
    pod_id: u64 = 0,
    name: []const u8 = "",
    op: []const u8 = "",
    phase: []const u8 = "",
    start_ms: i64 = 0,
    end_ms: i64 = 0,
    count: u64 = 1,
    source: []const u8 = "core/src",
};

var enabled: bool = false;
var run_id_buf: [64]u8 = std.mem.zeroes([64]u8);
var run_id_len: usize = 0;

pub fn initFromEnv(replica_id: u8) void {
    if (builtin.is_test) return;

    const trace_env = std.c.getenv("HIVEMIND_LATENCY_TRACE") orelse return;
    const trace = std.mem.span(trace_env);
    enabled = std.mem.eql(u8, trace, "1") or
        std.mem.eql(u8, trace, "true") or
        std.mem.eql(u8, trace, "yes") or
        std.mem.eql(u8, trace, "on");
    if (!enabled) return;

    if (std.c.getenv("HIVEMIND_LATENCY_RUN_ID")) |v| {
        setRunId(std.mem.span(v));
    } else if (std.c.getenv("RUN_ID")) |v| {
        setRunId(std.mem.span(v));
    } else {
        const written = std.fmt.bufPrint(&run_id_buf, "replica-{d}", .{replica_id}) catch return;
        run_id_len = written.len;
    }
}

fn setRunId(value: []const u8) void {
    run_id_len = @min(value.len, run_id_buf.len);
    @memcpy(run_id_buf[0..run_id_len], value[0..run_id_len]);
}

pub fn isEnabled() bool {
    return enabled and !builtin.is_test;
}

pub fn fixedName(comptime N: usize, fixed: *const [N]u8) []const u8 {
    return msg.fixedToSlice(fixed);
}

pub fn record(span: Span) void {
    if (!isEnabled()) return;
    const end_ms = if (span.end_ms == 0) span.start_ms else span.end_ms;
    const duration_ms = if (end_ms >= span.start_ms) end_ms - span.start_ms else 0;
    const run_id = if (span.run_id.len > 0) span.run_id else run_id_buf[0..run_id_len];

    std.debug.print(
        "hivemind_latency_span system=hivemind component={s} run_id={s} scenario={s} entity={s} deployment_id={d} pod_id={d} name={s} op={s} phase={s} start_ms={d} end_ms={d} duration_ms={d} count={d} source={s}\n",
        .{
            safe(span.component),
            safe(run_id),
            safe(span.scenario),
            safe(span.entity),
            span.deployment_id,
            span.pod_id,
            safe(span.name),
            safe(span.op),
            safe(span.phase),
            span.start_ms,
            end_ms,
            duration_ms,
            span.count,
            safe(span.source),
        },
    );
}

pub fn commandName(command: msg.Command) []const u8 {
    return switch (command) {
        .register_node => "register_node",
        .deregister_node => "deregister_node",
        .update_node_status => "update_node_status",
        .create_deployment => "create_deployment",
        .bind_pod_to_node => "bind_pod_to_node",
        .update_pod_status => "update_pod_status",
        .scale_deployment => "scale_deployment",
        .unbind_pod => "unbind_pod",
        .set_killswitch => "set_killswitch",
        .noop => "noop",
        .update_deployment => "update_deployment",
        .set_traffic_split => "set_traffic_split",
        .rollback_deployment => "rollback_deployment",
        .delete_deployment => "delete_deployment",
        .pause_deployment => "pause_deployment",
        .resume_deployment => "resume_deployment",
        .bind_pods_to_nodes => "bind_pods_to_nodes",
    };
}

pub fn deploymentId(command: msg.Command) u64 {
    return switch (command) {
        .create_deployment => 0,
        .bind_pod_to_node => 0,
        .bind_pods_to_nodes => 0,
        .update_pod_status => 0,
        .scale_deployment => |cmd| cmd.deployment_id,
        .unbind_pod => 0,
        .set_killswitch => |cmd| cmd.deployment_id,
        .update_deployment => |cmd| cmd.deployment_id,
        .set_traffic_split => |cmd| cmd.deployment_id,
        .rollback_deployment => |cmd| cmd.deployment_id,
        .delete_deployment => |cmd| cmd.deployment_id,
        .pause_deployment => |cmd| cmd.deployment_id,
        .resume_deployment => |cmd| cmd.deployment_id,
        else => 0,
    };
}

pub fn podId(command: msg.Command) u64 {
    return switch (command) {
        .bind_pod_to_node => |cmd| cmd.pod_id,
        .bind_pods_to_nodes => |cmd| if (cmd.count > 0) cmd.bindings[0].pod_id else 0,
        .update_pod_status => |cmd| cmd.pod_id,
        .unbind_pod => |cmd| cmd.pod_id,
        else => 0,
    };
}

pub fn commandNameField(command: msg.Command) []const u8 {
    return switch (command) {
        .create_deployment => |cmd| msg.fixedToSlice(&cmd.name),
        else => "",
    };
}

fn safe(value: []const u8) []const u8 {
    if (value.len == 0) return "-";
    return value;
}

test "latency command helpers extract IDs" {
    const command = msg.Command{ .scale_deployment = .{ .deployment_id = 42, .desired_replicas = 3 } };
    try std.testing.expectEqualStrings("scale_deployment", commandName(command));
    try std.testing.expectEqual(@as(u64, 42), deploymentId(command));
    try std.testing.expectEqual(@as(u64, 0), podId(command));
}

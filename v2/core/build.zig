const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const exe = b.addExecutable(.{ .name = "hivemind", .root_module = exe_mod });
    exe.stack_size = 16 * 1024 * 1024; // 16MB stack for large VRR message handling
    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run hivemind");
    run_step.dependOn(&run_cmd.step);

    // Unit tests (Debug, or whatever -Doptimize= was passed)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Unit tests (ReleaseFast) - catches struct padding UB and other
    // optimization-sensitive bugs that only manifest in release builds.
    const test_mod_release = b.createModule(.{
        .root_source_file = b.path("src/unit_tests.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const unit_tests_release = b.addTest(.{ .root_module = test_mod_release });
    const run_unit_tests_release = b.addRunArtifact(unit_tests_release);

    const test_step = b.step("test", "Run unit tests (Debug + ReleaseFast)");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_unit_tests_release.step);

    // Fuzz: standalone simulation fuzzer binary (always ReleaseFast for throughput)
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    const fuzz_exe = b.addExecutable(.{ .name = "fuzz", .root_module = fuzz_mod });
    fuzz_exe.stack_size = 16 * 1024 * 1024;
    b.installArtifact(fuzz_exe);

    const fuzz_run = b.addRunArtifact(fuzz_exe);
    fuzz_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| fuzz_run.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run fuzz simulation fuzzer");
    fuzz_step.dependOn(&fuzz_run.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tmp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);

    const tool = b.addExecutable(.{
        .name = "torzion",
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zig_cli = b.dependency("zig-cli", .{
        .target = target,
        .optimize = optimize,
    });

    const btp = b.addModule("btp", .{ .root_source_file = .{ .src_path = .{
        .sub_path = "src/protocol.zig",
        .owner = b,
    } } });

    tool.root_module.addImport("zig-cli", zig_cli.module("zig-cli"));
    tool.root_module.addImport("btp", btp);

    b.installArtifact(tool);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // const protocol_unit_tests = b.addTest(.{
    //     .root_source_file = b.path("src/protocol.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });

    // const run_protocol_unit_tests = b.addRunArtifact(protocol_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_unit_tests.root_module.addImport("zig-cli", zig_cli.module("zig-cli"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_protocol_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

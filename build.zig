const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/torzion.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("torzion", lib_mod);
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "torzion",
        .root_module = lib_mod,
    });

    b.installArtifact(lib);
    const exe = b.addExecutable(.{
        .name = "torzion",
        .root_module = exe_mod,
    });

    const zig_cli = b.dependency("cli", .{ .target = target, .optimize = optimize });
    exe_mod.addImport("zig-cli", zig_cli.module("zig-cli"));
    exe_mod.linkLibrary(zig_cli.artifact("zig-cli"));
    lib_mod.addImport("zig-cli", zig_cli.module("zig-cli"));
    lib_mod.linkLibrary(zig_cli.artifact("zig-cli"));

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{ .name = "torzion", .root_module = exe_mod });
    const check = b.step("check", "Check if torzion compiles");
    check.dependOn(&exe_check.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

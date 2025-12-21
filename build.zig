const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    //libaries
    const torzion_mod = b.createModule(.{ .root_source_file = b.path("src/torzion.zig"), .target = target, .optimize = optimize });

    const torzion = b.addLibrary(.{ .linkage = .static, .name = "torzion", .root_module = torzion_mod });
    b.installArtifact(torzion);

    const cli = b.dependency("cli", .{ .target = target, .optimize = optimize });

    // options
    const options = b.addOptions();
    const ignore_invalid_fields = b.option(bool, "ignore_invalid_fields", "") orelse false;
    options.addOption(bool, "ignore_invalid_fields", ignore_invalid_fields);
    torzion.root_module.addOptions("options", options);

    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe_mod.addImport("torzion", torzion_mod);
    exe_mod.addImport("cli", cli.module("cli"));
    exe_mod.linkLibrary(cli.artifact("cli"));

    const exe = b.addExecutable(.{ .name = "torzion", .root_module = exe_mod });
    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{ .name = "torzion", .root_module = exe_mod });
    const check = b.step("check", "Check if torzion compiles");
    check.dependOn(&exe_check.step);

    const lib_unit_tests = b.addTest(.{ .root_module = torzion_mod });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const exe_unit_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

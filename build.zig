const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const version = b.option([]const u8, "version", "Set the build version") orelse "unset";
    options.addOption([]const u8, "version", version);
    // Application modules never compile development hooks (the headless
    // profiling session and Model.assertValid's invariant checks).
    options.addOption(bool, "enable_profile_session", false);

    // The test and profiling modules opt into those hooks with their own
    // option set so shipped binaries never contain them.
    const dev_options = b.addOptions();
    dev_options.addOption([]const u8, "version", version);
    dev_options.addOption(bool, "enable_profile_session", true);

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_module.addImport("vaxis", vaxis.module("vaxis"));
    root_module.addImport("zeit", zeit.module("zeit"));
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zanger",
        .root_module = root_module,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run Zanger");
    run_step.dependOn(&run_cmd.step);

    // Tests compile the same sources with development hooks enabled so
    // Model.assertValid keeps validating every commit boundary.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("vaxis", vaxis.module("vaxis"));
    test_module.addImport("zeit", zeit.module("zeit"));
    test_module.addOptions("build_options", dev_options);

    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    const profile_vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const profile_zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const profile_module = b.createModule(.{
        .root_source_file = b.path("src/profile.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    profile_module.addImport("vaxis", profile_vaxis.module("vaxis"));
    profile_module.addImport("zeit", profile_zeit.module("zeit"));
    profile_module.addOptions("build_options", dev_options);
    const profile_exe = b.addExecutable(.{
        .name = "zanger-profile",
        .root_module = profile_module,
    });

    const run_profile = b.addRunArtifact(profile_exe);
    if (b.args) |args| run_profile.addArgs(args);
    const profile_step = b.step("profile", "Run repeatable performance profiles");
    profile_step.dependOn(&run_profile.step);

    const check_profile = b.addRunArtifact(profile_exe);
    check_profile.addArg("--check");
    if (b.args) |args| check_profile.addArgs(args);
    const profile_check_step = b.step("profile-check", "Check interactive performance budgets");
    profile_check_step.dependOn(&check_profile.step);
}

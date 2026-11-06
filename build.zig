const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit executable debug symbols") orelse false;
    // Offscreen tests save captures here, including on a fresh checkout.
    b.root.createDirPath(b.graph.io, "artifacts") catch |err|
        std.debug.panic("cannot create screenshot directory: {s}", .{@errorName(err)});

    const app_options = b.addOptions();
    app_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const lib = b.addModule("byakugan", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const cli = b.addExecutable(.{
        .name = "byakugan-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .imports = &.{.{ .name = "byakugan", .module = lib }},
        }),
    });
    cli.root_module.addOptions("app_options", app_options);
    b.installArtifact(cli);
    const run_cli = b.addRunArtifact(cli);
    run_cli.addPassthruArgs();
    b.step("run-cli", "Scan a volume from the console").dependOn(&run_cli.step);

    const nanoui_dep = b.dependency("nanoui", .{ .target = target, .optimize = optimize });
    const nanoui = nanoui_dep.module("nanoui");
    const gui = b.addExecutable(.{
        .name = "byakugan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
            .imports = &.{
                .{ .name = "nanoui", .module = nanoui },
                .{ .name = "byakugan", .module = lib },
            },
        }),
    });
    gui.root_module.addOptions("app_options", app_options);
    if (target.result.os.tag == .windows)
        gui.root_module.addWin32ResourceFile(.{ .file = b.path("src/assets/byakugan.rc") });
    gui.subsystem = .windows;
    b.installArtifact(gui);
    const run_gui = b.addRunArtifact(gui);
    run_gui.addPassthruArgs();
    b.step("run", "Open the byakugan window").dependOn(&run_gui.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test-pure", "Parser, scan, model and treemap tests").dependOn(&run_tests.step);

    const view_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests_view.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "nanoui", .module = nanoui },
            .{ .name = "byakugan", .module = lib },
        },
    });
    const view_tests = b.addTest(.{ .root_module = view_test_mod });
    if (target.result.os.tag == .windows)
        view_tests.root_module.addWin32ResourceFile(.{ .file = b.path("src/assets/byakugan.rc") });
    const run_view_tests = b.addRunArtifact(view_tests);
    b.step("test-ui", "Headless window interaction tests").dependOn(&run_view_tests.step);

    const chrome_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/win_frame.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    if (target.result.os.tag == .windows)
        chrome_tests.root_module.addWin32ResourceFile(.{ .file = b.path("src/assets/byakugan.rc") });
    const run_chrome_tests = b.addRunArtifact(chrome_tests);
    b.step("test-chrome", "Hidden Win32 frame and offscreen caption regressions").dependOn(&run_chrome_tests.step);

    const log_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests_log.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    const run_log_tests = b.addRunArtifact(log_tests);
    b.step("test-log", "Bounded diagnostic log regressions").dependOn(&run_log_tests.step);

    const test_step = b.step("test", "Run every test suite");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_view_tests.step);
    test_step.dependOn(&run_chrome_tests.step);
    test_step.dependOn(&run_log_tests.step);
}

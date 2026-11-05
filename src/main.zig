//! byakugan: the window. The console scanner lives in cli.zig and is a
//! separate artifact, so progress and accounting exist without a display.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").State;
const typeface = @import("typeface.zig");
const explorer = @import("explorer.zig");
const log = @import("log.zig");
const builtin = @import("builtin");

pub const std_options: std.Options = .{ .log_level = .info, .logFn = log.stdLog };

pub fn main(init: std.process.Init) !void {
    log.init(init);
    defer {
        log.info("shutdown complete", .{});
        log.deinit();
    }
    log.info("startup version={s} build={s} os={s} arch={s}", .{
        @import("app_options").version, @tagName(builtin.mode), @tagName(builtin.os.tag), @tagName(builtin.cpu.arch),
    });
    if (@import("byakugan").volume.elevation.isElevated()) |elevated| {
        log.info("startup token elevated={}", .{elevated});
    } else |err| log.warn("startup token query failed: {t}", .{err});
    run(init) catch |err| {
        log.err("application failed: {t}", .{err});
        return err;
    };
}

fn run(init: std.process.Init) !void {
    try typeface.register();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (@import("normal_launch.zig").requested(args) and try @import("byakugan").volume.elevation.isElevated()) {
        log.err("normal reopen rejected elevated child before window creation", .{});
        return error.NormalSessionRequired;
    }
    var state = App.init(init.gpa, init.io);
    defer state.deinit();

    const app = try nanoui.App.create(init, .{ .name = "byakugan" });
    defer app.destroy();
    state.app = app;
    state.window = try app.newWindow(.{
        .title = "byakugan — MFT disk analyzer",
        .width = 1440,
        .height = 1000,
        .min_width = 900,
        .min_height = 600,
        .title_bar = .hidden,
        .visible = false,
        .theme = explorer.palette(if (app.flags.snapshot != null) app.flags.dark else nanoui.isDark()),
        .content = .{ .view = .init(&state, App.view) },
    });
    if (comptime @import("builtin").os.tag == .windows) {
        const frame = @import("win_frame.zig");
        if (state.window.?.surface) |surface| frame.setContext(&surface.ctx);
        frame.install(state.window.?.hwnd);
    }
    state.begin(args);
    if (state.close_child) {
        log.warn("startup handoff rejected; exiting before show", .{});
        return;
    }
    if (!app.flags.hidden) state.window.?.show();
    log.info("event loop starting hidden={}", .{app.flags.hidden});
    app.run() catch |err| {
        log.err("event loop failed: {t}", .{err});
        return err;
    };
    log.info("event loop stopped", .{});
}

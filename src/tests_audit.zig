//! Whole-app usability regressions; no desktop input or filesystem actions.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").State;
const model = @import("byakugan").model;

fn init(t: *ui.Tester, s: *App, dark: bool) !void {
    try @import("typeface.zig").register();
    try t.init(std.testing.allocator, .init(s, App.view), .{ .width = 900, .height = 600, .scale = 1, .theme = @import("explorer.zig").palette(dark) });
    for (0..4) |_| t.frame();
    t.settle(1);
}
fn find(s: *App, name: []const u8) !u32 {
    for (s.model.?.nodes, 0..) |_, i| if (std.mem.eql(u8, s.model.?.name(@intCast(i)), name)) return @intCast(i);
    return error.NodeNotFound;
}
fn control(t: *ui.Tester, label: []const u8) !u32 {
    for (t.ctx.nodes.items) |n| if (n.content == .text and std.mem.eql(u8, n.content.text.str, label)) return n.parent;
    return error.ControlNotFound;
}
fn bounded(t: *ui.Tester, label: []const u8) !void {
    const r = t.ctx.nodes.items[try control(t, label)].rect;
    try std.testing.expect(r.x >= 0 and r.y >= 0 and r.x + r.w <= t.size.w and r.y + r.h <= t.size.h);
}
fn tabTo(t: *ui.Tester, label: []const u8) !void {
    const id = t.ctx.nodes.items[try control(t, label)].id;
    for (0..40) |_| {
        t.key(.tab);
        if (t.ctx.focus == id) return;
    }
    std.debug.print("not keyboard reachable: {s}\n", .{label});
    return error.UnreachableControl;
}

test "navigation controls work from keyboard and pointer selection restores arrow browsing" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    s.setFocus(try find(&s, "Games"));
    var t: ui.Tester = undefined;
    try init(&t, &s, false);
    defer t.deinit();
    try tabTo(&t, "Up");
    t.key(.enter);
    try std.testing.expectEqual(s.model.?.root, s.focus);
    try tabTo(&t, "Logical");
    t.key(.enter);
    try std.testing.expect(!s.metric_allocated);
    _ = t.shortcut(.{ .ctrl = true, .key = 'f' });
    t.typeText("Games");
    t.frame();
    try tabTo(&t, "Clear");
    t.key(.enter);
    try std.testing.expectEqualStrings("", s.filter_buf.text());
    s.setFocus(try find(&s, "Games"));
    t.frame();
    try tabTo(&t, "C:\\");
    t.key(.enter);
    try std.testing.expectEqual(s.model.?.root, s.focus);
    t.key(.down);
    t.key(.down);
    try std.testing.expectEqual(s.entries.items[1], s.selected);
    try t.screenshot("artifacts/ui-audit-keyboard.png");
}

test "long confirmation keeps both actions on screen with full path accessible" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    s.cleanup.phase = .confirm;
    s.cleanup.open = true;
    s.cleanup.instant_confirmation = true;
    s.cleanup.focus_cancel = true;
    s.cleanup.path_len = 0;
    for (0..75) |_| {
        const part = "Long folder name with spaces and details\\";
        @memcpy(s.cleanup.path_buf[s.cleanup.path_len..][0..part.len], part);
        s.cleanup.path_len += part.len;
    }
    const name = "Large archive.zip";
    @memcpy(s.cleanup.path_buf[s.cleanup.path_len..][0..name.len], name);
    s.cleanup.path_len += name.len;
    var t: ui.Tester = undefined;
    try init(&t, &s, true);
    defer t.deinit();
    try bounded(&t, "Cancel");
    try bounded(&t, "Move to Recycle Bin");
    try std.testing.expect(t.findText("Move file to Recycle Bin?").?.y >= 16);
    try t.screenshot("artifacts/ui-audit-long-confirm.png");
    const before = t.findText(name).?;
    t.key(.page_down);
    try std.testing.expect(t.findText(name).?.y < before.y);
    try bounded(&t, "Cancel");
    t.key(.enter);
    try std.testing.expect(!s.cleanup.open and s.cleanup.work == null);
}

test "expanded location chooser stays positioned on first layout and keyboard dismissal is immediate" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{});
    s.drives = (1 << 26) - 1;
    var t: ui.Tester = undefined;
    try init(&t, &s, false);
    defer t.deinit();
    try t.clickText("C: drive");
    const initial = t.findText("Choose a location").?;
    t.settle(1);
    try std.testing.expectEqual(initial, t.findText("Choose a location").?);
    try bounded(&t, "Close");
    try bounded(&t, "Z:");
    var accessible: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, t.ctx.arena.allocator(), &accessible);
    var browse_accessible = false;
    for (accessible.items) |item| {
        try std.testing.expect(!std.mem.eql(u8, item.label, "Choose location"));
        if (std.mem.eql(u8, item.label, "Browse for folder…")) browse_accessible = true;
    }
    try std.testing.expect(browse_accessible);
    try t.screenshot("artifacts/ui-audit-chooser.png");
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!s.location_open and !s.location_visible);
}

test "retained-result failures and notices leave actions and a content row visible" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    var t: ui.Tester = undefined;
    try init(&t, &s, true);
    defer t.deinit();
    s.failure = .access;
    s.elevation_error = error.TimedOut;
    t.frame();
    t.settle(1);
    try bounded(&t, "Restart as administrator");
    try t.screenshot("artifacts/ui-audit-retained-error.png");
    s.elevation_error = error.AlreadyElevated;
    t.frame();
    try std.testing.expect(!t.hasText("Restart as administrator"));
    s.failure = .none;
    s.elevation_error = null;
    s.cleanup.phase = .result;
    s.cleanup.message = "Windows could not confirm that recycling completed. Changes may have occurred. Inspect the original location and Recycle Bin before retrying.";
    t.frame();
    t.settle(1);
    const heading = t.findText("Folder contents").?;
    try std.testing.expect(heading.y + heading.h + 46 <= 600 - 52);
    try t.screenshot("artifacts/ui-audit-notice.png");
    s.failure = .folder_missing;
    t.frame();
    t.settle(1);
    const both = t.findText("Folder contents").?;
    try std.testing.expect(both.y + both.h + 46 <= 600 - 52);
    try bounded(&t, "Move to Recycle Bin…");
    try t.screenshot("artifacts/ui-audit-combined-notices.png");
}

test "scan cancel acknowledges immediately and app state gallery stays bounded" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    var t: ui.Tester = undefined;
    try init(&t, &s, false);
    defer t.deinit();
    // Render a controlled in-flight worker; never spawn it or join it.
    var job: @import("app.zig").Job = .{ .id = 1, .started = 0, .letter = 'C' };
    s.job = &job;
    defer s.job = null;
    job.total.store(10000, .release);
    job.bytes.store(3500, .release);
    job.records.store(1234, .release);
    t.frame();
    try t.clickText("Cancel scan");
    try std.testing.expect(job.cancel.load(.acquire));
    try std.testing.expect(t.hasText("Cancelling…") and !t.hasText("Cancel scan"));
    try std.testing.expect(t.hasText("Cancelling scan… waiting for the current read to stop."));
    try std.testing.expect(!t.hasText("Scanning… your map will appear when the scan finishes."));
    try t.screenshot("artifacts/ui-audit-cancelling.png");
    s.job = null;
    for ([_]bool{ false, true }) |dark| {
        t.theme = @import("explorer.zig").palette(dark);
        for ([_]@import("app.zig").Failure{ .none, .access, .geometry, .folder_access, .folder_missing, .picker, .start, .cancelled }) |failure| {
            s.failure = failure;
            t.frame();
            t.settle(1);
            try bounded(&t, "Choose location");
            try t.screenshot(t.ctx.print("artifacts/ui-audit-empty-{s}-{s}.png", .{ @tagName(failure), if (dark) "dark" else "light" }));
        }
    }
    s.begin(&.{"--demo"});
    for ([_]ui.Size{ .{ .w = 900, .h = 600 }, .{ .w = 1440, .h = 1000 } }) |size| {
        t.resize(size.w, size.h);
        for ([_]bool{ false, true }) |dark| {
            t.theme = @import("explorer.zig").palette(dark);
            t.frame();
            t.settle(1);
            try bounded(&t, "Logical");
            try bounded(&t, "Move to Recycle Bin…");
            try t.screenshot(t.ctx.print("artifacts/ui-audit-result-{d:.0}-{s}.png", .{ size.w, if (dark) "dark" else "light" }));
        }
    }
    t.resize(900, 600);
    _ = t.shortcut(.{ .ctrl = true, .key = 'f' });
    t.typeText("no such child exists");
    t.frame();
    try std.testing.expect(t.hasText("No matching direct children"));
    try bounded(&t, "Clear");
    try t.screenshot("artifacts/ui-audit-no-results.png");
}

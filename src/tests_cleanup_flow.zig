//! Cleanup interactions without a desktop window or a real recycle operation.
const std = @import("std");
const ui = @import("nanoui").ui;
const by = @import("byakugan");
const App = @import("app.zig").State;

fn find(m: *by.model.Model, name: []const u8) !u32 {
    for (m.nodes, 0..) |_, i| if (std.mem.eql(u8, m.name(@intCast(i)), name)) return @intCast(i);
    return error.NodeNotFound;
}
fn initTester(t: *ui.Tester, s: *App) !void {
    try @import("typeface.zig").register();
    try t.init(std.testing.allocator, .init(s, App.view), .{ .width = 900, .height = 600, .scale = 1, .theme = @import("explorer.zig").palette(false) });
    t.settle(1);
}
fn waitScan(t: *ui.Tester, s: *App) !void {
    for (0..200) |_| {
        t.frame();
        if (s.job == null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(s.job == null and s.failure == .none);
    t.settle(1);
}
fn rowRect(t: *ui.Tester, label: []const u8) !ui.Rect {
    for (t.ctx.nodes.items) |n| {
        if (n.content == .text and std.mem.eql(u8, n.content.text.str, label) and n.rect.x > 600 and n.rect.y > 450 and n.rect.y < 560) return n.rect;
    }
    return error.RowNotVisible;
}

fn visibleControl(t: *ui.Tester, label: []const u8) !ui.Rect {
    for (t.ctx.nodes.items) |n| {
        if (n.content != .text or !std.mem.eql(u8, n.content.text.str, label)) continue;
        const control = t.ctx.nodes.items[n.parent];
        var parent = control.parent;
        while (parent != std.math.maxInt(u32)) : (parent = t.ctx.nodes.items[parent].parent) {
            const box = t.ctx.nodes.items[parent];
            if (!box.style.clip and !box.style.scroll) continue;
            if (control.rect.y + control.rect.h > box.rect.y + box.rect.h + 0.5) {
                std.debug.print("clipped control '{s}': bottom={d}, clip bottom={d}\n", .{ label, control.rect.y + control.rect.h, box.rect.y + box.rect.h });
                return error.ControlClipped;
            }
            try std.testing.expect(control.rect.y >= box.rect.y - 0.5);
        }
        return control.rect;
    }
    return error.ControlNotFound;
}

test "inspector keeps complete action hit targets visible for folders and hard-linked files" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    var t: ui.Tester = undefined;
    try initTester(&t, &s);
    defer t.deinit();
    for ([_]ui.Size{ .{ .w = 900, .h = 600 }, .{ .w = 1440, .h = 1000 } }) |size| {
        t.resize(size.w, size.h);
        for ([_]bool{ false, true }) |dark| {
            t.theme = @import("explorer.zig").palette(dark);
            for ([_][]const u8{ "Games", "shared-plan.pdf" }) |name| {
                s.select(try find(s.model.?, name));
                t.frame();
                t.settle(1);
                _ = try visibleControl(&t, "Move to Recycle Bin…");
                _ = try visibleControl(&t, "More…");
                try t.screenshot(t.ctx.print("artifacts/ui-inspector-{s}-{s}-{d:.0}.png", .{ name, if (dark) "dark" else "light", size.w }));
            }
        }
    }
    // Inline errors reduce the available height; actions must still fit.
    t.resize(900, 600);
    s.cleanup.phase = .result;
    s.cleanup.message = "Windows could not confirm that recycling completed. Changes may have occurred. Inspect the original location and Recycle Bin before retrying.";
    t.frame();
    t.settle(1);
    const action = try visibleControl(&t, "Move to Recycle Bin…");
    const path = t.findText("1 extra hard link") orelse return error.TextNotFound;
    t.scroll(path.x + 10, action.y - 70, -200);
    t.frame();
    const after = try visibleControl(&t, "Move to Recycle Bin…");
    try std.testing.expectEqual(action.y, after.y);
    try std.testing.expect(t.findText("1 extra hard link").?.y < path.y);
    for (t.ctx.nodes.items) |n| {
        if (n.content != .text) continue;
        if (!std.mem.eql(u8, n.content.text.str, "1 extra hard link") and !std.mem.startsWith(u8, n.content.text.str, "also: ")) continue;
        const summary = t.ctx.nodes.items[n.parent];
        try std.testing.expect(n.rect.y >= summary.rect.y and n.rect.y + n.rect.h <= summary.rect.y + summary.rect.h);
    }
    try t.screenshot("artifacts/ui-inspector-details-scroll.png");
}

test "right click targets rows and tiles; Delete confirms and Enter cancels" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "first.bin", .data = "first" });
    try tmp.dir.writeFile(io, .{ .sub_path = "second.bin", .data = "second is larger" });
    var path: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path);
    var s = App.init(std.testing.allocator, io);
    defer s.deinit();
    s.startFolderScan(path[0..len]);
    var t: ui.Tester = undefined;
    try initTester(&t, &s);
    defer t.deinit();
    try waitScan(&t, &s);
    const root = s.model.?.root;
    const first = try find(s.model.?, "first.bin");
    const second = try find(s.model.?, "second.bin");
    s.selectInspector(first);
    t.frame();
    t.settle(1);
    const row = try rowRect(&t, "second.bin");
    t.secondaryClick(row.x + 5, row.y + 5); // native Win32 secondary event
    const menu_initial = t.findText("Copy path").?;
    t.settle(1);
    try std.testing.expectEqual(menu_initial, t.findText("Copy path").?);
    try std.testing.expectEqual(second, s.selected);
    try std.testing.expectEqual(root, s.focus);
    try std.testing.expect(s.cleanup.open and s.cleanup.phase == .actions);
    try std.testing.expect(std.mem.endsWith(u8, s.cleanup.path(), "\\second.bin"));
    try t.screenshot("artifacts/ui-recycle-context-light.png");
    t.key(.down);
    t.key(.enter); // menu's recycle action opens the same confirmation
    try std.testing.expect(s.cleanup.open and s.cleanup.phase == .confirm);
    const initial = t.findText("Move file to Recycle Bin?").?;
    t.settle(1);
    try std.testing.expectEqual(initial, t.findText("Move file to Recycle Bin?").?);
    try std.testing.expect(s.cleanup.work == null);
    try t.screenshot("artifacts/ui-recycle-confirm-light.png");
    t.key(.enter); // focused Cancel, never delete by default
    t.settle(1);
    try std.testing.expect(!s.cleanup.modal() and s.cleanup.work == null);
    t.key(.delete);
    t.settle(1);
    try std.testing.expect(s.cleanup.phase == .confirm and s.cleanup.open);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!s.cleanup.modal()); // keyboard dismissal has no exit wait
    t.key(.delete);
    try std.testing.expect(s.cleanup.open and s.cleanup.work == null);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.settle(1);
    // Outside dismissal consumes the click, so it cannot activate Refresh.
    try t.clickText("More…");
    t.settle(1);
    try t.clickText("Refresh");
    t.settle(1);
    try std.testing.expect(!s.cleanup.modal() and s.job == null);
    // A physical right button selects the actual map tile, not the old row.
    var clicked = false;
    for (s.tiles.items) |tile| {
        if (tile.node != first) continue;
        for (t.ctx.nodes.items) |n| {
            if (n.style.absolute and @abs(n.rect.w - tile.rect.w) < 0.1 and @abs(n.rect.h - tile.rect.h) < 0.1) {
                t.rightClick(n.rect.x + 10, n.rect.y + 10);
                clicked = true;
                break;
            }
        }
        break;
    }
    try std.testing.expect(clicked);
    t.settle(1);
    try std.testing.expectEqual(first, s.selected);
    try std.testing.expectEqual(root, s.focus);
    try t.clickText("Copy path");
    t.settle(1);
    try std.testing.expect(std.mem.endsWith(u8, t.clipboard.items, "\\first.bin"));
    try std.testing.expect(!s.cleanup.modal());
    // Delete in a text field edits text; it cannot open a confirmation.
    _ = t.shortcut(.{ .ctrl = true, .key = 'f' });
    t.typeText("first");
    t.key(.delete);
    try std.testing.expect(!s.cleanup.modal() and s.cleanup.work == null);
    try tmp.dir.access(io, "first.bin", .{});
    try tmp.dir.access(io, "second.bin", .{});
}

test "refresh preserves nested path filter and scroll and selects next surviving sibling" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/Nested");
    const data: [64]u8 = @splat('x');
    for (0..40) |i| {
        var name: [100]u8 = undefined;
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&name, "root/Nested/entry{d:0>2}.bin", .{i}), .data = data[0 .. i + 1] });
    }
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}\\root", .{buf[0..len]});
    defer std.testing.allocator.free(path);
    var s = App.init(std.testing.allocator, io);
    defer s.deinit();
    s.metric_allocated = false;
    s.startFolderScan(path);
    var t: ui.Tester = undefined;
    try initTester(&t, &s);
    defer t.deinit();
    try waitScan(&t, &s);
    s.setFocus(try find(s.model.?, "Nested"));
    t.frame();
    _ = t.shortcut(.{ .ctrl = true, .key = 'f' });
    t.typeText("entry");
    s.selectInspector(try find(s.model.?, "entry20.bin"));
    s.scroll_to = 19 * 46;
    t.frame();
    t.settle(1);
    const offset = s.inspector_scroll;
    try std.testing.expect(offset > 0);
    // Move the fixture outside the scanned root; do not touch Recycle Bin.
    try tmp.dir.rename("root/Nested/entry20.bin", tmp.dir, "retained.bin", io);
    s.rescan();
    try waitScan(&t, &s);
    try std.testing.expectEqualStrings("Nested", s.model.?.name(s.focus));
    try std.testing.expectEqualStrings("Nested", s.model.?.name(s.inspector_parent));
    try std.testing.expectEqualStrings("entry19.bin", s.model.?.name(s.selected));
    try std.testing.expectEqualStrings("entry", s.filter_buf.text());
    try std.testing.expectEqual(offset, s.inspector_scroll);
    try std.testing.expect(s.browsing_inspector);
    // A removed current folder falls back to its nearest surviving ancestor.
    try tmp.dir.rename("root/Nested", tmp.dir, "retained-folder", io);
    s.rescan();
    try waitScan(&t, &s);
    try std.testing.expectEqual(s.model.?.root, s.focus);
    try std.testing.expectEqual(s.model.?.root, s.selected);
    // Choosing another source resets the old filter and browsing context.
    s.startFolderScan(buf[0..len]);
    try waitScan(&t, &s);
    try std.testing.expectEqualStrings("", s.filter_buf.text());
    try std.testing.expectEqual(s.model.?.root, s.focus);
    try tmp.dir.access(io, "retained.bin", .{});
}

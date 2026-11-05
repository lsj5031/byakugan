//! Public interactions, driven offscreen: no windows or real input devices.
const std = @import("std");
const ui = @import("nanoui").ui;
const App = @import("app.zig").State;
const explorer = @import("explorer.zig");
const typeface = @import("typeface.zig");
const model = @import("byakugan").model;

test {
    _ = @import("tests_cleanup_flow.zig");
    _ = @import("tests_audit.zig");
}

fn findNode(m: *model.Model, name: []const u8) u32 {
    for (m.nodes, 0..) |_, i| if (std.mem.eql(u8, m.name(@intCast(i)), name)) return @intCast(i);
    return model.none;
}
fn tester(t: *ui.Tester, s: *App, width: f32, height: f32, dark: bool) !void {
    try typeface.register();
    try t.init(std.testing.allocator, .init(s, App.view), .{ .width = width, .height = height, .scale = 1, .theme = explorer.palette(dark) });
    for (0..4) |_| t.frame();
}
fn clickMap(t: *ui.Tester, s: *App, node: u32) !void {
    // The map's canvas is the tile controls' common parent. Click the
    // header so nested children do not intercept their parent's selection.
    for (s.tiles.items) |tile| {
        if (tile.node != node) continue;
        for (t.ctx.nodes.items) |n| {
            if (n.style.width == .px and @abs(n.rect.w - tile.rect.w) < 0.1 and @abs(n.rect.h - tile.rect.h) < 0.1 and n.style.absolute) {
                t.click(n.rect.x + @min(20, n.rect.w / 2), n.rect.y + @min(14, n.rect.h / 2));
                return;
            }
        }
    }
    return error.TileNotFound;
}
fn visibleText(t: *ui.Tester, name: []const u8) !ui.Rect {
    const r = t.findText(name) orelse return error.TextNotFound;
    try std.testing.expect(r.x >= 0 and r.y >= 0 and r.w > 0 and r.h > 0);
    try std.testing.expect(r.x + r.w <= t.size.w + 1 and r.y + r.h <= t.size.h + 1);
    return r;
}

test "map selects without navigating; explicit explore, breadcrumbs, metric and keyboard" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    var t: ui.Tester = undefined;
    try tester(&t, &s, 1440, 1000, false);
    defer t.deinit();
    const m = s.model.?;
    const games = findNode(m, "Games");
    try clickMap(&t, &s, games);
    try std.testing.expectEqual(games, s.selected);
    try std.testing.expectEqual(m.root, s.focus);
    try std.testing.expect(t.hasText("Explore folder"));
    try t.screenshot("artifacts/ui-desktop.png");
    try t.clickText("Explore folder");
    try std.testing.expectEqual(games, s.focus);
    try std.testing.expect(t.containsText("C:\\Games"));
    try t.clickText("Up");
    try std.testing.expectEqual(m.root, s.focus);
    const map_header = try visibleText(&t, "Games");
    t.doubleClick(map_header.x + 10, map_header.y + map_header.h / 2);
    try std.testing.expectEqual(games, s.focus);
    try t.clickText("C:\\");
    try std.testing.expectEqual(m.root, s.focus);
    // The inspector's first row is Games. A real doubleClick first
    // selects it, then clicks the same coordinates a second time.
    var inspector_row: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .text => |tx| if (std.mem.eql(u8, tx.str, "Games") and n.rect.x > 1000 and n.rect.y > 450) {
            inspector_row = n.rect;
        },
        else => {},
    };
    try std.testing.expect(inspector_row != null);
    const row = inspector_row.?;
    t.doubleClick(row.x + 10, row.y + row.h / 2);
    try std.testing.expectEqual(games, s.focus);
    try t.clickText("Up");
    try t.clickText("Logical");
    try std.testing.expect(!s.metric_allocated);
    try t.clickText("Allocated");
    try std.testing.expect(s.metric_allocated);
    t.key(.down);
    try std.testing.expectEqual(s.entries.items[0], s.selected);
    t.key(.down);
    try std.testing.expectEqual(s.entries.items[1], s.selected);
    t.key(.enter);
    try std.testing.expectEqual(s.selected, s.focus);
    t.key(.escape);
    try std.testing.expectEqual(m.root, s.focus);
    t.key(.up);
    try std.testing.expectEqual(s.entries.items[s.entries.items.len - 1], s.selected);
}

test "filter is direct-child scoped across map and inspector, with empty results" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    // Click and type into the public field, using its placeholder's rect.
    try t.clickText("Filter this folder’s direct children");
    t.typeText("gAmEs");
    t.frame();
    try std.testing.expectEqual(@as(usize, 1), s.entries.items.len);
    try std.testing.expectEqualStrings("Games", s.model.?.name(s.selected));
    for (s.tiles.items) |tile| if (tile.depth == 0) try std.testing.expectEqual(s.selected, tile.node);
    try std.testing.expect(!t.hasText("Windows"));
    try t.screenshot("artifacts/ui-filter.png");
    try t.clickText("Clear");
    try t.clickText("Filter this folder’s direct children");
    t.typeText("ntoskrnl");
    t.frame();
    try std.testing.expectEqual(@as(usize, 0), s.entries.items.len);
    try std.testing.expect(t.hasText("No matching direct children"));
    try std.testing.expect(t.hasText("No selection matches this filter."));
    try std.testing.expect(t.hasText("Try another name or clear the filter."));
    try std.testing.expect(!t.hasText("Empty and zero-byte entries are available in the inspector."));
}

test "Other reveals every remaining entry including zero bytes and excludes synthetic counts" {
    var b = try model.Builder.init(std.testing.allocator, 610);
    defer b.deinit();
    _ = try b.addRecord(5, 1, 5, 1, "root", true, 0, 0);
    for (0..600) |i| {
        var buf: [32]u8 = undefined;
        _ = try b.addRecord(@intCast(6 + i), 1, 5, 1, try std.fmt.bufPrint(&buf, "f{d:0>3}.bin", .{i}), false, if (i == 599) 0 else 601 - i, if (i == 599) 0 else 601 - i);
    }
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.install(try b.finish());
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 600), s.files);
    try std.testing.expectEqual(@as(usize, 0), s.folders);
    try clickMap(&t, &s, model.none);
    try std.testing.expect(t.hasText("Browse remaining entries"));
    try std.testing.expectEqual(@as(usize, 569), s.inspector_entries.items.len);
    var found_zero = false;
    for (s.inspector_entries.items) |idx| {
        if (std.mem.eql(u8, s.model.?.name(idx), "f599.bin")) found_zero = true;
    }
    try std.testing.expect(found_zero);
    const first = s.inspector_entries.items[0];
    const second = s.inspector_entries.items[1];
    try t.clickText(s.model.?.name(first));
    try std.testing.expectEqual(first, s.selected);
    t.key(.down);
    try std.testing.expectEqual(second, s.selected);
    try std.testing.expect(t.hasText("Browse remaining entries"));
}

test "minimum window and dark inspector retain controls and hardlink details" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, true);
    defer t.deinit();
    _ = try visibleText(&t, "Choose location");
    _ = try visibleText(&t, "Allocated");
    _ = try visibleText(&t, "Folder contents");
    _ = try visibleText(&t, "Games");
    try t.screenshot("artifacts/ui-dark-minimum.png");
    const m = s.model.?;
    // Navigate through public folder actions to the shared file's parent.
    const file = findNode(m, "shared-plan.pdf");
    const parent = m.nodes[file].parent;
    s.setFocus(parent);
    t.frame();
    try t.clickText("shared-plan.pdf");
    try std.testing.expect(t.containsText("1 extra hard link"));
    try std.testing.expect(t.containsText("also: byakugan-plan-copy.pdf"));
    try t.screenshot("artifacts/ui-hardlink.png");
    const selected = s.selected;
    // Errors opening the picker or starting a worker are also visible when
    // a result already exists; neither changes the map or its selection.
    s.failure = .picker;
    t.frame();
    _ = try visibleText(&t, "Folder picker could not open; previous scan retained");
    _ = try visibleText(&t, "Choose location");
    try std.testing.expectEqual(selected, s.selected);
    s.failure = .start;
    t.frame();
    _ = try visibleText(&t, "Scan could not start; previous scan retained");
    try std.testing.expectEqual(selected, s.selected);
    try t.screenshot("artifacts/ui-start-failed.png");
}

test "ordinary launch offers location selection without scanning at minimum width" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{});
    try std.testing.expect(s.model == null and s.job == null);
    s.drives = (1 << 26) - 1;
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    t.settle(1);
    _ = try visibleText(&t, "Choose a location");
    _ = try visibleText(&t, "Browse for folder…");
    _ = try visibleText(&t, "Scan drive");
    _ = try visibleText(&t, "Close");
    try std.testing.expect(!t.hasText("Refresh"));
    try std.testing.expect(!t.hasText("Rescan"));
    try t.screenshot("artifacts/ui-location-start.png");
    t.key(.tab);
    t.key(.tab);
    t.ctx.input.shortcut = .{ .key = ui.Shortcut.enter };
    t.key(.enter);
    try std.testing.expect(s.location_drives_open);
    t.settle(1);
    for ('A'..'Z' + 1) |letter| {
        const label: [2]u8 = .{ @intCast(letter), ':' };
        _ = try visibleText(&t, &label);
    }
    // From the drive selector, Tab passes Scan drive then all 26 choices.
    for (0..27) |_| t.key(.tab);
    t.key(.enter);
    try std.testing.expectEqual(@as(u8, 'Z'), s.pending_letter);
    try std.testing.expect(s.location_drives_open);
    try std.testing.expect(s.job == null and s.model == null);
    try t.screenshot("artifacts/ui-location-expanded.png");
    try t.clickText("Close");
    try std.testing.expect(!s.location_open);
    try std.testing.expect(s.job == null and s.model == null);
    t.settle(1);
    t.key(.enter);
    try std.testing.expect(s.location_open);
}

test "choosing a different drive leaves current result and refresh target intact" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    // Deterministic available drives; no system dialog or volume is opened.
    s.drives = (1 << 2) | (1 << 5);
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, true);
    defer t.deinit();
    const original = s.model;
    const focus = s.focus;
    const selected = s.selected;
    const refresh = try visibleText(&t, "Refresh");
    try std.testing.expect(refresh.x + refresh.w <= 900 - @import("chrome.zig").caption_w - 20);
    try t.clickText("Choose location");
    t.settle(1);
    try t.clickText("C: drive");
    t.settle(1);
    try t.clickText("F:");
    t.settle(1);
    try std.testing.expectEqual(@as(u8, 'F'), s.pending_letter);
    try std.testing.expectEqual(@as(u8, 'C'), s.letter);
    try std.testing.expect(s.job == null and s.model == original);
    try std.testing.expectEqual(focus, s.focus);
    try std.testing.expectEqual(selected, s.selected);
    _ = try visibleText(&t, "Scan drive");
    try t.screenshot("artifacts/ui-location-drive.png");
    try t.clickText("Close");
    t.settle(1);
    try std.testing.expect(!s.location_open);
    try std.testing.expectEqual(@as(u8, 'C'), s.letter);
    try std.testing.expect(s.job == null and s.model == original);
    _ = try visibleText(&t, "Refresh");
    try t.screenshot("artifacts/ui-location-closed.png");
    // Closing returns focus to Choose location; F5 still refreshes the
    // existing source, not the uncommitted drive choice.
    try std.testing.expectEqual(s.location_return_focus, t.ctx.focus);
    t.key(.f5);
    try std.testing.expect(s.model != original and s.job == null and s.demo);
    try std.testing.expectEqual(@as(u8, 'C'), s.letter);
    try t.clickText("Refresh");
    try std.testing.expect(s.job == null and s.demo and s.model != null);
}

test "no-source snapshots show chooser; failed restart keeps controls available" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--nanoui-snapshot=unused.png"});
    try std.testing.expect(s.location_open and s.model == null and s.job == null and !s.demo);
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    t.settle(1);
    try t.clickText("Close");
    t.settle(1);
    s.failure = .access;
    s.elevation_cancelled = true;
    t.frame();
    _ = try visibleText(&t, "Administrator restart cancelled. This window is still available.");
    _ = try visibleText(&t, "Restart as administrator");
    try std.testing.expect(!t.ctx.close_request);
    s.elevation_cancelled = false;
    s.elevation_error = error.AlreadyElevated;
    t.frame();
    _ = try visibleText(&t, "Already running as administrator; this drive still denies access.");
    try std.testing.expect(!t.ctx.close_request);
    try t.screenshot("artifacts/ui-elevation-recovery.png");
    s.failure = .geometry;
    s.elevation_error = null;
    t.frame();
    _ = try visibleText(&t, "Invalid NTFS volume geometry");
    try std.testing.expect(!t.hasText("Restart as administrator"));
    try t.screenshot("artifacts/ui-invalid-geometry.png");
    try t.clickText("Choose location");
    t.settle(1);
    _ = try visibleText(&t, "Browse for folder…");
}

test "location modal traps filter input and background activation through exit" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    try t.clickText("Filter this folder’s direct children");
    t.typeText("Games");
    const original = s.model;
    const selected = s.selected;
    try t.clickText("Choose location");
    t.settle(1);
    t.typeText("Windows");
    _ = t.shortcut(.{ .ctrl = true, .key = 'f' });
    for (0..12) |_| t.key(.tab);
    t.typeText("ignored");
    t.key(.down);
    t.key(.f5);
    try std.testing.expectEqualStrings("Games", s.filter_buf.text());
    try std.testing.expectEqual(selected, s.selected);
    try std.testing.expect(s.model == original and s.job == null);
    try std.testing.expect(t.ctx.focused_text == null);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!s.location_open);
    // Dismissal consumes its event, then returns focus without an exit wait.
    try std.testing.expect(!s.location_visible);
    try std.testing.expect(s.model == original and s.job == null);
    try std.testing.expectEqual(s.location_return_focus, t.ctx.focus);
    try t.clickText("Choose location");
    t.settle(1);
    const refresh = try visibleText(&t, "Refresh");
    t.click(refresh.x + 4, refresh.y + 4);
    try std.testing.expect(s.model == original and s.job == null);
}

test "System metadata stays counted and navigable across map inspector and filter" {
    var b = try model.Builder.init(std.testing.allocator, 32);
    defer b.deinit();
    const mb = 1024 * 1024;
    _ = try b.addRecord(5, 5, 5, 5, ".", true, 0, 0);
    const mft_node = try b.addRecord(0, 1, 5, 5, "$MFT", false, 64 * mb, 64 * mb);
    const log_node = try b.addRecord(2, 1, 5, 5, "$LogFile", false, 8 * mb, 8 * mb);
    const bad = try b.addRecord(8, 1, 5, 5, "$BadClus", false, 0, 0);
    for ([_]u32{ mft_node, log_node, bad }) |idx| b.nodes.items[idx].flags |= model.FLAG_SYSTEM;
    _ = try b.addRecord(16, 1, 5, 5, "Documents", true, 128 * mb, 128 * mb);
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    s.install(try b.finish());
    const m = s.model.?;
    const system = findNode(m, "System metadata");
    try std.testing.expectEqual(@as(u64, 200 * mb), m.nodes[m.root].allocated);
    try std.testing.expectEqual(@as(usize, 1), s.folders);
    var t: ui.Tester = undefined;
    try tester(&t, &s, 1440, 1000, false);
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), s.entries.items.len);
    try t.screenshot("artifacts/ui-metadata-root.png");
    try clickMap(&t, &s, system);
    _ = try visibleText(&t, "NTFS filesystem records");
    _ = try visibleText(&t, "Explore folder");
    try t.clickText("Explore folder");
    try std.testing.expectEqual(system, s.focus);
    try std.testing.expectEqual(@as(usize, 3), s.entries.items.len);
    try std.testing.expectEqual(@as(usize, 3), s.inspector_entries.items.len);
    try t.clickText("$BadClus");
    try std.testing.expectEqual(bad, s.selected);
    _ = try visibleText(&t, "0 B logical · 0 B allocated");
    try std.testing.expect(t.hasText("C:\\$BadClus"));
    try t.screenshot("artifacts/ui-metadata-badclus.png");
    try t.clickText("Filter this folder’s direct children");
    t.typeText("$BadClus");
    t.frame();
    try std.testing.expectEqual(@as(usize, 1), s.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), s.inspector_entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.tiles.items.len);
    try t.clickText("Logical");
    try std.testing.expectEqual(@as(u64, 72 * mb), s.size(system));
    try t.clickText("Clear");
    s.setFocus(system);
    t.frame();
    t.theme = explorer.palette(true);
    t.resize(900, 600);
    t.frame();
    _ = try visibleText(&t, "NTFS filesystem records");
    _ = try visibleText(&t, "$MFT");
    try t.screenshot("artifacts/ui-metadata-dark.png");
}

test "folder actions copy captured paths and cancel confirmation without touching desktop state" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Disposable folder");
    try tmp.dir.writeFile(io, .{ .sub_path = "Disposable folder/keep.txt", .data = "keep this fixture" });
    var path_buf: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const path = path_buf[0..path_len];
    var s = App.init(std.testing.allocator, io);
    defer s.deinit();
    s.install(try @import("byakugan").folder_scan.scanTree(std.testing.allocator, path, .{}));
    @memcpy(s.root_label_buf[0..path.len], path);
    s.root_label_len = path.len;
    s.folder_mode = true;
    s.select(findNode(s.model.?, "Disposable folder"));
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    _ = try visibleText(&t, "Explore folder");
    _ = try visibleText(&t, "More…");
    try t.screenshot("artifacts/ui-cleanup-selection.png");
    try t.clickText("More…");
    t.settle(1);
    _ = try visibleText(&t, "Open in Explorer");
    _ = try visibleText(&t, "Copy path");
    _ = try visibleText(&t, "Move to Recycle Bin…");
    try t.screenshot("artifacts/ui-cleanup-actions.png");
    try t.clickText("Copy path");
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}\\Disposable folder", .{path});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, t.clipboard.items);
    t.settle(1);
    try t.clickText("More…");
    t.settle(1);
    const selected = s.selected;
    const original = s.model;
    t.key(.f5);
    t.key(.down);
    _ = t.shortcut(.{ .ctrl = true, .key = 'f' });
    t.typeText("ignored");
    try std.testing.expect(s.job == null and s.model == original and s.selected == selected);
    try std.testing.expectEqualStrings("", s.filter_buf.text());
    try t.clickText("Close");
    t.settle(1);
    try t.clickText("Move to Recycle Bin…");
    t.settle(1);
    _ = try visibleText(&t, "Move folder to Recycle Bin?");
    _ = try visibleText(&t, "Cancel");
    _ = try visibleText(&t, "Move to Recycle Bin");
    t.key(.enter); // Cancel is initially focused.
    try std.testing.expect(s.cleanup.work == null and !s.cleanup.open);
    t.settle(1);
    try t.clickText("Move to Recycle Bin…");
    t.settle(1);
    t.theme = explorer.palette(true);
    t.frame();
    try t.screenshot("artifacts/ui-cleanup-confirm.png");
    try t.clickText("Cancel");
    t.key(.f5); // outgoing modal still owns input
    try std.testing.expect(s.job == null and s.cleanup.work == null);
    t.settle(1);
    try tmp.dir.access(io, "Disposable folder/keep.txt", .{});
    try std.testing.expectEqual(s.cleanup.return_focus, t.ctx.focus);
    {
        try t.clickText("Move to Recycle Bin…");
        t.settle(1);
        try tmp.dir.rename("Disposable folder", tmp.dir, "Kept original", io);
        try tmp.dir.createDirPath(io, "Disposable folder");
        try tmp.dir.writeFile(io, .{ .sub_path = "Disposable folder/replacement.txt", .data = "do not recycle" });
        try t.clickText("Move to Recycle Bin");
        for (0..200) |_| {
            t.frame();
            if (s.cleanup.work == null and s.job == null) break;
            try std.Io.sleep(io, .fromMilliseconds(5), .awake);
        }
        t.settle(1);
        try std.testing.expect(s.cleanup.work == null and s.job == null);
        try std.testing.expect(t.containsText("missing or changed since confirmation"));
        try std.testing.expect(!s.cleanup.stale); // successful automatic refresh
        try std.testing.expect(findNode(s.model.?, "Kept original") != model.none);
        try tmp.dir.access(io, "Kept original/keep.txt", .{});
        try tmp.dir.access(io, "Disposable folder/replacement.txt", .{});
        try t.screenshot("artifacts/ui-cleanup-changed.png");
        try std.testing.expect(!s.cleanup.modal());
        try t.clickText("Dismiss");
        t.settle(1);
    }
    s.select(s.model.?.root);
    t.frame();
    try t.clickText("More…");
    t.settle(1);
    try std.testing.expect(!s.cleanup.recycle_allowed);
    try std.testing.expect(t.containsText("scan root can be opened or copied"));
    try t.clickText("Close");
    t.settle(1);
    s.cleanup.stale = true;
    try t.clickText("More…");
    t.settle(1);
    try std.testing.expect(!t.hasText("Copy path"));
    try std.testing.expect(t.containsText("result may be stale"));
    try t.screenshot("artifacts/ui-cleanup-stale.png");
}

test "demo folder actions cannot target real paths" {
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    s.select(findNode(s.model.?, "Games"));
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    try t.clickText("More…");
    t.settle(1);
    try std.testing.expect(t.containsText("Demo entries are illustrative"));
    try std.testing.expect(!t.hasText("Copy path") and !t.hasText("Open in Explorer"));
    try std.testing.expect(s.cleanup.path_len == 0 and s.cleanup.work == null);
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try std.testing.expect(!s.cleanup.open);
}

test "file actions preserve contents on cancel and reject replacement before recycling" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const name = "Large & 日本語.bin";
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "keep this file" });
    var path_buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const path = path_buf[0..len];
    var s = App.init(std.testing.allocator, io);
    defer s.deinit();
    s.install(try @import("byakugan").folder_scan.scanTree(std.testing.allocator, path, .{}));
    @memcpy(s.root_label_buf[0..len], path);
    s.root_label_len = len;
    s.folder_mode = true;
    s.select(findNode(s.model.?, name));
    var t: ui.Tester = undefined;
    try tester(&t, &s, 900, 600, false);
    defer t.deinit();
    try std.testing.expect(!t.hasText("Explore folder"));
    try t.clickText("More…");
    t.settle(1);
    _ = try visibleText(&t, "Show in Explorer");
    try t.screenshot("artifacts/ui-file-actions.png");
    try t.clickText("Copy path");
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}\\{s}", .{ path, name });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, t.clipboard.items);
    t.settle(1);
    try t.clickText("Move to Recycle Bin…");
    t.settle(1);
    _ = try visibleText(&t, "Move file to Recycle Bin?");
    t.key(.enter);
    try std.testing.expect(s.cleanup.work == null and !s.cleanup.open);
    t.settle(1);
    try t.clickText("Move to Recycle Bin…");
    t.settle(1);
    t.theme = explorer.palette(true);
    t.frame();
    try t.screenshot("artifacts/ui-file-confirm.png");
    try t.clickText("Cancel");
    t.settle(1);
    try tmp.dir.access(io, name, .{});
    try t.clickText("Move to Recycle Bin…");
    t.settle(1);
    try tmp.dir.rename(name, tmp.dir, "Retained.bin", io);
    try tmp.dir.createDir(io, name, .default_dir);
    try t.clickText("Move to Recycle Bin");
    for (0..200) |_| {
        t.frame();
        if (s.cleanup.work == null and s.job == null) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    t.settle(1);
    try std.testing.expect(s.cleanup.work == null and s.job == null);
    try std.testing.expect(t.containsText("missing or changed since confirmation"));
    try std.testing.expect(!s.cleanup.stale);
    try std.testing.expect(findNode(s.model.?, "Retained.bin") != model.none);
    try tmp.dir.access(io, name, .{});
    var data: [32]u8 = undefined;
    try std.testing.expectEqualStrings("keep this file", try tmp.dir.readFile(io, "Retained.bin", &data));
    try t.screenshot("artifacts/ui-file-changed.png");
}

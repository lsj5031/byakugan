//! Native DiskTree-style exploration: cached nested map and selection inspector.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const by = @import("byakugan");
const model = by.model;
const treemap = by.treemap;
const App = @import("app.zig").State;
const typeface = @import("typeface.zig");
const chrome = @import("chrome.zig");
const location = @import("location_picker.zig");
const button = @import("controls.zig").button;
const alloc = std.heap.c_allocator;

pub const tile_limit = 31;
pub const Tile = struct { node: u32, parent: u32, rect: treemap.Rect, bytes: u64, depth: u8, count: usize = 0 };

pub fn palette(dark: bool) ui.Theme {
    var th = if (dark) ui.Theme.dark_theme else ui.Theme.light;
    th.font = typeface.family;
    th.background = .hex(if (dark) 0x202620 else 0xFCFCF9);
    th.surface = .hex(if (dark) 0x272E28 else 0xF5F6F0);
    th.surface_hover = .hex(if (dark) 0x354036 else 0xE9EEE3);
    th.text = .hex(if (dark) 0xE8EDE4 else 0x29342E);
    th.muted = .hex(if (dark) 0xA5B2A4 else 0x69746B);
    th.border = .hex(if (dark) 0x414C40 else 0xDCE2D6);
    th.accent = .hex(if (dark) 0xB7CDB0 else 0x3E5B4C);
    th.accent_text = .hex(if (dark) 0x202620 else 0xFFFFFF);
    th.accent_hover = .hex(if (dark) 0xC9DCC2 else 0x314D3E);
    th.track = .hex(if (dark) 0x414B3D else 0xE3E8DD);
    return th;
}

fn color(s: *App, node: u32, dark: bool) ui.Color {
    const m = s.model.?;
    var top = node;
    var guard: usize = 0;
    while (m.nodes[top].parent != m.root and m.nodes[top].parent != model.none and guard < 256) : (guard += 1) top = m.nodes[top].parent;
    const col = by.theme.nodeColor(m.name(top), m.nodes[top].isDirectory());
    const light: ui.Color = .{ .r = col.r, .g = col.g, .b = col.b };
    return if (dark) light.mix(.hex(0x26342B), 0.72) else light;
}
pub fn sizeText(c: *ui.Context, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) {
        v /= 1024;
        u += 1;
    }
    return if (u == 0) c.print("{d} B", .{n}) else c.print("{d:.1} {s}", .{ v, units[u] });
}
pub fn view(s: *App, c: *ui.Context) void {
    c.theme = palette(c.theme.dark);
    c.theme_chosen = c.theme;
    const root = ui.div(c).column().sizeFull().bg(c.theme.background);
    defer root.end();
    // The kit draws the overlay; keep background controls out of keyboard,
    // text-input and accessibility activation while its modal is open.
    const modal = s.location_open or s.location_visible;
    if (s.location_restore_focus) {
        c.focus = s.location_return_focus;
        s.location_restore_focus = false;
    }
    const input = c.input;
    if (modal) c.input = .{};
    header(s, c);
    if (s.model != null) {
        navigation(s, c);
        const body = ui.div(c).row().wFull().grow().p(16).pt(0).gap(18).clip();
        map(s, c);
        inspector(s, c);
        body.end();
    } else empty(s, c);
    status(s, c);
    chrome.caption(c, s.window);
    if (modal) {
        c.input = input;
        c.focusable_ids.clearRetainingCapacity();
        c.focused_text = null;
    }
    location.view(s, c);
}
fn header(s: *App, c: *ui.Context) void {
    const row = ui.div(c).row().wFull().h(chrome.header_h).pl(20).pr(20 + chrome.caption_w).gap(12).itemsCenter().border(c.theme.border).borderW(1);
    defer row.end();
    chrome.brand(c, 28);
    ui.text(c, "Byakugan", .{ .size = 20, .weight = .semibold });
    ui.spacer(c);
    if (s.demo) ui.text(c, "Demo", .{ .size = 13, .color = c.theme.muted });
    const choose = button(c, "Choose location", .{ .size = 14, .variant = .primary, .disabled = s.job != null or s.elevation_launch != null });
    s.location_return_focus = choose.id;
    if (choose.clicked) {
        s.chooseLocation();
        c.changed = true;
    }
    if (s.job) |j| {
        if (button(c, "Cancel scan", .{ .size = 14, .variant = .ghost }).clicked) j.cancel.store(true, .release);
    } else if (s.model != null and button(c, "Refresh", .{ .size = 14, .variant = .ghost, .disabled = s.elevation_launch != null }).clicked) s.rescan();
}
fn rootTitle(s: *App) []const u8 {
    const label = s.rootLabel();
    const name = if (s.folder_mode) std.fs.path.basenameWindows(label) else "";
    return if (name.len > 0) name else label;
}
fn navigation(s: *App, c: *ui.Context) void {
    const m = s.model.?;
    const nav = ui.div(c).column().wFull().px(20).py(12).gap(10);
    defer nav.end();
    const crumbs = ui.div(c).row().wFull().h(32).itemsCenter().gap(4).clip();
    if (ui.button(c, "Up", .{ .size = 13, .variant = .ghost, .disabled = s.focus == m.root }).clicked) {
        s.setFocus(m.nodes[s.focus].parent);
        c.changed = true;
    }
    var chain: [256]u32 = undefined;
    var len: usize = 0;
    var cur = s.focus;
    while (cur != model.none and len < chain.len) : (cur = m.nodes[cur].parent) {
        chain[len] = cur;
        len += 1;
        if (cur == m.root) break;
    }
    // Collapse long paths to the root, parent and current folder.
    var i = len;
    while (i > 0) {
        i -= 1;
        if (i > 1 and i + 1 < len) {
            if (i + 2 == len) ui.text(c, "… /", .{ .size = 13, .color = c.theme.muted });
            continue;
        }
        const node = chain[i];
        ui.keyInt(c, node);
        const title = if (node == m.root) rootTitle(s) else m.name(node);
        const box = ui.div(c).row().maxW(if (node == m.root) 220 else 180).h(32).px(12).itemsCenter().rounded(8).clip().control().hover(c.theme.surface_hover);
        c.addA11y(box.index, .button, title, "", false, true);
        ui.text(c, title, .{ .size = 14, .truncate = .ellipsis });
        if (box.interaction().clicked) {
            s.setFocus(node);
            c.changed = true;
        }
        box.end();
        if (i > 0) ui.text(c, "/", .{ .size = 13, .color = c.theme.muted });
    }
    crumbs.end();
    const controls = ui.div(c).row().wFull().h(38).gap(12).itemsCenter();
    const field = ui.textField(c, &s.filter_buf, .{ .placeholder = "Filter this folder’s direct children", .width = .{ .px = @min(340, c.size.w - 490) }, .size = 14, .select_all_on_focus = true });
    if (field.changed) c.changed = true;
    if (s.filter_buf.text().len > 0 and ui.button(c, "Clear", .{ .variant = .ghost, .size = 13 }).clicked) {
        s.filter_buf.clear();
        c.changed = true;
    }
    ui.spacer(c);
    ui.text(c, "Size", .{ .size = 13, .color = c.theme.muted });
    var choice: usize = if (s.metric_allocated) 0 else 1;
    if (ui.segmented(c, &.{ "Allocated", "Logical" }, &choice)) {
        s.metric_allocated = choice == 0;
        s.metricChanged();
        c.changed = true;
    }
    controls.end();
    const scope = ui.div(c).row().wFull().itemsCenter().gap(8);
    ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{d} direct children{s} · area shows {s} size", .{ s.entries.items.len, if (s.query.items.len > 0) " matching" else "", if (s.metric_allocated) "allocated" else "logical" });
    ui.spacer(c);
    ui.text(c, sizeText(c, s.size(s.focus)), .{ .size = 16, .weight = .medium });
    scope.end();
}

fn buildMap(s: *App, parent: u32, area: treemap.Rect, depth: u8) void {
    if (area.w < 8 or area.h < 8 or s.tiles.items.len > 1800) return;
    const m = s.model.?;
    var items: [tile_limit + 1]treemap.Item = undefined;
    var rects: [tile_limit + 1]treemap.Rect = undefined;
    var indexes: [tile_limit + 1]u32 = undefined;
    var count: usize = 0;
    var rest: u64 = 0;
    var remaining: usize = 0;
    var child = m.nodes[parent].first_child;
    while (child != model.none) : (child = m.nodes[child].next_sibling) {
        if (!@import("app.zig").visibleEntry(m, child)) continue;
        if (parent == s.focus and !by.tree_view.containsIgnoreCase(m.name(child), s.query.items)) continue;
        const bytes = s.size(child);
        if (bytes > 0 and count < tile_limit) {
            items[count] = .{ .index = child, .size = bytes };
            count += 1;
        } else {
            rest +|= bytes;
            remaining += 1;
        }
    }
    if (rest > 0) {
        items[count] = .{ .index = model.none, .size = rest };
        count += 1;
    }
    const result = treemap.layout(items[0..count], area.w, area.h, &rects, &indexes, .{});
    for (0..result.len) |i| {
        const r = rects[i];
        const node = indexes[i];
        const bounds: treemap.Rect = .{ .x = area.x + r.x + 2, .y = area.y + r.y + 2, .w = @max(0, r.w - 4), .h = @max(0, r.h - 4) };
        s.tiles.append(alloc, .{ .node = node, .parent = parent, .rect = bounds, .bytes = if (node == model.none) rest else s.size(node), .depth = depth, .count = if (node == model.none) remaining else 0 }) catch return;
        if (node != model.none and depth < 2 and m.nodes[node].isDirectory() and bounds.w > 140 and bounds.h > 100) {
            buildMap(s, node, .{ .x = bounds.x + 5, .y = bounds.y + 36, .w = bounds.w - 10, .h = bounds.h - 41 }, depth + 1);
        }
    }
}
fn map(s: *App, c: *ui.Context) void {
    const panel = ui.div(c).column().grow().hFull().gap(8);
    defer panel.end();
    ui.key(c, "treemap-canvas");
    const canvas = ui.div(c).grow().wFull().clip().rounded(6).bg(c.theme.surface);
    const rect = c.rects.get(canvas.id()) orelse ui.Rect{};
    if (s.map_dirty or s.map_w != rect.w or s.map_h != rect.h) {
        s.tiles.clearRetainingCapacity();
        buildMap(s, s.focus, .{ .x = 0, .y = 0, .w = rect.w, .h = rect.h }, 0);
        s.map_w = rect.w;
        s.map_h = rect.h;
        s.map_dirty = false;
        c.frameIn(0);
    }
    if (s.tiles.items.len == 0) {
        const msg = ui.div(c).column().sizeFull().center().gap(8).p(20);
        ui.text(c, if (s.query.items.len > 0 and s.entries.items.len == 0) "No matching direct children" else "No space to map", .{ .size = 17, .color = c.theme.muted });
        ui.text(c, "Empty and zero-byte entries are available in the inspector.", .{ .size = 13, .color = c.theme.muted, .wrap = true });
        msg.end();
    }
    for (s.tiles.items, 0..) |tile, i| {
        const r = tile.rect;
        const other = tile.node == model.none;
        const col = color(s, if (other) tile.parent else tile.node, c.theme.dark).mix(c.theme.surface, @as(f32, @floatFromInt(tile.depth)) * 0.12);
        const selected = if (other) s.other_parent == tile.parent else s.other_parent == null and s.selected == tile.node;
        ui.keyInt(c, i);
        const box = ui.div(c).absolute().offset(r.x, r.y).size(r.w, r.h).rounded(4).bg(col).border(if (selected) .hex(if (c.theme.dark) 0xE6BE79 else 0x946B2D) else col.mix(c.theme.text, 0.12)).borderW(if (selected) 2 else 1).clip().control().hover(col.mix(c.theme.text, 0.05));
        const interaction = box.interaction();
        if (r.w > 74 and r.h > 24) {
            const label = ui.div(c).column().wFull().p(if (tile.depth == 0) 10 else 7).gap(4);
            const header_row = ui.div(c).row().wFull().gap(8).itemsCenter();
            const name_box = ui.div(c).row().grow().clip();
            ui.text(c, if (other) c.print("Other · {d} entries", .{tile.count}) else s.model.?.name(tile.node), .{ .size = if (tile.depth == 0) 15 else 13, .weight = .medium, .truncate = .ellipsis });
            name_box.end();
            if (r.w > 220) ui.text(c, sizeText(c, tile.bytes), .{ .size = 12, .color = c.theme.text.alpha(0.75) });
            header_row.end();
            // Directory headers leave the nested rectangles unobscured.
            if (r.w <= 220 and r.h > 55 and !(tile.depth < 2 and !other and s.model.?.nodes[tile.node].isDirectory() and r.w > 140 and r.h > 100)) ui.text(c, sizeText(c, tile.bytes), .{ .size = 13, .color = c.theme.text.alpha(0.75) });
            label.end();
        }
        if (interaction.clicked) {
            if (other) {
                s.other_parent = tile.parent;
                s.selected = tile.parent;
                s.inspector_parent = tile.parent;
                s.browsing_inspector = true;
                s.inspector_key = model.none;
                s.scroll_to = 0;
            } else s.select(tile.node);
            c.changed = true;
        }
        if (interaction.double_clicked and !other) {
            s.setFocus(tile.node);
            c.changed = true;
        }
        box.end();
    }
    canvas.end();
    ui.text(c, "Click to inspect · double-click a folder to explore · color follows the top-level folder", .{ .size = 12, .color = c.theme.muted, .truncate = .ellipsis });
}
fn inspector(s: *App, c: *ui.Context) void {
    const m = s.model.?;
    s.ensureInspector();
    const panel = ui.div(c).column().w(if (c.size.w < 1050) 286 else 330).hFull().p(16).gap(10).bg(c.theme.surface).rounded(6).border(c.theme.border).borderW(1).clip();
    defer panel.end();
    const other = s.other_parent != null and s.selected == s.other_parent.?;
    const node = m.nodes[s.selected];
    // Keep the list's hit targets still while its selected item's details
    // change; the second click of a double-click must hit the same row.
    const details = ui.div(c).column().wFull().h(232).gap(8).clip();
    ui.text(c, if (other) "Other entries" else if (s.selected == s.focus) "Current folder" else "Selection", .{ .size = 12, .color = c.theme.muted });
    ui.text(c, if (other) "Remaining in this folder" else if (s.selected == m.root) rootTitle(s) else m.name(s.selected), .{ .size = 20, .weight = .medium, .truncate = .ellipsis });
    ui.text(c, s.displayPath(c, s.selected), .{ .size = 12, .color = c.theme.muted, .truncate = .middle });
    if (s.query.items.len > 0 and s.entries.items.len == 0) {
        ui.text(c, "No selection matches this filter.", .{ .size = 14, .color = c.theme.muted, .wrap = true });
        details.end();
        return;
    }
    var bytes = s.size(s.selected);
    if (other) {
        bytes = 0;
        for (s.inspector_entries.items) |idx| bytes +|= s.size(idx);
    }
    ui.text(c, sizeText(c, bytes), .{ .size = 30, .weight = .regular });
    if (!other) {
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{s} logical · {s} allocated", .{ sizeText(c, node.size), sizeText(c, node.allocated) });
        const total = s.size(s.focus);
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{d:.1}% of current folder", .{if (total == 0) @as(f64, 0) else @as(f64, @floatFromInt(bytes)) * 100 / @as(f64, @floatFromInt(total))});
        if (node.isDirectory() and s.selected != s.focus and button(c, "Explore folder", .{ .size = 14, .variant = .primary }).clicked) {
            s.setFocus(s.selected);
            c.changed = true;
        }
        const links = m.countExtraNames(s.selected);
        if (links > 0) {
            ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{d} extra hard link{s}", .{ links, if (links == 1) "" else "s" });
            for (m.links) |link| {
                if (link.node == s.selected) {
                    ui.text(c, c.print("also: {s}", .{m.linkName(link)}), .{ .size = 12, .truncate = .ellipsis });
                    break;
                }
            }
        }
    }
    details.end();
    ui.div(c).wFull().h(1).bg(c.theme.border).end();
    const title = ui.div(c).row().wFull().itemsCenter();
    ui.text(c, if (s.other_parent != null) "Browse remaining entries" else "Folder contents", .{ .size = 14, .weight = .medium });
    ui.spacer(c);
    ui.text(c, c.print("{d}", .{s.inspector_entries.items.len}), .{ .size = 13, .color = c.theme.muted });
    title.end();
    if (s.inspector_entries.items.len == 0) {
        ui.text(c, if (node.isDirectory()) "This folder is empty." else "File · no children", .{ .size = 13, .color = c.theme.muted });
    } else {
        ui.keyInt(c, @as(u64, s.inspector_parent) + if (s.other_parent != null) @as(u64, 0x100000000) else 0);
        var rows = ui.list(c, .{ .count = s.inspector_entries.items.len, .row_height = 46, .scroll_to = s.scroll_to });
        s.scroll_to = null;
        while (rows.next()) |i| {
            const idx = s.inspector_entries.items[i];
            const row = ui.div(c).column().wFull().h(46).px(6).gap(3).justifyCenter().rounded(4).bg(if (s.selected == idx) c.theme.surface_hover else c.theme.surface).control().hover(c.theme.surface_hover);
            const it = row.interaction();
            ui.text(c, m.name(idx), .{ .size = 14, .truncate = .ellipsis });
            ui.text(c, c.print("{s} · {s}", .{ sizeText(c, s.size(idx)), if (m.nodes[idx].isDirectory()) "folder" else "file" }), .{ .size = 12, .color = c.theme.muted });
            if (it.clicked) {
                s.selectInspector(idx);
                c.changed = true;
            }
            if (it.double_clicked) {
                s.setFocus(idx);
                c.changed = true;
            }
            row.end();
        }
        rows.end();
    }
    if (if (c.size.h >= 760) s.space else null) |space| {
        ui.spacer(c);
        ui.div(c).wFull().h(1).bg(c.theme.border).end();
        ui.text(c, "Containing volume", .{ .size = 12, .color = c.theme.muted });
        ui.textf(c, .{ .size = 18 }, "{s} free", .{sizeText(c, space.free)});
        ui.progress(c, if (space.total == 0) 0 else @as(f32, @floatFromInt(space.used())) / @as(f32, @floatFromInt(space.total)), .fill);
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{s} used · {s} capacity", .{ sizeText(c, space.used()), sizeText(c, space.total) });
        ui.text(c, "Includes space outside this folder", .{ .size = 11, .color = c.theme.muted });
    }
}
fn empty(s: *App, c: *ui.Context) void {
    const box = ui.div(c).column().grow().wFull().center().p(32).gap(14);
    defer box.end();
    ui.text(c, "See where your space goes", .{ .size = 28, .weight = .medium });
    if (s.job != null) {
        ui.text(c, "Scanning… your map will appear when the scan finishes.", .{ .size = 15, .color = c.theme.muted });
    } else {
        ui.text(c, failureTitle(s.failure), .{ .size = 18 });
        ui.text(c, switch (s.failure) {
            .access => "Open a folder for a scan without administrator rights, or restart elevated for a full NTFS scan.",
            .not_ntfs => "Choose an NTFS volume, or open a folder to scan its accessible files.",
            .folder_access => "Choose a folder your account can read.",
            .folder_missing => "The folder no longer exists. Open another folder to continue.",
            .none => "Choose a folder or drive to scan and explore its disk usage.",
            .cancelled => "Nothing was changed. Choose a location when you are ready.",
            else => "Choose a folder or drive to try again.",
        }, .{ .size = 14, .color = c.theme.muted, .wrap = true });
        if (s.failure == .access) {
            if (elevationMessage(s)) |message| ui.text(c, message, .{ .size = 14, .color = c.theme.muted, .wrap = true });
            restartButton(s, c);
        }
    }
}
fn restartButton(s: *App, c: *ui.Context) void {
    if (button(c, "Restart as administrator", .{ .size = 13, .variant = .secondary, .disabled = s.elevation_launch != null }).clicked) {
        s.restartElevated();
        c.changed = true;
    }
}
fn elevationMessage(s: *App) ?[]const u8 {
    if (s.elevation_launch != null) return "Waiting for administrator access…";
    if (s.elevation_cancelled) return "Administrator restart cancelled. This window is still available.";
    if (s.elevation_error) |err| return switch (err) {
        error.AlreadyElevated => "Already running as administrator; this drive still denies access.",
        error.TimedOut => "Administrator restart timed out. This window is still available.",
        error.ChildExited, error.ChildRejected, error.ScanCheckFailed => "The new process could not verify drive access. Try choosing a folder.",
        else => "Administrator restart failed. This window is still available.",
    };
    return null;
}
fn failureTitle(f: @import("app.zig").Failure) []const u8 {
    return switch (f) {
        .none => "Choose a location to begin",
        .access => "Administrator rights needed for this volume",
        .not_ntfs => "Not an NTFS volume",
        .cancelled => "Scan cancelled",
        .failed => "The scan could not finish",
        .folder_access => "Folder is not readable",
        .folder_missing => "Folder not found",
        .picker => "Folder picker could not open",
        .start => "Scan could not start",
    };
}
fn status(s: *App, c: *ui.Context) void {
    const bar = ui.div(c).row().wFull().h(36).px(20).gap(10).itemsCenter().border(c.theme.border).borderW(1).clip();
    defer bar.end();
    if (s.job) |j| {
        const total = j.total.load(.acquire);
        const bytes = j.bytes.load(.acquire);
        ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "Scanning · {d} {s} · {s}", .{ j.records.load(.acquire), if (j.kind == .folder) "entries found" else "records", sizeText(c, bytes) });
        if (total > 0) ui.progress(c, @min(1, @as(f32, @floatFromInt(bytes)) / @as(f32, @floatFromInt(total))), .{ .px = 100 });
    } else if (s.model) |m| {
        if (s.failure != .none) {
            if (elevationMessage(s)) |message| ui.text(c, message, .{ .size = 12, .color = c.theme.danger, .truncate = .ellipsis }) else ui.textf(c, .{ .size = 12, .color = c.theme.danger }, "{s}; previous scan retained", .{failureTitle(s.failure)});
            if (s.failure == .access) restartButton(s, c);
        } else ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{s} · {d} files · {d} folders · {d} skipped", .{ if (s.scan_cancelled) "Cancelled; previous scan retained" else if (s.demo) "Demo" else if (s.folder_mode) "Folder scan complete" else "Volume scan complete", s.files, s.folders, m.skipped });
    } else ui.text(c, failureTitle(s.failure), .{ .size = 12, .color = c.theme.muted });
    ui.spacer(c);
    if (s.failure != .access) ui.text(c, "↑↓ select · Enter explore · Esc up · Ctrl+F filter", .{ .size = 12, .color = c.theme.muted, .truncate = .ellipsis });
}

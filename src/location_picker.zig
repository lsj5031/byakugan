//! One deliberate entry point for folder and whole-drive scans.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").State;
const button = @import("controls.zig").button;

pub fn view(s: *App, c: *ui.Context) void {
    if (!s.location_open and !s.location_visible) return;
    const input = c.input;
    // Outgoing content is still painted by presence, but cannot activate.
    if (!s.location_open) c.input = .{};
    defer if (!s.location_open) {
        c.input = input;
        c.input.clearEdges();
    };
    const dialog = nanoui.kit.dialog(c, "choose-location", &s.location_open, .{
        .title = "Choose a location",
        .description = "Scan a folder, or inspect an entire NTFS drive.",
        .width = 460,
        .ok = "",
        .cancel = "",
        .close_button = false,
    }) orelse {
        if (s.location_visible) {
            s.location_visible = false;
            s.location_restore_focus = true;
            c.changed = true;
        }
        return;
    };
    s.location_visible = true;
    if (!s.location_open) c.input = .{};
    ui.text(c, "Folder", .{ .size = 16, .weight = .medium });
    ui.text(c, "Scan files you can access. No administrator rights needed.", .{ .size = 13, .color = c.theme.muted, .wrap = true });
    if (button(c, "Browse for folder…", .{ .size = 14, .variant = .primary }).clicked) s.openFolder();
    ui.div(c).wFull().h(1).bg(c.theme.border).end();
    ui.text(c, "Drive", .{ .size = 16, .weight = .medium });
    ui.text(c, "Fast NTFS scan. Windows may require administrator rights.", .{ .size = 13, .color = c.theme.muted, .wrap = true });
    const drive_row = ui.div(c).row().wFull().gap(12).itemsCenter();
    if (s.drives != 0) {
        if (button(c, c.print("{c}: drive", .{s.pending_letter}), .{ .width = .{ .px = 160 }, .icon = "chevron.down" }).clicked) {
            s.location_drives_open = !s.location_drives_open;
            c.changed = true;
        }
        if (button(c, "Scan drive", .{ .size = 14 }).clicked) {
            s.location_open = false;
            s.startVolumeScan(s.pending_letter);
            c.changed = true;
        }
    } else ui.text(c, "No drives available", .{ .size = 14, .color = c.theme.muted });
    drive_row.end();
    if (s.location_drives_open) {
        var letters: [26]u8 = undefined;
        var count: usize = 0;
        for (0..26) |i| {
            if (s.drives & (@as(u32, 1) << @intCast(i)) == 0) continue;
            letters[count] = 'A' + @as(u8, @intCast(i));
            count += 1;
        }
        const drives = ui.div(c).column().wFull().gap(4);
        var offset: usize = 0;
        while (offset < count) : (offset += 7) {
            const row = ui.div(c).row().wFull().gap(6);
            for (letters[offset..@min(offset + 7, count)]) |letter| {
                ui.keyInt(c, letter);
                if (button(c, c.print("{c}:", .{letter}), .{ .width = .{ .px = 48 }, .variant = if (letter == s.pending_letter) .primary else .secondary, .size = 13 }).clicked) {
                    s.pending_letter = letter;
                    c.changed = true;
                }
            }
            row.end();
        }
        drives.end();
    }
    if (button(c, "Close", .{ .size = 14, .variant = .ghost }).clicked) {
        s.location_open = false;
        c.changed = true;
    }
    _ = dialog.end();
}

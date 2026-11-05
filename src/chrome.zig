//! App-owned header controls, following nanomon's integrated Windows caption.
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const windows = @import("builtin").os.tag == .windows;

pub const header_h: f32 = 62;
pub const caption_w: f32 = if (windows) 138 else 0;

/// The existing circular Byakugan mark; the same source is the executable icon.
pub fn brand(c: *ui.Context, size: f32) void {
    _ = ui.image(c, .{
        .key = "byakugan-brand",
        .bytes = @embedFile("assets/byakugan.png"),
        .max_width = size,
        .max_height = size,
        .radius = 0,
        .scale = 1,
        .tint = c.theme.accent,
    });
}

/// Call at root level after page content; reserve caption_w in header padding.
/// A null window is supported by offscreen view tests.
pub fn caption(c: *ui.Context, window: ?*nanoui.Window) void {
    if (!windows) return;
    const row = ui.div(c).fixed().offset(c.size.w - caption_w, 0).w(caption_w).h(header_h).row();
    defer row.end();
    if (button(c, .minimize)) if (window) |w| w.minimize();
    if (button(c, .maximize)) if (window) |w| w.zoom();
    if (button(c, .close)) if (window) |w| w.close();
}

const Action = enum { minimize, maximize, close };

fn button(c: *ui.Context, action: Action) bool {
    const label = switch (action) {
        .minimize => "Minimize window",
        .maximize => "Maximize or restore window",
        .close => "Close window",
    };
    ui.key(c, label);
    const box = ui.div(c).row().w(caption_w / 3).h(header_h).center().control().hover(if (action == .close) ui.Color.hex(0xC93B3B) else c.theme.surface_hover);
    defer box.end();
    c.addA11y(box.index, .button, label, "", false, true);
    const interaction = box.interaction();
    const color = if (action == .close and interaction.hovered) ui.Color.white else c.theme.muted;
    switch (action) {
        .minimize => _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 1 }, .background = color }, .none, null),
        .maximize => _ = c.leaf(.{ .width = .{ .px = 10 }, .height = .{ .px = 10 }, .border = color, .border_width = 1 }, .none, null),
        .close => ui.icon(c, "xmark", .{ .size = 11, .color = color }),
    }
    return interaction.clicked;
}

test "caption hit regions track header width and leave blank header draggable" {
    if (!windows) return error.SkipZigTest;
    const std = @import("std");
    const Sample = struct {
        fn view(_: *@This(), c: *ui.Context) void {
            const root = ui.div(c).column().sizeFull().bg(c.theme.background);
            defer root.end();
            const header = ui.div(c).row().wFull().h(header_h).pl(20).pr(20 + caption_w).itemsCenter();
            brand(c, 28);
            ui.text(c, "Byakugan", .{ .size = 20, .weight = .semibold });
            header.end();
            caption(c, null);
        }
    };
    try @import("typeface.zig").register();
    var theme = ui.Theme.light;
    theme.font = @import("typeface.zig").family;
    var sample: Sample = .{};
    var tester: ui.Tester = undefined;
    try tester.init(std.testing.allocator, .init(&sample, Sample.view), .{ .width = 900, .height = 100, .scale = 1, .theme = theme });
    defer tester.deinit();
    const frame = @import("win_frame.zig");
    frame.setContext(&tester.ctx);
    defer frame.setContext(null);
    for ([_]f32{ 900, 1440 }) |width| {
        tester.resize(width, 100);
        try std.testing.expectEqual(@as(usize, 3), tester.ctx.hits.items.len);
        try std.testing.expect(!frame.overControl(300, 30));
        for (tester.ctx.hits.items, 0..) |hit, i| {
            try std.testing.expectEqual(width - caption_w + @as(f32, @floatFromInt(i)) * 46, hit.rect.x);
            try std.testing.expectEqual(@as(f32, 46), hit.rect.w);
            try std.testing.expectEqual(header_h, hit.rect.h);
            try std.testing.expect(frame.overControl(hit.rect.x + 23, 30));
        }
    }
}

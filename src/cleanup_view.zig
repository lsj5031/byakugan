//! One confirmation, with progress and outcomes kept in the browsing window.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const State = @import("cleanup_ui.zig").State;
const button = @import("controls.zig").button;

fn menuAction(c: *ui.Context, label: []const u8, disabled: bool) bool {
    const index: u32 = @intCast(c.nodes.items.len);
    const action = button(c, label, .{ .size = 13, .width = .fill, .variant = .ghost, .disabled = disabled });
    c.node(index).style.justify = .start;
    return action.clicked;
}

fn closed(self: *State, c: *ui.Context) void {
    self.visible = false;
    self.restore_focus = true;
    c.input.clearEdges();
    c.changed = true;
}

pub fn overlay(self: *State, s: anytype, c: *ui.Context) void {
    _ = s;
    if (!self.modal()) return;
    if (self.phase == .result) {
        closed(self, c);
        return;
    }
    // Repeated menus and keyboard actions should respond without zooming or
    // waiting for an exit animation. Pointer confirmations keep kit motion.
    if (self.phase == .confirm and (c.input.key != null or c.input.shortcut != null)) self.instant_confirmation = true;
    const reduced = c.reduce_motion;
    c.reduce_motion = reduced or self.phase == .actions or self.instant_confirmation;
    defer c.reduce_motion = reduced;
    const input = c.input;
    if (!self.open) c.input = .{};
    defer if (!self.open) {
        c.input = input;
        c.input.clearEdges();
    };
    if (self.phase == .actions) {
        const anchor = self.anchor orelse ui.Rect{ .x = c.size.w / 2, .y = c.size.h / 2 };
        const above = anchor.y > c.size.h / 2;
        const y = if (above) 6 else anchor.y + anchor.h + 6;
        const height = @max(0, if (above) anchor.y - 12 else c.size.h - y - 6);
        ui.key(c, "item-menu-placement");
        const placement = ui.div(c).fixed().offset(std.math.clamp(anchor.x, 6, c.size.w - 286), y).w(280).h(height).column();
        if (above) _ = placement.justifyEnd();
        defer placement.end();
        const popup = nanoui.kit.popover(c, "item-menu", &self.open, self.anchor, .{ .width = 280, .padding = 10 }) orelse {
            closed(self, c);
            return;
        };
        // Anchor the current measured menu, rather than last frame's height.
        const style = &c.node(popup.div.index).style;
        style.absolute = false;
        style.fixed = false;
        style.offset = .{};
        style.max_height = height;
        style.scroll = true;
        defer popup.end();
        self.visible = true;
        if (!self.open) c.input = .{};
        if (c.input.key == .down or c.input.key == .up) {
            c.focusCycle(c.input.key == .up);
            c.input.key = null;
            c.input.shortcut = null;
        }
        if (self.path_len > 0) ui.text(c, std.fs.path.basenameWindows(self.path()), .{ .size = 13, .weight = .medium, .truncate = .middle });
        if (self.message) |message| ui.text(c, message, .{ .size = 12, .color = c.theme.muted, .wrap = true });
        if (self.path_len > 0) {
            if (menuAction(c, "Move to Recycle Bin…", !self.recycle_allowed)) self.confirm(c);
            ui.div(c).wFull().h(1).bg(c.theme.border).end();
            if (menuAction(c, if (self.is_directory) "Open in Explorer" else "Show in Explorer", false)) self.start(.explore);
            if (menuAction(c, "Copy path", false)) {
                c.clipboard.write(c.clipboard.ctx, self.path());
                self.message = "Path copied.";
                self.phase = .result;
                self.open = false;
            }
            if (self.reopen_allowed and menuAction(c, "Reopen normally", false)) self.start(.reopen);
            ui.div(c).wFull().h(1).bg(c.theme.border).end();
        }
        if (menuAction(c, "Close", false)) self.open = false;
        if (!self.open) c.changed = true;
        return;
    }
    ui.key(c, "cleanup-dialog-placement");
    const placement = ui.div(c).fixed().w(c.size.w).h(c.size.h).column().center().pb(c.size.h * 0.12);
    defer placement.end();
    const dialog = nanoui.kit.dialog(c, "item-confirm", &self.open, .{
        .title = if (self.is_directory) "Move folder to Recycle Bin?" else "Move file to Recycle Bin?",
        .width = 480,
        .ok = "",
        .cancel = "",
        .close_button = false,
        .overlay_closable = false,
    }) orelse {
        closed(self, c);
        return;
    };
    // Measure and center in this pass. Retain pointer scale/fade, without
    // a previous-height positioning jump or translation on keyboard input.
    const style = &c.node(dialog.panel.index).style;
    style.absolute = false;
    style.fixed = false;
    style.offset = .{};
    self.visible = true;
    if (!self.open) c.input = .{};
    const identity = ui.div(c).column().wFull().gap(6).maxH(@max(80, c.size.h - 400)).scrollY();
    if (c.input.key == .page_down or c.input.key == .page_up) {
        const offset = c.scroll.get(identity.id()) orelse 0;
        c.setScroll(identity.id(), .y, @max(0, offset + @as(f32, if (c.input.key == .page_down) 120 else -120)));
        c.input.clearEdges();
        c.changed = true;
    }
    ui.text(c, std.fs.path.basenameWindows(self.path()), .{ .size = 18, .weight = .medium, .wrap = true });
    ui.text(c, std.fs.path.dirnameWindows(self.path()) orelse self.path(), .{ .size = 12, .color = c.theme.muted, .wrap = true });
    identity.end();
    ui.textf(c, .{ .size = 13 }, "{s} allocated in this scan{s}", .{ @import("explorer.zig").sizeText(c, self.allocated), if (self.is_directory) " · includes contents" else "" });
    ui.text(c, "Restore it from Recycle Bin if needed. Space stays used until the bin is emptied.", .{ .size = 13, .wrap = true });
    ui.text(c, "Contents may have changed since scanning. If Windows cannot recycle it, this stops without permanent deletion.", .{ .size = 12, .color = c.theme.muted, .wrap = true });
    const actions = ui.div(c).row().wFull().gap(8).justifyEnd().pt(4);
    const cancel = button(c, "Cancel", .{ .size = 13 });
    if (self.focus_cancel) {
        c.focus = cancel.id;
        self.focus_cancel = false;
        c.changed = true;
    }
    if (cancel.clicked) self.open = false;
    if (button(c, "Move to Recycle Bin", .{ .size = 13, .variant = .danger }).clicked) self.start(.recycle);
    actions.end();
    _ = dialog.end();
    if (!self.open) c.changed = true;
}

pub fn notice(self: *State, s: anytype, c: *ui.Context) void {
    if (self.phase != .result) return;
    const message = self.message orelse return;
    const box = ui.div(c).row().wFull().px(20).py(8).gap(12).itemsCenter().bg(c.theme.surface).border(c.theme.border);
    defer box.end();
    const text = ui.div(c).column().grow().gap(3);
    if (self.path_len > 0) ui.text(c, std.fs.path.basenameWindows(self.path()), .{ .size = 13, .weight = .medium, .truncate = .middle });
    ui.text(c, message, .{ .size = 12, .wrap = true });
    text.end();
    if (self.work != null) return;
    if (self.recycled and button(c, "Open Recycle Bin", .{ .size = 12 }).clicked) self.start(.bin);
    if (self.stale and button(c, "Refresh", .{ .size = 12, .disabled = s.job != null }).clicked) s.rescan();
    if (button(c, "Dismiss", .{ .size = 12, .variant = .ghost }).clicked) {
        self.message = null;
        c.changed = true;
    }
}

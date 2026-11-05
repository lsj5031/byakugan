//! Keyboard access for app actions; nanoui's basic buttons are pointer-only.
const ui = @import("nanoui").ui;

pub fn button(c: *ui.Context, label: []const u8, opts: ui.ButtonOptions) ui.Interaction {
    if (c.input.key == .tab) c.focusCycle(c.input.shift);
    const index: u32 = @intCast(c.nodes.items.len);
    var it = ui.button(c, label, opts);
    if (opts.disabled) return it;
    c.focusable_ids.append(c.gpa, it.id) catch {};
    if (it.clicked or it.pressed) c.focus = it.id;
    if (c.focus == it.id) {
        c.node(index).style.border = if (opts.variant == .primary or opts.variant == .danger) c.theme.accent_text else c.theme.accent;
        c.node(index).style.border_width = 2;
        if (c.input.key == .enter or c.shortcut(.{ .key = ui.Shortcut.enter }) or c.shortcut(.{ .key = ' ' })) {
            c.input.key = null;
            c.input.shortcut = null;
            it.clicked = true;
            c.changed = true;
        }
    }
    return it;
}

//! Keyboard access for app actions; nanoui's basic buttons are pointer-only.
const ui = @import("nanoui").ui;

pub fn button(c: *ui.Context, label: []const u8, opts: ui.ButtonOptions) ui.Interaction {
    if (c.input.key == .tab) c.focusCycle(c.input.shift);
    const index: u32 = @intCast(c.nodes.items.len);
    const it = ui.button(c, label, opts);
    if (opts.disabled) return it;
    return keyboard(c, index, it, opts.variant == .primary or opts.variant == .danger);
}

/// Adds the same Tab/activation contract to custom breadcrumbs and segments.
pub fn keyboard(c: *ui.Context, index: u32, interaction: ui.Interaction, filled: bool) ui.Interaction {
    if (c.input.key == .tab) c.focusCycle(c.input.shift);
    var it = interaction;
    c.focusable_ids.append(c.gpa, it.id) catch {};
    if (it.clicked or it.pressed) c.focus = it.id;
    if (c.focus == it.id) {
        c.node(index).style.border = if (filled) c.theme.accent_text else c.theme.accent;
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

pub fn segmented(c: *ui.Context, options: []const []const u8, selected: *usize) bool {
    const group = ui.div(c).row().p(2).gap(2).rounded(9).bg(c.theme.track);
    defer group.end();
    var changed = false;
    for (options, 0..) |label, i| {
        ui.key(c, label);
        const item = ui.div(c).row().px(14).py(5).rounded(7).itemsCenter().control().bg(if (selected.* == i) c.theme.surface else c.theme.track).hover(c.theme.surface_hover);
        c.addA11y(item.index, .radio_button, label, "", selected.* == i, true);
        const it = keyboard(c, item.index, item.interaction(), false);
        ui.text(c, label, .{ .size = 13, .weight = if (selected.* == i) .semibold else .regular });
        item.end();
        if (it.clicked and selected.* != i) {
            selected.* = i;
            changed = true;
            c.changed = true;
        }
    }
    return changed;
}

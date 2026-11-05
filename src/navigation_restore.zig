//! Resolve browsing state by ancestry, since rescans may change every index.
const std = @import("std");
const model = @import("byakugan").model;

fn resolve(old: *const model.Model, fresh: *const model.Model, node: u32, ancestor: bool) ?u32 {
    var chain: [256]u32 = undefined;
    var count: usize = 0;
    var at = node;
    while (at != old.root) {
        if (at == model.none or at >= old.nodes.len or count == chain.len) return null;
        chain[count] = at;
        count += 1;
        at = old.nodes[at].parent;
    }
    at = fresh.root;
    while (count > 0) {
        count -= 1;
        var child = fresh.nodes[at].first_child;
        while (child != model.none) : (child = fresh.nodes[child].next_sibling) {
            if (fresh.nodes[child].isDirectory() == old.nodes[chain[count]].isDirectory() and std.mem.eql(u8, fresh.name(child), old.name(chain[count]))) break;
        }
        if (child == model.none) return if (ancestor) at else null;
        at = child;
    }
    return at;
}

pub fn restore(s: anytype, old: *const model.Model, fresh: *const model.Model, focus: u32, selected: u32, parent: u32, other: ?u32, browsing: bool) void {
    s.focus = resolve(old, fresh, focus, true) orelse fresh.root;
    s.inspector_parent = resolve(old, fresh, parent, true) orelse s.focus;
    s.other_parent = if (other) |p| resolve(old, fresh, p, false) else null;
    s.browsing_inspector = browsing;
    s.selected = resolve(old, fresh, selected, false) orelse blk: {
        // Prefer the next visible sibling in the old sorted list, then the
        // preceding one. Never promote a similarly named item in another path.
        var next = old.nodes[selected].next_sibling;
        while (next != model.none) : (next = old.nodes[next].next_sibling) {
            if (!@import("app.zig").visibleEntry(old, next)) continue;
            if (!@import("byakugan").tree_view.containsIgnoreCase(old.name(next), s.filter_buf.text())) continue;
            if (resolve(old, fresh, next, false)) |found| break :blk found;
        }
        const p = old.nodes[selected].parent;
        var previous: ?u32 = null;
        if (p != model.none) {
            var child = old.nodes[p].first_child;
            while (child != model.none and child != selected) : (child = old.nodes[child].next_sibling) {
                if (!@import("app.zig").visibleEntry(old, child)) continue;
                if (!@import("byakugan").tree_view.containsIgnoreCase(old.name(child), s.filter_buf.text())) continue;
                if (resolve(old, fresh, child, false)) |found| previous = found;
            }
        }
        break :blk previous orelse s.inspector_parent;
    };
    s.scroll_to = s.inspector_scroll;
}

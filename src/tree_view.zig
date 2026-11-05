//! Visible rows of the directory tree: expansion state, a filter that keeps
//! matches plus their ancestors, and a flat list the virtual list can index.
//! Rebuilt only when expansion or the filter changes, never per frame.
const std = @import("std");
const model = @import("model.zig");

pub const Row = struct { node: u32, indent: u16 };

pub const State = struct {
    gpa: std.mem.Allocator,
    rows: std.ArrayList(Row) = .empty,
    expanded: std.AutoHashMapUnmanaged(u32, void) = .empty,
    filter: std.ArrayList(u8) = .empty,
    match: []bool = &.{},
    match_len: usize = 0,
    dirty: bool = true,
    filter_dirty: bool = true,

    pub fn init(gpa: std.mem.Allocator) State {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *State) void {
        self.rows.deinit(self.gpa);
        self.expanded.deinit(self.gpa);
        self.filter.deinit(self.gpa);
        if (self.match.len > 0) self.gpa.free(self.match);
        self.* = undefined;
    }

    pub fn isExpanded(self: *const State, node: u32) bool {
        return self.expanded.contains(node);
    }

    pub fn toggle(self: *State, node: u32) void {
        if (self.expanded.contains(node)) {
            _ = self.expanded.remove(node);
        } else {
            self.expanded.put(self.gpa, node, {}) catch return;
        }
        self.dirty = true;
    }

    pub fn expand(self: *State, node: u32) void {
        if (!self.expanded.contains(node)) {
            self.expanded.put(self.gpa, node, {}) catch return;
            self.dirty = true;
        }
    }

    pub fn collapse(self: *State, node: u32) void {
        if (self.expanded.remove(node)) self.dirty = true;
    }

    pub fn setFilter(self: *State, text: []const u8) void {
        if (std.mem.eql(u8, self.filter.items, text)) return;
        self.filter.clearRetainingCapacity();
        self.filter.appendSlice(self.gpa, text) catch return;
        self.filter_dirty = true;
        self.dirty = true;
    }

    pub fn filtering(self: *const State) bool {
        return self.filter.items.len > 0;
    }

    pub fn setModelDefaults(self: *State, m: *const model.Model) void {
        self.expanded.clearRetainingCapacity();
        self.expanded.put(self.gpa, m.root, {}) catch {};
        // The match array belongs to the old node table. Even an unchanged
        // filter string must be rebuilt for the replacement model.
        self.filter_dirty = true;
        self.dirty = true;
    }

    pub fn rebuild(self: *State, m: *const model.Model) !void {
        if (!self.dirty) return;
        if (self.filter_dirty) try self.rebuildMatches(m);
        self.rows.clearRetainingCapacity();
        const filt = self.filtering();
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.gpa);
        try stack.append(self.gpa, m.root);
        var level: std.ArrayList(u16) = .empty;
        defer level.deinit(self.gpa);
        try level.append(self.gpa, 0);
        var children: std.ArrayList(u32) = .empty;
        defer children.deinit(self.gpa);
        while (stack.pop()) |n| {
            const depth = level.pop().?;
            if (filt and (n >= self.match_len or !self.match[n])) continue;
            try self.rows.append(self.gpa, .{ .node = n, .indent = depth });
            const show_children = filt or self.expanded.contains(n);
            if (!show_children) continue;
            children.clearRetainingCapacity();
            var c = m.nodes[n].first_child;
            while (c != model.none) : (c = m.nodes[c].next_sibling) {
                if (!filt or (c < self.match_len and self.match[c])) try children.append(self.gpa, c);
            }
            var i = children.items.len;
            while (i > 0) {
                i -= 1;
                try stack.append(self.gpa, children.items[i]);
                try level.append(self.gpa, @intCast(@min(depth + 1, 65535)));
            }
        }
        self.dirty = false;
    }

    fn rebuildMatches(self: *State, m: *const model.Model) !void {
        if (self.match.len < m.nodes.len) {
            if (self.match.len > 0) self.gpa.free(self.match);
            self.match = try self.gpa.alloc(bool, m.nodes.len);
        }
        self.match_len = m.nodes.len;
        @memset(self.match, false);
        self.filter_dirty = false;
        if (self.filter.items.len == 0) return;
        const needle = self.filter.items;
        for (m.nodes, 0..) |_, i| {
            if (!containsIgnoreCase(m.name(@intCast(i)), needle)) continue;
            var cur: u32 = @intCast(i);
            var guard: usize = 0;
            while (cur != model.none and cur < m.nodes.len and guard < 512) : (guard += 1) {
                if (self.match[cur]) break;
                self.match[cur] = true;
                if (cur == m.root) break;
                cur = m.nodes[cur].parent;
            }
        }
    }

    pub fn selectedRow(self: *const State, node: u32) ?usize {
        for (self.rows.items, 0..) |r, i| if (r.node == node) return i;
        return null;
    }
};

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var k: usize = 0;
        while (k < needle.len) : (k += 1) {
            if (std.ascii.toLower(haystack[i + k]) != std.ascii.toLower(needle[k])) break;
        }
        if (k == needle.len) return true;
    }
    return false;
}

test "flatten expands and filters with ancestors" {
    const demo = @import("demo.zig");
    const m = try demo.build(std.testing.allocator);
    defer m.deinit();
    var s = State.init(std.testing.allocator);
    defer s.deinit();
    s.setModelDefaults(m);
    try s.rebuild(m);
    try std.testing.expect(s.rows.items.len > 5);
    s.setFilter("ntoskrnl");
    try s.rebuild(m);
    var found = false;
    for (s.rows.items) |r| {
        if (std.mem.eql(u8, m.name(r.node), "ntoskrnl.exe")) found = true;
    }
    try std.testing.expect(found);
    // The ancestors are there, so the match has a visible path.
    try std.testing.expect(s.rows.items.len >= 4);
}

fn testModelWith(gpa: std.mem.Allocator, name: []const u8) !*model.Model {
    var b = try model.Builder.init(gpa, 8);
    defer b.deinit();
    _ = try b.addRecord(5, 1, 5, 1, ".", true, 0, 0);
    _ = try b.addRecord(6, 1, 5, 1, name, false, 1, 1);
    return b.finish();
}

test "replacing a model invalidates filter matches" {
    const gpa = std.testing.allocator;
    const a = try testModelWith(gpa, "match.txt");
    defer a.deinit();
    const b = try testModelWith(gpa, "different.bin");
    defer b.deinit();
    var s = State.init(gpa);
    defer s.deinit();

    s.setModelDefaults(a);
    s.setFilter("match");
    try s.rebuild(a);
    var found_match = false;
    for (s.rows.items) |row| {
        if (std.mem.eql(u8, a.name(row.node), "match.txt")) found_match = true;
    }
    try std.testing.expect(found_match);

    s.setModelDefaults(b);
    try s.rebuild(b);
    try std.testing.expectEqual(@as(usize, 0), s.rows.items.len);
}

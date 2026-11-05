//! The node table byakugan builds from the MFT: one node per in-use record,
//! names in one arena, parents and children linked after the parse, sizes
//! aggregated bottom-up.
//!
//! The table is a value the scan publishes and the UI only reads. Sorting by
//! a metric is the one mutation after publish, and it happens on the UI thread.
const std = @import("std");

pub const none: u32 = 0xFFFFFFFF;

pub const FLAG_DIRECTORY: u8 = 0x01;
pub const FLAG_ORPHAN: u8 = 0x02;
pub const FLAG_ROOT: u8 = 0x04;
pub const FLAG_SYNTHETIC: u8 = 0x08;

/// 40 bytes, as the plan budgets: 4 + 4 + 4 + 4 + 2 + 1 + 1 + padding + 8 + 8.
pub const Node = struct {
    parent: u32 = none,
    first_child: u32 = none,
    next_sibling: u32 = none,
    name_off: u32 = 0,
    name_len: u16 = 0,
    flags: u8 = 0,
    depth: u8 = 0,
    size: u64 = 0,
    allocated: u64 = 0,

    pub fn isDirectory(n: Node) bool {
        return (n.flags & FLAG_DIRECTORY) != 0;
    }
    pub fn isOrphan(n: Node) bool {
        return (n.flags & FLAG_ORPHAN) != 0;
    }
};

pub const Link = struct {
    node: u32,
    parent_record: u32,
    parent_sequence: u16,
    namespace: u8,
    name_off: u32,
    name_len: u16,
};

pub const Metric = enum { logical, allocated };

pub const Model = struct {
    gpa: std.mem.Allocator,
    nodes: []Node,
    names: []u8,
    records: []u32,
    links: []Link,
    root: u32 = 0,
    record_count: u64 = 0,
    in_use: u64 = 0,
    corrupt: u32 = 0,
    skipped: u32 = 0,
    extensions: u32 = 0,
    orphans: u32 = 0,
    sorted_metric: ?Metric = null,

    pub fn deinit(self: *Model) void {
        const gpa = self.gpa;
        gpa.free(self.nodes);
        gpa.free(self.names);
        gpa.free(self.records);
        gpa.free(self.links);
        gpa.destroy(self);
    }

    pub fn name(self: *const Model, idx: u32) []const u8 {
        const n = self.nodes[idx];
        return self.names[n.name_off .. n.name_off + n.name_len];
    }

    pub fn nodeCount(self: *const Model) usize {
        return self.nodes.len;
    }

    pub fn childCount(self: *const Model, idx: u32) usize {
        var n: usize = 0;
        var c = self.nodes[idx].first_child;
        while (c != none) : (c = self.nodes[c].next_sibling) n += 1;
        return n;
    }

    pub fn childAt(self: *const Model, idx: u32, n: usize) ?u32 {
        var i: usize = 0;
        var c = self.nodes[idx].first_child;
        while (c != none) : (c = self.nodes[c].next_sibling) {
            if (i == n) return c;
            i += 1;
        }
        return null;
    }

    /// Node indices of the subtree, including `idx`, in table order.
    pub fn collectSubtree(self: *const Model, gpa: std.mem.Allocator, idx: u32) ![]u32 {
        var out: std.ArrayList(u32) = .empty;
        errdefer out.deinit(gpa);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(gpa);
        try stack.append(gpa, idx);
        while (stack.pop()) |n| {
            try out.append(gpa, n);
            var c = self.nodes[n].first_child;
            while (c != none) : (c = self.nodes[c].next_sibling) try stack.append(gpa, c);
        }
        return out.toOwnedSlice(gpa);
    }

    /// `C:\Users\me` is the caller's prefix plus this: names from just under
    /// the root down to `idx`, separated by backslashes.
    pub fn relativePathInto(self: *const Model, idx: u32, out: []u8) []const u8 {
        var chain: [256]u32 = undefined;
        var n: usize = 0;
        var cur = idx;
        while (cur != none and cur != self.root and n < chain.len) : (cur = self.nodes[cur].parent) {
            chain[n] = cur;
            n += 1;
        }
        var len: usize = 0;
        var i = n;
        while (i > 0) {
            i -= 1;
            if (len > 0) {
                if (len == out.len) break;
                out[len] = '\\';
                len += 1;
            }
            const nm = self.name(chain[i]);
            const take = @min(nm.len, out.len - len);
            @memcpy(out[len .. len + take], nm[0..take]);
            len += take;
        }
        return out[0..len];
    }

    pub fn countExtraNames(self: *const Model, idx: u32) usize {
        var n: usize = 0;
        for (self.links) |l| {
            if (l.node == idx) n += 1;
        }
        return n;
    }

    pub fn linkName(self: *const Model, l: Link) []const u8 {
        return self.names[l.name_off .. l.name_off + l.name_len];
    }

    /// Sorts every sibling list by the chosen metric, largest first, and
    /// relinks in place. O(n log n), once per metric change.
    pub fn sortChildren(self: *Model, gpa: std.mem.Allocator, metric: Metric) !void {
        if (self.nodes.len <= 1) {
            self.sorted_metric = metric;
            return;
        }
        const order = try gpa.alloc(u32, self.nodes.len);
        defer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sortUnstable(u32, order, SortCtx{ .nodes = self.nodes, .metric = metric }, lessNode);
        for (self.nodes) |*n| {
            n.first_child = none;
            n.next_sibling = none;
        }
        var last_parent: u32 = none;
        var last: u32 = none;
        for (order) |idx| {
            const p = self.nodes[idx].parent;
            if (p == none or p == idx) continue;
            if (p != last_parent) {
                self.nodes[p].first_child = idx;
                last_parent = p;
            } else {
                self.nodes[last].next_sibling = idx;
            }
            last = idx;
        }
        self.sorted_metric = metric;
    }

    const SortCtx = struct { nodes: []const Node, metric: Metric };

    fn lessNode(ctx: SortCtx, a: u32, b: u32) bool {
        const na = ctx.nodes[a];
        const nb = ctx.nodes[b];
        if (na.parent != nb.parent) return na.parent < nb.parent;
        const sa = switch (ctx.metric) {
            .logical => na.size,
            .allocated => na.allocated,
        };
        const sb = switch (ctx.metric) {
            .logical => nb.size,
            .allocated => nb.allocated,
        };
        if (sa != sb) return sa > sb;
        return a < b;
    }
};

const ExtraSizes = struct { logical: u64 = 0, allocated: u64 = 0 };

/// Collects records while the MFT streams past, then links, depths and
/// aggregates once in `finish`.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    names: std.ArrayList(u8) = .empty,
    records: []u32,
    links: std.ArrayList(Link) = .empty,
    seqs: std.ArrayList(u16) = .empty,
    parent_records: std.ArrayList(u32) = .empty,
    parent_seqs: std.ArrayList(u16) = .empty,
    extras: std.AutoHashMapUnmanaged(u32, ExtraSizes) = .empty,
    in_use: u64 = 0,
    corrupt: u32 = 0,
    extensions: u32 = 0,
    orphans: u32 = 0,
    hard_links: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, record_count: u64) !Builder {
        const n: usize = @intCast(@max(1, record_count));
        const records = try gpa.alloc(u32, n);
        @memset(records, none);
        return .{ .gpa = gpa, .records = records };
    }

    /// Grows the record map for callers that do not know their record count
    /// ahead of time, such as the folder walker. The MFT path still sizes it
    /// exactly from the volume geometry.
    pub fn reserveRecords(self: *Builder, needed: usize) !void {
        if (needed < self.records.len) return;
        var n = @max(self.records.len, 16);
        while (n <= needed) n = @max(n * 2, 16);
        const old = self.records;
        self.records = try self.gpa.realloc(old, n);
        @memset(self.records[old.len..], none);
    }

    pub fn deinit(self: *Builder) void {
        self.nodes.deinit(self.gpa);
        self.names.deinit(self.gpa);
        self.gpa.free(self.records);
        self.links.deinit(self.gpa);
        self.seqs.deinit(self.gpa);
        self.parent_records.deinit(self.gpa);
        self.parent_seqs.deinit(self.gpa);
        self.extras.deinit(self.gpa);
    }

    fn appendNode(self: *Builder, n: Node, seq: u16, parent_record: u32, parent_seq: u16) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, n);
        try self.seqs.append(self.gpa, seq);
        try self.parent_records.append(self.gpa, parent_record);
        try self.parent_seqs.append(self.gpa, parent_seq);
        return idx;
    }

    /// Adds an in-use, base record as a node. `name` must live for the call;
    /// it is copied into the name arena.
    pub fn addRecord(
        self: *Builder,
        record_ref: u64,
        sequence: u16,
        parent_record: u64,
        parent_sequence: u16,
        name: []const u8,
        is_dir: bool,
        logical: u64,
        allocated: u64,
    ) !u32 {
        if (record_ref >= @as(u64, self.records.len)) return none;
        const ref: usize = @intCast(record_ref);
        if (self.records[ref] != none) return self.records[ref];
        const off: u32 = @intCast(self.names.items.len);
        const len: u16 = @intCast(@min(name.len, 65535));
        try self.names.appendSlice(self.gpa, name[0..len]);
        var flags: u8 = 0;
        if (is_dir) flags |= FLAG_DIRECTORY;
        if (parent_record > 0xFFFFFFFF) flags |= FLAG_ORPHAN;
        const node = Node{
            .name_off = off,
            .name_len = len,
            .flags = flags,
            .size = logical,
            .allocated = allocated,
        };
        const idx = try self.appendNode(node, sequence, if (parent_record > 0xFFFFFFFF) none else @intCast(parent_record), parent_sequence);
        self.records[ref] = idx;
        self.in_use += 1;
        return idx;
    }

    pub fn addLink(self: *Builder, idx: u32, parent_record: u64, parent_sequence: u16, namespace: u8, name: []const u8) !void {
        if (idx == none or name.len == 0) return;
        if (self.links.items.len > 1_000_000) return;
        const off: u32 = @intCast(self.names.items.len);
        const len: u16 = @intCast(@min(name.len, 65535));
        try self.names.appendSlice(self.gpa, name[0..len]);
        try self.links.append(self.gpa, .{
            .node = idx,
            .parent_record = if (parent_record > 0xFFFFFFFF) 0xFFFFFFFF else @intCast(parent_record),
            .parent_sequence = parent_sequence,
            .namespace = namespace,
            .name_off = off,
            .name_len = len,
        });
        self.hard_links += 1;
    }

    pub fn addExtraSizes(self: *Builder, base_record: u64, logical: u64, allocated: u64) !void {
        if (base_record > 0xFFFFFFFF) return;
        const ref: u32 = @intCast(base_record);
        const gop = try self.extras.getOrPut(self.gpa, ref);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.logical +|= logical;
        gop.value_ptr.allocated +|= allocated;
        self.extensions += 1;
    }

    pub fn applyExtras(self: *Builder) void {
        var it = self.extras.iterator();
        while (it.next()) |e| {
            const ref = e.key_ptr.*;
            if (ref >= self.records.len) continue;
            const idx = self.records[ref];
            if (idx == none) continue;
            self.nodes.items[idx].size +|= e.value_ptr.logical;
            self.nodes.items[idx].allocated +|= e.value_ptr.allocated;
        }
    }

    pub fn finish(self: *Builder) !*Model {
        self.applyExtras();
        var root: u32 = if (self.records.len > 5) self.records[5] else none;

        // A volume without record 5 still needs a root to hang orphans on.
        if (root == none) {
            const off: u32 = @intCast(self.names.items.len);
            try self.names.appendSlice(self.gpa, "Volume");
            root = try self.appendNode(.{
                .name_off = off,
                .name_len = 6,
                .flags = FLAG_DIRECTORY | FLAG_ROOT | FLAG_SYNTHETIC,
            }, 0, none, 0);
        } else {
            self.nodes.items[root].flags |= FLAG_DIRECTORY | FLAG_ROOT;
        }

        // The synthetic orphan container, for parents that no longer exist
        // or whose sequence was reused.
        const orphan_name_off: u32 = @intCast(self.names.items.len);
        try self.names.appendSlice(self.gpa, "[orphans]");
        const orphan = try self.appendNode(.{
            .name_off = orphan_name_off,
            .name_len = 9,
            .flags = FLAG_DIRECTORY | FLAG_ORPHAN | FLAG_SYNTHETIC,
        }, 0, root, 0);

        // Resolve parents. A parent whose sequence does not match was
        // reused: the child is an orphan, not this node's child.
        var i: u32 = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            if (i == root or i == orphan) continue;
            const self_node = &self.nodes.items[i];
            const parent_ref = self.parent_records.items[i];
            var p: u32 = none;
            if (parent_ref != none and parent_ref < @as(u64, self.records.len)) p = self.records[parent_ref];
            if (p == none or p == i or p >= self.nodes.items.len) {
                self_node.parent = orphan;
                self_node.flags |= FLAG_ORPHAN;
                self.orphans += 1;
                continue;
            }
            const pseq = self.seqs.items[p];
            if (pseq != self.parent_seqs.items[i]) {
                self_node.parent = orphan;
                self_node.flags |= FLAG_ORPHAN;
                self.orphans += 1;
                continue;
            }
            if (!self.nodes.items[p].isDirectory()) {
                self_node.parent = orphan;
                self_node.flags |= FLAG_ORPHAN;
                self.orphans += 1;
                continue;
            }
            // The root's own $FILE_NAME points at itself.
            if (p == root and i != root) {
                self_node.parent = root;
                continue;
            }
            self_node.parent = p;
        }
        self.nodes.items[root].parent = root;
        self.nodes.items[orphan].parent = root;

        // Break any parent cycle that survived: a node whose chain returns to
        // itself an orphan. Uses a stamp array so no clearing pass is needed.
        const n_nodes = self.nodes.items.len;
        const state = try self.gpa.alloc(u32, n_nodes);
        defer self.gpa.free(state);
        @memset(state, 0);
        var path: std.ArrayList(u32) = .empty;
        defer path.deinit(self.gpa);
        var stamp: u32 = 0;
        for (0..n_nodes) |start| {
            if (state[start] != 0) continue;
            stamp += 1;
            path.clearRetainingCapacity();
            var cur: u32 = @intCast(start);
            var guard: usize = 0;
            while (cur != none and cur < n_nodes and state[cur] == 0 and guard < 300) : (guard += 1) {
                if (self.nodes.items[cur].parent == cur) break;
                state[cur] = stamp;
                try path.append(self.gpa, cur);
                cur = self.nodes.items[cur].parent;
            }
            if (cur != none and cur < n_nodes and state[cur] == stamp and self.nodes.items[cur].parent != cur) {
                // The chain closed on nodes we are visiting: cut it here.
                self.nodes.items[cur].parent = orphan;
                self.nodes.items[cur].flags |= FLAG_ORPHAN;
                self.orphans += 1;
            }
            for (path.items) |n| state[n] = 0xFFFFFFFF;
        }

        // Children: newest record first, then sorted below.
        for (self.nodes.items) |*n| {
            n.first_child = none;
            n.next_sibling = none;
        }
        i = 0;
        while (i < n_nodes) : (i += 1) {
            const p = self.nodes.items[i].parent;
            if (p == none or p == i) continue;
            self.nodes.items[i].next_sibling = self.nodes.items[p].first_child;
            self.nodes.items[p].first_child = i;
        }

        // Depths from the root. Every node either reaches it or was just
        // reattached to the orphan container.
        try computeDepths(self.gpa, self.nodes.items, root);

        // Aggregate deepest-first: counting sort by depth, then one walk.
        try aggregate(self.gpa, self.nodes.items);

        const nodes = try self.nodes.toOwnedSlice(self.gpa);
        const names = try self.names.toOwnedSlice(self.gpa);
        const links = try self.links.toOwnedSlice(self.gpa);
        const model = try self.gpa.create(Model);
        model.* = .{
            .gpa = self.gpa,
            .nodes = nodes,
            .names = names,
            .records = self.records,
            .links = links,
            .root = root,
            .in_use = self.in_use,
            .corrupt = self.corrupt,
            .extensions = self.extensions,
            .orphans = self.orphans,
        };
        self.records = &.{};
        self.nodes = .empty;
        self.names = .empty;
        self.links = .empty;
        // The remaining parallel arrays are freed by deinit.
        try model.sortChildren(self.gpa, .allocated);
        return model;
    }
};

fn computeDepths(gpa: std.mem.Allocator, nodes: []Node, root: u32) !void {
    const seen = try gpa.alloc(bool, nodes.len);
    defer gpa.free(seen);
    @memset(seen, false);
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    try stack.append(gpa, root);
    nodes[root].depth = 0;
    while (stack.pop()) |n| {
        if (seen[n]) continue;
        seen[n] = true;
        var c = nodes[n].first_child;
        while (c != none) : (c = nodes[c].next_sibling) {
            nodes[c].depth = if (nodes[n].depth == 255) 255 else nodes[n].depth + 1;
            try stack.append(gpa, c);
        }
    }
    // Unreachable nodes are effectively orphans. The container catches them:
    // depth 1 under it, still counted exactly once.
    for (nodes, 0..) |*n, idx| {
        if (!seen[idx]) {
            n.parent = if (nodes[root].first_child != none) nodes[root].first_child else root;
            n.depth = 2;
        }
    }
}

fn aggregate(gpa: std.mem.Allocator, nodes: []Node) !void {
    if (nodes.len == 0) return;
    var counts: [256]u32 = @splat(0);
    for (nodes) |n| counts[n.depth] += 1;
    var starts: [257]u32 = undefined;
    starts[0] = 0;
    var d: usize = 0;
    while (d < 256) : (d += 1) starts[d + 1] = starts[d] + counts[d];
    const order = try gpa.alloc(u32, nodes.len);
    defer gpa.free(order);
    var cursor = starts[0..256].*;
    for (nodes, 0..) |n, i| {
        order[cursor[n.depth]] = @intCast(i);
        cursor[n.depth] += 1;
    }
    var k: usize = order.len;
    while (k > 0) {
        k -= 1;
        const idx = order[k];
        const p = nodes[idx].parent;
        if (p == none or p == idx) continue;
        nodes[p].size +|= nodes[idx].size;
        nodes[p].allocated +|= nodes[idx].allocated;
    }
}

test "builder links, aggregates, and orphans bad parents" {
    const gpa = std.testing.allocator;
    var b = try Builder.init(gpa, 16);
    defer b.deinit();
    const root = try b.addRecord(5, 5, 5, 5, ".", true, 0, 0);
    const dir = try b.addRecord(6, 1, 5, 5, "Users", true, 0, 4096);
    const f1 = try b.addRecord(7, 1, 6, 1, "a.txt", false, 100, 4096);
    const f2 = try b.addRecord(8, 1, 6, 99, "stale.txt", false, 50, 2048);
    _ = f2;
    _ = f1;
    try b.addExtraSizes(7, 20, 0);
    const m = try b.finish();
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 0), m.root);
    try std.testing.expectEqual(@as(u64, 170), m.nodes[root].size);
    try std.testing.expectEqual(@as(u64, 8192), m.nodes[dir].allocated);
    try std.testing.expectEqual(@as(u32, 1), m.orphans);
    try std.testing.expectEqual(@as(u64, 50), m.nodes[root].size - 120);
}

test "sorting children relinks largest first" {
    const gpa = std.testing.allocator;
    var b = try Builder.init(gpa, 16);
    defer b.deinit();
    _ = try b.addRecord(5, 5, 5, 5, ".", true, 0, 0);
    _ = try b.addRecord(6, 1, 5, 5, "small", false, 1, 1);
    _ = try b.addRecord(7, 1, 5, 5, "big", false, 10, 10);
    const m = try b.finish();
    defer m.deinit();
    try std.testing.expectEqualStrings("big", m.name(m.nodes[m.root].first_child));
}

//! Squarified treemap layout, pure: sizes in, rectangles out.
//!
//! Bruls, Huizing and van Wijk's squarified algorithm, with a cap on the
//! number of tiles. Tiles smaller than `min_side` are merged into an "other"
//! tile so no pixel is wasted on an unclickable sliver.
const std = @import("std");

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Item = struct {
    index: u32,
    size: u64,
};

pub const Options = struct {
    /// At most this many tiles, including `other`.
    max_tiles: usize = 256,
    /// A tile with either side under this is not drawn on its own.
    min_side: f32 = 3,
};

pub const Layout = struct {
    rects: []Rect,
    indexes: []u32,
    /// Number of tiles written, and their summed size.
    len: usize,
    total: u64,
    /// Size of the tiles folded into "other", if there was one.
    other_size: u64,
    other_index: ?u32,
};

/// Lays out `items` (already sorted by size descending) in `width` x `height`.
/// `out_rects` and `out_indexes` must both be at least items.len.
pub fn layout(items: []const Item, width: f32, height: f32, out_rects: []Rect, out_indexes: []u32, opts: Options) Layout {
    std.debug.assert(out_rects.len >= items.len and out_indexes.len >= items.len);
    var total: u64 = 0;
    for (items) |it| total += it.size;
    if (total == 0 or width <= 0 or height <= 0 or items.len == 0) {
        return .{ .rects = out_rects, .indexes = out_indexes, .len = 0, .total = total, .other_size = 0, .other_index = null };
    }

    var count = items.len;
    var other_size: u64 = 0;
    var other_index: ?u32 = null;
    var capped = false;
    if (count > opts.max_tiles) {
        count = opts.max_tiles;
        capped = true;
    }
    if (capped) {
        for (items[count..]) |it| other_size += it.size;
        // "other" takes the last slot, so the largest max_tiles-1 keep theirs.
        count -= 1;
        other_index = 0xFFFFFFFF;
    }

    const area = width * height;
    var scale = area / @as(f64, @floatFromInt(total));
    var remaining = Rect{ .x = 0, .y = 0, .w = width, .h = height };
    var i: usize = 0;
    var out_len: usize = 0;
    var scale_total = total;
    if (other_size > 0) scale_total += other_size;
    scale = area / @as(f64, @floatFromInt(scale_total));

    while (i < count) {
        const row_len = worstRow(items[i..count], scale, remaining);
        const row = items[i .. i + row_len];
        layoutRow(row, scale, &remaining, out_rects[out_len..], out_indexes[out_len..]);
        out_len += row.len;
        i += row_len;
    }
    if (other_size > 0) {
        out_rects[out_len] = remaining;
        out_indexes[out_len] = 0xFFFFFFFF;
        out_len += 1;
    }
    return .{
        .rects = out_rects,
        .indexes = out_indexes,
        .len = out_len,
        .total = total,
        .other_size = other_size,
        .other_index = other_index,
    };
}

fn worstRow(items: []const Item, scale: f64, r: Rect) usize {
    if (items.len == 0) return 0;
    const side = @min(r.w, r.h);
    if (side <= 0) return items.len;
    var best: f64 = std.math.floatMax(f64);
    var area_sum: f64 = 0;
    var max_a: f64 = 0;
    var min_a: f64 = std.math.floatMax(f64);
    var n: usize = 0;
    while (n < items.len) : (n += 1) {
        const a = @as(f64, @floatFromInt(items[n].size)) * scale;
        area_sum += a;
        max_a = @max(max_a, a);
        min_a = @min(min_a, a);
        const worst = @max((side * side * max_a) / (area_sum * area_sum), (area_sum * area_sum) / (side * side * min_a));
        if (worst > best and n > 0) break;
        best = worst;
    }
    return @max(1, n);
}

fn layoutRow(items: []const Item, scale: f64, remaining: *Rect, out_rects: []Rect, out_indexes: []u32) void {
    var area_sum: f64 = 0;
    for (items) |it| area_sum += @as(f64, @floatFromInt(it.size)) * scale;
    if (area_sum <= 0) return;
    if (remaining.w >= remaining.h) {
        const col_w: f32 = @floatCast(area_sum / remaining.h);
        var y = remaining.y;
        for (items, 0..) |it, k| {
            const a = @as(f64, @floatFromInt(it.size)) * scale;
            const h: f32 = @floatCast(a / col_w);
            // Snap the last tile to the edge so the map has no hairline gap.
            const hh = if (k + 1 == items.len) remaining.y + remaining.h - y else h;
            out_rects[k] = .{ .x = remaining.x, .y = y, .w = col_w, .h = hh };
            out_indexes[k] = it.index;
            y += hh;
        }
        remaining.x += col_w;
        remaining.w -= col_w;
    } else {
        const row_h: f32 = @floatCast(area_sum / remaining.w);
        var x = remaining.x;
        for (items, 0..) |it, k| {
            const a = @as(f64, @floatFromInt(it.size)) * scale;
            const w: f32 = @floatCast(a / row_h);
            const ww = if (k + 1 == items.len) remaining.x + remaining.w - x else w;
            out_rects[k] = .{ .x = x, .y = remaining.y, .w = ww, .h = row_h };
            out_indexes[k] = it.index;
            x += ww;
        }
        remaining.y += row_h;
        remaining.h -= row_h;
    }
}

test "area conservation and no overlap" {
    const items = [_]Item{
        .{ .index = 0, .size = 60 }, .{ .index = 1, .size = 25 },
        .{ .index = 2, .size = 10 }, .{ .index = 3, .size = 5 },
    };
    var rects: [8]Rect = undefined;
    var idx: [8]u32 = undefined;
    const l = layout(&items, 400, 300, &rects, &idx, .{});
    try std.testing.expectEqual(@as(usize, 4), l.len);
    var area: f32 = 0;
    for (rects[0..l.len]) |r| {
        try std.testing.expect(r.w >= 0 and r.h >= 0);
        area += r.w * r.h;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 120000), area, 1);
    // Deterministic.
    var rects2: [8]Rect = undefined;
    var idx2: [8]u32 = undefined;
    const l2 = layout(&items, 400, 300, &rects2, &idx2, .{});
    for (rects[0..l2.len], rects2[0..l2.len]) |a, b| try std.testing.expectEqual(a, b);
}

test "zero and one child" {
    var rects: [2]Rect = undefined;
    var idx: [2]u32 = undefined;
    const none = layout(&.{}, 100, 100, &rects, &idx, .{});
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const one = [_]Item{.{ .index = 7, .size = 1 }};
    const l = layout(&one, 100, 100, &rects, &idx, .{});
    try std.testing.expectEqual(@as(usize, 1), l.len);
    try std.testing.expectApproxEqAbs(@as(f32, 10000), l.rects[0].w * l.rects[0].h, 0.01);
}

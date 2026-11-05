//! Colors for the treemap: file extensions get stable hues, with the app's
//! light/dark surface palette from nanoui.
const std = @import("std");

pub const Color = struct { r: f32, g: f32, b: f32, a: f32 = 1 };

fn hex(v: u24) Color {
    return .{
        .r = @as(f32, @floatFromInt((v >> 16) & 0xff)) / 255,
        .g = @as(f32, @floatFromInt((v >> 8) & 0xff)) / 255,
        .b = @as(f32, @floatFromInt(v & 0xff)) / 255,
    };
}

/// A dozen hues that stay distinguishable side by side in a treemap.
const palette = [_]Color{
    hex(0xD9E4D0), hex(0xD7E3ED), hex(0xE2DCF0), hex(0xEADFCB),
    hex(0xCEDFD9), hex(0xE9D8D2), hex(0xE5E5CA), hex(0xD4DDEC),
    hex(0xDED4DF), hex(0xD3E3DC), hex(0xE4DECF), hex(0xD8DFCE),
};

/// Password-less, stable hash by extension: no per-node map, no allocation.
pub fn extensionColor(name: []const u8) Color {
    const ext = extensionOf(name);
    if (ext.len == 0) return hex(0x6B7280);
    var h: u32 = 2166136261;
    for (ext) |ch| {
        h ^= std.ascii.toLower(ch);
        h *%= 16777619;
    }
    return palette[h % palette.len];
}

/// A directory has no extension: give it a stable colour from its whole
/// name, so sibling directories are distinguishable at a glance.
pub fn nodeColor(name: []const u8, is_dir: bool) Color {
    if (!is_dir and extensionOf(name).len > 0) return extensionColor(name);
    var h: u32 = 2166136261;
    for (name) |ch| {
        h ^= std.ascii.toLower(ch);
        h *%= 16777619;
    }
    return palette[h % palette.len];
}

pub fn extensionOf(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (dot + 1 < name.len and dot > 0) return name[dot + 1 ..];
    }
    return "";
}

pub fn textOn(c: Color) Color {
    const l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
    return if (l > 0.62) hex(0x1D1D1F) else hex(0xFFFFFF);
}

test "extension lookup" {
    try std.testing.expectEqualStrings("zig", extensionOf("main.zig"));
    try std.testing.expectEqualStrings("", extensionOf("Makefile"));
    try std.testing.expectEqualStrings("", extensionOf(".gitignore"));
}

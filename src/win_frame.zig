//! Integrated Windows frame, adapted from nanomon's src/win_frame.zig.
//! MIT License — Copyright (c) 2026 Rach Pradhan.
//! Permission is hereby granted, free of charge, to any person obtaining a copy
//! of this software and associated documentation files (the "Software"), to deal
//! in the Software without restriction, including without limitation the rights
//! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//! copies of the Software, and to permit persons to whom the Software is
//! furnished to do so, subject to the following conditions:
//! The above copyright notice and this permission notice shall be included in all
//! copies or substantial portions of the Software.
//! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//! SOFTWARE.
const ui = @import("nanoui").ui;
const chrome = @import("chrome.zig");
const HWND = *anyopaque;
const WNDPROC = *const fn (HWND, u32, usize, isize) callconv(.winapi) isize;
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
const POINT = extern struct { x: i32, y: i32 };
const MARGINS = extern struct { left: i32, right: i32, top: i32, bottom: i32 };
const MONITORINFO = extern struct {
    size: u32 = @sizeOf(MONITORINFO),
    monitor: RECT = .{},
    work: RECT = .{},
    flags: u32 = 0,
};
const NCCALCSIZE_PARAMS = extern struct { rects: [3]RECT, pos: ?*anyopaque };

extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn CallWindowProcW(WNDPROC, HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) i32;
extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, u32) callconv(.winapi) i32;
extern "user32" fn IsZoomed(HWND) callconv(.winapi) i32;
extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) u32;
extern "user32" fn GetSystemMetricsForDpi(i32, u32) callconv(.winapi) i32;
extern "user32" fn LoadImageW(?*anyopaque, ?*const anyopaque, u32, i32, i32, u32) callconv(.winapi) ?*anyopaque;
extern "user32" fn SendMessageW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn MonitorFromWindow(HWND, u32) callconv(.winapi) ?HWND;
extern "user32" fn GetMonitorInfoW(HWND, *MONITORINFO) callconv(.winapi) i32;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "dwmapi" fn DwmExtendFrameIntoClientArea(HWND, *const MARGINS) callconv(.winapi) i32;
extern "dwmapi" fn DwmSetWindowAttribute(HWND, u32, *const anyopaque, u32) callconv(.winapi) i32;

var context: ?*const ui.Context = null;
var installed: ?HWND = null;
var previous: WNDPROC = undefined;

/// This app has one window; inspect its last committed frame for controls.
pub fn setContext(c: ?*const ui.Context) void {
    context = c;
}

pub fn overControl(x: f32, y: f32) bool {
    const c = context orelse return false;
    for (c.hits.items) |hit| {
        const r = hit.rect;
        if (r.w <= 0 or r.h <= 0 or r.y >= chrome.header_h) continue;
        if (x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h) return true;
    }
    return false;
}

/// Keep WS_OVERLAPPEDWINDOW's resize/system-menu semantics; replace its caption.
/// Null in snapshot mode: no window is created or touched.
pub fn install(hwnd: ?HWND) void {
    const h = hwnd orelse return;
    if (installed != null) return;
    const prev = SetWindowLongPtrW(h, -4, @bitCast(@intFromPtr(&proc)));
    if (prev == 0) return;
    previous = @ptrFromInt(@as(usize, @bitCast(prev)));
    installed = h;
    const margins: MARGINS = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 };
    _ = DwmExtendFrameIntoClientArea(h, &margins);
    const rounded: u32 = 2;
    _ = DwmSetWindowAttribute(h, 33, &rounded, @sizeOf(u32));
    _ = SetWindowPos(h, null, 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004);
    setIcon(h);
}

fn setIcon(h: HWND) void {
    const instance = GetModuleHandleW(null) orelse return;
    const dpi = GetDpiForWindow(h);
    // Resource 1 is the same icon Explorer reads from the executable.
    for ([_]i32{ 11, 49 }, [_]usize{ 1, 0 }) |metric, kind| {
        const size = GetSystemMetricsForDpi(metric, dpi);
        if (LoadImageW(instance, @ptrFromInt(1), 1, size, size, 0x8000)) |icon|
            _ = SendMessageW(h, 0x0080, kind, @bitCast(@intFromPtr(icon)));
    }
}

fn proc(h: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    switch (msg) {
        0x0083 => if (wp != 0) { // WM_NCCALCSIZE
            if (IsZoomed(h) != 0) {
                var info: MONITORINFO = .{};
                if (MonitorFromWindow(h, 2)) |monitor| {
                    if (GetMonitorInfoW(monitor, &info) != 0)
                        @as(*NCCALCSIZE_PARAMS, @ptrFromInt(@as(usize, @bitCast(lp)))).rects[0] = info.work;
                }
            }
            return 0;
        },
        0x0084 => if (hitTest(h, lp)) |result| return result, // WM_NCHITTEST
        0x0082 => { // WM_NCDESTROY: the surface context will no longer be alive.
            const result = CallWindowProcW(previous, h, msg, wp, lp);
            installed = null;
            context = null;
            return result;
        },
        else => {},
    }
    return CallWindowProcW(previous, h, msg, wp, lp);
}

fn hitTest(h: HWND, lp: isize) ?isize {
    const bits: usize = @bitCast(lp);
    var p: POINT = .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
    };
    if (ScreenToClient(h, &p) == 0) return null;
    var rect: RECT = .{};
    if (GetClientRect(h, &rect) == 0) return null;
    const dpi = GetDpiForWindow(h);
    const scale = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
    const x = @as(f32, @floatFromInt(p.x)) / scale;
    const y = @as(f32, @floatFromInt(p.y)) / scale;
    return classify(x, y, @as(f32, @floatFromInt(rect.right)) / scale, @as(f32, @floatFromInt(rect.bottom)) / scale, IsZoomed(h) != 0, overControl(x, y));
}

/// Coordinates in logical points, shared with the rendered header.
fn classify(x: f32, y: f32, width: f32, height: f32, maximized: bool, control: bool) isize {
    if (!maximized) {
        const left = x < 6;
        const right = x >= width - 6;
        const top = y < 6;
        const bottom = y >= height - 6;
        if (top and left) return 13;
        if (top and right) return 14;
        if (bottom and left) return 16;
        if (bottom and right) return 17;
        if (left) return 10;
        if (right) return 11;
        if (top) return 12;
        if (bottom) return 15;
    }
    return if (y >= 0 and y < chrome.header_h and !control) 2 else 1;
}

test "frame edges resize, header drags, controls remain client when maximized" {
    const expectEqual = @import("std").testing.expectEqual;
    const points = [_][3]f32{
        .{ 1, 1, 13 },   .{ 999, 1, 14 },   .{ 1, 699, 16 },  .{ 999, 699, 17 },
        .{ 1, 200, 10 }, .{ 999, 200, 11 }, .{ 500, 1, 12 },  .{ 500, 699, 15 },
        .{ 200, 30, 2 }, .{ 200, 62, 1 },   .{ 200, 300, 1 },
    };
    for (points) |p| try expectEqual(@as(isize, @intFromFloat(p[2])), classify(p[0], p[1], 1000, 700, false, false));
    try expectEqual(@as(isize, 1), classify(200, 30, 1000, 700, false, true));
    try expectEqual(@as(isize, 2), classify(200, 1, 1000, 700, true, false));
    try expectEqual(@as(isize, 1), classify(999, 30, 1000, 700, true, true));
    try expectEqual(@as(isize, 1), classify(1, 300, 1000, 700, true, false));
}

test "real hidden Win32 frame has no system caption and retains resize hit tests" {
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const std = @import("std");
    const native = struct {
        extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
        extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
        extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) i32;
        extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
        extern "user32" fn ClientToScreen(HWND, *POINT) callconv(.winapi) i32;
        extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) i32;
    };
    const wide = std.unicode.utf8ToUtf16LeStringLiteral;
    // Same WS_OVERLAPPEDWINDOW as nanoui, deliberately without WS_VISIBLE.
    const h = native.CreateWindowExW(0, wide("STATIC"), wide("Byakugan frame regression"), 0x00CF0000, 100, 100, 1000, 700, null, null, GetModuleHandleW(null), null) orelse return error.CreateWindow;
    defer _ = native.DestroyWindow(h);
    try std.testing.expectEqual(@as(i32, 0), native.IsWindowVisible(h));
    const style = native.GetWindowLongPtrW(h, -16);
    var before: RECT = .{};
    try std.testing.expect(GetClientRect(h, &before) != 0);
    install(h);
    install(h);
    try std.testing.expect(SendMessageW(h, 0x007F, 1, 0) != 0); // WM_GETICON, large
    try std.testing.expect(SendMessageW(h, 0x007F, 0, 0) != 0); // WM_GETICON, small
    try std.testing.expectEqual(style, native.GetWindowLongPtrW(h, -16));
    try std.testing.expect(style & 0x00040000 != 0); // WS_THICKFRAME
    try std.testing.expect(style & 0x00030000 == 0x00030000); // min/max boxes
    var window: RECT = .{};
    var client: RECT = .{};
    try std.testing.expect(native.GetWindowRect(h, &window) != 0);
    try std.testing.expect(GetClientRect(h, &client) != 0);
    // A restored system caption would consume part of these dimensions.
    try std.testing.expectEqual(window.right - window.left, client.right);
    try std.testing.expectEqual(window.bottom - window.top, client.bottom);
    try std.testing.expect(client.bottom > before.bottom);
    const dpi = GetDpiForWindow(h);
    const scale = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
    const cases = [_][3]f32{ .{ 200, 30, 2 }, .{ 1, 200, 10 }, .{ 200, 1, 12 }, .{ 1, 1, 13 }, .{ 200, 200, 1 } };
    for (cases) |case| {
        var point: POINT = .{ .x = @intFromFloat(case[0] * scale), .y = @intFromFloat(case[1] * scale) };
        try std.testing.expect(native.ClientToScreen(h, &point) != 0);
        const coordinates: usize = @as(u16, @bitCast(@as(i16, @intCast(point.x)))) | (@as(usize, @as(u16, @bitCast(@as(i16, @intCast(point.y))))) << 16);
        try std.testing.expectEqual(@as(isize, @intFromFloat(case[2])), SendMessageW(h, 0x0084, 0, @bitCast(coordinates)));
    }
    try std.testing.expectEqual(@as(i32, 0), native.IsWindowVisible(h));
}

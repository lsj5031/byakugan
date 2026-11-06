//! Reopen through the desktop user's Explorer, never by stripping our token.
//! Microsoft: devblogs.microsoft.com/oldnewthing/20131118-00/?p=2643
//! Desktop view lookup: /oldnewthing/20130318-00/?p=4933
const std = @import("std");
const w = std.os.windows;
const cleanup = @import("cleanup.zig");
const alloc = std.heap.c_allocator;
const Guid = w.GUID;
const clsid_windows = Guid.parse("{9ba05972-f6a8-11cf-a442-00a0c90a8f39}");
const iid_windows = Guid.parse("{85cb6900-4d95-11cf-960c-0080c7f4ee85}");
const iid_service = Guid.parse("{6d5140c1-7436-11ce-8034-00aa006009fa}");
const sid_browser = Guid.parse("{4c96be40-915c-11cf-99d3-00aa004ae837}");
const iid_browser = Guid.parse("{000214e2-0000-0000-c000-000000000046}");
const iid_dispatch = Guid.parse("{00020400-0000-0000-c000-000000000046}");
const iid_folder = Guid.parse("{e7a1af80-4d96-11cf-960c-0080c7f4ee85}");
const iid_shell = Guid.parse("{a4c6892c-3ba9-11d2-9dea-00c04fb16162}");

const Com = extern struct {
    vtable: [*]const *const anyopaque,
    fn slot(self: *Com, comptime T: type, index: usize) T {
        return @ptrCast(@alignCast(self.vtable[index]));
    }
    fn release(self: *Com) void {
        _ = self.slot(*const fn (*Com) callconv(.winapi) u32, 2)(self);
    }
    fn query(self: *Com, id: *const Guid) !*Com {
        var result: ?*Com = null;
        try check(self.slot(*const fn (*Com, *const Guid, *?*Com) callconv(.winapi) i32, 0)(self, id, &result));
        return result orelse error.NoDesktopShell;
    }
};
// VARIANT is 24 bytes on Win64 (the BRECORD union member has two pointers).
const Variant = extern struct {
    kind: u16 = 0,
    reserved: [3]u16 = @splat(0),
    data: extern union { number: i64, string: ?[*:0]const u16, record: [2]?*anyopaque } = .{ .number = 0 },
    fn integer(value: i32) Variant {
        return .{ .kind = 3, .data = .{ .number = value } };
    }
    fn string(value: [*:0]const u16) Variant {
        return .{ .kind = 8, .data = .{ .string = value } };
    }
};
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(*const Guid, ?*anyopaque, u32, *const Guid, *?*Com) callconv(.winapi) i32;
extern "oleaut32" fn SysAllocString([*:0]const u16) callconv(.winapi) ?[*:0]u16;
extern "oleaut32" fn SysFreeString([*:0]const u16) callconv(.winapi) void;
extern "kernel32" fn GetModuleFileNameW(?w.HANDLE, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn OpenProcess(u32, i32, u32) callconv(.winapi) ?w.HANDLE;
extern "user32" fn GetShellWindow() callconv(.winapi) ?w.HWND;
extern "user32" fn GetWindowThreadProcessId(w.HWND, *u32) callconv(.winapi) u32;
extern "advapi32" fn OpenProcessToken(w.HANDLE, u32, *w.HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(.winapi) i32;

fn check(hr: i32) !void {
    if (hr < 0) {
        std.log.warn("normal reopen shell hresult=0x{x}", .{@as(u32, @bitCast(hr))});
        return error.NoDesktopShell;
    }
}

fn verifyShell(view: *Com) !void {
    var hwnd: ?w.HWND = null;
    try check(view.slot(*const fn (*Com, *?w.HWND) callconv(.winapi) i32, 3)(view, &hwnd));
    var pid: u32 = 0;
    if (GetWindowThreadProcessId(hwnd orelse return error.NoDesktopShell, &pid) == 0) return error.NoDesktopShell;
    const process = OpenProcess(0x1000, 0, pid) orelse return error.NoDesktopShell;
    defer w.CloseHandle(process);
    var token: w.HANDLE = undefined;
    if (OpenProcessToken(process, 8, &token) == 0) return error.NoDesktopShell;
    defer w.CloseHandle(token);
    var elevated: u32 = 1;
    var returned: u32 = 0;
    if (GetTokenInformation(token, 20, &elevated, 4, &returned) == 0 or returned != 4 or elevated != 0) return error.NoDesktopShell;
}

const Desktop = struct {
    shell: *Com,
    fn init() !Desktop {
        try check(CoInitializeEx(null, 2));
        errdefer CoUninitialize();
        var windows: ?*Com = null;
        try check(CoCreateInstance(&clsid_windows, null, 4, &iid_windows, &windows));
        const collection = windows orelse return error.NoDesktopShell;
        defer collection.release();
        var location = Variant.integer(0); // CSIDL_DESKTOP
        var empty = Variant{};
        var hwnd: i32 = 0;
        var dispatch: ?*Com = null;
        try check(collection.slot(*const fn (*Com, *Variant, *Variant, i32, *i32, i32, *?*Com) callconv(.winapi) i32, 15)(collection, &location, &empty, 8, &hwnd, 1, &dispatch));
        const desktop = dispatch orelse return error.NoDesktopShell;
        defer desktop.release();
        const service = try desktop.query(&iid_service);
        defer service.release();
        var browser_out: ?*Com = null;
        try check(service.slot(*const fn (*Com, *const Guid, *const Guid, *?*Com) callconv(.winapi) i32, 3)(service, &sid_browser, &iid_browser, &browser_out));
        const browser = browser_out orelse return error.NoDesktopShell;
        defer browser.release();
        var view_out: ?*Com = null;
        try check(browser.slot(*const fn (*Com, *?*Com) callconv(.winapi) i32, 15)(browser, &view_out));
        const view = view_out orelse return error.NoDesktopShell;
        defer view.release();
        try verifyShell(view);
        var object_out: ?*Com = null;
        try check(view.slot(*const fn (*Com, u32, *const Guid, *?*Com) callconv(.winapi) i32, 15)(view, 0, &iid_dispatch, &object_out));
        const object = object_out orelse return error.NoDesktopShell;
        defer object.release();
        const folder = try object.query(&iid_folder);
        defer folder.release();
        var app_out: ?*Com = null;
        try check(folder.slot(*const fn (*Com, *?*Com) callconv(.winapi) i32, 7)(folder, &app_out));
        const app = app_out orelse return error.NoDesktopShell;
        defer app.release();
        return .{ .shell = try app.query(&iid_shell) };
    }
    fn deinit(self: Desktop) void {
        self.shell.release();
        CoUninitialize();
    }
};

/// The child fails closed before creating a window if the shell did not lower
/// elevation (for example an executable configured to always run as admin).
pub fn requested(argv: []const []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, "--require-unelevated")) return true;
    return false;
}

fn parameters(buf: []u8, path: []const u8) ![]const u8 {
    try cleanup.validatePath(path);
    if (path.len <= 3) return error.UnsafePath;
    const split = std.mem.lastIndexOfScalar(u8, path, '\\') orelse return error.UnsafePath;
    const parent = path[0..@max(3, split)];
    // Validated paths contain no quotes. Double a root's trailing slash before
    // its closing quote according to Windows argv rules; no command shell runs.
    return std.fmt.bufPrint(buf, "--require-unelevated --folder=\"{s}{s}\" --select-child=\"{s}\"", .{ parent, if (parent[parent.len - 1] == '\\') "\\" else "", path[split + 1 ..] });
}

/// Success means Explorer accepted the request, not that the new scan finished.
/// The caller keeps the original window and its result open in every case.
pub fn reopen(path: []const u8) !void {
    _ = try cleanup.inspect(path);
    var buf: [8192]u8 = undefined;
    const args = try parameters(&buf, path);
    const args_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, args);
    defer alloc.free(args_w);
    const args_bstr = SysAllocString(args_w.ptr) orelse return error.OutOfMemory;
    defer SysFreeString(args_bstr);
    var exe_buf: [32768]u16 = undefined;
    const len = GetModuleFileNameW(null, &exe_buf, exe_buf.len);
    if (len == 0 or len >= exe_buf.len) return error.ExecutablePathFailed;
    const exe = SysAllocString(@ptrCast(&exe_buf)) orelse return error.OutOfMemory;
    defer SysFreeString(exe);
    const verb = SysAllocString(std.unicode.utf8ToUtf16LeStringLiteral("open")) orelse return error.OutOfMemory;
    defer SysFreeString(verb);
    const desktop = try Desktop.init();
    defer desktop.deinit();
    try check(desktop.shell.slot(*const fn (*Com, [*:0]const u16, Variant, Variant, Variant, Variant) callconv(.winapi) i32, 31)(desktop.shell, exe, Variant.string(args_bstr), .{}, Variant.string(verb), Variant.integer(1)));
    std.log.info("normal reopen accepted by unelevated desktop shell", .{});
}

test "normal reopen arguments preserve parent and selected folder without shell interpretation" {
    for ([_][]const u8{ "C:\\Folder", "D:\\Projects\\日本語 & 100%", "T:\\space here\\child (old)" }) |path| {
        var buf: [8192]u8 = undefined;
        const params = try parameters(&buf, path);
        const command = try std.fmt.allocPrint(std.testing.allocator, "app.exe {s}", .{params});
        defer std.testing.allocator.free(command);
        const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, command);
        defer std.testing.allocator.free(utf16);
        var it = try std.process.Args.Iterator.Windows.init(std.testing.allocator, utf16);
        defer it.deinit();
        try std.testing.expectEqualStrings("app.exe", it.next().?);
        try std.testing.expectEqualStrings("--require-unelevated", it.next().?);
        const split = std.mem.lastIndexOfScalar(u8, path, '\\').?;
        try std.testing.expectEqualStrings(path[0..@max(3, split)], it.next().?[9..]);
        try std.testing.expectEqualStrings(path[split + 1 ..], it.next().?[15..]);
        try std.testing.expect(it.next() == null);
    }
    var buf: [8192]u8 = undefined;
    try std.testing.expectError(error.UnsafePath, parameters(&buf, "C:\\"));
    try std.testing.expectError(error.UnsafePath, parameters(&buf, "C:\\bad\" --demo"));
}

test "desktop shell inspection accepts a normal shell and rejects an unavailable or elevated shell" {
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 24 else 16), @sizeOf(Variant));
    // CI can run without Explorer or with an elevated desktop. Determine that
    // independently of the COM lookup; never turn an arbitrary COM error into
    // a pass or skip on an ordinary unelevated desktop.
    const hwnd = GetShellWindow() orelse {
        std.debug.print("desktop shell absent: expecting safe rejection\n", .{});
        try std.testing.expectError(error.NoDesktopShell, Desktop.init());
        return;
    };
    var pid: u32 = 0;
    try std.testing.expect(GetWindowThreadProcessId(hwnd, &pid) != 0);
    const process = OpenProcess(0x1000, 0, pid) orelse return error.ShellProcessInspectionFailed;
    defer w.CloseHandle(process);
    var token: w.HANDLE = undefined;
    try std.testing.expect(OpenProcessToken(process, 8, &token) != 0);
    defer w.CloseHandle(token);
    var elevated: u32 = 1;
    var returned: u32 = 0;
    try std.testing.expect(GetTokenInformation(token, 20, &elevated, @sizeOf(u32), &returned) != 0);
    try std.testing.expectEqual(@as(u32, @sizeOf(u32)), returned);
    std.debug.print("desktop shell TokenElevation={}: expecting {s}\n", .{ elevated != 0, if (elevated != 0) "safe rejection" else "successful inspection" });
    if (elevated != 0) {
        try std.testing.expectError(error.NoDesktopShell, Desktop.init());
        return;
    }
    const desktop = try Desktop.init();
    defer desktop.deinit();
}

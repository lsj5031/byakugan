//! Deliberate file and folder actions. No permanent-delete fallback exists here.
const std = @import("std");
const model = @import("byakugan").model;
const w = std.os.windows;
const alloc = std.heap.c_allocator;

pub const Error = error{ UnsafePath, Missing, Changed, Unavailable, ShellFailed };
pub const Identity = extern struct {
    attributes: u32,
    created: w.FILETIME,
    accessed: w.FILETIME,
    written: w.FILETIME,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};
extern "kernel32" fn GetFileInformationByHandle(w.HANDLE, *Identity) callconv(.winapi) i32;
extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW([*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*w.SECURITY_ATTRIBUTES, u32, u32, ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "shell32" fn ShellExecuteW(?w.HWND, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, i32) callconv(.winapi) isize;
extern "shell32" fn SHParseDisplayName([*:0]const u16, ?*anyopaque, *?*anyopaque, u32, ?*u32) callconv(.winapi) i32;
extern "shell32" fn SHOpenFolderAndSelectItems(*const anyopaque, u32, ?*const anyopaque, u32) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;

fn wide(path: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
}
fn componentSafe(name: []const u8) bool {
    if (name.len == 0 or name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    for (name) |ch| if (ch < 32 or std.mem.indexOfScalar(u8, "\\/:*?\"<>|", ch) != null) return false;
    return true;
}

/// Assemble paths without the display helper's intentional truncation. Virtual
/// groups, orphan paths, and protected ancestors never become shell targets.
pub fn selectionPath(m: *const model.Model, selected: u32, root: []const u8, out: []u8) Error![]const u8 {
    if (selected >= m.nodes.len) return error.UnsafePath;
    var chain: [256]u32 = undefined;
    var len: usize = 0;
    var node = selected;
    while (node != m.root) {
        if (node == model.none or node >= m.nodes.len or len == chain.len) return error.UnsafePath;
        if (m.nodes[node].flags & (model.FLAG_SYSTEM | model.FLAG_SYNTHETIC | model.FLAG_ORPHAN) != 0) return error.UnsafePath;
        if (!componentSafe(m.name(node))) return error.UnsafePath;
        chain[len] = node;
        len += 1;
        node = m.nodes[node].parent;
    }
    if (root.len > out.len) return error.UnsafePath;
    @memcpy(out[0..root.len], root);
    var used = root.len;
    while (len > 0) {
        len -= 1;
        const name = m.name(chain[len]);
        const slash: usize = if (used > 0 and out[used - 1] == '\\') 0 else 1;
        if (used + slash + name.len > out.len) return error.UnsafePath;
        if (slash != 0) out[used] = '\\';
        used += slash;
        @memcpy(out[used..][0..name.len], name);
        used += name.len;
    }
    const path = out[0..used];
    try validatePath(path);
    return path;
}

/// Restrict to canonical local drive paths; reject shell/device namespaces,
/// streams, traversal, and OS-managed trees before consulting the filesystem.
pub fn validatePath(path: []const u8) Error!void {
    if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\') return error.UnsafePath;
    if (path.len == 3) return;
    var parts = std.mem.splitScalar(u8, path[3..], '\\');
    var first = true;
    while (parts.next()) |part| {
        if (!componentSafe(part)) return error.UnsafePath;
        if (first) {
            for ([_][]const u8{ "Windows", "Program Files", "Program Files (x86)", "ProgramData", "$Recycle.Bin", "System Volume Information", "Recovery", "$Extend" }) |protected| {
                if (std.ascii.eqlIgnoreCase(part, protected)) return error.UnsafePath;
            }
        }
        if (part[0] == '$') return error.UnsafePath;
        first = false;
    }
}

pub fn inspect(path: []const u8) !Identity {
    try validatePath(path);
    const path_w = try wide(path);
    defer alloc.free(path_w);
    // Check every prefix: an apparently harmless child under a junction can
    // otherwise point into a protected tree or another volume.
    var i: usize = 3;
    while (i <= path_w.len) : (i += 1) {
        if (i < path_w.len and path_w[i] != '\\') continue;
        const saved = path_w[i];
        path_w[i] = 0;
        const attrs = GetFileAttributesW(path_w.ptr);
        path_w[i] = saved;
        if (attrs == 0xffffffff) return switch (w.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.Missing,
            else => error.Unavailable,
        };
        if (attrs & (0x400 | 0x4) != 0 or (i < path_w.len and attrs & 0x10 == 0)) return error.UnsafePath;
    }
    const handle = CreateFileW(path_w.ptr, 0, 7, null, 3, 0x02200000, null);
    if (handle == w.INVALID_HANDLE_VALUE) return error.Unavailable;
    defer w.CloseHandle(handle);
    var identity: Identity = undefined;
    if (GetFileInformationByHandle(handle, &identity) == 0) return error.Unavailable;
    if (identity.attributes & (0x400 | 0x4) != 0) return error.UnsafePath;
    return identity;
}
pub fn same(a: Identity, b: Identity) bool {
    return a.attributes & 0x10 == b.attributes & 0x10 and
        a.volume == b.volume and a.index_high == b.index_high and a.index_low == b.index_low and
        a.created.dwLowDateTime == b.created.dwLowDateTime and a.created.dwHighDateTime == b.created.dwHighDateTime;
}
pub fn prepareRecycle(path: []const u8) !Identity {
    try validatePath(path);
    if (path.len <= 3 or std.ascii.eqlIgnoreCase(path[3..], "Users")) return error.UnsafePath;
    const drive: [4:0]u16 = .{ path[0], ':', '\\', 0 };
    if (GetDriveTypeW(&drive) != 3) return error.UnsafePath; // fixed disks only
    return inspect(path);
}
pub fn openExplorer(path: []const u8) !void {
    const identity = try inspect(path);
    const path_w = try wide(path);
    defer alloc.free(path_w);
    if (CoInitializeEx(null, 2) < 0) return error.Unavailable;
    defer CoUninitialize();
    if (identity.attributes & 0x10 != 0) {
        if (ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("explore"), path_w.ptr, null, null, 1) <= 32) return error.ShellFailed;
    } else {
        var item: ?*anyopaque = null;
        if (SHParseDisplayName(path_w.ptr, null, &item, 0, null) < 0) return error.ShellFailed;
        const target = item orelse return error.ShellFailed;
        defer CoTaskMemFree(target);
        // cidl=0 opens the parent and selects this item; never execute a file.
        if (SHOpenFolderAndSelectItems(target, 0, null, 0) < 0) return error.ShellFailed;
    }
}

// CLSID_RecycleBin from the Windows SDK's ShlGuid.h. This opens the shell
// folder; it never empties the bin or executes a selected filesystem item.
const recycle_bin = std.unicode.utf8ToUtf16LeStringLiteral("::{645FF040-5081-101B-9F08-00AA002F954E}");
pub fn openRecycleBin() !void {
    if (CoInitializeEx(null, 2) < 0) return error.Unavailable;
    defer CoUninitialize();
    if (ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), recycle_bin, null, null, 1) <= 32) return error.ShellFailed;
}

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const clsid: Guid = .{ .a = 0x3ad05575, .b = 0x8857, .c = 0x4850, .d = .{ 0x92, 0x77, 0x11, 0xb8, 0x5b, 0xdb, 0x8e, 0x09 } };
const iid: Guid = .{ .a = 0x947aab5f, .b = 0x0a5c, .c = 0x4c13, .d = .{ 0xb4, 0xd6, 0x4b, 0xf7, 0x83, 0x6f, 0xc9, 0xf8 } };
const shell_iid: Guid = .{ .a = 0x43826d1e, .b = 0xe718, .c = 0x42ee, .d = .{ 0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe } };
const sink_iid: Guid = .{ .a = 0x04b0f1a7, .b = 0x9490, .c = 0x44bc, .d = .{ 0x96, 0xe1, 0x42, 0x96, 0xa3, 0x12, 0x52, 0xe2 } };
const unknown_iid: Guid = .{ .a = 0, .b = 0, .c = 0, .d = .{ 0xc0, 0, 0, 0, 0, 0, 0, 0x46 } };
const Com = extern struct {
    vtable: [*]const *const anyopaque,
    fn slot(self: *Com, comptime T: type, index: usize) T {
        return @ptrCast(@alignCast(self.vtable[index]));
    }
    fn release(self: *Com) void {
        _ = self.slot(*const fn (*Com) callconv(.winapi) u32, 2)(self);
    }
};
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(*const Guid, ?*anyopaque, u32, *const Guid, *?*Com) callconv(.winapi) i32;
extern "shell32" fn SHCreateItemFromParsingName([*:0]const u16, ?*anyopaque, *const Guid, *?*Com) callconv(.winapi) i32;
const abort_hr: i32 = @bitCast(@as(u32, 0x80004004));

/// Veto any attempt to switch from recycling to permanent deletion. This
/// guard is additional to FOFX_RECYCLEONDELETE; ALLOWUNDO alone is insufficient.
const Sink = extern struct {
    vtable: [*]const *const anyopaque = &table,
    path_ptr: ?[*]const u8 = null,
    path_len: usize = 0,
    identity: Identity = std.mem.zeroes(Identity),
    recycled: bool = false,
    rejected: bool = false,
    item_hr: i32 = abort_hr,
    fn query(self: *Sink, id: *const Guid, out: *?*anyopaque) callconv(.winapi) i32 {
        if (std.mem.eql(u8, std.mem.asBytes(id), std.mem.asBytes(&sink_iid)) or std.mem.eql(u8, std.mem.asBytes(id), std.mem.asBytes(&unknown_iid))) {
            out.* = self;
            return 0;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002));
    }
    fn ref(_: *Sink) callconv(.winapi) u32 {
        return 1;
    }
    fn start(_: *Sink) callconv(.winapi) i32 {
        return 0;
    }
    fn finish(_: *Sink, _: i32) callconv(.winapi) i32 {
        return 0;
    }
    fn preRename(_: *Sink, _: u32, _: ?*Com, _: ?[*:0]const u16) callconv(.winapi) i32 {
        return abort_hr;
    }
    fn postRename(_: *Sink, _: u32, _: ?*Com, _: ?[*:0]const u16, _: i32, _: ?*Com) callconv(.winapi) i32 {
        return 0;
    }
    fn preMove(_: *Sink, _: u32, _: ?*Com, _: ?*Com, _: ?[*:0]const u16) callconv(.winapi) i32 {
        return abort_hr;
    }
    fn postMove(_: *Sink, _: u32, _: ?*Com, _: ?*Com, _: ?[*:0]const u16, _: i32, _: ?*Com) callconv(.winapi) i32 {
        return 0;
    }
    fn preDelete(self: *Sink, flags: u32, _: ?*Com) callconv(.winapi) i32 {
        if (flags & 0x80 == 0) {
            self.rejected = true;
            return abort_hr;
        }
        if (self.path_ptr) |ptr| {
            const current = inspect(ptr[0..self.path_len]) catch {
                self.rejected = true;
                return abort_hr;
            };
            if (!same(current, self.identity)) {
                self.rejected = true;
                return abort_hr;
            }
        }
        return 0;
    }
    fn postDelete(self: *Sink, flags: u32, _: ?*Com, hr: i32, recycled_item: ?*Com) callconv(.winapi) i32 {
        self.item_hr = hr;
        self.recycled = hr >= 0 and flags & 0x80 != 0 and recycled_item != null;
        return 0;
    }
    fn preNew(_: *Sink, _: u32, _: ?*Com, _: ?[*:0]const u16) callconv(.winapi) i32 {
        return abort_hr;
    }
    fn postNew(_: *Sink, _: u32, _: ?*Com, _: ?[*:0]const u16, _: ?[*:0]const u16, _: u32, _: i32, _: ?*Com) callconv(.winapi) i32 {
        return 0;
    }
    fn progress(_: *Sink, _: u32, _: u32) callconv(.winapi) i32 {
        return 0;
    }
    const table = [_]*const anyopaque{ @ptrCast(&query), @ptrCast(&ref), @ptrCast(&ref), @ptrCast(&start), @ptrCast(&finish), @ptrCast(&preRename), @ptrCast(&postRename), @ptrCast(&preMove), @ptrCast(&postMove), @ptrCast(&preMove), @ptrCast(&postMove), @ptrCast(&preDelete), @ptrCast(&postDelete), @ptrCast(&preNew), @ptrCast(&postNew), @ptrCast(&progress), @ptrCast(&start), @ptrCast(&start), @ptrCast(&start) };
};

pub const Outcome = enum { recycled, cancelled, incomplete, rejected };
pub const Result = struct { outcome: Outcome = .rejected, hr: i32 = 0, attempted: bool = false };
pub fn recycle(path: []const u8, identity: Identity) !Result {
    const current = try prepareRecycle(path);
    if (!same(current, identity)) return error.Changed;
    if (CoInitializeEx(null, 2) < 0) return error.Unavailable;
    defer CoUninitialize();
    var operation: ?*Com = null;
    if (CoCreateInstance(&clsid, null, 1, &iid, &operation) < 0) return error.ShellFailed;
    const op = operation orelse return error.ShellFailed;
    defer op.release();
    const path_w = try wide(path);
    defer alloc.free(path_w);
    var item: ?*Com = null;
    if (SHCreateItemFromParsingName(path_w.ptr, null, &shell_iid, &item) < 0) return error.Missing;
    const target = item orelse return error.Missing;
    defer target.release();
    // Silent, no error/UAC UI, fail on first error, recycle only, Explorer undo.
    const flags: u32 = 0x4 | 0x10 | 0x400 | 0x2000 | 0x80000 | 0x100000 | 0x20000000;
    if (op.slot(*const fn (*Com, u32) callconv(.winapi) i32, 5)(op, flags) < 0) return error.ShellFailed;
    var sink: Sink = .{ .path_ptr = path.ptr, .path_len = path.len, .identity = identity };
    if (op.slot(*const fn (*Com, *Com, *Sink) callconv(.winapi) i32, 18)(op, target, &sink) < 0) return error.ShellFailed;
    const hr = op.slot(*const fn (*Com) callconv(.winapi) i32, 21)(op);
    var aborted: i32 = 1;
    const abort_status = op.slot(*const fn (*Com, *i32) callconv(.winapi) i32, 22)(op, &aborted);
    const cancelled_hr: i32 = @bitCast(@as(u32, 0x800704c7));
    return .{ .attempted = true, .hr = if (hr < 0) hr else sink.item_hr, .outcome = if (sink.rejected) .rejected else if (hr >= 0 and abort_status >= 0 and aborted == 0 and sink.recycled) .recycled else if (hr == cancelled_hr or sink.item_hr == cancelled_hr) .cancelled else .incomplete };
}

test "unsafe shell targets and truncated model paths are rejected" {
    for ([_][]const u8{ "C:", "\\\\server\\share", "C:\\Windows\\Temp", "C:\\ProgramData\\x", "C:\\a\\..\\b", "C:\\a:stream", "C:\\a\\", "C:\\a.\\b", "C:\\$Recycle.Bin", "C:\\a/b" }) |path| {
        try std.testing.expectError(error.UnsafePath, validatePath(path));
    }
    try validatePath("D:\\Projects\\日本語");
    var builder = try model.Builder.init(std.testing.allocator, 10);
    defer builder.deinit();
    _ = try builder.addRecord(5, 1, 5, 1, "root", true, 0, 0);
    const child = try builder.addRecord(6, 1, 5, 1, "Downloads", true, 0, 0);
    const m = try builder.finish();
    defer m.deinit();
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\Users\\someone\\Downloads", try selectionPath(m, child, "C:\\Users\\someone", &buf));
    try std.testing.expectError(error.UnsafePath, selectionPath(m, child, "C:\\Users\\someone", buf[0..20]));
    m.nodes[child].flags |= model.FLAG_SYNTHETIC;
    try std.testing.expectError(error.UnsafePath, selectionPath(m, child, "C:\\Users\\someone", &buf));
}

test "recycle callback refuses permanent deletion and requires recycled item" {
    var sink: Sink = .{};
    try std.testing.expect(Sink.preDelete(&sink, 0, null) < 0);
    try std.testing.expect(sink.rejected);
    sink = .{};
    try std.testing.expectEqual(@as(i32, 0), Sink.preDelete(&sink, 0x80, null));
    _ = Sink.postDelete(&sink, 0x80, null, 0, null);
    try std.testing.expect(!sink.recycled);
}

test "replaced file and folder identities are rejected before any recycle operation" {
    try testReplacement(true);
    try testReplacement(false);
}

fn testReplacement(directory: bool) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    if (directory) try tmp.dir.createDir(io, "chosen", .default_dir) else try tmp.dir.writeFile(io, .{ .sub_path = "chosen", .data = "original" });
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}\\chosen", .{buf[0..len]});
    defer std.testing.allocator.free(path);
    const original = try inspect(path);
    try std.testing.expect(same(original, try inspect(path)));
    try tmp.dir.rename("chosen", tmp.dir, "original", io);
    if (directory) try tmp.dir.createDir(io, "chosen", .default_dir) else try tmp.dir.writeFile(io, .{ .sub_path = "chosen", .data = "replacement" });
    try std.testing.expect(!same(original, try inspect(path)));
    var sink: Sink = .{ .path_ptr = path.ptr, .path_len = path.len, .identity = original };
    try std.testing.expect(Sink.preDelete(&sink, 0x80, null) < 0);
    try std.testing.expectError(error.Changed, recycle(path, original));
    try tmp.dir.access(io, "chosen", .{});
    try tmp.dir.access(io, "original", .{});
}

test "native shell accepts file and folder recycle requests without executing them" {
    try testShellQueue(true);
    try testShellQueue(false);
}

fn testShellQueue(directory: bool) !void {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    try tmp.dir.writeFile(io, .{ .sub_path = "日本語 & file.bin", .data = "retained" });
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ buf[0..len], if (directory) "" else "\\日本語 & file.bin" });
    defer std.testing.allocator.free(path);
    const path_w = try wide(path);
    defer alloc.free(path_w);
    try std.testing.expect(CoInitializeEx(null, 2) >= 0);
    defer CoUninitialize();
    var pidl: ?*anyopaque = null;
    try std.testing.expect(SHParseDisplayName(path_w.ptr, null, &pidl, 0, null) >= 0);
    defer CoTaskMemFree(pidl);
    try std.testing.expect(pidl != null); // parse only; never open Explorer
    var bin_pidl: ?*anyopaque = null;
    try std.testing.expect(SHParseDisplayName(recycle_bin, null, &bin_pidl, 0, null) >= 0);
    defer CoTaskMemFree(bin_pidl);
    try std.testing.expect(bin_pidl != null); // resolve the actual shell folder without opening it
    var operation: ?*Com = null;
    try std.testing.expect(CoCreateInstance(&clsid, null, 1, &iid, &operation) >= 0);
    const op = operation.?;
    defer op.release();
    var item: ?*Com = null;
    try std.testing.expect(SHCreateItemFromParsingName(path_w.ptr, null, &shell_iid, &item) >= 0);
    const target = item.?;
    defer target.release();
    try std.testing.expect(op.slot(*const fn (*Com, u32) callconv(.winapi) i32, 5)(op, 0x20182414) >= 0);
    var sink: Sink = .{};
    try std.testing.expect(op.slot(*const fn (*Com, *Com, *Sink) callconv(.winapi) i32, 18)(op, target, &sink) >= 0);
    // Releasing an unperformed operation cancels its queue. Never call slot 21
    // here: validation must not touch the user's Recycle Bin or desktop.
    try tmp.dir.access(io, ".", .{});
    var contents: [32]u8 = undefined;
    try std.testing.expectEqualStrings("retained", try tmp.dir.readFile(io, "日本語 & file.bin", &contents));
}

//! A deliberately partial, non-elevated scan of one folder tree.
//!
//! This is the escape hatch when Windows will not let a normal user open a
//! volume for the MFT. It uses only ordinary file APIs, follows no reparse
//! points, skips entries the account cannot read, and counts those skips.
//! It is not a substitute for the MFT scan and is labelled as such everywhere.
const std = @import("std");
const windows = std.os.windows;
const model = @import("model.zig");
const mft = @import("mft.zig");
const scan = @import("scan.zig");

const HANDLE = windows.HANDLE;
const DWORD = u32;
const BOOL = i32;
const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

const FILE_READ_ATTRIBUTES: u32 = 0x80;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const FILE_SHARE_DELETE: u32 = 0x00000004;
const OPEN_EXISTING: u32 = 3;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
const FILE_ATTRIBUTE_SPARSE_FILE: u32 = 0x200;
const FILE_ATTRIBUTE_COMPRESSED: u32 = 0x800;

const CreateFileW = struct {
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: u32,
        share: u32,
        attrs: ?*windows.SECURITY_ATTRIBUTES,
        creation: u32,
        flags: u32,
        template: ?HANDLE,
    ) callconv(.winapi) HANDLE;
}.CreateFileW;

const GetFileInformationByHandle = struct {
    extern "kernel32" fn GetFileInformationByHandle(
        file: HANDLE,
        info: *BY_HANDLE_FILE_INFORMATION,
    ) callconv(.winapi) BOOL;
}.GetFileInformationByHandle;

const GetCompressedFileSizeW = struct {
    extern "kernel32" fn GetCompressedFileSizeW(
        file: [*:0]const u16,
        high: *DWORD,
    ) callconv(.winapi) DWORD;
}.GetCompressedFileSizeW;

const GetFileInformationByHandleEx = struct {
    extern "kernel32" fn GetFileInformationByHandleEx(
        file: HANDLE,
        class: u32,
        info: *anyopaque,
        len: DWORD,
    ) callconv(.winapi) BOOL;
}.GetFileInformationByHandleEx;

const FileStandardInfo: u32 = 1;

const FILE_STANDARD_INFO = extern struct {
    AllocationSize: i64,
    EndOfFile: i64,
    NumberOfLinks: DWORD,
    DeletePending: u8,
    Directory: u8,
};

const FindFirstFileW = struct {
    extern "kernel32" fn FindFirstFileW(
        name: [*:0]const u16,
        data: *WIN32_FIND_DATAW,
    ) callconv(.winapi) HANDLE;
}.FindFirstFileW;

const FindNextFileW = struct {
    extern "kernel32" fn FindNextFileW(
        find: HANDLE,
        data: *WIN32_FIND_DATAW,
    ) callconv(.winapi) BOOL;
}.FindNextFileW;

const FindClose = struct {
    extern "kernel32" fn FindClose(find: HANDLE) callconv(.winapi) BOOL;
}.FindClose;

const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: DWORD,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    nNumberOfLinks: DWORD,
    nFileIndexHigh: DWORD,
    nFileIndexLow: DWORD,
};

pub const Error = error{
    AccessDenied,
    NotFound,
    OpenFailed,
    Cancelled,
    OutOfMemory,
};

/// Walks `root` without elevation. The model is a normal model.Model so the
/// window and the console report render it with the same code as an MFT scan.
pub fn scanTree(
    gpa: std.mem.Allocator,
    root: []const u8,
    progress: scan.Progress,
) Error!*model.Model {
    if (root.len == 0) return error.NotFound;
    var b = try model.Builder.init(gpa, 16);
    defer b.deinit();
    try b.reserveRecords(5);
    _ = try b.addRecord(5, 1, 5, 1, "folder", true, 0, 0);

    var walker = Walker{
        .gpa = gpa,
        .root = root,
        .builder = &b,
        .progress = progress,
        .next_ref = 6,
        .seen = .empty,
    };
    defer walker.seen.deinit(gpa);

    progress.phase(.bootstrap);
    walker.walkRoot() catch |e| {
        return switch (e) {
            error.AccessDenied => error.AccessDenied,
            error.NotFound => error.NotFound,
            else => error.OpenFailed,
        };
    };
    progress.phase(.linking);
    const m = b.finish() catch return error.OutOfMemory;
    m.record_count = m.nodes.len;
    m.in_use = m.nodes.len;
    m.corrupt = 0;
    m.skipped = walker.skipped;
    progress.phase(.done);
    return m;
}

const Walker = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    builder: *model.Builder,
    progress: scan.Progress,
    next_ref: u64,
    seen: std.AutoHashMapUnmanaged(u128, u32),
    skipped: u32 = 0,
    entries: u64 = 0,
    bytes: u64 = 0,

    fn walkRoot(self: *Walker) anyerror!void {
        try self.walk(self.root, 5);
    }

    fn walk(self: *Walker, dir_path: []const u8, parent_ref: u64) anyerror!void {
        if (self.progress.cancelled()) return error.Cancelled;
        const wild = try joinPath(self.gpa, dir_path, "*");
        defer self.gpa.free(wild);
        const wide = try toWide(self.gpa, wild);
        defer self.gpa.free(wide.ptr[0 .. wide.len + 1]);

        var data: WIN32_FIND_DATAW = undefined;
        const find = FindFirstFileW(wide.ptr, &data);
        if (find == INVALID_HANDLE_VALUE) {
            if (parent_ref == 5 and windows.GetLastError() == .ACCESS_DENIED) return error.AccessDenied;
            if (parent_ref == 5) return error.NotFound;
            self.skipped +|= 1;
            return;
        }
        defer _ = FindClose(find);

        while (true) {
            if (self.progress.cancelled()) return error.Cancelled;
            const name_u16 = fileName(&data);
            if (!std.mem.eql(u16, name_u16, &[_]u16{'.'}) and !std.mem.eql(u16, name_u16, &[_]u16{ '.', '.' })) {
                var name_buf: [1024]u8 = undefined;
                const name = mft.utf16ToUtf8(&name_buf, std.mem.sliceAsBytes(name_u16)) catch {
                    self.skipped +|= 1;
                    if (FindNextFileW(find, &data) == 0) break;
                    continue;
                };
                if (name.len > 0) {
                    const full = joinPath(self.gpa, dir_path, name) catch {
                        self.skipped +|= 1;
                        if (FindNextFileW(find, &data) == 0) break;
                        continue;
                    };
                    defer self.gpa.free(full);
                    const is_dir = (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
                    const is_reparse = (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                    if (is_dir) {
                        const ref = self.next_ref;
                        self.next_ref += 1;
                        self.builder.reserveRecords(@intCast(ref)) catch {
                            self.skipped +|= 1;
                            if (FindNextFileW(find, &data) == 0) break;
                            continue;
                        };
                        _ = self.builder.addRecord(ref, 1, parent_ref, 1, name, true, 0, 0) catch {
                            self.skipped +|= 1;
                            if (FindNextFileW(find, &data) == 0) break;
                            continue;
                        };
                        self.entries += 1;
                        if (!is_reparse) {
                            self.walk(full, ref) catch |e| switch (e) {
                                error.Cancelled => return error.Cancelled,
                                else => self.skipped +|= 1,
                            };
                        } else {
                            self.skipped +|= 1;
                        }
                    } else {
                        const logical = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow;
                        const allocated = allocatedFor(self.gpa, full, logical);
                        const file_key = fileKey(self.gpa, full);
                        if (file_key) |key| {
                            if (self.seen.get(key)) |idx| {
                                self.builder.addLink(idx, parent_ref, 1, 3, name) catch {};
                            } else {
                                const ref = self.next_ref;
                                self.next_ref += 1;
                                self.builder.reserveRecords(@intCast(ref)) catch {
                                    self.skipped +|= 1;
                                    if (FindNextFileW(find, &data) == 0) break;
                                    continue;
                                };
                                const idx = self.builder.addRecord(ref, 1, parent_ref, 1, name, false, logical, allocated) catch {
                                    self.skipped +|= 1;
                                    if (FindNextFileW(find, &data) == 0) break;
                                    continue;
                                };
                                self.seen.put(self.gpa, key, idx) catch {};
                                self.entries += 1;
                                self.bytes +|= logical;
                            }
                        } else {
                            const ref = self.next_ref;
                            self.next_ref += 1;
                            self.builder.reserveRecords(@intCast(ref)) catch {
                                self.skipped +|= 1;
                                if (FindNextFileW(find, &data) == 0) break;
                                continue;
                            };
                            _ = self.builder.addRecord(ref, 1, parent_ref, 1, name, false, logical, allocated) catch {
                                self.skipped +|= 1;
                                if (FindNextFileW(find, &data) == 0) break;
                                continue;
                            };
                            self.entries += 1;
                            self.bytes +|= logical;
                        }
                    }
                    self.progress.update(self.entries, self.bytes);
                }
            }
            if (FindNextFileW(find, &data) == 0) break;
        }
    }
};

fn fileName(data: *const WIN32_FIND_DATAW) []const u16 {
    var n: usize = 0;
    while (n < data.cFileName.len and data.cFileName[n] != 0) : (n += 1) {}
    return data.cFileName[0..n];
}

fn joinPath(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len > 0 and (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/')) {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ dir, name });
    }
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ dir, name });
}

fn toWide(gpa: std.mem.Allocator, s: []const u8) ![:0]u16 {
    var buf = try gpa.alloc(u16, s.len + 1);
    errdefer gpa.free(buf);
    const n = try std.unicode.utf8ToUtf16Le(buf, s);
    buf[n] = 0;
    // UTF-8 can need fewer units than bytes. Shrink so callers that free
    // `len + 1` free exactly the allocation they received.
    buf = try gpa.realloc(buf, n + 1);
    return buf[0..n :0];
}

fn allocatedFor(gpa: std.mem.Allocator, path: []const u8, logical: u64) u64 {
    const wide = toWide(gpa, path) catch return logical;
    defer gpa.free(wide.ptr[0 .. wide.len + 1]);

    const h = CreateFileW(
        wide.ptr,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        null,
        OPEN_EXISTING,
        0,
        null,
    );
    if (h == INVALID_HANDLE_VALUE) return compressedBytes(wide.ptr, logical);
    defer _ = windows.CloseHandle(h);

    // GetCompressedFileSizeW is the compressed/sparse size, not the allocated
    // size of an ordinary file. For normal files ask FileStandardInfo for the
    // real on-disk allocation; keep the compressed API for compressed/sparse.
    var basic: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(h, &basic) != 0 and
        (basic.dwFileAttributes & (FILE_ATTRIBUTE_COMPRESSED | FILE_ATTRIBUTE_SPARSE_FILE)) != 0)
    {
        return compressedBytes(wide.ptr, logical);
    }

    var info: FILE_STANDARD_INFO = undefined;
    if (GetFileInformationByHandleEx(h, FileStandardInfo, @ptrCast(&info), @sizeOf(FILE_STANDARD_INFO)) != 0 and
        info.AllocationSize >= 0)
    {
        return @intCast(info.AllocationSize);
    }
    return compressedBytes(wide.ptr, logical);
}

fn compressedBytes(path: [*:0]const u16, logical: u64) u64 {
    var high: DWORD = 0;
    const low = GetCompressedFileSizeW(path, &high);
    if (low == 0xFFFFFFFF and high == 0) return logical;
    return (@as(u64, high) << 32) | low;
}

fn fileKey(gpa: std.mem.Allocator, path: []const u8) ?u128 {
    const wide = toWide(gpa, path) catch return null;
    defer gpa.free(wide.ptr[0 .. wide.len + 1]);
    const h = CreateFileW(
        wide.ptr,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        null,
        OPEN_EXISTING,
        0,
        null,
    );
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = windows.CloseHandle(h);
    var info: BY_HANDLE_FILE_INFORMATION = undefined;
    if (GetFileInformationByHandle(h, &info) == 0) return null;
    return (@as(u128, info.dwVolumeSerialNumber) << 64) |
        (@as(u128, info.nFileIndexHigh) << 32) |
        @as(u128, info.nFileIndexLow);
}

test "folder scan builds a partial tree without a volume handle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "sub/b.bin", .data = "123456" });
    var path_buf: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const path = path_buf[0..path_len];

    const m = try scanTree(gpa, path, .{});
    defer m.deinit();
    try std.testing.expect(m.nodes.len >= 4);
    try std.testing.expectEqual(@as(u64, 11), m.nodes[m.root].size);
    try std.testing.expect(m.skipped == 0);
}

test "folder scan uses on-disk allocation for ordinary files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const payload: [7001]u8 = @splat('x');
    try tmp.dir.writeFile(io, .{ .sub_path = "large.bin", .data = &payload });
    var path_buf: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);

    const m = try scanTree(gpa, path_buf[0..path_len], .{});
    defer m.deinit();
    var file_idx: ?u32 = null;
    for (m.nodes, 0..) |_, i| {
        if (std.mem.eql(u8, m.name(@intCast(i)), "large.bin")) file_idx = @intCast(i);
    }
    try std.testing.expect(file_idx != null);
    const node = m.nodes[file_idx.?];
    try std.testing.expectEqual(@as(u64, 7001), node.size);
    try std.testing.expect(node.allocated > node.size);
}

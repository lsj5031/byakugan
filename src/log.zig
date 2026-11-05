//! Bounded diagnostic logging for the Windows GUI and its elevated child.
//! See docs/logging.md for integration and the privacy contract.
const std = @import("std");
const windows = std.os.windows;

pub const env_name = "BYAKUGAN_LOG";
pub const max_file_bytes = 1024 * 1024;
pub const max_line_bytes = 2048;

extern "kernel32" fn AcquireSRWLockExclusive(lock: *usize) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *usize) callconv(.winapi) void;
extern "kernel32" fn CreateMutexW(attrs: ?*anyopaque, owner: i32, name: [*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn ReleaseMutex(handle: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn OutputDebugStringA(text: [*:0]const u8) callconv(.winapi) void;

var lock: usize = 0;
var mutex: ?windows.HANDLE = null;
var io: std.Io = undefined;
var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
var path_len: usize = 0;
var disabled = false;

/// Call before starting workers. Failure never prevents application startup.
/// An explicit override that fails also falls back to the normal destinations.
pub fn init(process: std.process.Init) void {
    AcquireSRWLockExclusive(&lock);
    closeLocked();
    disabled = false;
    io = process.io;
    ReleaseSRWLockExclusive(&lock);
    const env = process.environ_map;
    if (env.get(env_name)) |given| {
        if (given.len == 0 or std.mem.eql(u8, given, "0") or std.ascii.eqlIgnoreCase(given, "off")) {
            AcquireSRWLockExclusive(&lock);
            disabled = true;
            ReleaseSRWLockExclusive(&lock);
            return;
        }
        if (openAt(process.io, given)) return;
    }
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (env.get("LOCALAPPDATA")) |base| {
        if (std.fmt.bufPrint(&buf, "{s}\\byakugan\\byakugan.log", .{base})) |path| {
            if (openAt(process.io, path)) return;
        } else |_| {}
    }
    if (env.get("TEMP")) |base| {
        if (std.fmt.bufPrint(&buf, "{s}\\byakugan\\byakugan.log", .{base})) |path| {
            if (openAt(process.io, path)) return;
        } else |_| {}
    }
    fallback("byakugan: no writable log destination; using stderr/debugger\n");
}

/// Opens/probes an absolute or cwd-relative destination. Also useful for tests.
/// The path is copied; no caller memory is retained. Existing logs are appended.
pub fn openAt(new_io: std.Io, path: []const u8) bool {
    AcquireSRWLockExclusive(&lock);
    defer ReleaseSRWLockExclusive(&lock);
    closeLocked();
    disabled = false;
    io = new_io;
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var full_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full = if (std.fs.path.isAbsolute(path)) path else blk: {
        const n = std.Io.Dir.cwd().realPath(io, &cwd_buf) catch return false;
        break :blk std.fmt.bufPrint(&full_buf, "{s}\\{s}", .{ cwd_buf[0..n], path }) catch return false;
    };
    if (full.len + 2 > path_buf.len) return false;
    @memcpy(path_buf[0..full.len], full);
    path_len = full.len;
    mutex = CreateMutexW(null, 0, std.unicode.utf8ToUtf16LeStringLiteral("Local\\byakugan-log-v1"));
    if (mutex == null) {
        path_len = 0;
        fallback("byakugan: cannot coordinate log writers\n");
        return false;
    }
    // Creating directories is harmless if another process is doing the same.
    if (std.fs.path.dirname(full)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var ready_buf: [160]u8 = undefined;
    var stamp_buf: [40]u8 = undefined;
    const line = std.fmt.bufPrint(&ready_buf, "{s} pid={d} tid={d} INFO log destination ready\n", .{
        stamp(&stamp_buf), GetCurrentProcessId(), GetCurrentThreadId(),
    }) catch unreachable;
    appendLocked(line) catch |e| {
        fallbackError("cannot open log", e);
        closeLocked();
        return false;
    };
    var notice: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    fallback(std.fmt.bufPrint(&notice, "byakugan: logging to {s}\n", .{path_buf[0..path_len]}) catch "byakugan: log ready\n");
    return true;
}

/// Copy the active destination for a diagnostics UI. No borrowed mutable slice.
/// Null means disabled, unavailable, or the caller's buffer is too small.
pub fn filePath(buf: []u8) ?[]const u8 {
    AcquireSRWLockExclusive(&lock);
    defer ReleaseSRWLockExclusive(&lock);
    if (path_len == 0 or path_len > buf.len) return null;
    @memcpy(buf[0..path_len], path_buf[0..path_len]);
    return buf[0..path_len];
}

/// Join workers before shutdown if their final events must be retained.
pub fn deinit() void {
    AcquireSRWLockExclusive(&lock);
    defer ReleaseSRWLockExclusive(&lock);
    closeLocked();
}

fn closeLocked() void {
    if (mutex) |handle| _ = CloseHandle(handle);
    mutex = null;
    path_len = 0;
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    write("INFO", fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    write("WARN", fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    write("ERROR", fmt, args);
}

/// Install via root `std_options` to retain nanoui/backend diagnostics too.
pub fn stdLog(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime fmt: []const u8, args: anytype) void {
    if (scope == .default) {
        write(@tagName(level), fmt, args);
    } else {
        write(@tagName(level), "{s}: " ++ fmt, .{@tagName(scope)} ++ args);
    }
}

fn write(level: []const u8, comptime fmt: []const u8, args: anytype) void {
    AcquireSRWLockExclusive(&lock);
    defer ReleaseSRWLockExclusive(&lock);
    if (disabled) return;
    var message_buf: [1600]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, fmt, args) catch blk: {
        const replacement = "[message exceeded 1600 bytes]";
        @memcpy(message_buf[0..replacement.len], replacement);
        break :blk message_buf[0..replacement.len];
    };
    // One physical line per event, even for OS/backend error strings.
    for (message_buf[0..message.len]) |*ch| {
        if (ch.* < 32 or ch.* == 127) ch.* = ' ';
    }
    var line_buf: [max_line_bytes]u8 = undefined;
    var stamp_buf: [40]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{s} pid={d} tid={d} {s} {s}\n", .{
        if (path_len != 0) stamp(&stamp_buf) else "time-unavailable",
        GetCurrentProcessId(),
        GetCurrentThreadId(),
        level,
        message,
    }) catch return;
    if (path_len == 0) {
        fallback(line);
        return;
    }
    appendLocked(line) catch |e| {
        fallbackError("log write failed; using stderr/debugger", e);
        closeLocked();
        fallback(line);
    };
}

fn appendLocked(line: []const u8) !void {
    const handle = mutex orelse return error.NoLogMutex;
    const result = WaitForSingleObject(handle, 250);
    // WAIT_ABANDONED also grants ownership after a crashed writer.
    if (result != 0 and result != 0x80) return error.LogMutexUnavailable;
    defer _ = ReleaseMutex(handle);
    const path = path_buf[0..path_len];
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    var open = true;
    defer if (open) file.close(io);
    var length = try file.length(io);
    if (length + line.len > max_file_bytes) {
        file.close(io);
        open = false;
        var old_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const old = try std.fmt.bufPrint(&old_buf, "{s}.1", .{path});
        std.Io.Dir.deleteFileAbsolute(io, old) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
        try std.Io.Dir.renameAbsolute(path, old, io);
        file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        open = true;
        length = 0;
    }
    try file.writePositionalAll(io, line, length);
    // No user-space buffer; request OS flush so abrupt termination retains events.
    try file.sync(io);
}

fn fallbackError(comptime context: []const u8, e: anyerror) void {
    var buf: [256]u8 = undefined;
    fallback(std.fmt.bufPrint(&buf, "byakugan: " ++ context ++ ": {t}\n", .{e}) catch "byakugan: logging failed\n");
}

fn fallback(text: []const u8) void {
    std.debug.print("{s}", .{text});
    // A Windows GUI may have no stderr. DebugView/a debugger can still see this.
    var buf: [max_line_bytes + 1]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    OutputDebugStringA(buf[0..n :0]);
}

fn stamp(buf: []u8) []const u8 {
    const ms = std.Io.Clock.real.now(io).toMilliseconds();
    if (ms < 0) return "time-unavailable";
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year_day.year,                      month_day.month.numeric(), month_day.day_index + 1,
        day.getHoursIntoDay(),              day.getMinutesIntoHour(),  day.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(ms, 1000))),
    }) catch "time-unavailable";
}

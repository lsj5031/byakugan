//! Administrator restart: a launch is not a handoff until the child proves
//! its token and raw-volume read permission. Polling never blocks the UI.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const log = std.log;
const wide = std.unicode.utf8ToUtf16LeStringLiteral;

pub const Error = error{
    UnsupportedPlatform,
    InvalidVolume,
    ExecutablePathFailed,
    HandoffFailed,
    LaunchFailed,
    ChildExited,
    ChildRejected,
    TimedOut,
    AlreadyElevated,
    TokenQueryFailed,
    ScanCheckFailed,
};
pub const Status = enum { pending, ready };
pub const Start = union(enum) { cancelled, pending: Launch };
const timeout_ms = 15_000;
const handoff_arg = "--elevation-handoff=";

const ShellInfo = extern struct {
    size: u32 = @sizeOf(ShellInfo),
    mask: u32 = 0x40 | 0x100 | 0x400, // NOCLOSEPROCESS | NOASYNC | FLAG_NO_UI
    hwnd: ?*anyopaque = null,
    verb: [*:0]const u16 = wide("runas"),
    file: [*:0]const u16,
    parameters: [*:0]const u16,
    directory: ?[*:0]const u16 = null,
    show: c_int = 1,
    instance: ?*anyopaque = null,
    id_list: ?*anyopaque = null,
    class: ?[*:0]const u16 = null,
    class_key: ?*anyopaque = null,
    hot_key: u32 = 0,
    icon: ?*anyopaque = null,
    process: ?w.HANDLE = null,
};

extern "shell32" fn ShellExecuteExW(info: *ShellInfo) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(module: ?w.HANDLE, buf: [*]u16, len: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateEventW(attrs: ?*w.SECURITY_ATTRIBUTES, manual: i32, initial: i32, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn OpenEventW(access: u32, inherit: i32, name: [*:0]const u16) callconv(.winapi) ?w.HANDLE;
extern "kernel32" fn SetEvent(handle: w.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const w.HANDLE, all: i32, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(text: [*:0]const u16, revision: u32, descriptor: *?*anyopaque, size: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn OpenProcessToken(process: w.HANDLE, access: u32, token: *w.HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(token: w.HANDLE, class: u32, info: *anyopaque, len: u32, returned: *u32) callconv(.winapi) i32;
extern "bcrypt" fn BCryptGenRandom(algorithm: ?*anyopaque, bytes: [*]u8, len: u32, flags: u32) callconv(.winapi) i32;

fn winError(comptime operation: []const u8) void {
    const code = @backingInt(w.GetLastError());
    log.err("elevation {s} failed win32={d}", .{ operation, code });
}

/// Read only: membership in Administrators does not mean the token is elevated.
pub fn isElevated() Error!bool {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var token: w.HANDLE = undefined;
    if (OpenProcessToken(w.GetCurrentProcess(), 0x8, &token) == 0) {
        winError("OpenProcessToken");
        return error.TokenQueryFailed;
    }
    defer w.CloseHandle(token);
    var elevated: u32 = 0;
    var returned: u32 = 0;
    if (GetTokenInformation(token, 20, &elevated, @sizeOf(u32), &returned) == 0 or returned != @sizeOf(u32)) {
        winError("GetTokenInformation(TokenElevation)");
        return error.TokenQueryFailed;
    }
    log.info("elevation token elevated={}", .{elevated != 0});
    return elevated != 0;
}

pub const Launch = struct {
    process: w.HANDLE,
    ready: w.HANDLE,
    rejected: w.HANDLE,
    abandoned: w.HANDLE,
    started: u64,
    acknowledged: bool = false,

    /// Call on requested frames, e.g. every 50ms; never wait on the UI thread.
    /// Close the original only on .ready, then deinit this launch in all cases.
    pub fn poll(self: *Launch) Error!Status {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        // A dead child wins over a ready event left signalled by that child.
        const handles = [_]w.HANDLE{ self.process, self.rejected, self.ready };
        const result = WaitForMultipleObjects(handles.len, &handles, 0, 0);
        const status = classifyWait(result, GetTickCount64() -| self.started) catch |err| {
            if (result == 0xffffffff) winError("WaitForMultipleObjects");
            log.err("elevation handoff {t}", .{err});
            return err;
        };
        if (status == .ready) {
            self.acknowledged = true;
            log.info("elevation child verified token and volume; handoff ready", .{});
        }
        return status;
    }

    pub fn deinit(self: *Launch) void {
        if (builtin.os.tag != .windows) return;
        if (!self.acknowledged) _ = SetEvent(self.abandoned);
        w.CloseHandle(self.process);
        w.CloseHandle(self.ready);
        w.CloseHandle(self.rejected);
        w.CloseHandle(self.abandoned);
        self.* = undefined;
    }
};

fn classifyWait(result: u32, elapsed: u64) Error!Status {
    return switch (result) {
        0 => error.ChildExited,
        1 => error.ChildRejected,
        2 => .ready,
        258 => if (elapsed >= timeout_ms) error.TimedOut else .pending,
        else => error.HandoffFailed,
    };
}

fn cancelled(code: u32) Error!Start {
    if (code == 1223) return .cancelled;
    return error.LaunchFailed;
}

fn eventName(buf: *[96]u16, nonce: []const u8, suffix: u8) Error![*:0]const u16 {
    var ascii: [96]u8 = undefined;
    const name = std.fmt.bufPrint(&ascii, "Local\\byakugan-elevation-{s}-{c}", .{ nonce, suffix }) catch return error.HandoffFailed;
    const len = std.unicode.utf8ToUtf16Le(buf, name) catch return error.HandoffFailed;
    buf[len] = 0;
    return @ptrCast(buf);
}

fn parameters(buf: []u8, letter: u8, nonce: []const u8) Error![]const u8 {
    if (!std.ascii.isAlphabetic(letter)) return error.InvalidVolume;
    return std.fmt.bufPrint(buf, "--volume={c}: " ++ handoff_arg ++ "{s}", .{ std.ascii.toUpper(letter), nonce }) catch error.HandoffFailed;
}

fn createEvent(nonce: []const u8, suffix: u8) Error!w.HANDLE {
    // Owner keeps full rights; elevated Administrators (including a different
    // UAC account) can signal. No broad access for other unelevated users.
    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(wide("D:(A;;GA;;;OW)(A;;GA;;;SY)(A;;0x00100002;;;BA)"), 1, &descriptor, null) == 0) {
        winError("event security descriptor");
        return error.HandoffFailed;
    }
    defer _ = LocalFree(descriptor);
    var attrs: w.SECURITY_ATTRIBUTES = .{ .nLength = @sizeOf(w.SECURITY_ATTRIBUTES), .lpSecurityDescriptor = descriptor, .bInheritHandle = .FALSE };
    var name: [96]u16 = undefined;
    return CreateEventW(&attrs, 1, 0, try eventName(&name, nonce, suffix)) orelse {
        winError("create handoff event");
        return error.HandoffFailed;
    };
}

/// UAC itself is OS-mediated. Once it returns, readiness is polled with a
/// 15s deadline; success here alone never authorizes closing the original.
pub fn start(letter: u8) Error!Start {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (!std.ascii.isAlphabetic(letter)) return error.InvalidVolume;
    log.info("elevation restart requested", .{});
    if (try isElevated()) return error.AlreadyElevated;
    var random: [16]u8 = undefined;
    if (BCryptGenRandom(null, &random, random.len, 2) != 0) return error.HandoffFailed;
    const nonce = std.fmt.bytesToHex(random, .lower);
    const ready = try createEvent(&nonce, 'r');
    errdefer w.CloseHandle(ready);
    const rejected = try createEvent(&nonce, 'f');
    errdefer w.CloseHandle(rejected);
    const abandoned = try createEvent(&nonce, 'a');
    errdefer w.CloseHandle(abandoned);
    var exe: [32768]u16 = undefined;
    const len = GetModuleFileNameW(null, &exe, exe.len);
    if (len == 0 or len >= exe.len) {
        winError("GetModuleFileNameW");
        return error.ExecutablePathFailed;
    }
    exe[len] = 0;
    var text: [128]u8 = undefined;
    var args: [128]u16 = undefined;
    const args_len = std.unicode.utf8ToUtf16Le(&args, try parameters(&text, letter, &nonce)) catch return error.HandoffFailed;
    args[args_len] = 0;
    var info: ShellInfo = .{ .file = @ptrCast(&exe), .parameters = @ptrCast(&args) };
    log.info("elevation ShellExecuteExW runas attempt", .{});
    if (ShellExecuteExW(&info) == 0) {
        const code = @backingInt(w.GetLastError());
        log.warn("elevation ShellExecuteExW rejected win32={d} cancelled={}", .{ code, code == 1223 });
        // Cancellation is a result, so errdefer does not release its events.
        if (code == 1223) {
            w.CloseHandle(ready);
            w.CloseHandle(rejected);
            w.CloseHandle(abandoned);
        }
        return cancelled(code);
    }
    const process = info.process orelse return error.LaunchFailed;
    log.info("elevation child launched; awaiting token and volume check", .{});
    return .{ .pending = .{ .process = process, .ready = ready, .rejected = rejected, .abandoned = abandoned, .started = GetTickCount64() } };
}

const Request = struct { letter: u8, nonce: []const u8 };

fn request(argv: []const []const u8) Error!?Request {
    var nonce: ?[]const u8 = null;
    var letter: ?u8 = null;
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, handoff_arg)) {
            if (nonce != null) return error.HandoffFailed;
            const value = arg[handoff_arg.len..];
            if (value.len != 32) return error.HandoffFailed;
            for (value) |ch| if (!std.ascii.isHex(ch)) return error.HandoffFailed;
            nonce = value;
        }
    }
    const found_nonce = nonce orelse return null;
    for (argv) |arg| {
        if (std.mem.startsWith(u8, arg, "--volume=")) {
            if (arg.len != 11 or arg[10] != ':' or !std.ascii.isAlphabetic(arg[9]) or letter != null) return error.InvalidVolume;
            letter = std.ascii.toUpper(arg[9]);
        }
    }
    return .{ .nonce = found_nonce, .letter = letter orelse return error.InvalidVolume };
}

/// Called by the child's startup before starting its normal scan. Ordinary
/// launches return false. A failed child must close; the original remains.
pub fn accept(argv: []const []const u8, comptime verify: fn (u8) anyerror!void) Error!bool {
    if (builtin.os.tag != .windows) return false;
    const req = try request(argv) orelse return false;
    var name: [96]u16 = undefined;
    const ready = OpenEventW(2, 0, try eventName(&name, req.nonce, 'r')) orelse {
        winError("open ready event");
        return error.HandoffFailed;
    };
    defer w.CloseHandle(ready);
    const rejected = OpenEventW(2, 0, try eventName(&name, req.nonce, 'f')) orelse {
        winError("open rejection event");
        return error.HandoffFailed;
    };
    defer w.CloseHandle(rejected);
    errdefer _ = SetEvent(rejected);
    const abandoned = OpenEventW(0x100000, 0, try eventName(&name, req.nonce, 'a')) orelse {
        winError("open abandonment event");
        return error.HandoffFailed;
    };
    defer w.CloseHandle(abandoned);
    const wait = [_]w.HANDLE{abandoned};
    if (WaitForMultipleObjects(1, &wait, 0, 0) != 258) return error.HandoffFailed;
    log.info("elevation child validating token and raw-volume access", .{});
    if (!try isElevated()) return error.ChildRejected;
    verify(req.letter) catch |err| {
        log.err("elevation child volume check failed {t}", .{err});
        return error.ScanCheckFailed;
    };
    // A timed-out or closed parent must not gain a late duplicate window.
    if (WaitForMultipleObjects(1, &wait, 0, 0) != 258) return error.HandoffFailed;
    if (SetEvent(ready) == 0) {
        winError("signal ready event");
        return error.HandoffFailed;
    }
    log.info("elevation child permission verified; acknowledged handoff", .{});
    return true;
}

test "elevation arguments preserve selected volume and validate private handshake" {
    const testing = std.testing;
    const nonce = "0123456789abcdef0123456789abcdef";
    var buf: [128]u8 = undefined;
    const args = try parameters(&buf, 't', nonce);
    var split = std.mem.splitScalar(u8, args, ' ');
    const argv = [_][]const u8{ split.next().?, split.next().? };
    const req = (try request(&argv)).?;
    try testing.expectEqual(@as(u8, 'T'), req.letter);
    try testing.expectEqualStrings(nonce, req.nonce);
    try testing.expectEqual(@as(?Request, null), try request(&.{"byakugan.exe"}));
    try testing.expectEqual(@as(?Request, null), try request(&.{"--volume=C:garbage"}));
    try testing.expectError(error.InvalidVolume, parameters(&buf, '&', nonce));
    try testing.expectError(error.HandoffFailed, request(&.{"--elevation-handoff=bad"}));
    try testing.expectError(error.InvalidVolume, request(&.{"--elevation-handoff=" ++ nonce}));
    try testing.expectError(error.InvalidVolume, request(&.{ "--volume=C:garbage", "--elevation-handoff=" ++ nonce }));
}

test "elevation handoff never treats launch cancellation exit rejection or timeout as ready" {
    const testing = std.testing;
    try testing.expectEqual(Start.cancelled, try cancelled(1223));
    try testing.expectError(error.LaunchFailed, cancelled(5));
    try testing.expectEqual(Status.ready, try classifyWait(2, 1));
    try testing.expectError(error.ChildRejected, classifyWait(1, 1));
    try testing.expectError(error.ChildExited, classifyWait(0, 1));
    try testing.expectEqual(Status.pending, try classifyWait(258, timeout_ms - 1));
    try testing.expectError(error.TimedOut, classifyWait(258, timeout_ms));
    try testing.expectError(error.HandoffFailed, classifyWait(0xffffffff, 1));
}

test "elevation token query reads the current token without requesting UAC" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const elevated = try isElevated();
    std.debug.print("current process TokenElevation={} (read only)\n", .{elevated});
}

test "elevation private events reject an unelevated or abandoned child without UAC" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var random: [16]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), BCryptGenRandom(null, &random, random.len, 2));
    const nonce = std.fmt.bytesToHex(random, .lower);
    const ready = try createEvent(&nonce, 'r');
    defer w.CloseHandle(ready);
    const rejected = try createEvent(&nonce, 'f');
    defer w.CloseHandle(rejected);
    const abandoned = try createEvent(&nonce, 'a');
    defer w.CloseHandle(abandoned);
    var text: [128]u8 = undefined;
    var args = std.mem.splitScalar(u8, try parameters(&text, 'T', &nonce), ' ');
    const argv = [_][]const u8{ args.next().?, args.next().? };
    const Probe = struct {
        fn verify(letter: u8) !void {
            try std.testing.expectEqual(@as(u8, 'T'), letter);
        }
    };
    const elevated = try isElevated();
    if (elevated) {
        try std.testing.expect(try accept(&argv, Probe.verify));
    } else try std.testing.expectError(error.ChildRejected, accept(&argv, Probe.verify));
    const signals = [_]w.HANDLE{ ready, rejected };
    try std.testing.expectEqual(@as(u32, if (elevated) 0 else 1), WaitForMultipleObjects(2, &signals, 0, 0));
    try std.testing.expect(SetEvent(abandoned) != 0);
    try std.testing.expectError(error.HandoffFailed, accept(&argv, Probe.verify));
}

//! byakugan-cli: the scanner without a window. Verifiable, scriptable, and the
//! place where the accounting is checked against the volume.
const std = @import("std");
const by = @import("byakugan");
const scan = by.scan;
const folder_scan = by.folder_scan;
const volume = by.volume;
const model = by.model;

const version = "0.1.0";

const Ctx = struct {
    io: std.Io,
    last_ms: i64 = 0,
    disabled: bool = false,
    folder: bool = false,
};

var progress_ctx: Ctx = undefined;

fn progressReport(ctx: ?*anyopaque, phase: scan.Phase, records: u64, bytes: u64) void {
    const c: *Ctx = @ptrCast(@alignCast(ctx.?));
    if (c.disabled) return;
    const now = std.Io.Clock.now(.awake, c.io).nanoseconds;
    const now_ms: i64 = @intCast(@divTrunc(now, std.time.ns_per_ms));
    if (phase == .reading and now_ms - c.last_ms < 180 and records > 0) return;
    c.last_ms = now_ms;
    const phase_text = if (c.folder) switch (phase) {
        .bootstrap => "opening folder",
        .reading => "walking entries",
        .linking => "aggregating folders",
        .done => "done",
        .failed => "failed",
        .idle => "idle",
    } else switch (phase) {
        .bootstrap => "reading $MFT",
        .reading => "scanning records",
        .linking => "linking and aggregating",
        .done => "done",
        .failed => "failed",
        .idle => "idle",
    };
    const mb = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
    std.debug.print("\r{s} · {d} records · {d:.1} MiB · {s}    ", .{ phase_text, records, mb, if (phase == .done) "\n" else "" });
}

fn isCancel(ctx: ?*anyopaque) bool {
    _ = ctx;
    return false;
}

fn sizeText(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var v: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (v >= 1024 and u + 1 < units.len) {
        v /= 1024;
        u += 1;
    }
    if (u == 0) return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[u] }) catch "?";
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[u] }) catch "?";
}

fn driveLetter(arg: []const u8) ?u8 {
    var s = arg;
    if (std.mem.startsWith(u8, s, "\\\\.\\")) s = s[4..];
    if (s.len != 2 or s[1] != ':' or !std.ascii.isAlphabetic(s[0])) return null;
    return std.ascii.toUpper(s[0]);
}

const SortCtx = struct { nodes: []const model.Node, allocated: bool };

fn lessDir(ctx: SortCtx, a: u32, b: u32) bool {
    const na = ctx.nodes[a];
    const nb = ctx.nodes[b];
    const sa = if (ctx.allocated) na.allocated else na.size;
    const sb = if (ctx.allocated) nb.allocated else nb.size;
    if (sa != sb) return sa > sb;
    return a < b;
}

const Report = struct {
    title: []const u8,
    bytes_per_cluster: u32,
    record_size: u32,
    used: ?u64,
    elapsed_s: f64,
    allocated: bool,
    top_n: usize,
    folder: bool = false,
};

fn emitReport(io: std.Io, gpa: std.mem.Allocator, m: *const model.Model, r: Report) !void {
    var out_buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const w = &out.interface;

    if (r.folder) {
        try w.print("byakugan {s} — folder scan (no admin) — {s}\n", .{ version, r.title });
        try w.print("walked {d} items ({d} skipped) in {d:.2} s\n", .{ m.in_use, m.skipped, r.elapsed_s });
    } else {
        try w.print("byakugan {s} — {s} (NTFS, {d} B clusters, {d} B records)\n", .{ version, r.title, r.bytes_per_cluster, r.record_size });
        try w.print("scanned {d} records ({d} in use, {d} corrupt) in {d:.2} s\n", .{ m.record_count, m.in_use, m.corrupt, r.elapsed_s });
    }

    // These slices must not share a buffer: both are evaluated before print.
    var lbuf: [48]u8 = undefined;
    var abuf: [48]u8 = undefined;
    const logical = sizeText(&lbuf, m.nodes[m.root].size);
    const allocated = sizeText(&abuf, m.nodes[m.root].allocated);
    try w.print("logical {s} · allocated {s}\n", .{ logical, allocated });
    if (r.folder) {
        try w.print("partial scan: ordinary directory walk, no MFT; inaccessible entries skipped\n", .{});
    }
    if (r.used) |used| {
        const alloc = m.nodes[m.root].allocated;
        const delta = if (used > alloc) used - alloc else alloc - used;
        var ubuf: [48]u8 = undefined;
        var dbuf: [48]u8 = undefined;
        try w.print("volume used {s} · delta {s} ({s})\n", .{
            sizeText(&ubuf, used),
            sizeText(&dbuf, delta),
            if (alloc > used) "model is larger than used space" else "within used space",
        });
    }
    if (m.orphans > 0 or m.extensions > 0 or m.links.len > 0) {
        try w.print("{d} orphans · {d} extension records · {d} extra hard link{s}\n", .{ m.orphans, m.extensions, m.links.len, if (m.links.len == 1) "" else "s" });
    }

    try w.print("top directories by {s}\n", .{if (r.allocated) "allocated" else "logical"});
    const dirs = try gpa.alloc(u32, m.nodes.len);
    defer gpa.free(dirs);
    var n: usize = 0;
    for (m.nodes, 0..) |node, i| {
        if (i != m.root and node.isDirectory() and !node.isOrphan()) {
            dirs[n] = @intCast(i);
            n += 1;
        }
    }
    std.mem.sortUnstable(u32, dirs[0..n], SortCtx{ .nodes = m.nodes, .allocated = r.allocated }, lessDir);
    var path_buf: [512]u8 = undefined;
    var shown: usize = 0;
    while (shown < n and shown < r.top_n) : (shown += 1) {
        const idx = dirs[shown];
        var sbuf: [48]u8 = undefined;
        const p = m.relativePathInto(idx, &path_buf);
        try w.print("  {s:>10}  {s}\n", .{ sizeText(&sbuf, if (r.allocated) m.nodes[idx].allocated else m.nodes[idx].size), p });
    }
    try w.flush();
}

fn printHelp(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buf);
    const w = &out.interface;
    try w.writeAll(
        \\byakugan 0.1.0 — NTFS MFT disk analyzer
        \\
        \\usage: byakugan-cli [VOLUME] [options]
        \\
        \\  VOLUME        drive letter (C:) or \\.\C:
        \\  --top N       rows in the directory report (default 15)
        \\  --top=N       same, in one argument
        \\  --allocated   rank directories by allocated bytes (default)
        \\  --logical     rank directories by logical bytes
        \\  --no-progress suppress the progress line on stderr
        \\  --demo        report on the built-in synthetic volume (no admin)
        \\  --folder DIR  walk one accessible folder without admin (partial)
        \\  --folder=DIR  same, in one argument
        \\  --help        this text
        \\
        \\exit: 0 ok, 2 access denied, 3 not NTFS, 4 read/parse/usage failure
        \\
    );
    try w.flush();
}

fn usageError(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("byakugan-cli: " ++ fmt ++ "\n  Try --help.\n", args);
    return 4;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var top_n: usize = 15;
    var no_progress = false;
    var by_allocated = true;
    var want_demo = false;
    var help = false;
    var letter: ?u8 = null;
    var folder: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, a, "--demo")) {
            want_demo = true;
        } else if (std.mem.eql(u8, a, "--folder")) {
            i += 1;
            if (i >= args.len) return usageError("--folder needs a path", .{});
            folder = args[i];
        } else if (std.mem.startsWith(u8, a, "--folder=")) {
            folder = a[9..];
        } else if (std.mem.eql(u8, a, "--top")) {
            i += 1;
            if (i >= args.len) return usageError("--top needs a count", .{});
            top_n = std.fmt.parseInt(usize, args[i], 10) catch return usageError("'{s}' is not a count", .{args[i]});
        } else if (std.mem.startsWith(u8, a, "--top=")) {
            top_n = std.fmt.parseInt(usize, a[6..], 10) catch return usageError("'{s}' is not a count", .{a[6..]});
        } else if (std.mem.eql(u8, a, "--no-progress")) {
            no_progress = true;
        } else if (std.mem.eql(u8, a, "--allocated")) {
            by_allocated = true;
        } else if (std.mem.eql(u8, a, "--logical")) {
            by_allocated = false;
        } else if (std.mem.startsWith(u8, a, "--volume=")) {
            letter = driveLetter(a[9..]) orelse return usageError("'{s}' is not a volume", .{a[9..]});
        } else if (driveLetter(a)) |l| {
            letter = l;
        } else {
            return usageError("unknown argument '{s}'", .{a});
        }
    }

    if (help) {
        try printHelp(io);
        return 0;
    }
    if (folder != null and folder.?.len == 0) return usageError("--folder needs a path", .{});
    if (folder != null and (want_demo or letter != null)) {
        return usageError("--folder cannot be combined with a volume or --demo", .{});
    }

    if (folder) |path| {
        progress_ctx = .{ .io = io, .disabled = no_progress, .folder = true };
        const started = std.Io.Clock.now(.awake, io).nanoseconds;
        const m = folder_scan.scanTree(gpa, path, .{
            .ctx = &progress_ctx,
            .report = progressReport,
            .is_cancelled = isCancel,
        }) catch |e| {
            switch (e) {
                error.AccessDenied => {
                    std.debug.print("byakugan-cli: access denied walking {s}\n  Pick a folder your account can read, or run as administrator.\n", .{path});
                    return 2;
                },
                error.NotFound => {
                    std.debug.print("byakugan-cli: folder not found: {s}\n", .{path});
                    return 4;
                },
                else => {
                    std.debug.print("byakugan-cli: folder scan failed: ({s})\n", .{@errorName(e)});
                    return 4;
                },
            }
        };
        defer m.deinit();
        const elapsed_ns = std.Io.Clock.now(.awake, io).nanoseconds - started;
        try emitReport(io, gpa, m, .{
            .title = path,
            .bytes_per_cluster = 0,
            .record_size = 0,
            .used = null,
            .elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s,
            .allocated = by_allocated,
            .top_n = top_n,
            .folder = true,
        });
        return 0;
    }

    if (want_demo) {
        const started = std.Io.Clock.now(.awake, io).nanoseconds;
        const m = by.demo.build(gpa) catch {
            std.debug.print("byakugan-cli: could not build the demo model\n", .{});
            return 4;
        };
        defer m.deinit();
        const elapsed_ns = std.Io.Clock.now(.awake, io).nanoseconds - started;
        try emitReport(io, gpa, m, .{
            .title = "synthetic fixture (demo)",
            .bytes_per_cluster = 4096,
            .record_size = 1024,
            .used = null,
            .elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s,
            .allocated = by_allocated,
            .top_n = top_n,
        });
        return 0;
    }

    const drives = volume.logicalDrives();
    if (letter == null) {
        var d: usize = 2;
        while (d < 26) : (d += 1) {
            if ((drives & (@as(u32, 1) << @intCast(d))) != 0) {
                letter = 'A' + @as(u8, @intCast(d));
                break;
            }
        }
    }
    const l = letter orelse {
        std.debug.print("byakugan-cli: no volume with a drive letter found\n", .{});
        return 4;
    };

    progress_ctx = .{ .io = io, .disabled = no_progress };
    var vol = volume.Volume.open(gpa, l) catch |e| {
        switch (e) {
            error.AccessDenied => {
                std.debug.print("byakugan-cli: access denied opening {c}:\n  byakugan reads the NTFS master file table and needs administrator rights.\n  Run this terminal as administrator and try again.\n", .{l});
                return 2;
            },
            error.NotNtfs => {
                std.debug.print("byakugan-cli: {c}: is not an NTFS volume\n", .{l});
                return 3;
            },
            else => {
                std.debug.print("byakugan-cli: could not open {c}: ({s})\n", .{ l, @errorName(e) });
                return 4;
            },
        }
    };
    defer vol.close();

    const started = std.Io.Clock.now(.awake, io).nanoseconds;
    const m = scan.scan(gpa, vol.source(), vol.header, .{
        .ctx = &progress_ctx,
        .report = progressReport,
        .is_cancelled = isCancel,
    }) catch |e| {
        std.debug.print("\nbyakugan-cli: scan failed: ({s})\n", .{@errorName(e)});
        return 4;
    };
    defer m.deinit();
    const elapsed_ns = std.Io.Clock.now(.awake, io).nanoseconds - started;
    var title_buf: [8]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{c}:", .{l});
    const used = volume.usedBytes(l) catch 0;
    try emitReport(io, gpa, m, .{
        .title = title,
        .bytes_per_cluster = vol.header.bytes_per_cluster,
        .record_size = vol.header.record_size,
        .used = if (used > 0) used else null,
        .elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s,
        .allocated = by_allocated,
        .top_n = top_n,
    });
    return 0;
}

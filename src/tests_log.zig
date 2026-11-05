const std = @import("std");
const log = @import("log.zig");
const t = std.testing;

// Also buildable as a console helper for concurrent-process validation.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedPathAndWriterId;
    if (!log.openAt(init.io, args[1])) return error.LogUnavailable;
    defer log.deinit();
    for (0..120) |i| log.info("writer={s} event={d}", .{ args[2], i });
}

fn pathFor(tmp: *t.TmpDir, buf: []u8, name: []const u8) ![]const u8 {
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &base_buf);
    return std.fmt.bufPrint(buf, "{s}\\{s}", .{ base_buf[0..n], name });
}

fn read(tmp: *t.TmpDir, name: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(t.io, name, t.allocator, .limited(log.max_file_bytes + 1));
}

test "events survive reopening with scope, UTC, identity and single-line messages" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try pathFor(&tmp, &buf, "events.log");
    try t.expect(log.openAt(t.io, path));
    defer log.deinit();
    log.info("scan started type={s}", .{"folder"});
    log.stdLog(.info, .default, "default scope event", .{});
    log.stdLog(.warn, .backend, "failure\nsecond\r\tline", .{});
    const too_long: [1700]u8 = @splat('a');
    log.err("{s}", .{too_long});
    log.deinit();
    try t.expect(log.openAt(t.io, path));
    log.err("scan failed error={t}", .{error.AccessDenied});
    var location: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try t.expectEqualStrings(path, log.filePath(&location).?);
    try t.expect(log.filePath(location[0..2]) == null);
    const text = try read(&tmp, "events.log");
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "Z pid=") != null);
    try t.expect(std.mem.indexOf(u8, text, " tid=") != null);
    try t.expect(std.mem.indexOf(u8, text, "INFO scan started type=folder\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "backend: failure second  line\n") != null);
    try t.expect(std.mem.indexOf(u8, text, "[message exceeded 1600 bytes]") != null);
    try t.expect(std.mem.indexOf(u8, text, "scan failed error=AccessDenied") != null);
}

fn writer(id: usize) void {
    for (0..40) |i| log.info("writer={d} event={d}", .{ id, i });
}

test "parallel writers retain each complete event exactly once" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try t.expect(log.openAt(t.io, try pathFor(&tmp, &buf, "parallel.log")));
    defer log.deinit();
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    defer for (threads[0..started]) |thread| thread.join();
    for (&threads, 0..) |*thread, id| {
        thread.* = try std.Thread.spawn(.{}, writer, .{id});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    const text = try read(&tmp, "parallel.log");
    defer t.allocator.free(text);
    for (0..4) |id| for (0..40) |i| {
        var expected_buf: [64]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "INFO writer={d} event={d}\n", .{ id, i });
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, expected));
    };
}

test "rotation caps both files and replaces only the previous archive" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try pathFor(&tmp, &buf, "bounded.log");
    try t.expect(log.openAt(t.io, path));
    defer log.deinit();
    log.info("first generation", .{});
    // Put the existing file exactly at the boundary independently of logger state.
    var file = try tmp.dir.openFile(t.io, "bounded.log", .{ .mode = .read_write });
    try file.setLength(t.io, log.max_file_bytes);
    file.close(t.io);
    log.info("second generation", .{});
    const first = try read(&tmp, "bounded.log.1");
    defer t.allocator.free(first);
    try t.expectEqual(log.max_file_bytes, first.len);
    try t.expect(std.mem.indexOf(u8, first, "first generation") != null);
    file = try tmp.dir.openFile(t.io, "bounded.log", .{ .mode = .read_write });
    try file.setLength(t.io, log.max_file_bytes);
    file.close(t.io);
    log.info("third generation", .{});
    const archive = try read(&tmp, "bounded.log.1");
    defer t.allocator.free(archive);
    const current = try read(&tmp, "bounded.log");
    defer t.allocator.free(current);
    try t.expectEqual(log.max_file_bytes, archive.len);
    try t.expect(current.len < log.max_file_bytes);
    try t.expect(std.mem.indexOf(u8, archive, "second generation") != null);
    try t.expect(std.mem.indexOf(u8, archive, "first generation") == null);
    try t.expect(std.mem.indexOf(u8, current, "third generation") != null);
    try t.expectError(error.FileNotFound, tmp.dir.openFile(t.io, "bounded.log.2", .{}));
}

fn process(env: *std.process.Environ.Map) std.process.Init {
    // The logger contract consumes only io and the environment map.
    return .{ .io = t.io, .environ_map = env, .minimal = undefined, .arena = undefined, .gpa = t.allocator, .preopens = undefined };
}

test "destination defaults, override, off, unwritable fallback and recovery" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var env = std.process.Environ.Map.init(t.allocator);
    defer env.deinit();
    var base_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &base_buf);
    try env.put("LOCALAPPDATA", base_buf[0..n]);
    var destination: [std.Io.Dir.max_path_bytes]u8 = undefined;
    log.init(process(&env));
    defer log.deinit();
    try t.expect(std.mem.endsWith(u8, log.filePath(&destination).?, "\\byakugan\\byakugan.log"));
    var override_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const override = try pathFor(&tmp, &override_buf, "override.log");
    try env.put(log.env_name, override);
    log.init(process(&env));
    try t.expectEqualStrings(override, log.filePath(&destination).?);
    try env.put(log.env_name, "OFF");
    log.init(process(&env));
    try t.expect(log.filePath(&destination) == null);
    log.info("disabled event must not appear", .{});
    // An existing directory cannot be used as a file.
    try env.put(log.env_name, base_buf[0..n]);
    log.init(process(&env));
    try t.expect(std.mem.endsWith(u8, log.filePath(&destination).?, "\\byakugan\\byakugan.log"));
    // Force LOCALAPPDATA failure too, then verify TEMP is discoverable.
    try env.put("LOCALAPPDATA", override);
    try env.put("TEMP", base_buf[0..n]);
    log.init(process(&env));
    try t.expect(std.mem.startsWith(u8, log.filePath(&destination).?, base_buf[0..n]));
    try t.expect(!log.openAt(t.io, base_buf[0..n]));
    try t.expect(log.filePath(&destination) == null);
    log.err("unavailable destination remains nonfatal", .{});
    try t.expect(log.openAt(t.io, override));
    log.info("recovered", .{});
    const text = try read(&tmp, "override.log");
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "disabled event") == null);
    try t.expect(std.mem.indexOf(u8, text, "recovered") != null);
    // Runtime destination loss closes the logger instead of propagating errors.
    try tmp.dir.deleteFile(t.io, "override.log");
    try tmp.dir.createDir(t.io, "override.log", .default_dir);
    log.err("destination lost", .{});
    try t.expect(log.filePath(&destination) == null);
}

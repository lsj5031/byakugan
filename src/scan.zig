//! From an opened volume to a model: bootstrap the $MFT's own runlist, stream
//! the records through the parser, then link, aggregate and publish.
//!
//! Takes a `Source` (a read-at function), so the whole pipeline runs against a
//! byte array in tests with no administrator and no volume.
const std = @import("std");
const mft = @import("mft.zig");
const model = @import("model.zig");

pub const Phase = enum(u8) { idle = 0, bootstrap = 1, reading = 2, linking = 3, done = 4, failed = 5 };

pub const Source = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, offset: u64, buf: []u8) anyerror!usize,

    pub fn read(self: Source, offset: u64, buf: []u8) !usize {
        return self.read_fn(self.ctx, offset, buf);
    }
};

pub const Progress = struct {
    ctx: ?*anyopaque = null,
    report: ?*const fn (ctx: ?*anyopaque, phase: Phase, records: u64, bytes: u64) void = null,
    is_cancelled: ?*const fn (ctx: ?*anyopaque) bool = null,
    total_bytes: u64 = 0,

    pub fn phase(self: Progress, p: Phase) void {
        if (self.report) |f| f(self.ctx, p, 0, 0);
    }
    pub fn update(self: Progress, records: u64, bytes: u64) void {
        if (self.report) |f| f(self.ctx, .reading, records, bytes);
    }
    pub fn cancelled(self: Progress) bool {
        if (self.is_cancelled) |f| return f(self.ctx);
        return false;
    }
};

pub const Error = error{
    BadMft,
    Cancelled,
    OutOfMemory,
    UnexpectedEof,
    NotNtfs,
};

const no_parent: u64 = 0xFFFF_FFFF_FFFF_FFFF;
const chunk_max: usize = 4 << 20;

pub fn scan(gpa: std.mem.Allocator, source: Source, header_in: mft.VolumeHeader, progress: Progress) !*model.Model {
    var header = header_in;
    progress.phase(.bootstrap);

    const rec_size = header.record_size;
    if (rec_size < 256 or rec_size > 65536) return error.NotNtfs;
    const record0_off = header.mft_lcn * header.bytes_per_cluster;
    const rec0 = try gpa.alloc(u8, rec_size);
    defer gpa.free(rec0);
    try readExact(source, record0_off, rec0);
    var loc = mft.MftLocation{};
    const rh0 = mft.parseRecord(rec0, rec_size, header.bytes_per_sector) catch return error.BadMft;
    if (!rh0.inUse()) return error.BadMft;

    var attrs = mft.AttrIterator.init(rec0, rh0);
    var attr_list_value: []const u8 = &.{};
    while (true) {
        const maybe = attrs.next() catch break;
        const a = maybe orelse break;
        if (a.type == mft.ATTR_DATA and a.non_resident and a.isUnnamed()) {
            mft.appendMftRuns(&loc, a) catch return error.BadMft;
        } else if (a.type == mft.ATTR_ATTRIBUTE_LIST and !a.non_resident) {
            attr_list_value = a.value;
        }
    }
    if (loc.count == 0) return error.BadMft;

    // An attribute list can point at extension records holding more of the
    // $MFT $DATA. Merge their runlists before streaming; rare, but a silent
    // truncation would be worse than a slow path.
    if (attr_list_value.len > 0) try mergeAttrList(gpa, source, &header, &loc, attr_list_value);

    var stream_bytes: u64 = 0;
    for (loc.runs[0..loc.count]) |r| stream_bytes += r.clusters * header.bytes_per_cluster;
    if (header.mft_valid_len == 0 or header.mft_valid_len > stream_bytes) header.mft_valid_len = stream_bytes;
    const record_count = header.mft_valid_len / rec_size;
    if (record_count < 6) return error.BadMft;
    const mft_bytes = record_count * rec_size;

    var builder = try model.Builder.init(gpa, record_count);
    defer builder.deinit();
    builder.corrupt = 0;

    var chunk_len: usize = @intCast(@min(@as(u64, chunk_max), mft_bytes));
    chunk_len = @max(rec_size, chunk_len / rec_size * rec_size);
    const chunk = try gpa.alloc(u8, chunk_len);
    defer gpa.free(chunk);

    var records_done: u64 = 0;
    var in_use_total: u64 = 0;
    var stream_off: u64 = 0;
    var diagnostic_budget: u8 = 8;
    while (stream_off < mft_bytes) {
        if (progress.cancelled()) return error.Cancelled;
        const want: usize = @intCast(@min(@as(u64, chunk_len), mft_bytes - stream_off));
        readStream(source, &header, loc.runs[0..loc.count], stream_off, chunk[0..want]) catch |e| return e;
        const nrec = want / rec_size;
        var r: usize = 0;
        while (r < nrec) : (r += 1) {
            const rec = chunk[r * rec_size ..][0..rec_size];
            const rh = mft.parseRecord(rec, rec_size, header.bytes_per_sector) catch |e| {
                if (e == error.BadSignature) {
                    if (!allZero(rec)) builder.corrupt += 1;
                } else builder.corrupt += 1;
                records_done += 1;
                continue;
            };
            records_done += 1;
            if (!rh.inUse()) continue;
            in_use_total += 1;
            try handleRecord(&builder, &header, rec, rh, records_done - 1, &diagnostic_budget);
        }
        stream_off += want;
        progress.update(records_done, stream_off);
    }

    progress.phase(.linking);
    if (progress.cancelled()) return error.Cancelled;
    const m = try builder.finish();
    m.record_count = record_count;
    m.in_use = in_use_total;
    progress.phase(.done);
    return m;
}

fn allZero(buf: []const u8) bool {
    for (buf) |b| if (b != 0) return false;
    return true;
}

fn readExact(source: Source, offset: u64, buf: []u8) !void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = source.read(offset + done, buf[done..]) catch |e| return e;
        if (n == 0) return error.UnexpectedEof;
        done += n;
    }
}

fn readStream(source: Source, header: *const mft.VolumeHeader, runs: []const mft.Run, offset: u64, dst: []u8) !void {
    var consumed: usize = 0;
    var stream_base: u64 = 0;
    for (runs) |run| {
        const run_bytes = run.clusters * header.bytes_per_cluster;
        const run_end = stream_base + run_bytes;
        if (offset >= run_end) {
            stream_base = run_end;
            continue;
        }
        // `offset` applies only to the first run that contains it. All later
        // reads start at that run's first byte; using the original offset again
        // would underflow by the length already consumed.
        const within: u64 = if (consumed == 0 and offset > stream_base) offset - stream_base else 0;
        const available = run_bytes - within;
        const want: u64 = @intCast(dst.len - consumed);
        const take: usize = @intCast(@min(available, want));
        if (take > 0) {
            if (run.lcn) |lcn| {
                if (lcn < 0) return error.UnexpectedEof;
                const at: u64 = @as(u64, @intCast(lcn)) * header.bytes_per_cluster + within;
                readExact(source, at, dst[consumed .. consumed + take]) catch |e| return e;
            } else {
                @memset(dst[consumed .. consumed + take], 0);
            }
        }
        consumed += take;
        if (consumed == dst.len) return;
        stream_base = run_end;
    }
    if (consumed < dst.len) return error.UnexpectedEof;
}

/// Reads an extension record through the $MFT runlist already known.
fn readMftRecord(source: Source, header: *const mft.VolumeHeader, runs: []const mft.Run, ref: u64, buf: []u8) !void {
    const off = ref * header.record_size;
    if (off + header.record_size > @as(u64, @intCast(runsStreamBytes(header, runs)))) return error.UnexpectedEof;
    try readStream(source, header, runs, off, buf);
}

fn runsStreamBytes(header: *const mft.VolumeHeader, runs: []const mft.Run) u64 {
    var n: u64 = 0;
    for (runs) |r| n += r.clusters * header.bytes_per_cluster;
    return n;
}

fn mergeAttrList(gpa: std.mem.Allocator, source: Source, header: *mft.VolumeHeader, loc: *mft.MftLocation, value: []const u8) !void {
    const rec = try gpa.alloc(u8, header.record_size);
    defer gpa.free(rec);
    var pos: usize = 0;
    var looked: usize = 0;
    while (pos + 26 <= value.len and looked < 16) : (looked += 1) {
        const t = std.mem.readInt(u32, value[pos..][0..4], .little);
        const len = std.mem.readInt(u16, value[pos + 4 ..][0..2], .little);
        if (len < 26 or pos + len > value.len) break;
        if (t == mft.ATTR_DATA) {
            const ref = std.mem.readInt(u64, value[pos + 16 ..][0..8], .little) & 0x0000FFFFFFFFFFFF;
            const runs = loc.runs[0..loc.count];
            readMftRecord(source, header, runs, ref, rec) catch {
                pos += len;
                continue;
            };
            const rh = mft.parseRecord(rec, header.record_size, header.bytes_per_sector) catch {
                pos += len;
                continue;
            };
            var ai = mft.AttrIterator.init(rec, rh);
            while (true) {
                const maybe = ai.next() catch break;
                const a = maybe orelse break;
                if (a.type == mft.ATTR_DATA and a.non_resident and a.isUnnamed()) {
                    mft.appendMftRuns(loc, a) catch break;
                    break;
                }
            }
        }
        pos += len;
    }
}

fn handleRecord(builder: *model.Builder, header: *const mft.VolumeHeader, rec: []u8, rh: mft.RecordHeader, ordinal: u64, diagnostic_budget: *u8) !void {
    var name_buf: [1024]u8 = undefined;
    var name_len: usize = 0;
    var parent_record: u64 = no_parent;
    var parent_sequence: u16 = 0;
    var has_name = false;
    var has_win32 = false;
    var logical: u64 = 0;
    var allocated: u64 = 0;
    var is_dir = rh.isDirectory();

    var attrs = mft.AttrIterator.init(rec, rh);
    while (true) {
        // Diagnostic selection only: accounting below treats all records alike.
        // At most eight numeric metadata lines per scan; no user names/paths.
        const diagnose = diagnostic_budget.* > 0 and (ordinal == 8 or (rh.base_ref != 0 and rh.base_ref & 0x0000FFFFFFFFFFFF == 8));
        const maybe = attrs.next() catch |err| {
            builder.corrupt += 1;
            if (diagnose) {
                diagnostic_budget.* -= 1;
                std.log.warn("NTFS allocation record={d} attribute_error={t}", .{ ordinal, err });
            }
            break;
        };
        const a = maybe orelse break;
        // Every non-resident attribute consumes clusters, including $BITMAP
        // and $ATTRIBUTE_LIST. Resident values already live inside $MFT.
        if (a.non_resident) {
            const usage = a.allocation(header.bytes_per_cluster) catch |err| {
                builder.corrupt += 1;
                if (diagnose) {
                    diagnostic_budget.* -= 1;
                    std.log.warn("NTFS allocation record={d} type={x} flags={x} vcn={d}..{d} mapping_error={t}", .{ ordinal, a.type, a.flags, a.lowest_vcn, a.highest_vcn, err });
                }
                continue;
            };
            allocated +|= usage.bytes;
            if (diagnose) {
                diagnostic_budget.* -= 1;
                var prefix: [32]u8 = @splat(0);
                const n = @min(prefix.len, a.runlist.len);
                @memcpy(prefix[0..n], a.runlist[0..n]);
                const hex = std.fmt.bytesToHex(prefix, .lower);
                std.log.info("NTFS allocation record={d} base={d} type={x} named={} flags={x} vcn={d}..{d} cluster={d} header_hint={d} logical={d} physical={d} sparse_clusters={d} runs={d} run_bytes={d} prefix_bytes={d} run_prefix={s}", .{ ordinal, rh.base_ref & 0x0000FFFFFFFFFFFF, a.type, !a.isUnnamed(), a.flags, a.lowest_vcn, a.highest_vcn, header.bytes_per_cluster, a.allocated, a.logical, usage.bytes, usage.sparse_clusters, usage.runs, a.runlist.len, n, hex });
            }
        }
        switch (a.type) {
            mft.ATTR_FILE_NAME => {
                const fn_ = mft.parseFileName(a.value) catch continue;
                if (is_dir == false and (fn_.flags & 0x10000000) != 0) is_dir = true;
                const win32 = fn_.namespace != mft.NS_DOS;
                if (!has_name or (win32 and !has_win32)) {
                    const s = mft.utf16ToUtf8(&name_buf, fn_.name_utf16) catch continue;
                    name_len = s.len;
                    parent_record = fn_.parent_record;
                    parent_sequence = fn_.parent_sequence;
                    has_name = true;
                    has_win32 = win32;
                }
            },
            mft.ATTR_DATA => {
                if (a.non_resident) {
                    if (a.isUnnamed()) logical +|= a.logical;
                } else if (a.isUnnamed()) {
                    logical +|= a.value.len;
                }
            },
            else => {},
        }
    }

    if (rh.base_ref != 0) {
        try builder.addExtraSizes(rh.base_ref & 0x0000FFFFFFFFFFFF, logical, allocated);
        return;
    }

    var synthetic: [40]u8 = undefined;
    var fmt_name: []const u8 = undefined;
    if (has_name) {
        fmt_name = name_buf[0..name_len];
    } else {
        fmt_name = std.fmt.bufPrint(&synthetic, "[record {d}]", .{ordinal}) catch "[record]";
        parent_record = no_parent;
        has_name = false;
    }

    const idx = try builder.addRecord(ordinal, rh.sequence, parent_record, parent_sequence, fmt_name, is_dir, logical, allocated);
    // NTFS reserves the first 16 records for filesystem metadata. The root
    // remains the root; $Extend retains its subtree inside the metadata group.
    if (idx != model.none and ordinal < 16 and ordinal != 5) builder.nodes.items[idx].flags |= model.FLAG_SYSTEM;

    // Other names in the same record are hard links. DOS 8.3 aliases are not.
    if (idx != model.none and has_name) {
        var links = mft.AttrIterator.init(rec, rh);
        var extra: usize = 0;
        while (extra < 16) : (extra += 1) {
            const maybe = links.next() catch break;
            const a = maybe orelse break;
            if (a.type != mft.ATTR_FILE_NAME) continue;
            const fn_ = mft.parseFileName(a.value) catch continue;
            if (fn_.namespace == mft.NS_DOS) continue;
            var b: [1024]u8 = undefined;
            const s = mft.utf16ToUtf8(&b, fn_.name_utf16) catch continue;
            if (s.len == 0) continue;
            if (std.mem.eql(u8, s, name_buf[0..name_len]) and fn_.parent_record == parent_record) continue;
            try builder.addLink(idx, fn_.parent_record, fn_.parent_sequence, fn_.namespace, s);
        }
    }
}

pub const MemSource = struct {
    data: []const u8,
    pub fn source(self: *MemSource) Source {
        return .{ .ctx = self, .read_fn = readFn };
    }
    fn readFn(ctx: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
        const self: *MemSource = @ptrCast(@alignCast(ctx));
        if (offset >= self.data.len) return 0;
        const take = @min(buf.len, self.data.len - @as(usize, @intCast(offset)));
        @memcpy(buf[0..take], self.data[@intCast(offset)..][0..take]);
        return take;
    }
};

test "scan a minimal synthetic volume" {
    const gpa = std.testing.allocator;
    const image = try @import("tests_scan.zig").buildMinimalImage(gpa);
    defer gpa.free(image);
    var src = MemSource{ .data = image };
    const h = mft.VolumeHeader{
        .bytes_per_sector = 512,
        .bytes_per_cluster = 4096,
        .record_size = 1024,
        .mft_lcn = 1,
        .mft_valid_len = 6 * 1024,
    };
    const m = try scan(gpa, src.source(), h, .{});
    defer m.deinit();
    try std.testing.expectEqual(@as(u64, 6), m.record_count);
    try std.testing.expect(m.nodes.len >= 3);
}

test "readStream crosses noncontiguous runs without underflow" {
    var image: [20]u8 = @splat('.');
    @memcpy(image[4..8], "abcd");
    @memcpy(image[12..16], "efgh");
    @memcpy(image[16..20], "ijkl");
    var src = MemSource{ .data = &image };
    const header = mft.VolumeHeader{ .bytes_per_cluster = 4, .bytes_per_sector = 4, .record_size = 4 };
    const runs = [_]mft.Run{
        .{ .lcn = 1, .clusters = 1 },
        .{ .lcn = 3, .clusters = 2 },
    };
    var out: [8]u8 = undefined;
    try readStream(src.source(), &header, &runs, 2, &out);
    try std.testing.expectEqualStrings("cdefghij", &out);
}

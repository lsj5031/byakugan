//! The NTFS on-disk structures byakugan reads: the boot sector, FILE records,
//! their attributes, and the runlists that say where a stream really lives.
//!
//! Pure: every function here takes bytes and returns numbers. No Windows calls,
//! no allocation except the caller's UTF-8 buffer, no global state.
const std = @import("std");

pub const ATTR_STANDARD_INFORMATION: u32 = 0x10;
pub const ATTR_ATTRIBUTE_LIST: u32 = 0x20;
pub const ATTR_FILE_NAME: u32 = 0x30;
pub const ATTR_DATA: u32 = 0x80;
pub const ATTR_INDEX_ALLOCATION: u32 = 0xA0;
pub const ATTR_END: u32 = 0xFFFFFFFF;

pub const FLAG_IN_USE: u16 = 0x01;
pub const FLAG_DIRECTORY: u16 = 0x02;

pub const NS_DOS: u8 = 2;

pub const VolumeHeader = struct {
    bytes_per_sector: u32 = 512,
    bytes_per_cluster: u32 = 4096,
    record_size: u32 = 1024,
    mft_lcn: u64 = 0,
    mft_valid_len: u64 = 0,
    mft2_lcn: u64 = 0,
    total_clusters: u64 = 0,
    volume_bytes: u64 = 0,
    serial: u64 = 0,

    pub fn recordCount(h: VolumeHeader) u64 {
        if (h.record_size == 0) return 0;
        return h.mft_valid_len / h.record_size;
    }
};

pub const ParseError = error{
    NotNtfs,
    ShortRecord,
    BadSignature,
    BadFixup,
    BadAttribute,
    BadRunlist,
    InvalidUtf16,
    TooLong,
};

/// The boot sector is the fallback when FSCTL_GET_NTFS_VOLUME_DATA is not
/// available. Only the fields byakugan needs are checked.
pub fn parseBootSector(buf: []const u8) ParseError!VolumeHeader {
    if (buf.len < 512) return error.ShortRecord;
    if (!std.mem.eql(u8, buf[3..11], "NTFS    ")) return error.NotNtfs;
    const bps = std.mem.readInt(u16, buf[0x0B..0x0D], .little);
    const spc = buf[0x0D];
    if (bps < 256 or spc == 0) return error.NotNtfs;
    const total_sectors = std.mem.readInt(u64, buf[0x28..0x30], .little);
    const mft_lcn = std.mem.readInt(u64, buf[0x30..0x38], .little);
    const cpr: i8 = @bitCast(buf[0x40]);
    const cluster = @as(u64, bps) * @as(u64, spc);
    var record_size: u32 = undefined;
    if (cpr > 0) {
        record_size = @intCast(@as(u64, @intCast(cpr)) * cluster);
    } else {
        const shift: u5 = @intCast(@min(31, -@as(i32, cpr)));
        record_size = @as(u32, 1) << shift;
    }
    if (record_size < 256 or record_size > 65536) return error.NotNtfs;
    return .{
        .bytes_per_sector = bps,
        .bytes_per_cluster = @intCast(cluster),
        .record_size = record_size,
        .mft_lcn = mft_lcn,
        .total_clusters = total_sectors / spc,
        .volume_bytes = total_sectors * bps,
        .serial = std.mem.readInt(u64, buf[0x48..0x50], .little),
    };
}

pub const RecordHeader = struct {
    sequence: u16,
    first_attr: u16,
    flags: u16,
    used: u32,
    allocated: u32,
    base_ref: u64,

    pub fn inUse(h: RecordHeader) bool {
        return (h.flags & FLAG_IN_USE) != 0;
    }
    pub fn isDirectory(h: RecordHeader) bool {
        return (h.flags & FLAG_DIRECTORY) != 0;
    }
};

/// Verifies a FILE record and applies its update sequence array in place.
/// The signature is checked before the USA count, as the plan requires: a
/// zero-filled record must not produce a header full of nonsense.
pub fn parseRecord(buf: []u8, record_size: u32, sector_size: u32) ParseError!RecordHeader {
    if (buf.len < 48 or buf.len < record_size) return error.ShortRecord;
    if (!std.mem.eql(u8, buf[0..4], "FILE")) return error.BadSignature;
    const usa_off = std.mem.readInt(u16, buf[4..6], .little);
    const usa_count = std.mem.readInt(u16, buf[6..8], .little);
    const sectors: u32 = @max(1, record_size / @max(1, sector_size));
    if (usa_count != sectors + 1) return error.BadFixup;
    if (usa_off < 8 or @as(u32, usa_off) + @as(u32, usa_count) * 2 > record_size) return error.BadFixup;
    const check_off: usize = usa_off;
    const check = std.mem.readInt(u16, buf[check_off..][0..2], .little);
    var i: u32 = 0;
    while (i < sectors) : (i += 1) {
        const end = @as(usize, i + 1) * @as(usize, sector_size);
        if (end > record_size) return error.BadFixup;
        const at = end - 2;
        if (std.mem.readInt(u16, buf[at..][0..2], .little) != check) return error.BadFixup;
        const repl_at = check_off + 2 + @as(usize, i) * 2;
        buf[at] = buf[repl_at];
        buf[at + 1] = buf[repl_at + 1];
    }
    return .{
        .sequence = std.mem.readInt(u16, buf[0x10..0x12], .little),
        .first_attr = std.mem.readInt(u16, buf[0x14..0x16], .little),
        .flags = std.mem.readInt(u16, buf[0x16..0x18], .little),
        .used = std.mem.readInt(u32, buf[0x18..0x1C], .little),
        .allocated = std.mem.readInt(u32, buf[0x1C..0x20], .little),
        .base_ref = std.mem.readInt(u64, buf[0x20..0x28], .little) & 0x0000FFFFFFFFFFFF,
    };
}

pub const Attr = struct {
    type: u32,
    len: u32,
    non_resident: bool,
    name: []const u8,
    /// Resident value, or empty for a non-resident attribute.
    value: []const u8,
    /// Non-resident stream sizes.
    logical: u64 = 0,
    allocated: u64 = 0,
    initialized: u64 = 0,
    runlist: []const u8 = &.{},

    pub fn isUnnamed(a: Attr) bool {
        return a.name.len == 0;
    }
};

pub const AttrIterator = struct {
    buf: []const u8,
    used: u32,
    off: u32,
    done: bool = false,

    pub fn init(buf: []const u8, h: RecordHeader) AttrIterator {
        return .{ .buf = buf, .used = @min(h.used, @as(u32, @intCast(buf.len))), .off = h.first_attr };
    }

    pub fn next(self: *AttrIterator) ParseError!?Attr {
        if (self.done) return null;
        if (self.off + 8 > self.used) {
            self.done = true;
            return null;
        }
        const t = std.mem.readInt(u32, self.buf[self.off..][0..4], .little);
        if (t == ATTR_END) {
            self.done = true;
            return null;
        }
        const len = std.mem.readInt(u32, self.buf[self.off + 4 ..][0..4], .little);
        if (len < 24 or self.off + len > self.used) return error.BadAttribute;
        const at = self.off;
        self.off += len;
        const nonresident = self.buf[at + 8] != 0;
        const name_len = self.buf[at + 9];
        const name_off = std.mem.readInt(u16, self.buf[at + 10 ..][0..2], .little);
        var name: []const u8 = &.{};
        if (name_len > 0) {
            if (@as(u32, name_off) + @as(u32, name_len) * 2 > len) return error.BadAttribute;
            name = self.buf[at + name_off .. at + name_off + @as(u32, name_len) * 2];
        }
        if (!nonresident) {
            if (len < 24) return error.BadAttribute;
            const value_len = std.mem.readInt(u32, self.buf[at + 16 ..][0..4], .little);
            const value_off = std.mem.readInt(u16, self.buf[at + 20 ..][0..2], .little);
            if (@as(u32, value_off) + value_len > len) return error.BadAttribute;
            return .{
                .type = t,
                .len = len,
                .non_resident = false,
                .name = name,
                .value = self.buf[at + value_off .. at + value_off + value_len],
                .logical = value_len,
            };
        }
        if (len < 64) return error.BadAttribute;
        const run_off = std.mem.readInt(u16, self.buf[at + 32 ..][0..2], .little);
        if (run_off >= len) return error.BadAttribute;
        return .{
            .type = t,
            .len = len,
            .non_resident = true,
            .name = name,
            .value = &.{},
            .allocated = std.mem.readInt(u64, self.buf[at + 40 ..][0..8], .little),
            .logical = std.mem.readInt(u64, self.buf[at + 48 ..][0..8], .little),
            .initialized = std.mem.readInt(u64, self.buf[at + 56 ..][0..8], .little),
            .runlist = self.buf[at + run_off .. at + len],
        };
    }
};

pub const FileName = struct {
    parent_record: u64,
    parent_sequence: u16,
    flags: u32,
    namespace: u8,
    /// UTF-16LE bytes, without the terminator.
    name_utf16: []const u8,
};

pub fn parseFileName(value: []const u8) ParseError!FileName {
    if (value.len < 66) return error.BadAttribute;
    const parent = std.mem.readInt(u64, value[0..8], .little);
    const nlen = value[64];
    if (66 + @as(usize, nlen) * 2 > value.len) return error.BadAttribute;
    return .{
        .parent_record = parent & 0x0000FFFFFFFFFFFF,
        .parent_sequence = @truncate(parent >> 48),
        .flags = std.mem.readInt(u32, value[56..60], .little),
        .namespace = value[65],
        .name_utf16 = value[66 .. 66 + @as(usize, nlen) * 2],
    };
}

pub fn utf16ToUtf8(out: []u8, units: []const u8) ParseError![]u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 1 < units.len) : (i += 2) {
        var cp: u21 = std.mem.readInt(u16, units[i..][0..2], .little);
        if (cp >= 0xD800 and cp <= 0xDBFF) {
            if (i + 3 >= units.len) return error.InvalidUtf16;
            const lo = std.mem.readInt(u16, units[i + 2 ..][0..2], .little);
            if (lo < 0xDC00 or lo > 0xDFFF) return error.InvalidUtf16;
            cp = 0x10000 + ((@as(u21, cp) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
            i += 2;
        } else if (cp >= 0xDC00 and cp <= 0xDFFF) return error.InvalidUtf16;
        n += std.unicode.utf8Encode(cp, out[n..]) catch return error.InvalidUtf16;
        if (n >= out.len) return error.TooLong;
    }
    return out[0..n];
}

pub const Run = struct {
    /// Logical cluster number; null for a sparse run.
    lcn: ?i64,
    clusters: u64,
};

pub const RunIterator = struct {
    data: []const u8,
    pos: usize = 0,
    lcn: i64 = 0,

    pub fn next(self: *RunIterator) ParseError!?Run {
        if (self.pos >= self.data.len) return null;
        const header = self.data[self.pos];
        if (header == 0) return null;
        self.pos += 1;
        const len_bytes: usize = header & 0x0F;
        const off_bytes: usize = header >> 4;
        if (len_bytes == 0 or len_bytes > 8 or off_bytes > 8) return error.BadRunlist;
        if (self.pos + len_bytes + off_bytes > self.data.len) return error.BadRunlist;
        var length: u64 = 0;
        var k: usize = 0;
        while (k < len_bytes) : (k += 1) length |= @as(u64, self.data[self.pos + k]) << @as(u6, @intCast(k * 8));
        self.pos += len_bytes;
        var sparse = false;
        var delta: i64 = 0;
        if (off_bytes == 0) {
            sparse = true;
        } else {
            var raw: u64 = 0;
            k = 0;
            while (k < off_bytes) : (k += 1) raw |= @as(u64, self.data[self.pos + k]) << @as(u6, @intCast(k * 8));
            if (off_bytes < 8 and (raw & (@as(u64, 1) << @as(u6, @intCast(off_bytes * 8 - 1)))) != 0) {
                // Sign-extend a negative offset.
                const shift: u6 = @intCast(64 - off_bytes * 8);
                delta = @bitCast(raw << shift);
                delta >>= shift;
            } else {
                delta = @bitCast(raw);
            }
            self.pos += off_bytes;
            self.lcn += delta;
        }
        if (length == 0) return error.BadRunlist;
        return .{ .lcn = if (sparse) null else self.lcn, .clusters = length };
    }
};

/// Where an unnamed $DATA stream begins, for the MFT bootstrap.
pub const MftLocation = struct {
    runs: [64]Run = undefined,
    count: usize = 0,
    last_vcn: u64 = 0,
    has_total: bool = false,
    total: u64 = 0,
};

/// Parses record 0 (or an extension record's $DATA) and appends its runs.
pub fn appendMftRuns(loc: *MftLocation, attr: Attr) ParseError!void {
    if (attr.type != ATTR_DATA or !attr.non_resident or !attr.isUnnamed()) return;
    var it = RunIterator{ .data = attr.runlist };
    while (it.next() catch return error.BadRunlist) |run| {
        if (loc.count == loc.runs.len) return error.BadRunlist;
        loc.runs[loc.count] = run;
        loc.count += 1;
    }
    loc.total = attr.logical;
    loc.has_total = true;
}

test "boot sector positive clusters per record" {
    var b: [512]u8 = @splat(0);
    @memcpy(b[3..11], "NTFS    ");
    std.mem.writeInt(u16, b[0x0B..0x0D], 512, .little);
    b[0x0D] = 8;
    std.mem.writeInt(u64, b[0x28..0x30], 1 << 20, .little);
    std.mem.writeInt(u64, b[0x30..0x38], 4, .little);
    b[0x40] = 1;
    const h = try parseBootSector(&b);
    try std.testing.expectEqual(@as(u32, 4096), h.bytes_per_cluster);
    try std.testing.expectEqual(@as(u32, 4096), h.record_size);
    try std.testing.expectEqual(@as(u64, 4), h.mft_lcn);
}

test "boot sector negative clusters per record" {
    var b: [512]u8 = @splat(0);
    @memcpy(b[3..11], "NTFS    ");
    std.mem.writeInt(u16, b[0x0B..0x0D], 512, .little);
    b[0x0D] = 8;
    b[0x40] = @bitCast(@as(i8, -10));
    const h = try parseBootSector(&b);
    try std.testing.expectEqual(@as(u32, 1024), h.record_size);
}

test "runlist signed offsets and sparse runs" {
    // length 2 at LCN +100, length 3 at +(-20), sparse length 5, end.
    const data = [_]u8{ 0x11, 2, 100, 0x11, 3, @bitCast(@as(i8, -20)), 0x01, 5, 0 };
    var it = RunIterator{ .data = &data };
    const a = (try it.next()).?;
    try std.testing.expectEqual(@as(i64, 100), a.lcn.?);
    try std.testing.expectEqual(@as(u64, 2), a.clusters);
    const b = (try it.next()).?;
    try std.testing.expectEqual(@as(i64, 80), b.lcn.?);
    const c = (try it.next()).?;
    try std.testing.expectEqual(@as(?i64, null), c.lcn);
    try std.testing.expectEqual(@as(u64, 5), c.clusters);
}

test "utf16 converts non-ascii and surrogate pairs" {
    var units: [8]u8 = undefined;
    std.mem.writeInt(u16, units[0..2], 'n', .little);
    std.mem.writeInt(u16, units[2..4], 0x00E9, .little);
    std.mem.writeInt(u16, units[4..6], 0xD83D, .little);
    std.mem.writeInt(u16, units[6..8], 0xDE00, .little);
    var out: [32]u8 = undefined;
    const s = try utf16ToUtf8(&out, &units);
    try std.testing.expectEqualStrings("né😀", s);
}

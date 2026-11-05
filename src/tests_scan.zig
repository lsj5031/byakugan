//! A byte-for-byte synthetic NTFS image: boot record area, two MFT clusters,
//! update-sequence arrays on 512-byte sectors, resident and non-resident data.
const std = @import("std");
const mft = @import("mft.zig");

const record_size: usize = 1024;
const cluster: usize = 4096;
const sector: usize = 512;
const mft_lcn: usize = 1;
const total_records: usize = 8;

fn putAttrHeader(buf: []u8, at: usize, typ: u32, len: usize, nonres: bool, value_off: usize) void {
    std.mem.writeInt(u32, buf[at..][0..4], typ, .little);
    std.mem.writeInt(u32, buf[at + 4 ..][0..4], @intCast(len), .little);
    buf[at + 8] = if (nonres) 1 else 0;
    buf[at + 9] = 0;
    std.mem.writeInt(u16, buf[at + 10 ..][0..2], 0, .little);
    std.mem.writeInt(u16, buf[at + 12 ..][0..2], 0, .little);
    std.mem.writeInt(u16, buf[at + 14 ..][0..2], 0, .little);
    if (!nonres) {
        std.mem.writeInt(u16, buf[at + 20 ..][0..2], @intCast(value_off), .little);
    }
}

fn addFileName(rec: []u8, at_ptr: *usize, parent: u64, seq: u16, ns: u8, name: []const u8) void {
    const at = at_ptr.*;
    const value_len = 66 + name.len * 2;
    const total = std.mem.alignForward(usize, 24 + value_len, 8);
    putAttrHeader(rec, at, mft.ATTR_FILE_NAME, total, false, 24);
    const v = rec[at + 24 ..];
    std.mem.writeInt(u64, v[0..8], parent | (@as(u64, seq) << 48), .little);
    std.mem.writeInt(u32, v[56..60], 0, .little);
    v[64] = @intCast(name.len);
    v[65] = ns;
    for (name, 0..) |ch, i| {
        v[66 + i * 2] = ch;
        v[66 + i * 2 + 1] = 0;
    }
    std.mem.writeInt(u32, rec[at + 16 ..][0..4], @intCast(value_len), .little);
    at_ptr.* += total;
}

fn addResidentData(rec: []u8, at_ptr: *usize, value: []const u8) void {
    const at = at_ptr.*;
    const total = std.mem.alignForward(usize, 24 + value.len, 8);
    putAttrHeader(rec, at, mft.ATTR_DATA, total, false, 24);
    std.mem.writeInt(u32, rec[at + 16 ..][0..4], @intCast(value.len), .little);
    @memcpy(rec[at + 24 .. at + 24 + value.len], value);
    at_ptr.* += total;
}

fn addNonResidentData(rec: []u8, at_ptr: *usize, runs: []const u8, payload: []const u8, allocated: u64) void {
    const at = at_ptr.*;
    const total = std.mem.alignForward(usize, 64 + runs.len, 8);
    putAttrHeader(rec, at, mft.ATTR_DATA, total, true, 64);
    const a = rec[at..];
    std.mem.writeInt(u64, a[24..32], allocated / cluster - 1, .little);
    std.mem.writeInt(u16, a[32..34], 64, .little);
    std.mem.writeInt(u64, a[40..48], allocated, .little);
    std.mem.writeInt(u64, a[48..56], @intCast(payload.len), .little);
    std.mem.writeInt(u64, a[56..64], @intCast(payload.len), .little);
    @memcpy(a[64 .. 64 + runs.len], runs);
    at_ptr.* += total;
}

fn beginRecord(buf: []u8, seq: u16, flags: u16) usize {
    @memset(buf, 0);
    @memcpy(buf[0..4], "FILE");
    std.mem.writeInt(u16, buf[4..6], 0x30, .little); // USA offset
    std.mem.writeInt(u16, buf[6..8], 3, .little); // USA count for 1024/512
    std.mem.writeInt(u16, buf[0x10..0x12], seq, .little);
    std.mem.writeInt(u16, buf[0x14..0x16], 0x38, .little);
    std.mem.writeInt(u16, buf[0x16..0x18], flags, .little);
    std.mem.writeInt(u32, buf[0x18..0x1C], 0x38, .little);
    std.mem.writeInt(u32, buf[0x1C..0x20], record_size, .little);
    return 0x38;
}

fn endRecord(rec: []u8, used: usize) void {
    std.mem.writeInt(u32, rec[used..][0..4], mft.ATTR_END, .little);
    const usa = 0x30;
    const check: u16 = 0xA55A;
    std.mem.writeInt(u16, rec[usa..][0..2], check, .little);
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const end = (i + 1) * sector;
        std.mem.writeInt(u16, rec[usa + 2 + i * 2 ..][0..2], std.mem.readInt(u16, rec[end - 2 ..][0..2], .little), .little);
        std.mem.writeInt(u16, rec[end - 2 ..][0..2], check, .little);
    }
    const total = 0x38 + 0;
    _ = total;
    std.mem.writeInt(u32, rec[0x18..0x1C], @intCast(used + 8), .little);
}

pub fn buildMinimalImage(gpa: std.mem.Allocator) ![]u8 {
    const mft_bytes = total_records * record_size;
    const image_len = mft_lcn * cluster + mft_bytes + cluster;
    const image = try gpa.alloc(u8, image_len);
    @memset(image, 0);

    // Record 0: $MFT itself, with the $DATA runlist that spans two clusters
    // starting at LCN 1.
    const r0 = image[mft_lcn * cluster ..][0..record_size];
    var at = beginRecord(r0, 1, 0x01);
    const runs = [_]u8{ 0x11, 2, 1, 0 };
    addFileName(r0, &at, 5, 5, 3, "$MFT");
    addNonResidentData(r0, &at, &runs, image[cluster .. cluster + mft_bytes], mft_bytes);
    endRecord(r0, at);

    // Record 5: the root directory.
    const r5 = image[mft_lcn * cluster + 5 * record_size ..][0..record_size];
    at = beginRecord(r5, 5, 0x03);
    addFileName(r5, &at, 5, 5, 3, ".");
    endRecord(r5, at);

    // Record 6: a resident file under the root.
    const r6 = image[mft_lcn * cluster + 6 * record_size ..][0..record_size];
    at = beginRecord(r6, 1, 0x01);
    addFileName(r6, &at, 5, 5, 3, "hello.txt");
    addResidentData(r6, &at, "hello from the MFT");
    endRecord(r6, at);

    // Record 7: a directory with a non-resident index allocation.
    const r7 = image[mft_lcn * cluster + 7 * record_size ..][0..record_size];
    at = beginRecord(r7, 1, 0x03);
    addFileName(r7, &at, 5, 5, 3, "Users");
    const idx_runs = [_]u8{ 0x11, 1, 3, 0 };
    const at7 = at;
    putAttrHeader(r7, at7, mft.ATTR_INDEX_ALLOCATION, std.mem.alignForward(usize, 64 + idx_runs.len, 8), true, 64);
    std.mem.writeInt(u16, r7[at7 + 32 ..][0..2], 64, .little);
    std.mem.writeInt(u64, r7[at7 + 40 ..][0..8], cluster, .little);
    std.mem.writeInt(u64, r7[at7 + 48 ..][0..8], 0, .little);
    @memcpy(r7[at7 + 64 .. at7 + 64 + idx_runs.len], &idx_runs);
    at = at7 + std.mem.alignForward(usize, 64 + idx_runs.len, 8);
    endRecord(r7, at);

    return image;
}

/// A full scanner fixture, including named metadata, sparse/compressed streams,
/// continuation extents before their base, and a new ADS in an extension.
/// The unflagged $Bad stream follows ntfs-3g mkntfs.c: sparse mapping pairs,
/// flags 0, ordinary 64-byte non-resident header (also observed by libfsntfs).
pub fn buildAccountingImage(gpa: std.mem.Allocator) ![]u8 {
    const image = try gpa.alloc(u8, cluster + 32 * record_size);
    @memset(image, 0);
    const entries = .{
        .{ 0, "$MFT", 0, 0, 32768, 32768, 32768, 5, false },
        .{ 1, "", 0, 0, 4096, 0, 4096, 5, false },
        .{ 2, "$LogFile", 0, 0, 8192, 8000, 8192, 5, false },
        .{ 5, ".", 0, 0, 0, 0, 0, 5, true },
        .{ 8, "$BadClus", 0, 0, 2 * 1024 * 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024 * 1024, 0, 5, false },
        .{ 11, "$Extend", 0, 0, 4096, 0, 4096, 5, true },
        .{ 16, "all-sparse.bin", 0x8000, 0, 1048576, 1048576, 0, 5, false },
        .{ 17, "compressed.bin", 1, 0, 65536, 65536, 8192, 5, false },
        .{ 18, "", 0x8000, 3, 999999, 999999, 999999, 5, false },
        .{ 19, "normal.bin", 0, 0, 12288, 9000, 12288, 5, false },
        .{ 20, "mixed.bin", 0x8000, 0, 24576, 24576, 12288, 5, false },
        .{ 21, "", 0, 0, 4096, 3000, 4096, 5, false },
        .{ 24, "$UsnJrnl", 0, 0, 4096, 100, 4096, 11, false },
        .{ 25, "unflagged-sparse.bin", 0, 0, 1048576, 1048576, 0, 5, false },
    };
    inline for (entries) |entry| {
        const ref, const name, const flags, const vcn, const virtual, const logical, const physical, const parent, const dir = entry;
        const rec = image[cluster + ref * record_size ..][0..record_size];
        var at = beginRecord(rec, if (ref == 5) 5 else 1, if (dir) 3 else 1);
        if (name.len > 0) addFileName(rec, &at, parent, if (parent == 5) 5 else 1, 3, name);
        if (ref == 18 or ref == 21) std.mem.writeInt(u64, rec[32..40], 20 | (@as(u64, 1) << 48), .little);
        if (ref == 1) std.mem.writeInt(u64, rec[32..40], @as(u64, 1) << 48, .little);
        if (ref != 5) {
            const named = ref == 8 or ref == 21;
            const header_len: usize = if (flags != 0 and vcn == 0) 72 else 64;
            const run_off = header_len + if (named) @as(usize, 8) else 0;
            const runs: []const u8 = switch (ref) {
                0 => &.{ 0x11, 8, 1, 0 },
                8 => &.{ 0x04, 0, 0, 0, 0x20, 0 }, // 2 TiB of holes
                16, 25 => &.{ 0x02, 0, 1, 0 }, // 256 sparse clusters
                17 => &.{ 0x11, 2, 40, 0x01, 14, 0 },
                18 => &.{ 0x11, 2, 60, 0x01, 1, 0 },
                19 => &.{ 0x11, 3, 40, 0 },
                20 => &.{ 0x11, 1, 40, 0x01, 2, 0 },
                2 => &.{ 0x11, 2, 40, 0 },
                else => &.{ 0x11, 1, 40, 0 },
            };
            const len = std.mem.alignForward(usize, run_off + runs.len, 8);
            putAttrHeader(rec, at, if (ref == 1) 0xB0 else if (dir) mft.ATTR_INDEX_ALLOCATION else mft.ATTR_DATA, len, true, 0);
            const a = rec[at..];
            std.mem.writeInt(u16, a[12..14], flags, .little);
            std.mem.writeInt(u64, a[16..24], vcn, .little);
            std.mem.writeInt(u64, a[24..32], switch (ref) {
                0 => 7,
                8 => 536870911,
                16, 25 => 255,
                17 => 15,
                18 => 5,
                19, 20 => 2,
                2 => 1,
                else => 0,
            }, .little);
            std.mem.writeInt(u16, a[32..34], run_off, .little);
            if (flags == 1) a[34] = 4;
            std.mem.writeInt(u64, a[40..48], virtual, .little);
            std.mem.writeInt(u64, a[48..56], logical, .little);
            std.mem.writeInt(u64, a[56..64], logical, .little);
            if (header_len == 72) std.mem.writeInt(u64, a[64..72], physical, .little);
            if (named) {
                a[9] = 4;
                std.mem.writeInt(u16, a[10..12], header_len, .little);
                @memcpy(a[header_len..][0..8], &[_]u8{ '$', 0, 'B', 0, 'a', 0, 'd', 0 });
            }
            @memcpy(a[run_off..][0..runs.len], runs);
            at += len;
        }
        endRecord(rec, at);
    }
    return image;
}

pub const accounting_header = mft.VolumeHeader{ .mft_lcn = 1, .mft_valid_len = 32 * record_size };

test "public scanner counts physical sparse compressed normal and extension streams once" {
    const scanner = @import("scan.zig");
    const image = try buildAccountingImage(std.testing.allocator);
    defer std.testing.allocator.free(image);
    var source = scanner.MemSource{ .data = image };
    const result = try scanner.scan(std.testing.allocator, source.source(), accounting_header, .{});
    defer result.deinit();
    const expected = .{
        .{ 8, 0, 0 },
        .{ 16, 1048576, 0 },
        .{ 17, 65536, 8192 },
        .{ 19, 9000, 12288 },
        .{ 20, 24576, 16384 },
        .{ 25, 1048576, 0 },
        .{ 0, 32768, 36864 },
        .{ 2, 8000, 8192 },
    };
    inline for (expected) |e| {
        const node = result.nodes[result.records[e[0]]];
        try std.testing.expectEqual(@as(u64, e[1]), node.size);
        try std.testing.expectEqual(@as(u64, e[2]), node.allocated);
    }
    try std.testing.expectEqual(@as(u64, 90112), result.nodes[result.root].allocated);
    try std.testing.expectEqual(@import("model.zig").none, result.records[1]);
    const system = result.nodes[result.records[8]].parent;
    try std.testing.expectEqualStrings("System metadata", result.name(system));
    try std.testing.expectEqual(@as(u64, 53248), result.nodes[system].allocated);
    try std.testing.expectEqual(result.records[11], result.nodes[result.records[24]].parent);
    var path: [128]u8 = undefined;
    try std.testing.expectEqualStrings("$Extend\\$UsnJrnl", result.relativePathInto(result.records[24], &path));
    try std.testing.expectEqual(@as(u32, 0), result.corrupt);
}

test "public scanner rejects missing or overlapping sparse extended size fields" {
    const scanner = @import("scan.zig");
    for ([_]u32{ 64, 72 }) |bad_len| {
        const image = try buildAccountingImage(std.testing.allocator);
        defer std.testing.allocator.free(image);
        const rec = image[cluster + 16 * record_size ..][0..record_size];
        // Decode fixups before modifying the first DATA attribute, then seal
        // the record again so this tests attribute validation, not USA errors.
        const rh = try mft.parseRecord(rec, record_size, sector);
        var it = mft.AttrIterator.init(rec, rh);
        _ = try it.next();
        const at = it.off;
        std.mem.writeInt(u32, rec[at + 4 ..][0..4], bad_len, .little);
        std.mem.writeInt(u16, rec[at + 32 ..][0..2], 64, .little);
        endRecord(rec, at + bad_len);
        var source = scanner.MemSource{ .data = image };
        const result = try scanner.scan(std.testing.allocator, source.source(), accounting_header, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(u32, 1), result.corrupt);
        try std.testing.expectEqual(@as(u64, 0), result.nodes[result.records[16]].allocated);
        try std.testing.expectEqual(@as(u64, 90112), result.nodes[result.root].allocated);
    }
}

test "public scanner keeps real bad clusters in metadata totals" {
    const scanner = @import("scan.zig");
    const image = try buildAccountingImage(std.testing.allocator);
    defer std.testing.allocator.free(image);
    const rec = image[cluster + 8 * record_size ..][0..record_size];
    const rh = try mft.parseRecord(rec, record_size, sector);
    var it = mft.AttrIterator.init(rec, rh);
    _ = try it.next();
    const at = it.off;
    std.mem.writeInt(u32, rec[at + 4 ..][0..4], 88, .little);
    // One reserved bad cluster followed by the rest of the volume as holes.
    @memcpy(rec[at + 72 ..][0..9], &[_]u8{ 0x11, 1, 70, 0x04, 0xFF, 0xFF, 0xFF, 0x1F, 0 });
    endRecord(rec, at + 88);
    var source = scanner.MemSource{ .data = image };
    const result = try scanner.scan(std.testing.allocator, source.source(), accounting_header, .{});
    defer result.deinit();
    const bad = result.records[8];
    try std.testing.expectEqual(@as(u64, 4096), result.nodes[bad].allocated);
    try std.testing.expectEqual(@as(u64, 57344), result.nodes[result.nodes[bad].parent].allocated);
    try std.testing.expectEqual(@as(u64, 94208), result.nodes[result.root].allocated);
    try std.testing.expectEqual(@as(u32, 0), result.corrupt);
}

test "public scanner rejects malformed mapping pairs without header fallback" {
    const scanner = @import("scan.zig");
    const invalid = [_][]const u8{
        &.{ 0x11, 1, 40 }, // Missing terminator, despite plausible size hint.
        &.{ 0x11, 1 }, // Missing LCN bytes.
        &.{ 0x11, 1, 40, 0 }, // Does not cover HighestVcn=2.
        &.{ 0x81, 1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x11, 1, 1, 0 }, // LCN overflow.
    };
    for (invalid) |runs| {
        const image = try buildAccountingImage(std.testing.allocator);
        defer std.testing.allocator.free(image);
        const rec = image[cluster + 19 * record_size ..][0..record_size];
        const rh = try mft.parseRecord(rec, record_size, sector);
        var it = mft.AttrIterator.init(rec, rh);
        _ = try it.next();
        const at = it.off;
        const len: u32 = @intCast(64 + runs.len);
        std.mem.writeInt(u32, rec[at + 4 ..][0..4], len, .little);
        @memcpy(rec[at + 64 ..][0..runs.len], runs);
        endRecord(rec, at + len);
        var source = scanner.MemSource{ .data = image };
        const result = try scanner.scan(std.testing.allocator, source.source(), accounting_header, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(u32, 1), result.corrupt);
        try std.testing.expectEqual(@as(u64, 0), result.nodes[result.records[19]].allocated);
        try std.testing.expectEqual(@as(u64, 77824), result.nodes[result.root].allocated);
    }
}

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
    const idx_runs = [_]u8{ 0x21, 1, 3, 0 };
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

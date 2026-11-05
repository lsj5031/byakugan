//! The Windows side: open a volume read-only, ask NTFS for its geometry,
//! and read sector-aligned bytes. Everything above this file sees `Source`.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const mft = @import("mft.zig");
const scan = @import("scan.zig");
const log = std.log;
pub const elevation = @import("elevation.zig");

const is_windows = builtin.os.tag == .windows;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_EXISTING: u32 = 3;
const FSCTL_GET_NTFS_VOLUME_DATA: u32 = 0x00090064;

const CreateFileW = struct {
    extern "kernel32" fn CreateFileW(
        name: [*:0]const u16,
        access: u32,
        share: u32,
        attrs: ?*windows.SECURITY_ATTRIBUTES,
        creation: u32,
        flags: u32,
        template: ?windows.HANDLE,
    ) callconv(.winapi) windows.HANDLE;
}.CreateFileW;

const DeviceIoControl = struct {
    extern "kernel32" fn DeviceIoControl(
        h: windows.HANDLE,
        code: u32,
        in: ?*anyopaque,
        in_len: u32,
        out: ?*anyopaque,
        out_len: u32,
        returned: *u32,
        overlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
}.DeviceIoControl;

const SetFilePointerEx = struct {
    extern "kernel32" fn SetFilePointerEx(h: windows.HANDLE, distance: i64, new_pos: ?*i64, method: u32) callconv(.winapi) i32;
}.SetFilePointerEx;

const ReadFile = struct {
    extern "kernel32" fn ReadFile(h: windows.HANDLE, buf: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
}.ReadFile;

const GetLogicalDrives = struct {
    extern "kernel32" fn GetLogicalDrives() u32;
}.GetLogicalDrives;

const GetDiskFreeSpaceExW = struct {
    extern "kernel32" fn GetDiskFreeSpaceExW(path: [*:0]const u16, available: ?*u64, total: *u64, total_free: ?*u64) callconv(.winapi) i32;
}.GetDiskFreeSpaceExW;

pub const Error = error{
    AccessDenied,
    NotNtfs,
    InvalidGeometry,
    NotFound,
    OpenFailed,
    ReadFailed,
    NoVolume,
    UnexpectedEof,
};

/// NTFS_VOLUME_DATA_BUFFER uses LARGE_INTEGER for both signed geometry and
/// the opaque serial. The serial's high bit is data, not a negative count.
fn parseVolumeData(data: []const u8) Error!mft.VolumeHeader {
    if (data.len < 96) return error.InvalidGeometry;
    const sector = std.mem.readInt(u32, data[40..44], .little);
    const cluster = std.mem.readInt(u32, data[44..48], .little);
    const record = std.mem.readInt(u32, data[48..52], .little);
    const sectors = std.mem.readInt(i64, data[8..16], .little);
    const clusters = std.mem.readInt(i64, data[16..24], .little);
    const valid = std.mem.readInt(i64, data[56..64], .little);
    const mft_lcn = std.mem.readInt(i64, data[64..72], .little);
    const mirror = std.mem.readInt(i64, data[72..80], .little);
    if (sector < 512 or !std.math.isPowerOfTwo(sector) or
        cluster < sector or !std.math.isPowerOfTwo(cluster) or
        record < 256 or record > 65536 or !std.math.isPowerOfTwo(record) or
        sectors <= 0 or clusters <= 0 or valid <= 0 or
        mft_lcn < 0 or mft_lcn >= clusters or mirror < 0 or mirror >= clusters)
        return error.InvalidGeometry;
    const capacity = std.math.mul(u64, @intCast(clusters), cluster) catch return error.InvalidGeometry;
    const sector_bytes = std.math.mul(u64, @intCast(sectors), sector) catch return error.InvalidGeometry;
    if (capacity > sector_bytes or capacity > std.math.maxInt(i64) or valid > capacity)
        return error.InvalidGeometry;
    return .{
        .bytes_per_sector = sector,
        .bytes_per_cluster = cluster,
        .record_size = record,
        .mft_lcn = @intCast(mft_lcn),
        .mft_valid_len = @intCast(valid),
        .mft2_lcn = @intCast(mirror),
        .total_clusters = @intCast(clusters),
        .volume_bytes = capacity,
        .serial = std.mem.readInt(u64, data[0..8], .little),
    };
}

pub const Volume = struct {
    gpa: std.mem.Allocator,
    handle: windows.HANDLE,
    letter: u8,
    header: mft.VolumeHeader,
    sector: u32,
    scratch: []u8 = &.{},

    pub fn open(gpa: std.mem.Allocator, letter: u8) !*Volume {
        if (!is_windows) return error.NoVolume;
        var path: [8]u16 = .{ '\\', '\\', '.', '\\', letter, ':', 0, 0 };
        const h = CreateFileW(@ptrCast(&path), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
        if (h == windows.INVALID_HANDLE_VALUE) {
            const e = windows.GetLastError();
            log.warn("raw-volume drive={c}: read-only open failed win32={d}", .{ letter, @backingInt(e) });
            return if (e == .ACCESS_DENIED) error.AccessDenied else error.OpenFailed;
        }
        log.info("raw-volume drive={c}: read-only open succeeded", .{letter});
        const self = gpa.create(Volume) catch {
            windows.CloseHandle(h);
            return error.OutOfMemory;
        };
        self.* = .{ .gpa = gpa, .handle = h, .letter = letter, .header = .{}, .sector = 512 };
        errdefer self.close();
        self.queryHeader() catch |err| {
            log.warn("raw-volume drive={c}: geometry failed {t}", .{ letter, err });
            return err;
        };
        log.info("raw-volume drive={c}: NTFS geometry verified sector={d} cluster={d} record={d}", .{ letter, self.header.bytes_per_sector, self.header.bytes_per_cluster, self.header.record_size });
        return self;
    }

    fn queryHeader(self: *Volume) !void {
        var vdb: [96]u8 align(8) = @splat(0);
        var got: u32 = 0;
        const ok = DeviceIoControl(self.handle, FSCTL_GET_NTFS_VOLUME_DATA, null, 0, &vdb, vdb.len, &got, null);
        if (ok != 0) {
            self.header = try parseVolumeData(vdb[0..@min(got, vdb.len)]);
            self.sector = self.header.bytes_per_sector;
            return;
        }
        const e = windows.GetLastError();
        log.warn("raw-volume drive={c}: NTFS geometry ioctl failed win32={d}", .{ self.letter, @backingInt(e) });
        if (e == .ACCESS_DENIED) return error.AccessDenied;
        // ReFS, BitLocker and FAT do not answer this ioctl. The boot sector
        // is the documented fallback, and says "not NTFS" quickly.
        var boot: [512]u8 = undefined;
        self.sector = 512;
        self.header = .{};
        const n = self.readAt(0, &boot) catch return error.NotNtfs;
        if (n < 512) return error.NotNtfs;
        self.header = mft.parseBootSector(&boot) catch return error.NotNtfs;
        self.sector = self.header.bytes_per_sector;
    }

    pub fn close(self: *Volume) void {
        if (self.scratch.len > 0) self.gpa.free(self.scratch);
        self.scratch = &.{};
        if (is_windows) windows.CloseHandle(self.handle);
        self.gpa.destroy(self);
    }

    pub fn source(self: *Volume) scan.Source {
        return .{ .ctx = self, .read_fn = readFn };
    }

    fn readFn(ctx: *anyopaque, offset: u64, buf: []u8) anyerror!usize {
        const self: *Volume = @ptrCast(@alignCast(ctx));
        return self.readAt(offset, buf);
    }

    fn ensureScratch(self: *Volume, len: usize) ![]u8 {
        if (self.scratch.len < len) {
            if (self.scratch.len > 0) self.gpa.free(self.scratch);
            self.scratch = try self.gpa.alloc(u8, len);
        }
        return self.scratch[0..len];
    }

    /// Arbitrary offset and length; the handle sees sector-aligned reads.
    pub fn readAt(self: *Volume, offset: u64, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        const sector: u64 = @max(512, self.sector);
        const aligned_off = offset / sector * sector;
        const delta: usize = @intCast(offset - aligned_off);
        const want = delta + buf.len;
        const aligned_len: usize = std.mem.alignForward(usize, want, @intCast(sector));
        const scratch = try self.ensureScratch(aligned_len);

        var pos: i64 = @intCast(aligned_off);
        const seeked = SetFilePointerEx(self.handle, pos, &pos, 0);
        if (seeked == 0) return error.ReadFailed;
        var got: usize = 0;
        while (got < scratch.len) {
            var n: u32 = 0;
            const left: u32 = @intCast(@min(scratch.len - got, @as(usize, 1 << 20)));
            const ok = ReadFile(self.handle, scratch.ptr + got, left, &n, null);
            if (ok == 0) {
                const e = windows.GetLastError();
                if (e == .HANDLE_EOF) break;
                return error.ReadFailed;
            }
            if (n == 0) break;
            got += n;
        }
        if (got <= delta) return error.UnexpectedEof;
        const copy = @min(buf.len, got - delta);
        @memcpy(buf[0..copy], scratch[delta .. delta + copy]);
        return copy;
    }
};

pub fn logicalDrives() u32 {
    if (!is_windows) return 0;
    return GetLogicalDrives();
}

pub fn letterAt(mask: u32, n: usize) u8 {
    var count: usize = 0;
    var i: u8 = 0;
    while (i < 26) : (i += 1) {
        if ((mask & (@as(u32, 1) << @intCast(i))) != 0) {
            if (count == n) return 'A' + i;
            count += 1;
        }
    }
    return 'C';
}

pub fn usedBytes(letter: u8) !u64 {
    if (!is_windows) return 0;
    var path: [4]u16 = .{ letter, ':', '\\', 0 };
    var total: u64 = 0;
    var free: u64 = 0;
    if (GetDiskFreeSpaceExW(@ptrCast(&path), null, &total, &free) == 0) return error.NoVolume;
    if (free >= total) return 0;
    return total - free;
}

/// Capacity available to the caller, respecting Windows disk quotas.
pub const Space = struct {
    total: u64,
    free: u64,

    pub fn used(self: Space) u64 {
        return self.total -| self.free;
    }
};

pub fn spaceBytes(letter: u8) !Space {
    const path = [_]u8{ letter, ':', '\\' };
    return spaceAtPath(&path);
}

/// Query the volume containing this directory, including mounted volumes
/// and UNC shares. This is capacity, not the size of the scanned folder.
pub fn spaceAtPath(path: []const u8) !Space {
    if (!is_windows) return error.NoVolume;
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.NoVolume;
    var wide: [32768]u16 = undefined;
    var len = std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 2], path) catch return error.NoVolume;
    // GetDiskFreeSpaceEx requires a trailing separator for UNC shares.
    if (wide[len - 1] != '\\' and wide[len - 1] != '/') {
        wide[len] = '\\';
        len += 1;
    }
    wide[len] = 0;
    var result: Space = .{ .total = 0, .free = 0 };
    if (GetDiskFreeSpaceExW(@ptrCast(&wide), &result.free, &result.total, null) == 0) return error.NoVolume;
    return result;
}

test "usedBytes excludes total free space" {
    if (!is_windows) return error.SkipZigTest;
    var path: [4]u16 = .{ 'C', ':', '\\', 0 };
    var total: u64 = 0;
    var free: u64 = 0;
    if (GetDiskFreeSpaceExW(@ptrCast(&path), null, &total, &free) == 0 or free == 0) return error.SkipZigTest;
    const used = try usedBytes('C');
    try std.testing.expect(used < total);
}

test "capacity follows the containing volume of an actual directory" {
    if (!is_windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "Māori folder", .default_dir);
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "Māori folder", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const space = try spaceAtPath(path);
    var wide: [32768]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&wide, path);
    wide[len] = 0;
    var total: u64 = 0;
    var available: u64 = 0;
    try std.testing.expect(GetDiskFreeSpaceExW(@ptrCast(&wide), &available, &total, null) != 0);
    try std.testing.expectEqual(total, space.total);
    try std.testing.expect(space.total > 0);
    try std.testing.expect(space.free <= space.total);
    try std.testing.expectEqual(space.total, space.used() + space.free);
    try std.testing.expectError(error.NoVolume, spaceAtPath(""));
    try std.testing.expectError(error.NoVolume, spaceAtPath("C:\\\x00ignored"));
}

pub const relaunchElevated = elevation.start;

/// The restart child must pass both token and actual volume-read checks
/// before the original is allowed to close. Ordinary launches return false.
pub fn acceptElevation(argv: []const []const u8) elevation.Error!bool {
    return elevation.accept(argv, verifyScanPermission);
}

fn verifyScanPermission(letter: u8) !void {
    const vol = try Volume.open(std.heap.c_allocator, letter);
    defer vol.close();
    var signature: [4]u8 = undefined;
    const offset = std.math.mul(u64, vol.header.mft_lcn, vol.header.bytes_per_cluster) catch return error.NotNtfs;
    const n = try vol.readAt(offset, &signature);
    if (n != signature.len) return error.UnexpectedEof;
    if (!std.mem.eql(u8, &signature, "FILE")) return error.NotNtfs;
    log.info("elevation child drive={c}: first MFT record read verified", .{letter});
}

test {
    _ = elevation;
}

test "NTFS geometry preserves high-bit serials and rejects invalid signed geometry" {
    var data: [96]u8 = @splat(0);
    std.mem.writeInt(i64, data[8..16], 2048, .little);
    std.mem.writeInt(i64, data[16..24], 256, .little);
    std.mem.writeInt(u32, data[40..44], 512, .little);
    std.mem.writeInt(u32, data[44..48], 4096, .little);
    std.mem.writeInt(u32, data[48..52], 1024, .little);
    std.mem.writeInt(i64, data[56..64], 8192, .little);
    std.mem.writeInt(i64, data[64..72], 4, .little);
    std.mem.writeInt(i64, data[72..80], 128, .little);
    // Actual C: and D: serials obtained with read-only FILE_ID_INFO metadata.
    for ([_]u64{ 0xa076329e7632755e, 0x14a4cf11a4cef470, 0, 0xffffffffffffffff }) |serial| {
        std.mem.writeInt(u64, data[0..8], serial, .little);
        const header = try parseVolumeData(&data);
        try std.testing.expectEqual(serial, header.serial);
        try std.testing.expectEqual(@as(u64, 1048576), header.volume_bytes);
        try std.testing.expectEqual(@as(u64, 8), header.recordCount());
        try std.testing.expectEqual(@as(u64, 4), header.mft_lcn);
        try std.testing.expectEqual(@as(u64, 128), header.mft2_lcn);
    }
    const valid = data;
    for ([_]usize{ 8, 16, 56, 64, 72 }) |offset| {
        data = valid;
        std.mem.writeInt(i64, data[offset..][0..8], -1, .little);
        try std.testing.expectError(error.InvalidGeometry, parseVolumeData(&data));
    }
    for ([_]usize{ 8, 16, 56 }) |offset| {
        data = valid;
        std.mem.writeInt(i64, data[offset..][0..8], 0, .little);
        try std.testing.expectError(error.InvalidGeometry, parseVolumeData(&data));
    }
    data = valid;
    std.mem.writeInt(i64, data[64..72], 256, .little);
    try std.testing.expectError(error.InvalidGeometry, parseVolumeData(&data));
    data = valid;
    std.mem.writeInt(i64, data[16..24], std.math.maxInt(i64), .little);
    try std.testing.expectError(error.InvalidGeometry, parseVolumeData(&data));
    data = valid;
    std.mem.writeInt(i64, data[56..64], 1048577, .little);
    try std.testing.expectError(error.InvalidGeometry, parseVolumeData(&data));
    data = valid;
    std.mem.writeInt(u32, data[44..48], 3000, .little);
    try std.testing.expectError(error.InvalidGeometry, parseVolumeData(&data));
    try std.testing.expectError(error.InvalidGeometry, parseVolumeData(valid[0..95]));
}

//! A believable volume for snapshots, tests and the demo clips. Built through
//! the same model builder a real scan uses, so the UI cannot tell the
//! difference — except that this one is instant and needs no administrator.
const std = @import("std");
const model = @import("model.zig");

const GB: u64 = 1024 * 1024 * 1024;
const MB: u64 = 1024 * 1024;

var next_ref: u64 = 100;
var seq: u16 = 1;

fn dir(b: *model.Builder, parent_ref: u64, parent_seq: u16, name: []const u8, alloc: u64) !u64 {
    next_ref += 1;
    const r = next_ref;
    _ = try b.addRecord(r, seq, parent_ref, parent_seq, name, true, 0, alloc);
    return r;
}

fn file(b: *model.Builder, parent_ref: u64, parent_seq: u16, name: []const u8, logical: u64, alloc: u64) !u64 {
    next_ref += 1;
    const r = next_ref;
    _ = try b.addRecord(r, seq, parent_ref, parent_seq, name, false, logical, alloc);
    return r;
}

pub fn build(gpa: std.mem.Allocator) !*model.Model {
    next_ref = 100;
    seq = 1;
    var b = try model.Builder.init(gpa, 5000);
    defer b.deinit();
    const root = try b.addRecord(5, 5, 5, 5, ".", true, 0, 0);

    _ = try file(&b, 5, 5, "$MFT", 2_100 * MB, 2_100 * MB);
    _ = try file(&b, 5, 5, "pagefile.sys", 16 * GB, 16 * GB);
    _ = try file(&b, 5, 5, "hiberfil.sys", 12 * GB, 12 * GB);
    _ = try file(&b, 5, 5, "swapfile.sys", 4 * GB, 4 * GB);

    const win = try dir(&b, 5, 5, "Windows", 0);
    _ = try dir(&b, win, 1, "WinSxS", 30 * GB);
    const sys32 = try dir(&b, win, 1, "System32", 0);
    _ = try file(&b, sys32, 1, "ntoskrnl.exe", 12 * MB, 12 * MB);
    _ = try file(&b, sys32, 1, "kernel32.dll", 2 * MB, 2 * MB);
    _ = try file(&b, sys32, 1, "ntdll.dll", 2 * MB, 2 * MB);
    const drivers = try dir(&b, sys32, 1, "drivers", 0);
    var dbuf: [64]u8 = undefined;
    for (0..24) |i| {
        const name = try std.fmt.bufPrint(&dbuf, "driver{d:0>2}.sys", .{i});
        _ = try file(&b, drivers, 1, name, (i % 5 + 1) * 400 * 1024, (i % 5 + 1) * 400 * 1024);
    }
    _ = try dir(&b, win, 1, "Fonts", 620 * MB);
    _ = try dir(&b, win, 1, "assembly", 3 * GB);

    const users = try dir(&b, 5, 5, "Users", 0);
    const me = try dir(&b, users, 1, "dev", 0);
    const downloads = try dir(&b, me, 1, "Downloads", 0);
    _ = try file(&b, downloads, 1, "ubuntu-24.04.iso", 6 * GB, 6 * GB);
    _ = try file(&b, downloads, 1, "assets.zip", 2 * GB, 2 * GB);
    _ = try file(&b, downloads, 1, "keynote.mp4", 1_400 * MB, 1_400 * MB);
    _ = try file(&b, downloads, 1, "zig-0.17.1.tar.xz", 48 * MB, 48 * MB);
    const documents = try dir(&b, me, 1, "Documents", 0);
    _ = try file(&b, documents, 1, "byakugan-plan.pdf", 4 * MB, 4 * MB);
    _ = try file(&b, documents, 1, "taxes-2025.pdf", 2 * MB, 2 * MB);
    const src = try dir(&b, documents, 1, "byakugan", 0);
    _ = try file(&b, src, 1, "mft.zig", 42 * 1024, 48 * 1024);
    _ = try file(&b, src, 1, "scan.zig", 30 * 1024, 32 * 1024);
    _ = try file(&b, src, 1, "app.zig", 58 * 1024, 64 * 1024);
    _ = try file(&b, src, 1, "model.zig", 26 * 1024, 28 * 1024);
    const pics = try dir(&b, me, 1, "Pictures", 0);
    for (0..18) |i| {
        var pbuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&pbuf, "frame-{d:0>2}.png", .{i});
        _ = try file(&b, pics, 1, name, (i % 4 + 1) * 18 * MB, (i % 4 + 1) * 19 * MB);
    }
    const videos = try dir(&b, me, 1, "Videos", 0);
    _ = try file(&b, videos, 1, "demo-raw.mkv", 9 * GB, 9 * GB);
    _ = try file(&b, videos, 1, "launch-cut.mp4", 2 * GB, 2 * GB);
    const appdata = try dir(&b, me, 1, "AppData", 0);
    const local = try dir(&b, appdata, 1, "Local", 0);
    _ = try file(&b, local, 1, "docker.vhdx", 14 * GB, 14 * GB);
    _ = try file(&b, local, 1, "spotify-cache.bin", 3 * GB, 3 * GB);
    _ = try dir(&b, local, 1, "Packages", 2 * GB);
    _ = try dir(&b, local, 1, "Temp", 5 * GB);

    const pf = try dir(&b, 5, 5, "Program Files", 0);
    _ = try file(&b, pf, 1, "byakugan.exe", 2 * MB, 2 * MB);
    _ = try file(&b, pf, 1, "zig.exe", 180 * MB, 180 * MB);
    _ = try dir(&b, pf, 1, "Google", 1_200 * MB);
    _ = try dir(&b, pf, 1, "Microsoft Office", 3 * GB);

    const pd = try dir(&b, 5, 5, "ProgramData", 0);
    _ = try file(&b, pd, 1, "DockerDesktop.vhdx", 8 * GB, 8 * GB);
    _ = try dir(&b, pd, 1, "Package Cache", 1 * GB);
    _ = try dir(&b, pd, 1, "NVIDIA", 4 * GB);

    const games = try dir(&b, 5, 5, "Games", 0);
    const steam = try dir(&b, games, 1, "Steam", 0);
    const s1 = try dir(&b, steam, 1, "Steamapps", 0);
    _ = try file(&b, s1, 1, "celeste.bin", 2 * GB, 2 * GB);
    _ = try file(&b, s1, 1, "hades2.bin", 14 * GB, 14 * GB);
    _ = try file(&b, s1, 1, "factorio.bin", 4 * GB, 4 * GB);
    _ = try file(&b, s1, 1, "baldurs-gate-3.bin", 72 * GB, 72 * GB);
    _ = try dir(&b, games, 1, "Epic", 3 * GB);

    const projects = try dir(&b, 5, 5, "Projects", 0);
    _ = try dir(&b, projects, 1, "nanoui", 1_800 * MB);
    _ = try dir(&b, projects, 1, "byakugan-build", 600 * MB);
    const mall = try dir(&b, projects, 1, "web-store", 0);
    _ = try dir(&b, mall, 1, "node_modules", 900 * MB);
    _ = try file(&b, mall, 1, "bundle.js.map", 14 * MB, 14 * MB);
    _ = try dir(&b, projects, 1, "archive", 4 * GB);

    const media = try dir(&b, 5, 5, "Media", 0);
    const movies = try dir(&b, media, 1, "Movies", 0);
    _ = try file(&b, movies, 1, "dune-part-two.mkv", 28 * GB, 28 * GB);
    _ = try file(&b, movies, 1, "arrival.mkv", 14 * GB, 14 * GB);
    _ = try file(&b, movies, 1, "the-brutalist.mkv", 19 * GB, 19 * GB);
    const music = try dir(&b, media, 1, "Music", 0);
    for (0..12) |i| {
        var mbuf: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&mbuf, "track-{d:0>2}.flac", .{i});
        _ = try file(&b, music, 1, name, 32 * MB, 32 * MB);
    }

    _ = try dir(&b, 5, 5, "Recovery", 0);
    _ = try dir(&b, 5, 5, "temp", 0);

    // A hard link, counted once in the totals and visible in the detail pane.
    // `file` returns the on-disk record reference; addLink wants the node index.
    const linked_ref = try file(&b, documents, 1, "shared-plan.pdf", 8 * MB, 8 * MB);
    try b.addLink(b.records[@intCast(linked_ref)], 5, 5, 3, "byakugan-plan-copy.pdf");
    _ = root;
    const m = try b.finish();
    m.record_count = 5000;
    m.in_use = 94;
    return m;
}

test "demo model aggregates and has a deep tree" {
    const m = try build(std.testing.allocator);
    defer m.deinit();
    try std.testing.expectEqual(@as(u32, 0), m.root);
    try std.testing.expect(m.nodes[m.root].allocated > 200 * GB);
    const users = m.nodes[m.root].first_child;
    try std.testing.expect(users != model.none);
    var depth_max: u8 = 0;
    for (m.nodes) |n| depth_max = @max(depth_max, n.depth);
    try std.testing.expect(depth_max >= 4);
    try std.testing.expectEqual(@as(usize, 1), m.links.len);
    var linked_node: ?u32 = null;
    for (m.links) |l| linked_node = l.node;
    try std.testing.expect(linked_node != null);
    try std.testing.expectEqual(@as(usize, 1), m.countExtraNames(linked_node.?));
}

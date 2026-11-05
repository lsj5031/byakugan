//! File and folder actions, using the explorer's modal convention.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const cleanup = @import("cleanup.zig");
const normal = @import("normal_launch.zig");
const log = @import("log.zig");
const alloc = std.heap.c_allocator;

const Action = enum { recycle, reopen, explore, bin };
const Work = struct {
    action: Action,
    path: []u8,
    identity: cleanup.Identity,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    result: cleanup.Result = .{},
    failure: ?anyerror = null,
    fn run(self: *Work) void {
        switch (self.action) {
            .recycle => self.result = cleanup.recycle(self.path, self.identity) catch |err| blk: {
                self.failure = err;
                break :blk .{};
            },
            .reopen => normal.reopen(self.path) catch |err| {
                self.failure = err;
            },
            .explore => cleanup.openExplorer(self.path) catch |err| {
                self.failure = err;
            },
            .bin => cleanup.openRecycleBin() catch |err| {
                self.failure = err;
            },
        }
        self.done.store(true, .release);
    }
};

pub const State = struct {
    open: bool = false,
    visible: bool = false,
    restore_focus: bool = false,
    return_focus: u64 = 0,
    phase: enum { actions, confirm, result } = .actions,
    anchor: ?ui.Rect = null,
    focus_cancel: bool = false,
    instant_confirmation: bool = false,
    allocated: u64 = 0,
    recycled: bool = false,
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    identity: ?cleanup.Identity = null,
    is_directory: bool = false,
    recycle_allowed: bool = false,
    reopen_allowed: bool = false,
    message: ?[]const u8 = null,
    stale: bool = false,
    work: ?*Work = null,

    pub fn deinit(self: *State) void {
        if (self.work) |work| {
            work.thread.join();
            alloc.free(work.path);
            alloc.destroy(work);
        }
    }
    pub fn modal(self: *const State) bool {
        return self.open or self.visible;
    }
    pub fn path(self: *const State) []const u8 {
        return self.path_buf[0..self.path_len];
    }
    pub fn begin(self: *State, s: anytype, focus: u64) void {
        if (s.job != null or self.work != null or s.elevation_launch != null) return;
        self.return_focus = focus;
        self.open = true;
        self.phase = .actions;
        self.anchor = null;
        self.recycled = false;
        self.identity = null;
        self.is_directory = false;
        self.path_len = 0;
        self.message = null;
        self.recycle_allowed = false;
        self.reopen_allowed = false;
        if (s.demo) {
            self.message = "Demo entries are illustrative. Scan a real folder to use these actions.";
            return;
        }
        if (self.stale) {
            self.message = "This result may be stale. Refresh successfully before using actions.";
            return;
        }
        const m = s.model orelse return;
        if (s.other_parent != null and s.selected == s.other_parent.?) {
            self.message = "Choose an individual file or folder first.";
            return;
        }
        const selected_path = cleanup.selectionPath(m, s.selected, s.rootLabel(), &self.path_buf) catch {
            self.message = "Actions are unavailable for metadata, protected items, or incomplete paths.";
            return;
        };
        self.path_len = selected_path.len;
        self.is_directory = m.nodes[s.selected].isDirectory();
        self.allocated = m.nodes[s.selected].allocated;
        self.recycle_allowed = s.selected != m.root;
        self.reopen_allowed = @import("byakugan").volume.elevation.isElevated() catch false;
        if (!self.recycle_allowed) self.message = "The scan root can be opened or copied, but cannot be recycled here.";
    }
    fn fail(self: *State, err: anyerror) void {
        log.warn("item action rejected error={s}", .{@errorName(err)});
        self.phase = .result;
        self.open = false;
        self.message = switch (err) {
            error.Missing, error.Changed => "The item is missing or changed since confirmation. Nothing was recycled. Refresh before trying again.",
            error.UnsafePath => "This item cannot be safely recycled here. Roots, protected items, junctions and non-local drives are excluded.",
            else => "Windows could not complete this action. No permanent-delete fallback was attempted.",
        };
    }
    pub fn confirm(self: *State, c: *ui.Context) void {
        if (!self.recycle_allowed or self.path_len == 0) return;
        self.identity = cleanup.prepareRecycle(self.path()) catch |err| {
            self.fail(err);
            c.changed = true;
            return;
        };
        if ((self.identity.?.attributes & 0x10 != 0) != self.is_directory) {
            self.identity = null;
            self.fail(error.Changed);
            c.changed = true;
            return;
        }
        self.phase = .confirm;
        self.open = true;
        self.focus_cancel = true;
        self.instant_confirmation = !c.input.released;
        self.message = null;
        c.focus = 0;
        c.input.clearEdges();
        c.changed = true;
    }
    pub fn request(self: *State, s: anytype, c: *ui.Context, focus: u64) void {
        if (s.job != null or self.work != null or s.elevation_launch != null) return;
        self.begin(s, focus);
        self.confirm(c);
    }
    pub fn contextMenu(self: *State, s: anytype, c: *ui.Context, anchor: ui.Rect, focus: u64) void {
        if (s.job != null or self.work != null or s.elevation_launch != null) return;
        self.begin(s, focus);
        self.anchor = anchor;
        c.focus = 0;
        c.input.clearEdges();
        c.changed = true;
    }
    pub fn start(self: *State, action: Action) void {
        const identity = self.identity orelse if (action == .recycle) return else std.mem.zeroes(cleanup.Identity);
        const work = alloc.create(Work) catch {
            self.fail(error.OutOfMemory);
            return;
        };
        const owned = alloc.dupe(u8, self.path()) catch {
            alloc.destroy(work);
            self.fail(error.OutOfMemory);
            return;
        };
        work.* = .{ .action = action, .path = owned, .identity = identity };
        work.thread = std.Thread.spawn(.{}, Work.run, .{work}) catch |err| {
            alloc.free(owned);
            alloc.destroy(work);
            self.fail(err);
            return;
        };
        self.work = work;
        self.open = false;
        self.phase = .result;
        self.message = switch (action) {
            .reopen => "Requesting a normal window…",
            .explore => "Requesting Explorer…",
            .bin => "Opening Recycle Bin…",
            .recycle => "Moving item to Recycle Bin…",
        };
    }
    pub fn finish(self: *State, s: anytype) void {
        const work = self.work orelse return;
        if (!work.done.load(.acquire)) return;
        work.thread.join();
        const action = work.action;
        const result = work.result;
        const failure = work.failure;
        alloc.free(work.path);
        alloc.destroy(work);
        self.work = null;
        self.phase = .result;
        self.open = false;
        if (action == .explore or action == .bin) {
            if (failure) |err| self.fail(err) else self.message = null;
            return;
        }
        if (action == .reopen) {
            self.reopen_allowed = failure != null;
            if (failure) |err| {
                log.warn("normal reopen failed error={s}", .{@errorName(err)});
                self.message = if (err == error.Missing or err == error.UnsafePath)
                    "The item is missing or no longer available. Refresh before trying again. This window stays open."
                else
                    "Windows could not request a normal window. Make sure Explorer is running normally, or open Byakugan from Explorer yourself. This window stays open.";
            } else self.message = "Explorer accepted the request for a normal window. It will scan the containing folder and select this item. This administrator window and its result remain open; no files were changed.";
            return;
        }
        if (failure) |err| self.fail(err) else {
            log.info("recycle finished outcome={s} hresult=0x{x}", .{ @tagName(result.outcome), @as(u32, @bitCast(result.hr)) });
            self.recycled = result.outcome == .recycled;
            self.message = switch (result.outcome) {
                .recycled => "Moved to Recycle Bin. You can restore it there. Disk space is not freed until the bin is emptied.",
                .cancelled => "Windows cancelled the operation. Changes may have occurred; inspect the original location and Recycle Bin before retrying.",
                .incomplete => "Windows could not confirm that recycling completed. Changes may have occurred. Inspect the original location and Recycle Bin before retrying.",
                .rejected => "Recycling was unavailable and the operation stopped. Changes may have occurred; inspect the original location and Recycle Bin. No permanent-delete fallback was used.",
            };
        }
        // Refresh even after partial failure or cancellation. A failed/cancelled
        // refresh retains the old map, but leaves its actions explicitly stale.
        const changed = if (failure) |err| err == error.Missing or err == error.Changed else false;
        if (result.attempted or changed) {
            self.stale = true;
            s.rescan();
        }
    }

    pub fn view(self: *State, s: anytype, c: *ui.Context) void {
        @import("cleanup_view.zig").overlay(self, s, c);
    }
};

test "normal reopen preserves file and folder selection and keeps original result on launch failure" {
    try testReopenSelection(true);
    try testReopenSelection(false);
}

fn testReopenSelection(directory: bool) !void {
    const App = @import("app.zig").State;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "Other/Chosen & 日本語");
    if (directory) try tmp.dir.createDirPath(io, "Chosen & 日本語");
    try tmp.dir.writeFile(io, .{ .sub_path = if (directory) "Chosen & 日本語/keep.txt" else "Chosen & 日本語", .data = "retained" });
    var path_buf: [4096]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const arg = try std.fmt.allocPrint(std.testing.allocator, "--folder={s}", .{path_buf[0..path_len]});
    defer std.testing.allocator.free(arg);
    var s = App.init(std.testing.allocator, io);
    defer s.deinit();
    s.begin(&.{ arg, "--require-unelevated", "--select-child=Chosen & 日本語" });
    try @import("typeface.zig").register();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, App.view), .{ .width = 900, .height = 600, .scale = 1, .theme = @import("explorer.zig").palette(false) });
    defer t.deinit();
    for (0..200) |_| {
        t.frame();
        if (s.job == null) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(s.job == null and s.model != null);
    const m = s.model.?;
    try std.testing.expect(s.selected != m.root);
    try std.testing.expectEqual(m.root, m.nodes[s.selected].parent);
    try std.testing.expectEqualStrings("Chosen & 日本語", m.name(s.selected));
    try std.testing.expectEqual(directory, m.nodes[s.selected].isDirectory());
    try t.clickText("More…");
    t.settle(1);
    // Render the optional elevated-session action without changing the token.
    s.cleanup.reopen_allowed = true;
    t.frame(); // rebuild before settling the centered dialog's new height
    t.settle(1);
    try std.testing.expect(t.hasText("Reopen normally"));
    try std.testing.expect(t.hasText("Move to Recycle Bin…"));
    try t.clickText("Close");
    t.settle(1);
    try t.clickText("Move to Recycle Bin…");
    t.settle(1);
    try std.testing.expect(t.hasText(if (directory) "Move folder to Recycle Bin?" else "Move file to Recycle Bin?"));
    try std.testing.expect(s.cleanup.identity != null);
    try t.clickText("Cancel");
    t.settle(1);
    try t.clickText("More…");
    s.cleanup.reopen_allowed = true;
    t.frame();
    t.settle(1);
    try t.screenshot(if (directory) "artifacts/ui-reopen-normal-light.png" else "artifacts/ui-file-reopen-light.png");
    t.theme = @import("explorer.zig").palette(true);
    t.frame();
    try t.screenshot(if (directory) "artifacts/ui-reopen-normal-dark.png" else "artifacts/ui-file-reopen-dark.png");
    try tmp.dir.rename("Chosen & 日本語", tmp.dir, "Kept original", io);
    const selected = s.selected;
    try t.clickText("Reopen normally");
    for (0..200) |_| {
        t.frame();
        if (s.cleanup.work == null) break;
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
    t.settle(1);
    try std.testing.expect(s.cleanup.work == null);
    try std.testing.expect(t.containsText("item is missing or no longer available"));
    try std.testing.expect(s.model == m and s.selected == selected and !s.close_child);
    try std.testing.expect(s.job == null);
    var retained: [32]u8 = undefined;
    try std.testing.expectEqualStrings("retained", try tmp.dir.readFile(io, if (directory) "Kept original/keep.txt" else "Kept original", &retained));
    try t.screenshot(if (directory) "artifacts/ui-reopen-normal-failed.png" else "artifacts/ui-file-reopen-failed.png");
    try std.testing.expect(!s.cleanup.modal());
    try std.testing.expectEqual(s.cleanup.return_focus, t.ctx.focus);
    try t.clickText("Dismiss");
    t.settle(1);
}

test "recycle outcomes stay inline and only confirmed success offers restoration" {
    const App = @import("app.zig").State;
    var s = App.init(std.testing.allocator, std.testing.io);
    defer s.deinit();
    s.begin(&.{"--demo"});
    try @import("typeface.zig").register();
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&s, App.view), .{ .width = 900, .height = 600, .scale = 1, .theme = @import("explorer.zig").palette(false) });
    defer t.deinit();
    // Inject shell completion results at the worker boundary. This exercises
    // the real finish/render/refresh path without deleting any actual item.
    for ([_]cleanup.Outcome{ .recycled, .cancelled, .incomplete, .rejected }) |outcome| {
        const work = try alloc.create(Work);
        work.* = .{ .action = .recycle, .path = try alloc.dupe(u8, "C:\\fixture\\Archive.zip"), .identity = std.mem.zeroes(cleanup.Identity), .result = .{ .outcome = outcome, .attempted = true } };
        work.thread = try std.Thread.spawn(.{}, struct {
            fn complete(wrk: *Work) void {
                wrk.done.store(true, .release);
            }
        }.complete, .{work});
        s.cleanup.work = work;
        s.cleanup.phase = .result;
        s.cleanup.message = "Moving item to Recycle Bin…";
        const path = "C:\\fixture\\Archive.zip";
        @memcpy(s.cleanup.path_buf[0..path.len], path);
        s.cleanup.path_len = path.len;
        for (0..200) |_| {
            t.frame();
            if (s.cleanup.work == null) break;
            try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
        }
        t.settle(1);
        try std.testing.expect(s.cleanup.work == null and !s.cleanup.modal());
        try std.testing.expectEqual(outcome == .recycled, t.hasText("Open Recycle Bin"));
        if (outcome != .recycled) try std.testing.expect(t.containsText("Changes may have occurred"));
        if (outcome == .recycled) try t.screenshot("artifacts/ui-recycle-success-fixture.png");
        if (outcome == .incomplete) try t.screenshot("artifacts/ui-recycle-partial-fixture.png");
        try t.clickText("Dismiss");
        t.settle(1);
        try std.testing.expect(!t.hasText("Dismiss"));
    }
}

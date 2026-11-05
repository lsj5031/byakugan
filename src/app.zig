//! Scan lifecycle and the native explorer's shared navigation state.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const by = @import("byakugan");
const model = by.model;
const scan = by.scan;
const volume = by.volume;
const explorer = @import("explorer.zig");
const log = @import("log.zig");
const alloc = std.heap.c_allocator;

pub const Failure = enum(u8) { none, access, not_ntfs, geometry, cancelled, failed, folder_access, folder_missing, picker, start };
const JobKind = enum { volume, folder };
pub const Job = struct {
    id: u64,
    started: i96,
    kind: JobKind = .volume,
    folder_path: []u8 = &.{},
    letter: u8,
    phase: std.atomic.Value(u8) = .init(0),
    records: std.atomic.Value(u64) = .init(0),
    bytes: std.atomic.Value(u64) = .init(0),
    total: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    result: std.atomic.Value(usize) = .init(0),
    failure: Failure = .none,
    used: u64 = 0,
    space: ?volume.Space = null,
    thread: std.Thread = undefined,
};

fn report(ctx: ?*anyopaque, phase: scan.Phase, records: u64, bytes: u64) void {
    const j: *Job = @ptrCast(@alignCast(ctx.?));
    j.phase.store(@backingInt(phase), .release);
    if (records > 0) j.records.store(records, .release);
    if (bytes > 0) j.bytes.store(bytes, .release);
}
fn cancelled(ctx: ?*anyopaque) bool {
    const j: *Job = @ptrCast(@alignCast(ctx.?));
    return j.cancel.load(.acquire);
}
fn runJob(j: *Job) void {
    if (j.kind == .volume) log.info("scan started id={d} kind=volume drive={c}:", .{ j.id, j.letter }) else log.info("scan started id={d} kind=folder", .{j.id});
    const callbacks: scan.Progress = .{ .ctx = j, .report = report, .is_cancelled = cancelled };
    const result = blk: {
        if (j.kind == .folder) break :blk by.folder_scan.scanTree(alloc, j.folder_path, callbacks);
        const vol = volume.Volume.open(alloc, j.letter) catch |err| {
            log.err("scan failed id={d} stage=open error={s}", .{ j.id, @errorName(err) });
            j.failure = switch (err) {
                error.AccessDenied => .access,
                error.NotNtfs => .not_ntfs,
                error.InvalidGeometry => .geometry,
                else => .failed,
            };
            j.done.store(true, .release);
            return;
        };
        defer vol.close();
        j.total.store(vol.header.mft_valid_len, .release);
        const m = scan.scan(alloc, vol.source(), vol.header, callbacks);
        j.used = volume.usedBytes(j.letter) catch 0;
        break :blk m;
    };
    if (result) |m| {
        j.space = if (j.kind == .folder) volume.spaceAtPath(j.folder_path) catch null else volume.spaceBytes(j.letter) catch null;
        j.result.store(@intFromPtr(m), .release);
    } else |err| {
        if (err == error.Cancelled) log.info("scan cancelled id={d}", .{j.id}) else log.err("scan failed id={d} stage=read error={s}", .{ j.id, @errorName(err) });
        j.failure = switch (err) {
            error.Cancelled => .cancelled,
            error.AccessDenied => if (j.kind == .folder) .folder_access else .access,
            error.NotFound => .folder_missing,
            error.NotNtfs, error.BadMft => .not_ntfs,
            else => .failed,
        };
    }
    j.done.store(true, .release);
}

pub const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: ?*nanoui.App = null,
    window: ?*nanoui.Window = null,
    drives: u32 = 0,
    letter: u8 = 'C',
    pending_letter: u8 = 'C',
    location_open: bool = false,
    location_visible: bool = false,
    location_return_focus: u64 = 0,
    location_restore_focus: bool = false,
    location_drives_open: bool = false,
    next_scan_id: u64 = 0,
    elevation_letter: u8 = 'C',
    elevation_launch: ?volume.elevation.Launch = null,
    elevation_error: ?volume.elevation.Error = null,
    elevation_cancelled: bool = false,
    cleanup: @import("cleanup_ui.zig").State = .{},
    close_child: bool = false,
    demo: bool = false,
    folder_mode: bool = false,
    root_label_buf: [4096]u8 = undefined,
    root_label_len: usize = 0,
    initial_child_buf: [1024]u8 = undefined,
    initial_child_len: usize = 0,
    used_bytes: u64 = 0,
    space: ?volume.Space = null,
    model: ?*model.Model = null,
    job: ?*Job = null,
    failure: Failure = .none,
    scan_error_kept: bool = false,
    scan_cancelled: bool = false,
    focus: u32 = 0,
    selected: u32 = 0,
    metric_allocated: bool = true,
    filter_buf: ui.TextBuffer = .{},
    query: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(u32) = .empty,
    inspector_entries: std.ArrayList(u32) = .empty,
    other_parent: ?u32 = null,
    inspector_parent: u32 = model.none,
    browsing_inspector: bool = false,
    inspector_key: u32 = model.none,
    inspector_other: bool = false,
    rows_dirty: bool = true,
    scroll_to: ?f32 = null,
    inspector_scroll: f32 = 0,
    preserve_navigation: bool = false,
    map_dirty: bool = true,
    map_w: f32 = -1,
    map_h: f32 = -1,
    tiles: std.ArrayList(explorer.Tile) = .empty,
    files: usize = 0,
    folders: usize = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) State {
        return .{ .gpa = gpa, .io = io };
    }
    pub fn deinit(self: *State) void {
        self.cleanup.deinit();
        if (self.elevation_launch) |*launch| launch.deinit();
        if (self.job) |j| {
            j.cancel.store(true, .release);
            j.thread.join();
            const p = j.result.load(.acquire);
            if (p != 0) {
                const m: *model.Model = @ptrFromInt(p);
                m.deinit();
            }
            self.destroyJob(j);
        }
        if (self.model) |m| m.deinit();
        self.filter_buf.deinit();
        self.query.deinit(alloc);
        self.entries.deinit(alloc);
        self.inspector_entries.deinit(alloc);
        self.tiles.deinit(alloc);
    }
    fn destroyJob(self: *State, j: *Job) void {
        if (j.folder_path.len > 0) alloc.free(j.folder_path);
        alloc.destroy(j);
        self.job = null;
    }
    pub fn begin(self: *State, argv: []const []const u8) void {
        _ = volume.acceptElevation(argv) catch |err| {
            log.err("elevated child rejected error={s}", .{@errorName(err)});
            self.close_child = true;
            return;
        };
        var live = false;
        var explicit_volume = false;
        var folder: ?[]const u8 = null;
        var i: usize = 0;
        while (i < argv.len) : (i += 1) {
            const a = argv[i];
            if (std.mem.eql(u8, a, "--demo")) self.demo = true;
            if (std.mem.eql(u8, a, "--live")) live = true;
            if (std.mem.startsWith(u8, a, "--volume=") and a.len >= 10) {
                const ch = std.ascii.toUpper(a[9]);
                if (ch >= 'A' and ch <= 'Z') {
                    self.letter = ch;
                    explicit_volume = true;
                }
            }
            if (std.mem.eql(u8, a, "--folder")) {
                i += 1;
                if (i < argv.len) folder = argv[i];
            } else if (std.mem.startsWith(u8, a, "--folder=")) folder = a[9..];
            if (std.mem.startsWith(u8, a, "--select-child=") and a.len - 15 <= self.initial_child_buf.len) {
                self.initial_child_len = a.len - 15;
                @memcpy(self.initial_child_buf[0..self.initial_child_len], a[15..]);
            }
        }
        self.drives = volume.logicalDrives();
        self.setVolumeLabel();
        if (folder) |path| {
            self.setRootLabel(path);
            self.startFolderScan(path);
        } else if (self.demo) {
            log.info("scan started id=0 kind=fixture", .{});
            self.demo = true;
            self.install(by.demo.build(alloc) catch {
                self.failure = .failed;
                return;
            });
            log.info("scan complete id=0 kind=fixture files={d} folders={d}", .{ self.files, self.folders });
        } else if (explicit_volume or live) self.startScan() else self.chooseLocation();
    }
    pub fn chooseLocation(self: *State) void {
        self.location_drives_open = false;
        self.pending_letter = self.letter;
        if (self.drives & (@as(u32, 1) << @intCast(self.pending_letter - 'A')) == 0) {
            for (0..26) |i| {
                if (self.drives & (@as(u32, 1) << @intCast(i)) != 0) {
                    self.pending_letter = 'A' + @as(u8, @intCast(i));
                    break;
                }
            }
        }
        self.location_open = true;
    }
    fn setRootLabel(self: *State, label: []const u8) void {
        const n = @min(label.len, self.root_label_buf.len);
        @memcpy(self.root_label_buf[0..n], label[0..n]);
        self.root_label_len = n;
    }
    fn setVolumeLabel(self: *State) void {
        self.root_label_len = (std.fmt.bufPrint(&self.root_label_buf, "{c}:\\", .{self.letter}) catch return).len;
    }
    pub fn rootLabel(self: *const State) []const u8 {
        return self.root_label_buf[0..self.root_label_len];
    }
    pub fn displayPath(self: *State, c: *ui.Context, node: u32) []const u8 {
        const m = self.model orelse return self.rootLabel();
        var buf: [4096]u8 = undefined;
        const rel = m.relativePathInto(node, &buf);
        const root = self.rootLabel();
        return c.print("{s}{s}{s}", .{ root, if (root.len > 0 and root[root.len - 1] == '\\' or rel.len == 0) "" else "\\", rel });
    }
    pub fn install(self: *State, m: *model.Model) void {
        const old = self.model;
        defer if (old) |previous| previous.deinit();
        const focus = self.focus;
        const selected = self.selected;
        const parent = self.inspector_parent;
        const other = self.other_parent;
        const browsing = self.browsing_inspector;
        self.model = m;
        self.cleanup.stale = false;
        self.failure = .none;
        self.scan_error_kept = false;
        self.focus = m.root;
        self.selected = m.root;
        self.inspector_parent = m.root;
        self.browsing_inspector = false;
        self.other_parent = null;
        self.files = 0;
        self.folders = 0;
        for (m.nodes, 0..) |n, i| {
            if (i == m.root or n.flags & model.FLAG_SYNTHETIC != 0) continue;
            if (n.isDirectory()) self.folders += 1 else self.files += 1;
        }
        m.sortChildren(alloc, if (self.metric_allocated) .allocated else .logical) catch {};
        if (self.initial_child_len > 0) {
            for (m.nodes, 0..) |n, i| {
                if (n.parent == m.root and std.mem.eql(u8, m.name(@intCast(i)), self.initial_child_buf[0..self.initial_child_len])) {
                    self.select(@intCast(i));
                    break;
                }
            }
            self.initial_child_len = 0;
        }
        self.invalidate();
        if (self.preserve_navigation and old != null) {
            @import("navigation_restore.zig").restore(self, old.?, m, focus, selected, parent, other, browsing);
        } else {
            self.filter_buf.clear();
            self.query.clearRetainingCapacity();
        }
        self.preserve_navigation = false;
    }
    pub fn invalidate(self: *State) void {
        self.rows_dirty = true;
        self.map_dirty = true;
        self.inspector_key = model.none;
        self.scroll_to = 0;
    }
    pub fn setFocus(self: *State, node: u32) void {
        const m = self.model orelse return;
        if (!m.nodes[node].isDirectory()) return;
        self.focus = node;
        self.selected = node;
        self.inspector_parent = node;
        self.browsing_inspector = false;
        self.other_parent = null;
        self.filter_buf.clear();
        self.invalidate();
    }
    pub fn select(self: *State, node: u32) void {
        const m = self.model.?;
        self.selected = node;
        self.inspector_parent = if (m.nodes[node].isDirectory()) node else m.nodes[node].parent;
        self.browsing_inspector = false;
        self.other_parent = null;
        self.inspector_key = model.none;
        self.scroll_to = 0;
    }
    pub fn selectInspector(self: *State, node: u32) void {
        self.selected = node;
        self.browsing_inspector = true;
    }
    pub fn size(self: *const State, node: u32) u64 {
        const n = self.model.?.nodes[node];
        return if (self.metric_allocated) n.allocated else n.size;
    }
    pub fn metricChanged(self: *State) void {
        const m = self.model orelse return;
        m.sortChildren(alloc, if (self.metric_allocated) .allocated else .logical) catch {};
        self.invalidate();
    }
    pub fn ensureEntries(self: *State) void {
        const m = self.model orelse return;
        const text = self.filter_buf.text();
        if (!std.mem.eql(u8, text, self.query.items)) {
            self.query.clearRetainingCapacity();
            self.query.appendSlice(alloc, text) catch {};
            self.invalidate();
            self.other_parent = null;
            self.selected = self.focus;
            self.inspector_parent = self.focus;
            self.browsing_inspector = false;
        }
        if (!self.rows_dirty) return;
        self.entries.clearRetainingCapacity();
        var child = m.nodes[self.focus].first_child;
        while (child != model.none) : (child = m.nodes[child].next_sibling) {
            if (!visibleEntry(m, child)) continue;
            if (by.tree_view.containsIgnoreCase(m.name(child), text)) self.entries.append(alloc, child) catch break;
        }
        if (text.len > 0 and self.selected == self.focus and self.entries.items.len > 0) self.selected = self.entries.items[0];
        self.rows_dirty = false;
    }
    pub fn ensureInspector(self: *State) void {
        const parent = self.other_parent orelse self.inspector_parent;
        const other = self.other_parent != null;
        if (self.inspector_key == parent and self.inspector_other == other) return;
        self.inspector_key = parent;
        self.inspector_other = other;
        self.inspector_entries.clearRetainingCapacity();
        const m = self.model orelse return;
        var child = m.nodes[parent].first_child;
        var shown: usize = 0;
        while (child != model.none) : (child = m.nodes[child].next_sibling) {
            if (!visibleEntry(m, child)) continue;
            if (parent == self.focus and !by.tree_view.containsIgnoreCase(m.name(child), self.filter_buf.text())) continue;
            if (other and self.size(child) > 0 and shown < explorer.tile_limit) {
                shown += 1;
                continue;
            }
            self.inspector_entries.append(alloc, child) catch break;
        }
    }
    pub fn openFolder(self: *State) void {
        if (self.job != null) return;
        const paths = nanoui.dialog.open(alloc, .{ .title = "Open folder to scan", .button = "Scan folder", .files = false, .directories = true }) catch |err| {
            log.err("folder picker failed error={s}", .{@errorName(err)});
            self.failure = .picker;
            self.location_open = false;
            return;
        } orelse return;
        defer nanoui.dialog.freePaths(alloc, paths);
        if (paths.len > 0) {
            self.location_open = false;
            self.startFolderScan(paths[0]);
        }
    }
    pub fn startScan(self: *State) void {
        self.startVolumeScan(self.letter);
    }
    pub fn startVolumeScan(self: *State, letter: u8) void {
        self.startJob(.volume, "", letter);
    }
    pub fn startFolderScan(self: *State, path: []const u8) void {
        self.startJob(.folder, path, self.letter);
    }
    fn startJob(self: *State, kind: JobKind, path: []const u8, letter: u8) void {
        if (self.job != null or self.elevation_launch != null or self.cleanup.work != null) return;
        self.preserve_navigation = false;
        self.elevation_error = null;
        self.elevation_cancelled = false;
        self.next_scan_id += 1;
        if (kind == .volume) log.info("scan request id={d} kind=volume drive={c}:", .{ self.next_scan_id, letter }) else log.info("scan request id={d} kind=folder", .{self.next_scan_id});
        const owned = alloc.dupe(u8, path) catch |err| {
            log.err("scan start failed id={d} error={s}", .{ self.next_scan_id, @errorName(err) });
            self.failure = .start;
            return;
        };
        const j = alloc.create(Job) catch |err| {
            log.err("scan start failed id={d} error={s}", .{ self.next_scan_id, @errorName(err) });
            alloc.free(owned);
            self.failure = .start;
            return;
        };
        j.* = .{ .id = self.next_scan_id, .started = std.Io.Clock.now(.awake, self.io).nanoseconds, .kind = kind, .letter = letter, .folder_path = owned };
        self.job = j;
        self.failure = .none;
        self.scan_error_kept = false;
        self.scan_cancelled = false;
        j.thread = std.Thread.spawn(.{}, runJob, .{j}) catch |err| {
            log.err("scan start failed id={d} error={s}", .{ j.id, @errorName(err) });
            self.failure = .start;
            self.destroyJob(j);
            return;
        };
        nanoui.App.after(80, self, tick);
    }
    pub fn rescan(self: *State) void {
        if (self.job != null or self.elevation_launch != null or self.cleanup.work != null) return;
        if (self.demo) {
            const fixture = by.demo.build(alloc) catch {
                self.failure = .start;
                return;
            };
            self.preserve_navigation = true;
            self.install(fixture);
            log.info("scan complete id=0 kind=fixture files={d} folders={d}", .{ self.files, self.folders });
            return;
        }
        if (self.folder_mode) self.startFolderScan(self.rootLabel()) else self.startScan();
        self.preserve_navigation = self.job != null;
    }
    pub fn restartElevated(self: *State) void {
        if (self.elevation_launch != null) return;
        self.elevation_error = null;
        self.elevation_cancelled = false;
        const started = volume.relaunchElevated(self.elevation_letter) catch |err| {
            self.elevation_error = err;
            log.err("administrator restart failed error={s}", .{@errorName(err)});
            return;
        };
        switch (started) {
            .cancelled => self.elevation_cancelled = true,
            .pending => |launch| self.elevation_launch = launch,
        }
    }
    fn pollElevation(self: *State, c: *ui.Context) void {
        if (self.close_child) {
            c.requestClose();
            return;
        }
        const launch = if (self.elevation_launch) |*launch| launch else return;
        const result = launch.poll() catch |err| {
            launch.deinit();
            self.elevation_launch = null;
            self.elevation_error = err;
            log.err("administrator handoff failed error={s}", .{@errorName(err)});
            return;
        };
        if (result == .ready) {
            launch.deinit();
            self.elevation_launch = null;
            c.requestClose();
        } else c.frameIn(0.05);
    }
    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(ctx.?));
        if (self.window) |w| w.redraw();
        if (self.job != null or self.cleanup.work != null) nanoui.App.after(80, self, tick);
    }
    fn finishJob(self: *State) void {
        const j = self.job orelse return;
        if (!j.done.load(.acquire)) return;
        j.thread.join();
        const p = j.result.load(.acquire);
        log.info("scan finished id={d} kind={s} result={s} elapsed_ms={d} records={d} bytes={d}", .{ j.id, @tagName(j.kind), if (p != 0) "complete" else @tagName(j.failure), @divTrunc(std.Io.Clock.now(.awake, self.io).nanoseconds - j.started, std.time.ns_per_ms), j.records.load(.acquire), j.bytes.load(.acquire) });
        if (p != 0) {
            self.install(@ptrFromInt(p));
            self.demo = false;
            self.folder_mode = j.kind == .folder;
            self.letter = j.letter;
            if (self.folder_mode) self.setRootLabel(j.folder_path) else self.setVolumeLabel();
            self.used_bytes = j.used;
            self.space = j.space;
            log.info("scan totals id={d} files={d} folders={d} logical={d} allocated={d} skipped={d}", .{ j.id, self.files, self.folders, self.model.?.nodes[self.model.?.root].size, self.model.?.nodes[self.model.?.root].allocated, self.model.?.skipped });
        } else if (j.failure == .cancelled) {
            self.scan_cancelled = true;
            if (self.model == null) self.failure = .cancelled;
        } else if (j.failure != .none) {
            self.failure = j.failure;
            if (j.failure == .access) self.elevation_letter = j.letter;
            self.scan_error_kept = self.model != null;
        }
        self.destroyJob(j);
    }
    fn keys(self: *State, c: *ui.Context) void {
        if (self.location_open or self.location_visible or self.elevation_launch != null or self.cleanup.modal()) return;
        if (c.input.shortcut) |sc| {
            if ((sc.ctrl or sc.cmd) and sc.key == 'f') {
                self.filter_buf.focus();
                c.changed = true;
                return;
            }
        }
        const k = c.input.key orelse return;
        if (c.focus != 0 and c.focus == self.filter_buf.last_id) return;
        if (c.focused_text != null or (c.focus != 0 and k != .f5 and k != .delete and k != .down and k != .up)) return;
        const m = self.model orelse return;
        // One physical keystroke produces one navigation action, including
        // when nanoui rebuilds this frame after the state changes.
        defer c.input.key = null;
        switch (k) {
            .f5 => self.rescan(),
            .delete => {
                self.cleanup.request(self, c, c.focus);
                c.input.shortcut = null;
            },
            .escape, .backspace, .left => {
                if (self.filter_buf.text().len > 0) self.filter_buf.clear() else if (self.focus != m.root) self.setFocus(m.nodes[self.focus].parent);
            },
            .enter, .right => self.setFocus(self.selected),
            .down, .up => {
                c.focus = 0;
                const browsing = self.other_parent != null or self.browsing_inspector;
                const entries = if (browsing) self.inspector_entries.items else self.entries.items;
                if (entries.len == 0) return;
                var current: ?usize = null;
                for (entries, 0..) |node, i| {
                    if (node == self.selected) {
                        current = i;
                        break;
                    }
                }
                const pos = if (current) |i| (if (k == .down) @min(i + 1, entries.len - 1) else i -| 1) else if (k == .down) 0 else entries.len - 1;
                if (browsing) {
                    self.selectInspector(entries[pos]);
                    self.scroll_to = @as(f32, @floatFromInt(pos)) * 46;
                } else self.select(entries[pos]);
            },
            else => return,
        }
        c.changed = true;
    }
    pub fn view(self: *State, c: *ui.Context) void {
        self.pollElevation(c);
        self.finishJob();
        self.cleanup.finish(self);
        self.ensureEntries();
        self.ensureInspector();
        self.keys(c);
        explorer.view(self, c);
        if (self.job != null or self.cleanup.work != null) c.frameIn(0.08);
    }
};

pub fn visibleEntry(m: *const model.Model, node: u32) bool {
    return m.nodes[node].flags & model.FLAG_SYNTHETIC == 0 or m.nodes[node].first_child != model.none;
}

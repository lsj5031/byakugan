# byakugan — an MFT disk analyzer in Zig + nanoui

**白眼**, the Hyūga's all-seeing eye: it reads the chakra network through everything in front of it. This tool does the same to a volume — it reads the NTFS master file table directly instead of walking the directory API, so it sees every file, every size, and where the space actually went.

Status: plan only, no code. Windows, Zig 0.17.x, nanoui.

## 0. Decisions made up front

| Decision | Choice | Why |
| --- | --- | --- |
| Location | `T:\playground\byakugan`, sibling of `nanoui` | Rembrandt's build and its one-app rules stay untouched |
| Artifacts | two exes from one library module: `byakugan.exe` (window) and `byakugan-cli.exe` (console) | Phase 0 is verifiable without a window; the CLI stays useful |
| Header facts | `FSCTL_GET_NTFS_VOLUME_DATA` first, boot sector as fallback | one call, no signed-field parsing, and it yields `MftValidDataLength` |
| Treemap tiles | absolutely positioned `ui.div`s, not `ui.canvas` shapes | canvas has no text and no hit testing; ≤256 tiles is nothing for layout |
| Hard links | one node, canonical path + extra links in the detail pane | counted once, both paths still visible |
| Reparse points | never followed | the scan never traverses the directory API, so junctions cannot double-count |
| Repaint while scanning | driven from the view on the UI thread | nanoui has no timer API and `Surface.frame_posted` is a plain `bool` |

## 1. Layout

```text
byakugan/
  build.zig            lib module + two exes + run/scan/test steps
  build.zig.zon        nanoui path dep, minimum_zig_version 0.17.0
  src/lib.zig          root module: re-exports model, mft, volume, scan, treemap
  src/main.zig         GUI entry: App.create, window, State
  src/cli.zig          console entry: argument parsing, report
  src/app.zig          State + view (toolbar, tree, treemap, rollup, status)
  src/model.zig        Node table, name arena, link table, aggregation
  src/mft.zig          pure parser: boot sector, records, attributes, runlists
  src/volume.zig       Win32: open, FSCTL, aligned reads; `Source` interface
  src/scan.zig         bootstrap, iterate, link, aggregate — takes a Source
  src/treemap.zig      squarified layout, pure math
  src/tree_view.zig    flatten visible rows, indent, sort, share columns
  src/theme.zig        palette, extension → colour
  src/tests.zig        imports the suites, holds shared fixtures
  src/tests_parser.zig record/attribute/runlist fixtures
  src/tests_scan.zig   whole pipeline against a synthetic volume image
  src/tests_treemap.zig layout invariants
  src/tests_view.zig   `ui.Tester` frames over a fixture model
```

`scan.zig` takes a `Source` (a read-at vtable), so the entire pipeline — bootstrap, runlist following, linking, aggregation — runs against a byte array in tests, no admin and no volume.

## 2. Host facts (verified 2026-11-05)

- `zig version` → **0.17.1**, and `zig` resolves on PATH.
- `std.fs.File` is gone; file I/O is `std.Io.File` / `std.Io.Dir` / `std.Io.Threaded`. `src/log.zig` is the local precedent for the new API.
- `std/os/windows/kernel32.zig` is 928 bytes and declares **only** `CreateProcessW`. Every other call is a local `extern "kernel32"` / `"shell32"` declaration with `callconv(.winapi)`.
- nanoui provides `ui.list` (virtualized `Rows` with overscan), `ui.div` with `.absolute().offset()`, `ui.textField`, `ui.key`, `ui.Tester` (`click`, `moveTo`, `key`, `typeText`, `scroll`, `screenshot`), `Window.redraw()`, and `nui snapshot` via `--nanoui-snapshot`.
- nanoui provides **no timer API**, and `windows/surface.zig`'s `requestFrame` touches a non-atomic `frame_posted`; repaint during a scan is therefore driven from the UI thread (§9.5).
- `ui.panes` is a two-pane, fold-aware primitive, not a general splitter. Window layout uses `ui.div`.
- `ui.canvas` draws rects/lines/circles/polygons and clips them, but has no text primitive and no hit testing. It stays as the fallback if tile counts ever exceed a few hundred.

## 3. Opening the volume

```zig
CreateFileW(L"\\\\.\\C:", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null,
            OPEN_EXISTING, 0, null)
```

- Share modes keep the volume mounted. No `FSCTL_LOCK_VOLUME`: the scan is a point-in-time snapshot, like WizTree's.
- `INVALID_HANDLE_VALUE` + `ERROR_ACCESS_DENIED` → elevation flow (§9.7). Any other error gets its own message.
- No `FILE_FLAG_NO_BUFFERING`; Windows still requires sector-aligned offset *and* length on a volume handle, so every read goes through a cluster-sized buffer.

### 3.1 Header facts from FSCTL, not the boot sector

`DeviceIoControl(h, FSCTL_GET_NTFS_VOLUME_DATA /* 0x00090064 */, null, 0, &vdb, @sizeOf(NTFS_VOLUME_DATA_BUFFER), ...)`

| Offset | Field | Use |
| --- | --- | --- |
| 0x28 | `BytesPerSector` | USA fixup stride, read alignment |
| 0x2C | `BytesPerCluster` | LCN → byte offset |
| 0x30 | `BytesPerFileRecordSegment` | record stride |
| 0x38 | `MftValidDataLength` | how much `$MFT` to read and iterate |
| 0x40 | `MftStartLcn` | record 0 |
| 0x48 | `Mft2StartLcn` | `$MFTMirr`, fallback only |

Failure modes are clean and early: `ERROR_INVALID_FUNCTION` / `ERROR_NOT_SUPPORTED` → "not an NTFS volume" (covers ReFS and BitLocker, whose boot sectors are not ours to parse). Only if the ioctl is unavailable does the boot sector path run.

The boot sector parser still exists — it is the fallback and a test fixture generator:

- `0x03` OEM ID, must be `NTFS    `.
- `0x0B` bytes per sector (`u16`), `0x0D` sectors per cluster (`u8`).
- `0x30` MFT LCN (`i64`, relative to the volume start).
- `0x40` clusters per record (`i8`): positive = clusters, negative = record is `1 << -n` bytes.

### 3.2 Reads

One reusable buffer. Runs are coalesced into reads of up to 8 MiB (a fragmented MFT otherwise costs one syscall per extent); `SetFilePointerEx` + `ReadFile`, looping on short reads, treating `ERROR_HANDLE_EOF` as the end. `ReadFile` returning 0 bytes before the expected length is an error, not a quiet stop.

## 4. Record parsing (`mft.zig`, pure)

`FILE` record header:

| Offset | Field |
| --- | --- |
| 0x00 | signature `"FILE"` — **checked first**, before the USA count |
| 0x04 | USA offset, 0x06 USA count |
| 0x10 | sequence number (`u16`) |
| 0x14 | first attribute offset (`u16`) |
| 0x16 | flags (`u16`): 0x01 in use, 0x02 directory |
| 0x18 | used size, 0x1C allocated size |
| 0x20 | base record reference (`u64`, low 48 bits) |

- **USA fixup** is applied per `BytesPerSector`, not per 512 bytes. `count = 1 + record_size / sector_size`; `usa[0]` is the check value; `usa[i+1]` replaces the last two bytes of sector `i`. If a sector's last two bytes do not equal `usa[0]`, the record is corrupt — count it, skip it, and report the total at the end. A 4 KiB-sector fixture is mandatory.
- Records are read as a byte stream, not one per cluster: with 512-byte clusters a 1 KiB record straddles clusters, and the buffer must carry the remainder.
- Iterate to `MftValidDataLength / record_size`. Skip `flags & 0x01 == 0`. Skip records with a non-zero base reference as *nodes*, but still parse them: extension records are where an `$ATTRIBUTE_LIST` points.
- Zero-filled records stop parsing immediately (signature check) rather than producing a header full of nonsense.

Attributes: walk from the first offset by the record-relative length, stopping at `0xFFFFFFFF`.

| Type | Needed for |
| --- | --- |
| `$FILE_NAME` (0x30) | name, parent FRN + sequence, namespace, flags |
| `$DATA` (0x80) | logical and allocated size; unnamed and named streams |
| `$INDEX_ALLOCATION` (0xA0) | directory index space, allocated only |
| `$ATTRIBUTE_LIST` (0x20) | extension records holding more `$FILE_NAME`/`$DATA` |

`$STANDARD_INFORMATION` is **not** needed: timestamps are not shown, and reparse / sparse / compressed flags are all in `$FILE_NAME`. Drop it from the hot path.

`$FILE_NAME` content: parent FRN at 0x00 (low 48 bits = record, high 16 = sequence), flags at 0x38, name length at 0x40 (UTF-16 chars), namespace at 0x41, name at 0x42. Namespace 2 is DOS 8.3 — prefer 0/1/3 (Win32), fall back to 2 only when it is the sole name. Keep the parent's sequence number: a parent FRN whose sequence no longer matches the parent record is a reused record, so the child is an orphan, not a child.

`$DATA` non-resident sizes: allocated at 0x28, real at 0x30, initialized at 0x38. Resident data is the value length at 0x10 with value at 0x14.

Runlist: header byte low nibble = length-field bytes, high nibble = offset-field bytes. Length is unsigned, offset is **signed little-endian and cumulative from the previous LCN**; a zero-width offset field means a sparse run. Terminator = a zero header byte.

## 5. Scan (`scan.zig`)

1. **Bootstrap.** Read record 0 at `MftStartLcn * BytesPerCluster`. Parse its unnamed non-resident `$DATA` runlist; that runlist *is* the MFT, fragmented or not. Clamp the read length to `MftValidDataLength`. If record 0 carries an `$ATTRIBUTE_LIST`, walk it to the extension records for the full `$DATA` before proceeding — rare, and the alternative is a silently truncated scan. `$MFTMirr` at `Mft2StartLcn` is the fallback if record 0 itself is unreadable; it only holds the first four records, so it buys the header facts and nothing else.
2. **Iterate.** Stream the MFT through the parser in record order. In-use records with a zero base reference become nodes; extension records are parsed for attributes and dropped.
3. **Pass 1** fills the dense `record → node index` table (`u32`, `0xFFFFFFFF` = absent) and appends names to the arena. Record order is not tree order; never link while parsing.
4. **Pass 2** resolves each node's parent: in range, sequence match, else orphan. The root is record 5 (its `$FILE_NAME` parent is itself — special-case it).
5. **Hard links.** The first Win32-namespace `$FILE_NAME` becomes the canonical parent and name; the rest go into a small `Link` table (node, parent, name offset/length) shown in the detail pane. Add the record's sizes once.
6. **Orphans** attach to a synthetic node under the root, labelled with the parent FRN, so no bytes vanish from the totals.
7. **Aggregation** bottom-up. Nodes are in record order, not topological order: counting-sort indices by depth (256 buckets), then walk depths from deepest to shallowest, adding each node's own totals into its parent. O(n), no recursion.

## 6. Space accounting

| Quantity | Definition |
| --- | --- |
| logical | unnamed `$DATA` real size |
| allocated | unnamed + named `$DATA` allocated size, plus `$INDEX_ALLOCATION` allocated for directories |
| subtree totals | node totals plus children, aggregated in §5.7 |

This is deliberate, and it is what makes the acceptance numbers achievable:

- **Named streams count** toward allocated. `$Secure:$SDS` alone is tens of MB on C:; ignoring it would silently under-count.
- **Directory index space counts** toward allocated but not logical. It is real clusters, and without it the total cannot match the volume.
- The UI shows logical by default with a toggle; the CLI prints both.
- Excluded and documented: the boot cluster, the MFT reserved zone (not allocated), and `$BadClus` (sparse, allocated 0).

## 7. Memory

`Node` is 40 bytes: `parent: u32, first_child: u32, next_sibling: u32, name_off: u32, name_len: u16, flags: u8, depth: u8, size: u64, allocated: u64`.

| Table | Cost |
| --- | --- |
| nodes | 40 B × in-use records |
| record → node | 4 B × record slots |
| names (UTF-8 arena) | ~28–40 B × nodes |
| extra hard links | 16 B × extras |

So ~1M records ≈ 84 MB, and ~2.5M (a typical C:) ≈ 210 MB. State the whole number in the status bar, not just the node count. `depth` is `u8`: assert < 255 at link time rather than truncating.

The scan thread owns the model until it publishes. Publishing is a mutex-guarded pointer plus a release-ordered `ready` flag; the UI acquires it, and frees the previous model at the top of the *next* frame, after a frame has drawn the new one.

## 8. CLI (`byakugan-cli.exe`)

```text
byakugan-cli C: [--top N] [--allocated] [--no-progress]
```

```text
byakugan 0.1.0 — C: (NTFS, 4096 B clusters, 1024 B records)
scanned 2,431,887 records (1,986,204 in use) in 1.84 s
logical 812.4 GiB · allocated 798.1 GiB · volume used 798.1 GiB · delta 3.2 MiB
top directories by allocated
  ...
```

Exit codes: 0 ok, 2 access denied, 3 not NTFS, 4 read/parse failure. Access denied prints the "run as administrator" hint — no auto-elevation in v1. The console subsystem is a separate artifact precisely so this output exists at all.

## 9. App

### 9.1 Layout

`ui.div` column: toolbar (44) · middle row (grow: tree 40 %, treemap 60 %) · rollup (180) · status bar (28). Each region clipped. No `ui.panes`.

### 9.2 Tree

`ui.list` with `count = visible rows`, `row_height = 26`. `tree_view.zig` flattens the visible rows each frame from expansion state into a reused `ArrayList(u32)`; a filter keeps matches plus their ancestors. Row: expander, name (`truncate = .fade`), size, share bar, indent `depth * 14`. Click focuses, arrows walk, Enter expands, share column follows the logical/allocated toggle. Children are sorted once at publish by allocated descending; a sort change re-links in place and accepts a one-frame hitch (measure it; move off-thread only if it hurts).

### 9.3 Treemap

`treemap.zig`: squarified layout of the focused node's children, pure, returning rects in a caller-provided slice. Cached by `(focus, width, height, metric)` and recomputed only when one of those changes.

Tiles are `.absolute().offset()` divs inside a clipped container: background from `theme.extensionColor`, 1 px padding for separation, label only when `w > 48 && h > 18`, hover in `theme.hover`, click focuses. No `ui.canvas` and no manual hit testing. Cap at 256 tiles; the layout already drops tiles below ~3 px.

Breadcrumb above, `Backspace`/`Esc` up, double-click a tile to focus. Tile labels use the same size formatter as the tree (GiB/MiB, one decimal).

### 9.4 Rollup

Top 12 extensions by allocated in the focused subtree, plus "other": name, size, share bar, count. Clicking a row sets the filter to that extension.

### 9.5 Scan thread and repaint

`std.Thread.spawn` with a `ScanJob`:

```zig
phase: std.atomic.Value(Phase),   // idle, reading, linking, done, failed
bytes_done: std.atomic.Value(u64),
records_done: std.atomic.Value(u32),
cancel: std.atomic.Value(bool),
```

Cancel is checked between MFT extents (and between record pages during linking), never inside a syscall.

Repaint: the view, on the UI thread, calls `window.redraw()` while a scan is live, throttled to ~10 fps by accumulating `c.frame_time`. This keeps `Surface.frame_posted` single-threaded and needs no nanoui change. On completion the thread publishes the model and stores `done`; the next UI frame picks it up. A failure stores a message and the UI shows it in the status bar, not a modal.

### 9.6 Progress

Status bar: phase, records, bytes read, elapsed, a thin progress bar whose total is `MftValidDataLength`. Instantaneous MB/s over the last second, kept in the state.

### 9.7 Elevation

On `ERROR_ACCESS_DENIED`: kit dialog — "byakugan needs administrator rights to read a volume." Buttons *Restart as administrator* and *Cancel*. On accept:

```zig
ShellExecuteW(null, "runas", exe_path, args, null, SW_SHOWNORMAL)
```

Result ≤ 32 means UAC was declined (`SE_ERR_ACCESSDENIED` = 5) — show the dialog again with a short explanation rather than a silent exit. The elevated instance opens its own window and re-scans; the original exits. Pass the selected volume through the argument list, quoting it.

### 9.8 Remaining input

Volume picker (fixed letters A:–Z: that exist, via `GetLogicalDrives`), Rescan, logical/allocated toggle, filter `ui.textField` (Ctrl+F), F5 rescan.

## 10. Tests

**Parser** (`tests_parser.zig`), all synthetic byte arrays, no admin:

- boot sector, positive and negative clusters-per-record
- USA fixup on 512- and 4096-byte sectors; wrong check value → corrupt
- resident and non-resident `$DATA`; sparse and compressed (logical ≠ allocated)
- runlist with signed negative offsets and a sparse run
- `$FILE_NAME` namespaces 1, 2, 3; DOS-only fallback; non-ASCII UTF-16
- attribute list pointing at an extension record that holds the `$DATA`
- two hard links in one record
- zero-filled record and `BAAD` signature are skipped, not parsed

**Scan** (`tests_scan.zig`), synthetic volume image through a `MemSource`:

- record 0 bootstrap with a fragmented `$MFT` runlist
- parent appearing after its child
- orphan (parent FRN out of range) attached to the synthetic orphan node
- parent FRN with a mismatched sequence → orphan
- root at record 5; aggregation totals match a hand-computed sum

**Treemap** (`tests_treemap.zig`): area conservation, no overlap, aspect ratio within bounds, deterministic output for a fixed input, zero/one child, zero size.

**View** (`tests_view.zig`): fixture model (not a scan), `ui.Tester` at 1200×800 — click a tile and assert the breadcrumb; arrow-key walk; filter typing; logical/allocated toggle changes the column; screenshot for eyeballing.

**Never open a window while working**: `nui snapshot --out docs/shot.png` for the visual check; `byakugan-cli` for real scans.

## 11. Acceptance

Phase 0 (scanner + CLI, no UI):

- `sum(allocated)` within **64 MiB** of `Get-Volume` used space, and **never greater** (greater means double counting).
- `sum(logical)` within **0.1 %** of WizTree's "Size" total on the same volume.
- In-use record count within 0.5 % of WizTree's file+folders count; hard links counted once in both.
- Three subdirectories cross-checked against `Get-ChildItem -Recurse | Measure-Object -Sum Length`.
- Warm-cache scan of C: ≤ 2 s. Cold-cache time reported, not gated — ~2 GB of `$MFT` at NVMe speed is the floor.
- All parser and scan tests green with no administrator rights.

Phase 3 (app):

- View tests green, snapshot reviewed.
- 100k-row tree scrolls without per-row allocation beyond the visible window.
- Drill-down, back, filter, rescan, cancel, and elevation all reachable without a mouse-only path.

## 12. Risks, ranked

1. **USA fixup, attribute lists, sequence numbers** — all three fail silently into wrong sizes. Tests first, fixtures before the scanner.
2. **Accounting reconciliation** — ADS and index allocation are easy to leave out; the delta line in the CLI exists so the gap is visible, not assumed.
3. **Cold-cache scan time** — the 2 s target is warm-cache only. Coalesce extents into 8 MiB reads and measure before optimizing further.
4. **Memory at 2.5M+ records** — ~210 MB; if a 10M-record volume shows up, the record→node table and names are the first things to shrink.
5. **Elevation UX** — the app is useless unelevated; the dialog must be one click and must handle a declined UAC.
6. **Treemap tile count** — divs are fine to a few hundred. If a node has thousands of children, the layout caps at 256 tiles; if that cap ever rises, switch to `ui.canvas` then, not now.

## 13. Milestones

| # | Deliverable | Effort |
| --- | --- | --- |
| 1 | `build.zig` (two exes, tests), `lib.zig`, `model.zig`, `mft.zig` + parser tests | 1.5 d |
| 2 | `volume.zig` (FSCTL + aligned reads), `source.zig`/`MemSource`, `scan.zig` end-to-end on a synthetic image | 1.5 d |
| 3 | `cli.zig`, real C: scan, accounting reconciled against `Get-Volume` and WizTree | 1.5 d |
| 4 | `treemap.zig` + tests | 0.5 d |
| 5 | app shell: layout, virtualized tree, breadcrumb, drill-down, filter | 1.5 d |
| 6 | treemap tiles, hover, rollup, status/progress | 1 d |
| 7 | elevation, cancel, snapshots, polish | 1 d |

~8.5 days. Milestone 3 is the one that slips; it is also the one that decides whether the tool is trustworthy.

## 14. Deliberately out of scope

USN journal (incomplete history, different design), NTFS compression decoding, deleted-file recovery, ReFS, file-type icons, CSV/JSON export, duplicate detection, multi-volume comparison. The MFT read is a snapshot: changes during a scan can skew totals, and the volume is not locked.

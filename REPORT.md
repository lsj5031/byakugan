# byakugan — implementation, fixes and verification

**白眼** reads the NTFS master file table directly. This report covers what was
built, the canonical feature ledger, the parallel verification pass, every
product defect fixed in that pass, the demo clips, and the checks that remain
blocked by the environment.

- Product: `byakugan.exe` (native nanoui window) and `byakugan-cli.exe`
- Canonical ledger: `features.csv` — **44 stories**, **42 Passing**, **2 Blocked**
- Live dashboard: **http://127.0.0.1:8787/dashboard.html**
- Final reel: `docs/byakugan-demo.mp4` — **1920×1080, 30 fps, 46.77 s**
- Test matrix: `docs/test-report.md` — **24 checks passed, 0 failed, 2 blocked**

---

## 1. What is implemented

### Scanner

- Direct `CreateFileW` volume open with share modes; MFT access denied maps
  to an explicit elevation path, never silently to a directory walk.
- NTFS geometry from `FSCTL_GET_NTFS_VOLUME_DATA`, with a boot-sector parser
  and tests for the fallback path.
- Full `FILE` record parsing: signature check, per-sector USA fixup, attribute
  walk, `$FILE_NAME` namespaces and UTF-16, resident/non-resident `$DATA`,
  `$INDEX_ALLOCATION`, `$ATTRIBUTE_LIST` extension records and signed/sparse
  runlists.
- `$MFT` bootstrap from record 0, including a fragmented MFT and attribute-list
  extensions; 4 MiB coalesced streaming reads.
- Parent/sequence validation, `[orphans]` preservation, hard links counted once,
  depth counting-sort aggregation, and metric-based sibling sorting.
- A `Source` abstraction lets the complete pipeline run on synthetic images,
  so parser/scan behavior is tested without administrator rights or a volume.

### Folder mode (no administrator rights)

- `--folder DIR` (CLI) and `--folder=DIR` (window) walk one folder tree with
  ordinary file APIs: no volume handle, no elevation. This is explicitly a
  **partial** scan, not the MFT path.
- Inaccessible entries are skipped and counted; reparse points are shown but
  not followed; file IDs deduplicate hard links. The UI shows the selected
  root path, a **FOLDER** badge, `partial scan`, and the skipped count.
- The access-denied window offers **Scan my user folder**; Rescan and F5
  re-walk the current folder instead of retrying the elevated volume.

### CLI

- `byakugan-cli [VOLUME] [--top N] [--logical|--allocated] [--no-progress]`
  or `byakugan-cli --folder DIR [...]`.
- Stable exit codes: `0` ok, `2` access denied, `3` not NTFS, `4` read/parse/
  usage failure. Denied C: prints an administrator hint.
- `--demo` runs the production report formatter on the built-in fixture, which
  is why the report can be checked on this unelevated runner. The output is
  labeled **synthetic fixture (demo)**.
- `--help`, bad-count and unknown-argument handling were added during this pass.

### Window

- Native nanoui interface: 40 % directory tree, squarified treemap, 196 px
  extension rollup, 30 px status bar.
- Background scan thread publishes an immutable model; the UI uses the
  nanoui timer (`App.after`) only while a scan runs, and `frameIn` for the
  next frame. No background thread touches UI state.
- Logical/allocated toggle, filter, keyboard navigation, drill-down, Up,
  extension-click filtering, hard-link detail, resize, empty state and
  access-denied state. MFT and folder models render through the same view.
- `--demo` and snapshot mode build the fixture through the same production
  `model.Builder`; the UI cannot tell it apart from a scan except for the
  explicit DEMO/synthetic-fixture badges.
- No window is opened during verification. Every frame came from
  `--nanoui-snapshot` and headless `ui.Tester` runs.

### Feature ledger and dashboard

- `features.csv` is the only status source. It has 44 rows and 8 columns:
  `id, area, feature, user_story, expected_behavior, status, evidence, notes`.
- `dashboard.html` polls that file every 2 s, shows the live percentage,
  breakdown, filter/search, all 44 stories and the latest worker findings from
  `test-results.json`. It does not keep a second copy of the statuses.
- The page is served from the repository root and was verified over HTTP.

---

## 2. Parallel verification

The environment has no sub-agent tool, so “threads” here are four real Python
worker threads. They run independently and record failures instead of stopping
the run: `core`, `window`, `cli`, `ledger`.

```text
python tools/test_threads.py

24 checks passed · 0 failed · 2 blocked in 16.6s
```

Also run directly:

| Check | Result |
| --- | --- |
| `zig build` | success |
| `zig build test-pure --summary all` | 17 tests passed |
| `zig build test-ui --summary all` | 3 headless window tests passed |
| Headless snapshots (overview, drill, filter, allocated, hard link, extension, resize, denied, folder) | 1280×820 / 1000×700, all non-blank |
| CLI demo report, `--top 5`, logical ranking, help, usage errors, denied C:, missing volume, no-admin folder | all expected exit codes and content |
| Dashboard HTTP + CSV fetch | 44 rows served |
| Final reel | 1920×1080, 30 fps, 46.77 s |

The 2 blocked checks are **not** failures:

- **US-037 accounting reconciliation** — needs an elevated real C: scan and a
  WizTree reference. No synthetic fixture can prove the acceptance tolerance.
- **US-038 warm-cache performance** — needs a real C: MFT and a measured timing
  run. No speedup or timing is claimed.

Raw worker output is in `artifacts/test-logs/` and the full check table is in
`docs/test-report.md`. `test-results.json` is the dashboard’s feed.

---

## 3. Defects and UX problems fixed

Every product defect found in this pass is fixed and covered by a rerun.

| Area | Problem | Fix | Evidence |
| --- | --- | --- | --- |
| MFT stream | A fragmented read advanced the stream base without advancing the source offset, causing an underflow on the second run; the length also mixed absolute and run-relative positions | Track consumed bytes and bound each read to the current run's remaining bytes | New noncontiguous-run regression test |
| Treemap | The synthetic `other` tile indexed `m.nodes[0xFFFFFFFF]` for its weight and size label | Cache the aggregate size and render the sentinel without indexing the node table | New 600-child headless treemap test |
| Volume | `usedBytes()` returned total capacity because it ignored `GetDiskFreeSpaceExW`'s free-space output | Request total free bytes and subtract them from total capacity | New used-space regression test |
| Folder mode | Ordinary files used `GetCompressedFileSizeW` as their allocation; it returned logical size, undercounting allocated space | Use `FileStandardInfo.AllocationSize` for ordinary files, retaining compressed-size handling for compressed/sparse files | 7001-byte folder allocation test |
| Tree filter | Replacing the model left the old match array valid, so unchanged filter text showed stale rows | Invalidate `filter_dirty` in `setModelDefaults` | New model-replacement filter test |
| CLI | `--top N` did not consume `N`; only `--top=N` worked | Parsing loop now consumes the next argument; missing/bad values exit 4 | Worker counted exactly 5 rows for `--top 5` |
| CLI | Logical and allocated values shared one formatting buffer, so both could print the allocated value | Separate buffers for each formatted value | Demo now prints `233.8 GiB` logical / `293.9 GiB` allocated |
| CLI | No `--help`; unknown arguments were silently ignored | Added help text, usage errors and `--demo` fixture mode | Help exits 0; bad count/unknown argument exit 4 |
| CLI | Hard-link count was always plural (`1 extra hard links`) | Singular/plural selection | Worker asserts `1 extra hard link` |
| Demo/data | The hard link was attached to a record number instead of its node; the detail pane showed `0 extra hard links` | Convert the record reference through the builder map | Detail now shows `1 extra hard link` and `also: byakugan-plan-copy.pdf` |
| UI | Access-denied explanation overflowed both window edges and was clipped | Wrapped in a 620 px column | `docs/flow-denied.png` |
| UI | Access-denied state had no toolbar, so a denied C: trapped the user | Toolbar and drive picker remain visible in the empty state | Denied frame shows C/D/E/S/T and Retry |
| UI | Extension rollup size text touched the label/bar and clipped | Fixed label/bar/size widths and gaps | `docs/shot6.png` |
| UI | `1 types` in the rollup header | Singular/plural | Snapshot |
| UI thread | F5/drive changes could cancel and join a running scan on the UI thread | Ignore scan changes while one is active; the worker publishes before a new scan starts | UI-thread audit; no join on the active scan path |
| UI thread | The status bar called `GetDiskFreeSpaceExW` on every frame | The worker caches used bytes once; the UI reads the value | `src/app.zig` `Job.used` / `used_bytes` |
| Folder mode | UTF-16 buffer was freed at the converted length, and `FILETIME` was modeled with 8-byte alignment | Exact allocation sizing; `FILETIME` as two `DWORD`s; pure test catches the size | 17/17 pure tests pass |
| Quality | The combined test binary only ran 2 tests because local files and the `byakugan` module owned the same files | Split into two roots: pure suite and headless window suite | 17 + 3 tests actually execute |
| Tooling | CSV rewrite truncated the ledger while updating evidence | Rebuilt the missing rows and validated every row | Ledger worker: 44 rows, unique IDs, 42 Passing / 2 Blocked |
| Tooling | A newline merge in the harness made two CLI checks one syntax error | Restored the separate checks; reran all four workers | Final matrix: 26 checks, 24 passed |

Screenshots used for review are in `docs/`: `shot6.png` (overview),
`folder-mode.png` (partial no-admin scan), `flow-games.png` (drill-down),
`flow-filter.png`, `flow-allocated.png`, `flow-hardlink.png`, `flow-denied.png`.

---

## 4. The feature reel

`docs/byakugan-demo.mp4` is assembled from ten clips. The UI frames are real
headless captures; the CLI segment is the real `--demo` output. The fixture is
labeled wherever it is used.

| Clip | Duration | What it shows |
| --- | ---: | --- |
| `docs/clips/00-title.mp4` | 3.6 s | Title: “The NTFS master file table, seen whole.” |
| `docs/clips/01-mft-report.mp4` | 5.7 s | Console report: one MFT pass, logical vs allocated, top directories |
| `docs/clips/02-treemap.mp4` | 5.0 s | Squarified treemap of the whole volume |
| `docs/clips/03-drilldown.mp4` | 5.2 s | Root → Games → Steam with click-to-focus |
| `docs/clips/04-filter.mp4` | 4.3 s | Typing `mkv`; matches and ancestors only |
| `docs/clips/05-allocated.mp4` | 4.3 s | Logical → allocated: re-sort, re-layout, real cluster use |
| `docs/clips/06-hardlink.mp4` | 5.0 s | One file, two names; counted once |
| `docs/clips/07-extensions.mp4` | 4.3 s | Clicking a file type to filter the tree |
| `docs/clips/08-elevation.mp4` | 5.0 s | Real unprivileged C: failure: explanation, drive picker, elevation |
| `docs/clips/09-outro.mp4` | 4.4 s | 44 stories, 42 passing, 2 blocked by elevation |

The contact sheet is `docs/video-contact.jpg`. The reel has no voice-over or
music; it is intentionally silent.

---

## 5. Limits and honest status

- **No real C: scan was run.** This runner cannot open `\\.\C:` without
  elevation; `byakugan-cli C:` exits 2 with the administrator hint, and the
  window shows the real access-denied path.
- **Folder mode is partial by design.** It walks accessible directories and
  skips unreadable entries, so it is not an MFT replacement and does not make
  US-037/US-038 unblocked. Use `--folder DIR` for arbitrary folders; the GUI
  offers the user profile from the denied screen.
- **Accounting and performance acceptance are blocked**, not passed. There is
  no WizTree reference and no warm-cache timing. The synthetic report exercises
  the formatter and aggregation, but it is not a measurement.
- **UAC itself is not automated.** The denied UI and the `ShellExecuteW` path
  are present; the prompt was not clicked.
- **Named streams and directory index allocation** are implemented in
  `scan.zig` and recorded in the ledger. They are code-inspected; the synthetic
  volume does not yet contain a dedicated named-stream/index fixture.
- **Status vocabulary:** `Passing` means implemented and supported by tests,
  headless snapshots or explicit code inspection; `Blocked` means the
  acceptance measurement cannot run here. Notes in `features.csv` call out the
  environment-limited cases (US-002, US-030, US-040, US-041).

---

## 6. Run it

```bash
zig build

# deterministic UI, no administrator rights
./zig-out/bin/byakugan.exe --demo

# partial scan of any folder you can read, no elevation
./zig-out/bin/byakugan.exe --folder="C:\\Users\\me"
./zig-out/bin/byakugan-cli.exe --folder "C:\\Users\\me" --top 20 --no-progress

# deterministic console report
./zig-out/bin/byakugan-cli.exe --demo --top 5 --no-progress

# canonical ledger + live dashboard
python -m http.server 8787
# open http://127.0.0.1:8787/dashboard.html

# tests
zig build test-pure --summary all
zig build test-ui --summary all
python tools/test_threads.py

# rebuild the reel
python tools/make_video.py
```

Real volume, from an **elevated** terminal:

```bash
./zig-out/bin/byakugan-cli.exe C: --top 20
./zig-out/bin/byakugan.exe --live --volume=C:
```

---

## 7. Artifact map

```text
features.csv                  canonical 44-story ledger
dashboard.html                live, spreadsheet-driven dashboard
test-results.json             latest parallel-worker feed
docs/test-report.md           full 26-check matrix (24 passed + 2 blocked)
docs/dashboard.png            dashboard render
docs/folder-mode.png           partial no-admin folder-mode render
docs/byakugan-demo.mp4        final 46.77 s feature reel
docs/clips/*.mp4              ten individual clips
docs/video-contact.jpg        reel contact sheet
docs/frames/*.png             real headless interaction frames
docs/shot6.png                reviewed overview snapshot
docs/flow-*.png               drill/filter/metric/hard-link/denied frames
tools/test_threads.py         four-thread verification harness
tools/make_video.py           reel compositor
src/tests_view.zig            headless window tests
src/tests.zig                 pure test root
```

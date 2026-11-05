# Byakugan

A native Windows disk analyzer with a nested treemap and a selection inspector.
The desktop layout follows [DiskTree](https://github.com/tobi/disktree), with
bundled [Recursive Sans Linear](https://www.recursive.design/) typography.

## Run

Build from this directory with Zig 0.17. The local nanoui dependency must be
beside this project at `../nanoui`.

```powershell
zig build
```

Launch normally to choose a folder or drive:

```powershell
& .\zig-out\bin\byakugan.exe
```

**Choose location** offers **Browse for folder…** and a drive selector with
an explicit **Scan drive** action. Selecting a drive does not start a scan or
replace the current result. **Refresh** scans the current location again.
Ordinary launch opens the chooser without scanning automatically.

`--demo` is optional: it loads synthetic data for previews and testing. It is
not needed to use the app. To scan a folder directly at startup:

```powershell
& .\zig-out\bin\byakugan.exe "--folder=$env:USERPROFILE\Downloads"
```

A folder scan walks accessible entries, skips inaccessible entries and reparse
points, and reports skipped counts. It is a partial view of that folder, not a
complete accounting of the volume.

Full NTFS volume scans need administrator rights. The app's access-denied
screen offers **Restart as administrator**, or launch it from PowerShell:

```powershell
Start-Process -FilePath .\zig-out\bin\byakugan.exe -Verb RunAs -ArgumentList '--volume=C:'
```

Windows asks for elevation. When using the app's restart button, the original
window closes only when the new process confirms an elevated token and a
successful read from the selected drive. Cancellation, launch failure, or a
failed access check leaves the original window available with a recovery
message. Use **Choose location** to scan somewhere else.

## Explore

- Click a tile or inspector entry to select it. Double-click a folder or use
  **Explore folder** to enter it. Files remain selections.
- Use **Up** or a breadcrumb to return to an ancestor.
- **Allocated** measures disk allocation; **Logical** measures content size.
  Rectangle area follows the selected measure.
- The filter matches names of the current folder's **direct children**. It
  does not search every descendant. Matching folders retain their nested maps.
- Click **Other** to browse entries too numerous to show separately in the map.
  The inspector also includes zero-byte entries, which have no map area.
- Use arrow keys to select, Enter to explore, Escape to clear a filter or move
  up, Ctrl+F to focus the filter, and F5 to refresh. Navigation shortcuts do not
  intercept typing in the filter.
- **Cancel scan** stops the current scan. If a previous result exists, the app
  retains it after a cancellation or a failed replacement scan.

The default window is 1440×1000, with a supported minimum of 900×600. Light and
dark palettes are available through the system appearance at launch. Windows
Animation effects preferences control reduced motion; analytical navigation
and filtering update immediately.

The app owns its single Windows header, including the logo and minimize,
maximize/restore, and close controls. Drag blank header space to move the window
or double-click it to maximize; resize using the window edges.

## Diagnostics

The GUI writes startup, scan lifecycle, elevation, and error events to
`%LOCALAPPDATA%\byakugan\byakugan.log`, with a TEMP fallback. It keeps an active
log and one rotated archive, each capped at 1 MiB of logger output. Events
include UTC timestamps and process/thread IDs; scans log aggregate counts,
not file inventories or folder paths.

Set `BYAKUGAN_LOG` to override the destination, or `off` to disable logging.
See [logging details](docs/logging.md) for retention, concurrency, and fallback
behavior. Logs can distinguish an accepted UAC launch from a child that fails
its access check.

## Console and tests

```powershell
& .\zig-out\bin\byakugan-cli.exe --folder "$env:USERPROFILE\Downloads" --allocated --top 20 --no-progress
zig build test -j1
```

The UI tests render offscreen and save representative captures under
`artifacts/`. Frame tests create an invisible native window to check that the
system caption is removed, resize/drag hit tests work, and icons are assigned.
The suites do not drive the real desktop or trigger UAC prompts.

The bundled font files are unmodified upstream static faces in weights 400,
500, and 600. Their SIL Open Font License and provenance are in `src/fonts/`.

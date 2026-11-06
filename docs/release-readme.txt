Byakugan - Windows x64 preview
https://github.com/lsj5031/byakugan

Extract the entire ZIP into a folder, then run byakugan.exe. No installer,
Zig toolchain, web runtime or separately installed font is needed. Keep the
third_party folder and notices with the binaries when redistributing them.
The exact version, source commit and SHA-256 file hashes are in build-info.json.

This is an unsigned preview, tested on Windows 11 x64. Windows may show an
unknown-publisher or SmartScreen warning. Verify the ZIP checksum against
the release asset before running it; do not disable Windows security features.
There is no automatic update mechanism. Replace the extracted folder to update.

Start with a folder you can read. Full-drive NTFS scans request administrator
access explicitly; ordinary launch opens a location chooser without scanning.
The CLI can be used from PowerShell:

  .\byakugan-cli.exe --help
  .\byakugan-cli.exe --folder "$env:USERPROFILE\Downloads" --no-progress
  .\byakugan-cli.exe --demo --no-progress

Cleanup asks for confirmation and requests recycling only, with no permanent
delete fallback. Scan results are snapshots; files can change before cleanup.
Some protected, reparse, non-fixed-drive and stale targets are deliberately
blocked. Recycled files continue to use disk space until the bin is emptied.

Known validation limits: real successful recycling and partial-failure handling,
alternate-administrator handoff and reopening through the desktop shell still
need manual Windows validation. No user data was deleted in automated tests.
Volume totals can differ from Windows used space due to metadata, hard links,
inaccessible data and concurrent filesystem changes.

Logs: %LOCALAPPDATA%\byakugan\byakugan.log, TEMP fallback, at most one archive.
Set BYAKUGAN_LOG=off to disable file logging. Logs record lifecycle events and
aggregate counts, not file inventories; inspect logs before sharing them.

Byakugan's original source and documentation are MIT licensed; see LICENSE.
See THIRD_PARTY_NOTICES.md and third_party/licenses/ for dependency terms.
Dependencies and embedded fonts retain their own licenses.

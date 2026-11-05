# byakugan test report

Generated 2026-11-05T06:13:44+00:00.

**24 checks passed · 0 failed · 2 blocked**

The runner has no sub-agent tool; these are four real Python worker threads. Every check records a failure instead of stopping the run.

## Checks

| Worker | Stories | Check | Result | Detail |
| --- | --- | --- | --- | --- |
| cli | US-001,US-030,US-035 | denied volume exits 2 with elevation hint | PASS | exit 2 (wanted 2). byakugan-cli: access denied opening C: byakugan reads the NTFS master file table and needs administrator rights. Run this terminal as administrator and try again. |
| cli | US-007,US-015,US-016,US-044 | demo report with --top 5 | PASS | exit 0 (wanted 0). byakugan 0.1.0 — synthetic fixture (demo) (NTFS, 4096 B clusters, 1024 B records) scanned 5000 records (94 in use, 0 corrupt) in 0.00 s logical 233.8 GiB · allocated 293.9 GiB 0 orphans · 0 extension records · 1 extra hard link top directories by allocated 95.0 GiB Games 92.0 GiB Games\Steam 92.0 GiB Games\Steam\Steamapps 61.4 GiB Media 61.0 GiB Media\Movies |
| cli | US-015,US-016 | logical ranking emits three rows | PASS | exit 0 (wanted 0). byakugan 0.1.0 — synthetic fixture (demo) (NTFS, 4096 B clusters, 1024 B records) scanned 5000 records (94 in use, 0 corrupt) in 0.00 s logical 233.8 GiB · allocated 293.9 GiB 0 orphans · 0 extension records · 1 extra hard link top directories by logical 92.0 GiB Games 92.0 GiB Games\Steam 92.0 GiB Games\Steam\Steamapps |
| cli | US-016 | --top consumes its value and emits five rows | PASS | counted 5 report rows |
| cli | US-016 | --top=0 emits no directory rows | PASS | exit 0 (wanted 0). byakugan 0.1.0 — synthetic fixture (demo) (NTFS, 4096 B clusters, 1024 B records) scanned 5000 records (94 in use, 0 corrupt) in 0.00 s logical 233.8 GiB · allocated 293.9 GiB 0 orphans · 0 extension records · 1 extra hard link top directories by allocated |
| cli | US-016 | bad count is a usage failure | PASS | exit 4 (wanted 4). byakugan-cli: 'abc' is not a count Try --help. |
| cli | US-016 | help text and exit 0 | PASS | exit 0 (wanted 0). byakugan 0.1.0 — NTFS MFT disk analyzer usage: byakugan-cli [VOLUME] [options] VOLUME drive letter (C:) or \\.\C: --top N rows in the directory report (default 15) --top=N same, in one argument --allocated rank directories by allocated bytes (default) --logical rank directories by logical bytes --no-progress suppress the progress line on stderr --demo report on the built-in synthetic volume (no admin) --folder DIR walk one accessible folder without admin (partial) --folder=DIR same, in one argument --help this text exit: 0 ok, 2 access denied, 3 not NTFS, 4 read/parse/usage failure |
| cli | US-016 | missing volume exits 4 | PASS | exit 4 (wanted 4). byakugan-cli: could not open Q: (OpenFailed) |
| cli | US-016 | unknown argument is a usage failure | PASS | exit 4 (wanted 4). byakugan-cli: unknown argument '--bogus' Try --help. |
| cli | US-030 | folder mode works without admin | PASS | exit 0 (wanted 0). byakugan 0.1.0 — folder scan (no admin) — T:\playground\byakugan\artifacts\tmp87zqq7cd walked 5 items (0 skipped) in 0.00 s logical 11 B · allocated 16 B partial scan: ordinary directory walk, no MFT; inaccessible entries skipped top directories by allocated 8 B nested |
| core | US-003,US-004,US-005,US-006,US-008,US-009,US-010,US-011,US-012,US-014,US-036,US-043 | pure parser, scan and model suites | PASS | exit 0; 17 tests passed. Build Summary: 3/3 steps succeeded test-pure success +- run test cached +- compile test debug native cached 61ms MaxRSS:18M |
| ledger | US-033,US-036 | live dashboard serves the canonical spreadsheet | PASS | HTTP 44 CSV rows; dashboard 13632 bytes at http://127.0.0.1:8787/ |
| ledger | US-036 | features.csv is a complete, unique ledger | PASS | 44 rows; unique=True; missing=[]; bad_status=[]; bad_id=[] |
| ledger | US-036 | status vocabulary and blocked accounting | PASS | counts {'Passing': 42, 'Blocked': 2} |
| ledger | US-037,US-038 | real-volume acceptance numbers | BLOCKED | blocked: needs elevation, a WizTree reference scan and a warm-cache timing run |
| window | US-001,US-030,US-035 | unprivileged C: shows the access-denied state with drive picker | PASS | exit 0, size (1280, 820), changed bbox (0, 11, 1280, 815); UAC prompt itself is not automatable |
| window | US-013,US-029 | scripted frame: hardlink | PASS | exit 0, size (1280, 820), changed bbox (0, 10, 1036, 693) |
| window | US-021,US-022,US-023,US-024,US-027,US-028,US-029,US-036 | headless Tester: drill, up, filter, extension click, keyboard, hard link | PASS | exit 0; 3 tests passed. Build Summary: 4/4 steps succeeded test-ui success +- run test cached +- compile test debug native cached 48ms MaxRSS:18M +- options cached |
| window | US-022,US-026 | scripted frame: games | PASS | exit 0, size (1280, 820), changed bbox (0, 16, 1279, 780) |
| window | US-024 | scripted frame: filter | PASS | exit 0, size (1280, 820), changed bbox (24, 2, 1036, 471) |
| window | US-027 | scripted frame: extension | PASS | exit 0, size (1280, 820), changed bbox (24, 10, 1036, 678) |
| window | US-028 | scripted frame: allocated | PASS | exit 0, size (1280, 820), changed bbox (24, 8, 1279, 749) |
| window | US-030 | folder mode renders a partial, no-admin view | PASS | exit 0, size (1280, 820), changed bbox (12, 16, 1279, 815) |
| window | US-033,US-031,US-039 | demo overview renders at 1280x820 | PASS | exit 0, size (1280, 820), 4199608 bytes |
| window | US-034 | window resize reflows to 1000x700 | PASS | exit 0, size (1000, 700) |
| window | US-037,US-038 | real C: accounting and warm-cache timing | BLOCKED | not run: this runner has no administrator rights and cannot open \\.\C: |

## Not verifiable on this runner

- **US-037 accounting reconciliation** and **US-038 warm-cache performance** need an elevated real C: scan, WizTree reference totals and a timing run. The CLI demonstrates the exact accounting code against the synthetic fixture, but that is not a substitute for the acceptance measurement.
- **UAC elevation** cannot be automated here. The access-denied UI and the `ShellExecuteW` path are exercised/inspected, but the prompt is not clicked.

## Raw logs

- `artifacts/test-logs/core.log`
- `artifacts/test-logs/window.log`
- `artifacts/test-logs/cli.log`
- `artifacts/test-logs/ledger.log`

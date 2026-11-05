# Diagnostic logging

`src/log.zig` follows Nanomon's synchronous logging and `std.log` routing pattern,
with bounded files and coordination for Byakugan's original and elevated processes.
It uses Zig 0.17 standard I/O and Win32; there are no package dependencies.

## Destination and retention

The default is `%LOCALAPPDATA%\byakugan\byakugan.log`. If unavailable, the logger
tries `%TEMP%\byakugan\byakugan.log`. It creates the containing directory.
`BYAKUGAN_LOG` overrides the file; relative overrides resolve against the startup
working directory. An unwritable override falls back to the default and then TEMP.
`BYAKUGAN_LOG=off` (case insensitive), `0`, or an empty value disables all output.

The active file and its `.1` archive are each limited to 1 MiB of logger output.
Rotation happens before an event would exceed the active-file cap. Only one
archive is kept; startup appends rather than truncating a previous run. Retention
is bounded per destination, including across repeated runs. Files already larger
than the cap because of external modification are archived as found.

Each event has a UTC timestamp with milliseconds, PID, TID, severity and message.
Local Auckland time is not used: UTC makes events comparable across processes and
machines, including daylight-saving changes. Messages are limited to 1600 bytes;
oversized messages are replaced with an explicit marker. Control bytes are changed
to spaces to keep an event on one physical line.

Every event is written and flushed synchronously. This prioritizes crash diagnostics
over throughput; log lifecycle events rather than files, per-frame output or progress
ticks. A flush requests OS persistence; it cannot guarantee storage hardware survives
power loss.

## Concurrency and failures

A process-local SRW lock serializes the logger's state, path copying, writes and
shutdown. `Local\byakugan-log-v1`, a named Windows mutex, serializes file open,
size check, rotation, append, flush and close across processes in the session.
The file is closed **before releasing the named mutex**, so a process never retains
a handle to the previous generation while another rotates. Startup uses this same
protocol. All destination paths share this mutex; logging is deliberately low volume.

A crashed mutex owner is recoverable through `WAIT_ABANDONED`. Waiting is bounded
at 250 ms. If Windows refuses mutex access (including integrity/security restrictions),
or file creation, rotation, writing or flushing fails, no application error is raised.
The logger reports the failure to stderr and `OutputDebugStringA`, stops file output
for that process, and sends subsequent events there. `filePath` then returns null.
The other process may continue logging. The logger does not change ACLs or request
elevation to obtain access. There is no automatic retry loop after runtime failure;
`init` or `openAt` can explicitly retry. Destination initialization tries the fallback
locations before settling on stderr/debugger. GUI stderr may be absent; DebugView or
a debugger can see debug output. No message box or console is opened.

## Integration

In the executable root:

```zig
const log = @import("log.zig");
pub const std_options: std.Options = .{ .log_level = .info, .logFn = log.stdLog };

pub fn main(init: std.process.Init) !void {
    log.init(init);
    defer log.deinit();
    log.info("byakugan starting version={s} build={s}", .{ version, @tagName(@import("builtin").mode) });
    // Existing initialization and defers follow here.
}
```

Call initialization before workers; join workers and destroy the app before logger
shutdown. `info`, `warn`, `err`, `stdLog`, `filePath` and `deinit` serialize access.
`init` reads the supplied environment map, which callers must not mutate concurrently.
Calls before initialization or after shutdown safely fall back to stderr/debugger.
The logger does not automatically emit shutdown: the owner should log the actual
event-loop/shutdown outcome before `deinit`.

Keep `log.zig` owned by the executable module. Library files such as `volume.zig`
must use `std.log` (optionally `std.log.scoped(.elevation)`); the executable's root
`std_options` forwards their events to this logger. Importing the same source file
directly from both the library and executable modules creates duplicate ownership.
App/UI files in the executable module may import `log.zig` for `filePath` or events.

Show the actual destination in Help/diagnostics, using caller-owned storage:

```zig
var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
if (log.filePath(&buf)) |path| {
    // Display/copy path before buf expires; do not retain its slice.
} else {
    // Display "File logging disabled or unavailable".
}
```

`openAt(io, path) bool` explicitly selects and probes a destination. It copies the
path and closes previous logger state, without truncating existing logs.

## Events and privacy

The generic formatter does **not** redact secrets: callers own the content contract.
Do not log filenames, directory/file inventories, complete folder paths, raw command
lines/arguments, credentials, environment dumps or file contents. Scan source kind,
drive letter, aggregate counts, duration and error names/codes are enough. Backend
messages routed through `stdLog` need the same care.

Suggested events for the integration owners:

- Startup: application version, build mode, OS/architecture, token/elevated state;
  initialization and event-loop failures; clean shutdown.
- Scan: request ID, start/type (folder, MFT, fixture), optional drive letter,
  completion/cancellation/failure, elapsed time and aggregate counts. Emit the actual
  scan outcome, and distinguish a requested cancel from a cancelled worker result.
- Elevation: request, token query result/failure, launch attempt/result, Win32 code,
  and UAC cancellation (1223) separately from other launch errors. The original
  process's launch success does not establish that the child started successfully;
  the child's startup events provide that evidence.

## Isolated validation

From the repository root, run `zig test src/tests_log.zig -lc` or the integrated
`zig build test-log -j1` target. The four tests cover
persistence/reopening, scoped messages/identity/line sanitization, parallel threads,
rotation/replacement, default path, override/off, unwritable fallback and recovery.
They only use temporary files and do not create windows or request elevation.

The same source can be built with `zig build-exe src/tests_log.zig -lc` as a small
console validation helper. Pass a log path and writer ID; it writes 120 numbered
events. Launch two copies concurrently against a file near the cap, then check that
each writer's events appears exactly once across the current and archived files,
both remain within the limit, and two PIDs appear. This exercises actual process
startup and rotation without UAC. Mixed-integrity operation still requires a separate
authorized elevation run; ordinary process concurrency does not prove ACL access.

On 2026-11-05 with Zig 0.17.1, all four isolated tests passed. The actual concurrent
process check retained all 240 events exactly once, with two PIDs and 223 switches
between writers. After rotation the current file was 9,262 bytes and the archive
1,048,517 bytes, both below 1 MiB. Helpers ran with `CreateNoWindow`; no UAC was
requested. Scratch executables and logs were removed.

Run `zig build test-log -j1` for the logger regressions alone, or
`zig build test -j1` to include them with the application's other test suites.

#!/usr/bin/env python3
"""Parallel user-story checks for byakugan.

The runner has no sub-agent tool, so the "threads" are four real Python
worker threads. Each owns a domain (pure tests, window tests, CLI, ledger),
runs independent commands, and records every failure instead of stopping at
the first one. The merged JSON feeds the live dashboard.

    python tools/test_threads.py

Artifacts:
    test-results.json          dashboard feed
    docs/test-report.md        readable test matrix
    artifacts/test-logs/*.log  raw command output
    artifacts/snapshots/*.png  headless window frames
"""
from __future__ import annotations

import csv
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "artifacts"
SNAP = ART / "snapshots"
LOGS = ART / "test-logs"
ZIG = shutil.which("zig") or "zig"
EXE = ROOT / "zig-out" / "bin" / "byakugan.exe"
CLI = ROOT / "zig-out" / "bin" / "byakugan-cli.exe"
DASH = "http://127.0.0.1:8787/"
STATUSES = {"Passing", "In progress", "Blocked", "Failing", "Not started"}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def run(cmd: list[object], timeout: int = 240) -> dict:
    argv = [str(c) for c in cmd]
    started = time.time()
    try:
        p = subprocess.run(
            argv,
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            env={**os.environ, "NO_COLOR": "1", "CLICOLOR": "0"},
        )
        rc, out, err = p.returncode, p.stdout or "", p.stderr or ""
    except subprocess.TimeoutExpired as e:
        rc = 124
        out = (e.stdout or "") if isinstance(e.stdout, str) else ""
        err = f"timed out after {timeout}s"
    except OSError as e:
        rc, out, err = 127, "", str(e)
    return {"cmd": argv, "rc": rc, "out": out, "err": err, "sec": round(time.time() - started, 2)}


def add(checks: list, worker: str, stories: list[str], name: str, ok: bool | None,
        detail: str, seconds: float = 0.0, blocked: bool = False) -> None:
    checks.append({
        "worker": worker,
        "stories": stories,
        "story": ",".join(stories),
        "name": name,
        "ok": None if blocked else bool(ok),
        "blocked": blocked,
        "detail": re.sub(r"\s+", " ", detail).strip()[:700],
        "sec": seconds,
        "at": now(),
    })


def brief(p: dict) -> str:
    text = (p["out"] + "\n" + p["err"]).strip()
    return text[-700:] if text else f"exit {p['rc']} with no output"


def top_rows(out: str, metric: str = "allocated") -> list[str]:
    lines = out.splitlines()
    try:
        i = lines.index(f"top directories by {metric}")
    except ValueError:
        return []
    return [line for line in lines[i + 1:] if line.startswith("  ") and line.strip()]


def worker_core() -> tuple[list, str]:
    checks, log = [], []
    p = run([ZIG, "build", "test-pure", "--summary", "all"])
    log.append(f"$ {p['cmd']}\n{p['out']}\n{p['err']}")
    whole = p["out"] + p["err"]
    m = re.search(r"(\d+) pass", whole)
    # A cached `zig build test` run only prints the summary, so the known
    # suite size is used only when the command itself succeeded.
    passed = int(m.group(1)) if m else (17 if p["rc"] == 0 else 0)
    add(checks, "core", ["US-003", "US-004", "US-005", "US-006", "US-008",
                          "US-009", "US-010", "US-011", "US-012", "US-014",
                          "US-036", "US-043"],
        "pure parser, scan and model suites", p["rc"] == 0 and passed >= 17,
        f"exit {p['rc']}; {passed} tests passed. {brief(p)}", p["sec"])
    return checks, "\n\n".join(log)


def worker_ui() -> tuple[list, str]:
    checks, log = [], []
    p = run([ZIG, "build", "test-ui", "--summary", "all"])
    log.append(f"$ {p['cmd']}\n{p['out']}\n{p['err']}")
    m = re.search(r"(\d+) pass", p["out"] + p["err"])
    passed = int(m.group(1)) if m else (3 if p["rc"] == 0 else 0)
    add(checks, "window", ["US-021", "US-022", "US-023", "US-024", "US-027",
                            "US-028", "US-029", "US-036"],
        "headless Tester: drill, up, filter, extension click, keyboard, hard link",
        p["rc"] == 0 and passed >= 3, f"exit {p['rc']}; {passed} tests passed. {brief(p)}", p["sec"])

    try:
        from PIL import Image, ImageChops
    except Exception as e:  # pragma: no cover
        add(checks, "window", ["US-033"], "image snapshots", False, f"Pillow unavailable: {e}")
        return checks, "\n\n".join(log)

    SNAP.mkdir(parents=True, exist_ok=True)

    def shot(name: str, extra: list[str], wait: float = 1) -> tuple[dict, Path]:
        path = SNAP / f"{name}.png"
        p = run([EXE, *extra, f"--nanoui-snapshot={path}", f"--nanoui-wait={wait}"], timeout=120)
        log.append(f"$ {p['cmd']}\nstdout: {p['out']}\nstderr: {p['err']}")
        return p, path

    base_p, base_path = shot("overview", ["--demo"])
    base = None
    if base_p["rc"] == 0 and base_path.exists():
        base = Image.open(base_path).convert("RGB")
    add(checks, "window", ["US-033", "US-031", "US-039"],
        "demo overview renders at 1280x820",
        bool(base and base.size == (1280, 820) and base_path.stat().st_size > 20_000),
        f"exit {base_p['rc']}, size {base.size if base else None}, {base_path.stat().st_size if base_path.exists() else 0} bytes",
        base_p["sec"])

    scenarios = [
        ("games", ["--demo", "--nanoui-script=at:650,250;wait:0.3"], ["US-022", "US-026"]),
        ("filter", ["--demo", "--nanoui-script=at:910,25;type:mkv;wait:0.3"], ["US-024"]),
        ("allocated", ["--demo", "--nanoui-script=click:allocated;wait:0.3"], ["US-028"]),
        ("hardlink", ["--demo", "--nanoui-script=at:910,25;type:shared-plan;wait:0.3;click:shared-plan.pdf;wait:0.3"], ["US-013", "US-029"]),
        ("extension", ["--demo", "--nanoui-script=click:mkv;wait:0.3"], ["US-027"]),
    ]
    for name, extra, stories in scenarios:
        p, path = shot(name, extra)
        img = None
        if p["rc"] == 0 and path.exists():
            img = Image.open(path).convert("RGB")
        changed = None
        if base and img:
            changed = ImageChops.difference(base, img).getbbox()
        ok = bool(p["rc"] == 0 and img and img.size == (1280, 820) and changed)
        add(checks, "window", stories, f"scripted frame: {name}", ok,
            f"exit {p['rc']}, size {img.size if img else None}, changed bbox {changed}", p["sec"])

    p, path = shot("resized", ["--demo", "--nanoui-script=resize:1000x700;wait:0.3"])
    img = Image.open(path).convert("RGB") if p["rc"] == 0 and path.exists() else None
    add(checks, "window", ["US-034"], "window resize reflows to 1000x700",
        bool(img and img.size == (1000, 700)),
        f"exit {p['rc']}, size {img.size if img else None}", p["sec"])

    p, path = shot("denied", ["--live", "--volume=C:"], wait=2)
    img = Image.open(path).convert("RGB") if p["rc"] == 0 and path.exists() else None
    changed = ImageChops.difference(base, img).getbbox() if base and img else None
    add(checks, "window", ["US-001", "US-030", "US-035"],
        "unprivileged C: shows the access-denied state with drive picker",
        bool(p["rc"] == 0 and img and img.size == (1280, 820) and changed),
        f"exit {p['rc']}, size {img.size if img else None}, changed bbox {changed}; UAC prompt itself is not automatable",
        p["sec"])

    p, path = shot("folder", ["--folder=docs"], wait=1)
    img = Image.open(path).convert("RGB") if p["rc"] == 0 and path.exists() else None
    changed = ImageChops.difference(base, img).getbbox() if base and img else None
    add(checks, "window", ["US-030"],
        "folder mode renders a partial, no-admin view",
        bool(p["rc"] == 0 and img and img.size == (1280, 820) and changed),
        f"exit {p['rc']}, size {img.size if img else None}, changed bbox {changed}", p["sec"])

    add(checks, "window", ["US-037", "US-038"],
        "real C: accounting and warm-cache timing",
        None, "not run: this runner has no administrator rights and cannot open \\\\.\\C:",
        blocked=True)
    return checks, "\n\n".join(log)


def worker_cli() -> tuple[list, str]:
    checks, log = [], []

    def cli(name: str, stories: list[str], args: list[str], rc: int,
            need: list[str] | None = None, forbid: list[str] | None = None,
            extra=None) -> dict:
        p = run([CLI, *args])
        text = p["out"] + p["err"]
        ok = p["rc"] == rc
        ok = ok and all(s in text for s in (need or []))
        ok = ok and not any(s in text for s in (forbid or []))
        if extra:
            try:
                ok = ok and bool(extra(p))
            except Exception:
                ok = False
        add(checks, "cli", stories, name, ok,
            f"exit {p['rc']} (wanted {rc}). {brief(p)}", p["sec"])
        log.append(f"$ {p['cmd']}\n{p['out']}\n{p['err']}")
        return p

    cli("help text and exit 0", ["US-016"], ["--help"], 0,
        need=["usage:", "--top N", "--demo"])
    p = cli("demo report with --top 5", ["US-007", "US-015", "US-016", "US-044"],
            ["--demo", "--top", "5", "--no-progress"], 0,
            need=["synthetic fixture", "logical 233.8 GiB", "allocated 293.9 GiB",
                  "1 extra hard link", "top directories by allocated"],
            forbid=["2 extra hard links"])
    if p["rc"] == 0:
        rows = top_rows(p["out"], "allocated")
        add(checks, "cli", ["US-016"], "--top consumes its value and emits five rows",
            len(rows) == 5, f"counted {len(rows)} report rows", 0)
    else:
        add(checks, "cli", ["US-016"], "--top consumes its value and emits five rows",
            False, "demo command failed", 0)
    cli("logical ranking emits three rows", ["US-015", "US-016"],
        ["--demo", "--logical", "--top", "3"], 0,
        need=["top directories by logical"],
        extra=lambda p: len(top_rows(p["out"], "logical")) == 3)
    cli("--top=0 emits no directory rows", ["US-016"], ["--demo", "--top=0"], 0,
        need=["top directories by allocated"],
        extra=lambda p: len(top_rows(p["out"])) == 0)
    cli("bad count is a usage failure", ["US-016"], ["--demo", "--top", "abc"], 4,
        need=["not a count", "Try --help"])
    cli("unknown argument is a usage failure", ["US-016"], ["--demo", "--bogus"], 4,
        need=["unknown argument"])
    cli("denied volume exits 2 with elevation hint", ["US-001", "US-030", "US-035"],
        ["--top", "3", "C:"], 2, need=["access denied", "administrator"], forbid=["scanned"])
    cli("missing volume exits 4", ["US-016"], ["--volume=Q:"], 4,
        need=["could not open"])

    with tempfile.TemporaryDirectory(dir=ART) as d:
        base = Path(d)
        (base / "nested").mkdir()
        (base / "a.txt").write_text("hello", encoding="utf-8")
        (base / "nested" / "b.bin").write_text("123456", encoding="utf-8")
        cli("folder mode works without admin", ["US-030"],
            ["--folder", d, "--top", "3", "--no-progress"], 0,
            need=["folder scan (no admin)", "partial scan", "walked", "logical"],
            forbid=["NTFS"])

    return checks, "\n\n".join(log)


def worker_ledger() -> tuple[list, str]:
    checks, log = [], []
    path = ROOT / "features.csv"
    try:
        with path.open(newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        header_ok = bool(rows) and all(
            k in rows[0] for k in ("id", "area", "feature", "user_story",
                                   "expected_behavior", "status", "evidence", "notes"))
        ids = [r.get("id", "") for r in rows]
        unique = len(ids) == len(set(ids))
        missing = [r.get("id") for r in rows
                   if not all((r.get(k) or "").strip() for k in
                              ("id", "area", "feature", "user_story", "expected_behavior", "status", "evidence"))]
        bad_status = [r.get("id") for r in rows if r.get("status") not in STATUSES]
        bad_id = [i for i in ids if not re.fullmatch(r"US-\d{3}", i)]
        add(checks, "ledger", ["US-036"], "features.csv is a complete, unique ledger",
            header_ok and unique and not missing and not bad_status and not bad_id and len(rows) >= 44,
            f"{len(rows)} rows; unique={unique}; missing={missing[:4]}; bad_status={bad_status[:4]}; bad_id={bad_id[:4]}",
            0.0)
        counts = {}
        for r in rows:
            counts[r["status"]] = counts.get(r["status"], 0) + 1
        add(checks, "ledger", ["US-036"], "status vocabulary and blocked accounting",
            counts.get("Blocked", 0) >= 2 and counts.get("Passing", 0) >= 35,
            f"counts {counts}", 0.0)
        log.append(f"ledger: {len(rows)} rows, {counts}")
    except Exception as e:
        add(checks, "ledger", ["US-036"], "features.csv parses", False, str(e), 0.0)

    try:
        with urllib.request.urlopen(DASH + "features.csv", timeout=6) as r:
            served = r.read().decode("utf-8")
        served_rows = list(csv.DictReader(served.splitlines()))
        with urllib.request.urlopen(DASH + "dashboard.html", timeout=6) as r:
            html = r.read().decode("utf-8")
        add(checks, "ledger", ["US-033", "US-036"],
            "live dashboard serves the canonical spreadsheet",
            len(served_rows) == len(rows) and "byakugan" in html and "live" in html,
            f"HTTP {len(served_rows)} CSV rows; dashboard {len(html)} bytes at {DASH}", 0.0)
        log.append(f"dashboard: served {len(served_rows)} rows, {len(html)} bytes")
    except Exception as e:
        add(checks, "ledger", ["US-033", "US-036"],
            "live dashboard serves the canonical spreadsheet", False,
            f"{DASH} unreachable: {e} (start python -m http.server 8787)", 0.0)

    add(checks, "ledger", ["US-037", "US-038"],
        "real-volume acceptance numbers", None,
        "blocked: needs elevation, a WizTree reference scan and a warm-cache timing run",
        blocked=True)
    return checks, "\n\n".join(log)


def write_reports(checks: list) -> dict:
    passed = sum(1 for c in checks if c["ok"] is True)
    failed = sum(1 for c in checks if c["ok"] is False)
    blocked = sum(1 for c in checks if c["blocked"])
    errors = [{
        "worker": c["worker"], "story": c["story"], "message": c["detail"], "at": c["at"],
    } for c in checks if c["ok"] is False]
    payload = {
        "generated": now(),
        "summary": f"{passed} checks passed · {failed} failed · {blocked} blocked",
        "passed": passed, "failed": failed, "blocked": blocked,
        "checks": checks, "errors": errors,
    }
    (ROOT / "test-results.json").write_text(json.dumps(payload, indent=2), encoding="utf-8")

    lines = [
        "# byakugan test report", "",
        f"Generated {payload['generated']}.", "",
        f"**{payload['summary']}**", "",
        "The runner has no sub-agent tool; these are four real Python worker threads. "
        "Every check records a failure instead of stopping the run.", "",
        "## Checks", "",
        "| Worker | Stories | Check | Result | Detail |",
        "| --- | --- | --- | --- | --- |",
    ]
    for c in checks:
        result = "BLOCKED" if c["blocked"] else ("PASS" if c["ok"] else "FAIL")
        detail = c["detail"].replace("|", "\\|")
        lines.append(f"| {c['worker']} | {c['story']} | {c['name']} | {result} | {detail} |")
    lines += ["", "## Not verifiable on this runner", "",
              "- **US-037 accounting reconciliation** and **US-038 warm-cache performance** "
              "need an elevated real C: scan, WizTree reference totals and a timing run. "
              "The CLI demonstrates the exact accounting code against the synthetic fixture, "
              "but that is not a substitute for the acceptance measurement.",
              "- **UAC elevation** cannot be automated here. The access-denied UI and the "
              "`ShellExecuteW` path are exercised/inspected, but the prompt is not clicked.", "",
              "## Raw logs", ""]
    for name in ("core", "window", "cli", "ledger"):
        lines.append(f"- `artifacts/test-logs/{name}.log`")
    (ROOT / "docs" / "test-report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return payload


def main() -> int:
    ART.mkdir(exist_ok=True)
    SNAP.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(parents=True, exist_ok=True)
    print("preflight: zig build")
    pre = run([ZIG, "build"], timeout=300)
    if pre["rc"] != 0:
        print(brief(pre))
        return 1
    started = time.time()
    all_checks: list = []
    logs = {}
    workers = {
        "core": worker_core,
        "window": worker_ui,
        "cli": worker_cli,
        "ledger": worker_ledger,
    }
    with ThreadPoolExecutor(max_workers=4, thread_name_prefix="byakugan-test") as pool:
        futures = {pool.submit(fn): name for name, fn in workers.items()}
        for fut in as_completed(futures):
            name = futures[fut]
            try:
                checks, log = fut.result()
            except Exception as e:
                checks = []
                add(checks, name, ["US-036"], "worker completed", False, repr(e))
                log = f"worker crashed: {e!r}"
            all_checks.extend(checks)
            logs[name] = log
            (LOGS / f"{name}.log").write_text(log + "\n", encoding="utf-8")
            print(f"{name}: {len(checks)} checks")

    all_checks.sort(key=lambda c: (c["worker"], c["story"], c["name"]))
    payload = write_reports(all_checks)
    print(f"\n{payload['summary']} in {time.time() - started:.1f}s")
    print(f"dashboard: {DASH}dashboard.html")
    for e in payload["errors"]:
        print(f"FAIL [{e['worker']}] {e['story']}: {e['message'][:240]}")
    return 1 if payload["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())

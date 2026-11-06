#!/usr/bin/env python3
"""Build, test, smoke-check and package Windows binaries without desktop input."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NANOUI = ROOT.parent / "nanoui"
NANOUI_COMMIT = "7d4424b1046f8bbab365b42f61d00f1934d4dcc8"
ZIG_VERSION = "0.17.1"
TARGET = "x86_64-windows-gnu"


def run(args, *, cwd=ROOT, expected=0, log=None, env=None, timeout=900):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=timeout, env=env,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    output = result.stdout + result.stderr
    if log:
        log.write_text(output, encoding="utf-8")
    if result.returncode != expected:
        raise RuntimeError(f"{args[0]} exited {result.returncode}, expected {expected}\n{output[-6000:]}")
    return output.strip()


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect_pe(path, subsystem):
    """Require x64, ASLR/NX, stripped symbols and imports from Windows itself."""
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[:2] != b"MZ" or data[pe:pe + 4] != b"PE\0\0":
        raise RuntimeError(f"Not a PE executable: {path.name}")
    machine, sections = struct.unpack_from("<HH", data, pe + 4)
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    opt = pe + 24
    actual_subsystem, flags = struct.unpack_from("<HH", data, opt + 68)
    if machine != 0x8664 or struct.unpack_from("<H", data, opt)[0] != 0x20B:
        raise RuntimeError("Release must use PE32+ x64")
    if actual_subsystem != subsystem or flags & 0x140 != 0x140:
        raise RuntimeError("Wrong subsystem, or ASLR/NX missing")

    def offset(rva):
        for i in range(sections):
            section = opt + optional_size + i * 40
            size, virtual, raw_size, raw = struct.unpack_from("<IIII", data, section + 8)
            if virtual <= rva < virtual + max(size, raw_size):
                return raw + rva - virtual
        raise RuntimeError(f"Unmapped PE RVA {rva}")

    debug_rva, debug_size = struct.unpack_from("<II", data, opt + 112 + 6 * 8)
    if debug_size % 28:
        raise RuntimeError("Malformed PE debug directory")
    for i in range(debug_size // 28):
        kind, size = struct.unpack_from("<II", data, offset(debug_rva) + i * 28 + 12)
        # LLD retains an empty IMAGE_DEBUG_TYPE_REPRO marker when stripping.
        # It has no symbols or PDB path. All other debug records are rejected.
        if kind != 16 or size != 0:
            raise RuntimeError("Release executable contains debug data")

    imports = []
    import_rva = struct.unpack_from("<I", data, opt + 112 + 8)[0]
    at = offset(import_rva)
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.LoadLibraryExW.argtypes = [ctypes.c_wchar_p, ctypes.c_void_p, ctypes.c_uint32]
    kernel.LoadLibraryExW.restype = ctypes.c_void_p
    kernel.FreeLibrary.argtypes = [ctypes.c_void_p]
    while any(data[at:at + 20]):
        name_at = offset(struct.unpack_from("<I", data, at + 12)[0])
        name = data[name_at:data.index(0, name_at)].decode("ascii")
        handle = kernel.LoadLibraryExW(name, None, 0x800)  # system32 search only
        if not handle:
            raise RuntimeError(f"Non-system or unavailable runtime dependency: {name}")
        kernel.FreeLibrary(handle)
        imports.append(name)
        at += 20
    return imports


def smoke(package, evidence, version):
    cli = package / "byakugan-cli.exe"
    gui = package / "byakugan.exe"
    help_text = run([cli, "--help"], cwd=package, log=evidence / "cli-help.log")
    if f"byakugan {version}" not in help_text:
        raise RuntimeError("CLI release version does not match the manifest")
    demo = run([cli, "--demo", "--no-progress"], cwd=package, log=evidence / "cli-demo.log")
    if "synthetic fixture (demo)" not in demo or "Games" not in demo:
        raise RuntimeError("Demo report missing expected content")
    run([cli, "--not-a-real-option"], cwd=package, expected=4)
    fixture = evidence / "fixture"
    fixture.mkdir()
    (fixture / "nested").mkdir()
    (fixture / "one.bin").write_bytes(b"a" * 1024)
    (fixture / "nested" / "two.bin").write_bytes(b"b" * 4096)
    report = run([cli, "--folder", fixture, "--logical", "--no-progress"], cwd=package,
                 log=evidence / "cli-folder.log")
    if "logical 5.0 KiB" not in report or "0 skipped" not in report or "4.0 KiB  nested" not in report:
        raise RuntimeError(f"Folder control returned unexpected totals:\n{report}")
    for mode, extra in [("chooser", []), ("demo", ["--demo"]),
                        ("dark", ["--demo", "--nanoui-dark"]),
                        ("folder", [f"--folder={fixture}", "--nanoui-wait=1"])]:
        image = evidence / f"{mode}.png"
        env = {**os.environ, "BYAKUGAN_LOG": str(evidence / f"{mode}.log")}
        run([gui, *extra, "--nanoui-hidden", f"--nanoui-snapshot={image}",
             "--nanoui-script=resize:900x600"], cwd=package, env=env, timeout=60,
            log=evidence / f"{mode}-process.log")
        if not image.exists() or image.read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
            raise RuntimeError(f"Missing native {mode} capture")
        events = (evidence / f"{mode}.log").read_text(encoding="utf-8")
        # Zig 0.17 names the ReleaseSafe builtin mode `safe` in startup logs.
        if f"version={version} build=safe" not in events or "hidden=true" not in events or "shutdown complete" not in events:
            raise RuntimeError(f"Incomplete native {mode} lifecycle")
        if mode == "folder" and "kind=folder result=complete" not in events:
            raise RuntimeError("Packaged GUI folder scan did not finish")
    if (fixture / "one.bin").stat().st_size != 1024 or (fixture / "nested" / "two.bin").stat().st_size != 4096:
        raise RuntimeError("Read-only smoke test changed its fixture")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts" / "release")
    args = parser.parse_args()
    if os.name != "nt":
        raise RuntimeError("Native Windows smoke tests require Windows")
    zig = shutil.which(args.zig)
    if not zig or run([zig, "version"]) != ZIG_VERSION:
        raise RuntimeError(f"Use Zig {ZIG_VERSION}")
    if run(["git", "status", "--porcelain"]):
        raise RuntimeError("Commit the source before producing a release archive")
    commit = run(["git", "rev-parse", "HEAD"])
    if run(["git", "rev-parse", "HEAD"], cwd=NANOUI) != NANOUI_COMMIT:
        raise RuntimeError("nanoui must be at the documented pinned revision")
    run(["git", "apply", "--reverse", "--check", ROOT / "tools/nanoui-windows.patch"], cwd=NANOUI)
    version = re.search(r'\.version\s*=\s*"([\w.+-]+)"', (ROOT / "build.zig.zon").read_text()).group(1)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    name = f"byakugan-{version}-windows-x86_64"
    archive = output / f"{name}.zip"
    if archive.exists():
        raise RuntimeError(f"Refusing to replace existing artifact: {archive}")
    evidence = output / f"{name}-evidence"
    evidence.mkdir()
    run([zig, "fmt", "--check", "build.zig", "build.zig.zon", "src"])
    flags = ["-j1", f"-Dtarget={TARGET}", "-Dcpu=baseline", "-Doptimize=ReleaseSafe"]
    print("Testing ReleaseSafe with baseline x64 CPU...", flush=True)
    run([zig, "build", "test", *flags, "--summary", "all"], log=evidence / "tests.log")
    with tempfile.TemporaryDirectory(prefix="stage-", dir=output) as temp:
        stage = Path(temp)
        print("Building stripped GUI and CLI...", flush=True)
        run([zig, "build", *flags, "-Dstrip=true", "--prefix", stage / "build", "--summary", "all"],
            log=evidence / "build.log")
        package = stage / name
        package.mkdir()
        imports = {}
        for executable, subsystem in [("byakugan.exe", 2), ("byakugan-cli.exe", 3)]:
            shutil.copy2(stage / "build" / "bin" / executable, package)
            imports[executable] = inspect_pe(package / executable, subsystem)
        shutil.copy2(ROOT / "docs" / "release-readme.txt", package / "README.txt")
        shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", package)
        shutil.copytree(ROOT / "third_party" / "licenses", package / "third_party" / "licenses")
        if (ROOT / "LICENSE").exists():
            shutil.copy2(ROOT / "LICENSE", package)
        print("Checking packaged binaries in an isolated directory...", flush=True)
        smoke(package, evidence, version)
        manifest = {
            "version": version, "source_commit": commit, "zig": ZIG_VERSION,
            "target": TARGET, "cpu": "baseline", "optimize": "ReleaseSafe", "stripped": True,
            "nanoui_commit": NANOUI_COMMIT,
            "nanoui_patch_sha256": sha256(ROOT / "tools/nanoui-windows.patch"),
            "imports": imports,
            "files": {str(p.relative_to(package)).replace("\\", "/"): sha256(p)
                      for p in sorted(package.rglob("*")) if p.is_file()},
        }
        (package / "build-info.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for path in sorted(package.rglob("*")):
                if path.is_file():
                    z.write(path, path.relative_to(stage))
        with zipfile.ZipFile(archive) as z:
            if z.testzip() is not None:
                raise RuntimeError("ZIP integrity check failed")
        shutil.copy2(package / "build-info.json", output / f"{name}.build-info.json")
    checksum = f"{sha256(archive)}  {archive.name}\n"
    archive.with_suffix(".zip.sha256").write_text(checksum, encoding="ascii")
    print(checksum, end="", flush=True)
    print(f"Evidence: {evidence}", flush=True)


if __name__ == "__main__":
    main()

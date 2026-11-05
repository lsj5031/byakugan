#!/usr/bin/env python3
"""Compose the byakugan feature reel from real headless captures.

The UI frames are the same 1280x820 PNGs written by --nanoui-snapshot. This
script puts them on a 1920x1080 stage, adds fixed captions, applies a slow
push-in to the UI only, and pipes raw frames to ffmpeg. The CLI segment is
built from the actual `byakugan-cli --demo --top 5` output.

    python tools/make_video.py
"""
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
FRAMES = ROOT / "docs" / "frames"
CLIPS = ROOT / "docs" / "clips"
FFMPEG = shutil.which("ffmpeg") or "ffmpeg"

W, H = 1920, 1080
UI_W, UI_H = 1440, 922
UI_X, UI_Y = 240, 64
FPS = 30
BLACK = Image.new("RGB", (W, H), (0, 0, 0))

BG0 = (7, 11, 18)
BG1 = (13, 22, 36)
TEXT = (232, 238, 252)
MUTED = (139, 155, 180)
FAINT = (76, 91, 114)
ACCENT = (77, 212, 198)
ACCENT2 = (122, 162, 255)
BORDER = (31, 42, 61)
FONT_DIR = Path("C:/Windows/Fonts")

_fonts: dict[tuple[str, int], ImageFont.FreeTypeFont] = {}


def font(kind: str, size: int) -> ImageFont.FreeTypeFont:
    key = (kind, size)
    if key in _fonts:
        return _fonts[key]
    choices = {
        "bold": ["segoeuib.ttf", "arialbd.ttf", "segoeui.ttf"],
        "body": ["segoeui.ttf", "arial.ttf"],
        "mono": ["consola.ttf", "cour.ttf", "lucon.ttf"],
        "monob": ["consolab.ttf", "consola.ttf", "courbd.ttf"],
        "cn": ["msyh.ttc", "msyhbd.ttc", "simhei.ttf", "segoeui.ttf"],
    }[kind]
    for name in choices:
        p = FONT_DIR / name
        if p.exists():
            try:
                f = ImageFont.truetype(str(p), size)
                _fonts[key] = f
                return f
            except OSError:
                continue
    f = ImageFont.load_default()
    _fonts[key] = f
    return f


def lerp(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))  # type: ignore[return-value]


def background() -> Image.Image:
    img = Image.new("RGB", (W, H), BG0)
    d = ImageDraw.Draw(img)
    for y in range(H):
        d.line([(0, y), (W, y)], fill=lerp(BG0, BG1, y / H))

    # A soft cyan glow in the upper right, and a blue one lower left.
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for r in range(720, 80, -18):
        a = int(16 * (1 - r / 760))
        gd.ellipse((1580 - r, -240 - r, 1580 + r, -240 + r), fill=(77, 212, 198, a))
    for r in range(560, 60, -18):
        a = int(9 * (1 - r / 580))
        gd.ellipse((-180 - r, 900 - r, -180 + r, 900 + r), fill=(122, 162, 255, a))
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    img = Image.alpha_composite(img.convert("RGBA"), glow).convert("RGB")

    # Faint measurement grid.
    grid = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    for x in range(0, W, 48):
        gd.line([(x, 0), (x, H)], fill=(255, 255, 255, 5))
    for y in range(0, H, 48):
        gd.line([(0, y), (W, y)], fill=(255, 255, 255, 5))
    img = Image.alpha_composite(img.convert("RGBA"), grid).convert("RGB")
    return img


def mask() -> Image.Image:
    m = Image.new("L", (UI_W, UI_H), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, UI_W - 1, UI_H - 1), radius=10, fill=255)
    return m


UI_MASK = mask()


def base(title: str, subtitle: str, index: int | None, kicker: str = "FEATURE REEL") -> Image.Image:
    img = background()
    d = ImageDraw.Draw(img)
    d.text((UI_X, 20), "白眼", font=font("cn", 25), fill=ACCENT)
    d.text((UI_X + 58, 19), "byakugan", font=font("bold", 25), fill=TEXT)
    d.text((UI_X + 190, 29), "MFT disk analyzer", font=font("body", 13), fill=MUTED)
    right = kicker if index is None else f"{index:02d} / 08   ·   {kicker}"
    d.text((W - UI_X, 29), right, font=font("mono", 12), fill=FAINT, anchor="ra")

    # Window shadow and a one-pixel rim.
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((UI_X - 8, UI_Y - 6, UI_X + UI_W + 8, UI_Y + UI_H + 10),
                         radius=18, fill=(0, 0, 0, 210))
    shadow = shadow.filter(ImageFilter.GaussianBlur(18))
    img = Image.alpha_composite(img.convert("RGBA"), shadow).convert("RGB")
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((UI_X - 1, UI_Y - 1, UI_X + UI_W, UI_Y + UI_H),
                        radius=11, fill=BORDER)

    d.rectangle((UI_X, 993, UI_X + 52, 996), fill=ACCENT)
    d.text((UI_X, 1008), title, font=font("bold", 28), fill=TEXT)
    d.text((UI_X, 1047), subtitle, font=font("body", 15), fill=MUTED)
    return img


def ui_frame(src: Image.Image, p: float) -> Image.Image:
    z = 1.0 + 0.035 * max(0.0, min(1.0, p))
    cw = src.width / z
    ch = src.height / z
    box = ((src.width - cw) / 2, (src.height - ch) / 2,
           (src.width + cw) / 2, (src.height + ch) / 2)
    crop = src.crop(tuple(round(v) for v in box)).resize(
        (UI_W, UI_H), Image.Resampling.LANCZOS)
    return crop


class Stage:
    def __init__(self, ui_path: str | None = None, still: Image.Image | None = None,
                 title: str = "", subtitle: str = "", index: int | None = None,
                 kicker: str = "FEATURE REEL"):
        self.ui = Image.open(FRAMES / ui_path).convert("RGB") if ui_path else None
        self.base = base(title, subtitle, index, kicker) if still is None else None
        if still is not None:
            self.still = still
        else:
            self.still = None

    def frame(self, p: float = 0.0) -> Image.Image:
        if self.still is not None:
            return self.still.copy()
        assert self.base is not None and self.ui is not None
        out = self.base.copy()
        out.paste(ui_frame(self.ui, p), (UI_X, UI_Y), UI_MASK)
        return out


def terminal(lines: list[str], index: int, title: str, subtitle: str,
             command: str, show_cursor: bool = False) -> Stage:
    b = base(title, subtitle, index, "CONSOLE REPORT")
    panel = Image.new("RGB", (UI_W, UI_H), (9, 14, 23))
    d = ImageDraw.Draw(panel)
    d.rounded_rectangle((0, 0, UI_W - 1, UI_H - 1), radius=10, fill=(9, 14, 23),
                        outline=(38, 50, 68), width=1)
    d.rectangle((1, 1, UI_W - 2, 42), fill=(16, 24, 36))
    d.rounded_rectangle((1, 1, UI_W - 2, 60), radius=10, fill=(16, 24, 36))
    d.rectangle((1, 43, UI_W - 2, 61), fill=(16, 24, 36))
    for i, col in enumerate(((251, 113, 133), (251, 191, 36), (54, 211, 153))):
        d.ellipse((18 + i * 19, 15, 28 + i * 19, 25), fill=col)
    d.text((UI_W / 2, 21), "byakugan-cli  —  synthetic fixture (demo)",
           font=font("mono", 13), fill=MUTED, anchor="mm")

    x, y, lh = 34, 77, 27
    prompt = "PS T:\\playground\\byakugan> "
    pw = d.textlength(prompt, font=font("mono", 18))
    d.text((x, y), prompt, font=font("mono", 18), fill=(54, 211, 153))
    d.text((x + pw, y), command, font=font("mono", 18), fill=TEXT)
    if show_cursor:
        cw = d.textlength(command, font=font("mono", 18))
        d.rectangle((x + pw + cw + 3, y + 1, x + pw + cw + 12, y + 21), fill=ACCENT)
    y += lh
    for line in lines:
        color = MUTED
        if line.startswith("byakugan "):
            color = TEXT
        elif line.startswith("logical "):
            color = ACCENT
        elif line.startswith("     ") and ("GiB" in line or "MiB" in line):
            color = (198, 211, 232)
        d.text((x, y), line, font=font("mono", 18), fill=color)
        y += lh
    b.paste(panel, (UI_X, UI_Y), UI_MASK)
    return Stage(still=b, title=title, subtitle=subtitle, index=index)


def card(kind: str) -> Stage:
    img = background()
    d = ImageDraw.Draw(img)
    if kind == "title":
        d.text((UI_X, 245), "白眼", font=font("cn", 78), fill=ACCENT)
        d.text((UI_X, 355), "byakugan", font=font("bold", 84), fill=TEXT)
        d.text((UI_X, 475), "The NTFS master file table, seen whole.",
               font=font("body", 32), fill=(198, 211, 232))
        d.text((UI_X, 527), "Direct MFT scan   ·   native Zig + nanoui",
               font=font("body", 18), fill=MUTED)
        d.rectangle((UI_X, 604, UI_X + 64, 607), fill=ACCENT)
        d.text((UI_X, 640), "Feature reel  ·  demo fixture where noted  ·  real C: needs elevation",
               font=font("body", 14), fill=FAINT)
        d.text((W - UI_X, 29), "BYAKUGAN 0.1.0", font=font("mono", 12), fill=FAINT, anchor="ra")
    else:
        d.text((UI_X, 248), "44 user stories.", font=font("bold", 64), fill=TEXT)
        d.text((UI_X, 330), "42 passing   ·   2 blocked by elevation",
               font=font("body", 28), fill=ACCENT)
        d.text((UI_X, 392), "One direct read of the MFT, from parsing to pixels.",
               font=font("body", 25), fill=(198, 211, 232))
        d.text((UI_X, 470), "byakugan 0.1.0   ·   Zig + nanoui   ·   Windows",
               font=font("body", 18), fill=MUTED)
        d.rectangle((UI_X, 548, UI_X + 64, 551), fill=ACCENT)
        d.text((UI_X, 585), "Every UI frame was rendered headlessly with --nanoui-snapshot.",
               font=font("body", 14), fill=FAINT)
        d.text((UI_X, 1004), "No window was opened on the developer's screen.",
               font=font("body", 14), fill=FAINT)
    return Stage(still=img, title="", subtitle="")


def render(path: Path, stages: list[Stage], durations: list[float], cross: float = 0.0,
           fade: float = 0.25) -> None:
    assert len(stages) == len(durations)
    starts = [0.0]
    for d in durations[:-1]:
        starts.append(starts[-1] + d - cross)
    total = sum(durations) - cross * (len(stages) - 1)
    n = max(1, round(total * FPS))
    cmd = [
        FFMPEG, "-y", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-r", str(FPS),
        "-i", "-", "-an", "-c:v", "libx264", "-preset", "veryfast", "-crf", "19",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(path),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdin is not None
    try:
        for i in range(n):
            t = i / FPS
            idx = 0
            for j, s in enumerate(starts):
                if t >= s:
                    idx = j
            p = (t - starts[idx]) / max(0.001, durations[idx])
            frame = stages[idx].frame(p)
            if idx > 0 and cross > 0 and t < starts[idx] + cross:
                w = (t - starts[idx]) / cross
                prev = stages[idx - 1].frame(1.0)
                frame = Image.blend(prev, frame, max(0.0, min(1.0, w)))
            a = min(1.0, t / fade, (total - t) / fade)
            if a < 1.0:
                frame = Image.blend(BLACK, frame, max(0.0, a))
            proc.stdin.write(frame.tobytes())
    finally:
        proc.stdin.close()
        err = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
        rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"ffmpeg failed for {path}: {rc}\n{err}")
    print(f"wrote {path.relative_to(ROOT)}  ({total:.1f}s)")


def main() -> int:
    CLIPS.mkdir(parents=True, exist_ok=True)
    root = ("drill-1.png", "Every byte, at a glance",
            "A squarified treemap of the focused directory; labels only where they fit.", 2)
    games = ("drill-2.png", "Follow the space",
             "Click a directory tile to focus it. Up returns to its parent.", 3)
    steam = ("drill-3.png", "Follow the space",
             "Click a directory tile to focus it. Up returns to its parent.", 3)
    f1 = ("filter-1.png", "Find it instantly",
          "Case-insensitive substring filter keeps matches and their ancestors.", 4)
    f2 = ("filter-2.png", "Find it instantly",
          "Case-insensitive substring filter keeps matches and their ancestors.", 4)
    m1 = ("metric-1.png", "Logical vs allocated",
          "Compare file size with real cluster use; re-sort and re-layout instantly.", 5)
    m2 = ("metric-2.png", "Logical vs allocated",
          "Compare file size with real cluster use; re-sort and re-layout instantly.", 5)
    e1 = ("extension-1.png", "What is taking the space?",
          "Top file types in the focused subtree; click one to filter.", 7)
    e2 = ("extension-2.png", "What is taking the space?",
          "Top file types in the focused subtree; click one to filter.", 7)

    def ui(spec) -> Stage:
        return Stage(ui_path=spec[0], title=spec[1], subtitle=spec[2], index=spec[3])

    cmd = "byakugan-cli --demo --top 5 --no-progress"
    raw = (ROOT / "artifacts" / "cli-demo.txt").read_text(encoding="utf-8").splitlines()
    plain = [line for line in raw if line.strip()]
    title = "One pass over the MFT"
    subtitle = "The production report formatter, run on the synthetic fixture. Real C: needs elevation."
    stages = [
        terminal([], 1, title, subtitle, cmd, show_cursor=True),
        terminal(plain[:2], 1, title, subtitle, cmd),
        terminal(plain[:4], 1, title, subtitle, cmd),
        terminal(plain[:8], 1, title, subtitle, cmd),
        terminal(plain, 1, title, subtitle, cmd),
    ]
    clips = [
        ("01-mft-report.mp4", stages, [1.1, 0.9, 0.9, 1.1, 2.4], 0.18, 0.25),
        ("02-treemap.mp4", [ui(root)], [5.0], 0.0, 0.25),
        ("03-drilldown.mp4", [ui(root), ui(games), ui(steam)], [1.8, 1.9, 2.4], 0.45, 0.25),
        ("04-filter.mp4", [ui(f1), ui(f2)], [1.9, 2.9], 0.5, 0.25),
        ("05-allocated.mp4", [ui(m1), ui(m2)], [1.9, 2.9], 0.5, 0.25),
        ("06-hardlink.mp4", [Stage(ui_path="hardlink.png", title="One file, every name",
                                    subtitle="Hard links are counted once; every path stays visible.", index=6)],
         [5.0], 0.0, 0.25),
        ("07-extensions.mp4", [ui(e1), ui(e2)], [1.9, 2.9], 0.5, 0.25),
        ("08-elevation.mp4", [Stage(ui_path="denied.png", title="No silent failure",
                                     subtitle="Access denied explains itself, keeps the drive picker and offers elevation.", index=8)],
         [5.0], 0.0, 0.25),
    ]

    title_clip = CLIPS / "00-title.mp4"
    outro_clip = CLIPS / "09-outro.mp4"
    render(title_clip, [card("title")], [3.6], 0.0, 0.5)
    for name, stages_, durs, cross, fade in clips:
        render(CLIPS / name, stages_, durs, cross, fade)
    render(outro_clip, [card("outro")], [4.4], 0.0, 0.5)

    ordered = [title_clip] + [CLIPS / c[0] for c in clips] + [outro_clip]
    lst = ROOT / "artifacts" / "clip-list.txt"
    lst.write_text("".join(f"file '{p.as_posix()}'\n" for p in ordered), encoding="utf-8")
    final = ROOT / "docs" / "byakugan-demo.mp4"
    p = subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
                        "-i", str(lst), "-c", "copy", "-movflags", "+faststart", str(final)],
                       capture_output=True, text=True)
    if p.returncode != 0:
        print("concat -c copy failed, re-encoding once")
        p = subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
                            "-i", str(lst), "-c:v", "libx264", "-preset", "veryfast",
                            "-crf", "19", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(final)],
                           capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr)
        return 1
    print(f"wrote {final.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

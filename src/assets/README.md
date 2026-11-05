# Byakugan mark

Partition is the original vector direction selected by the user on
5 November 2026: a B built from three separate data regions. `byakugan.svg`
is the editable geometry source for both the header mark and app icon.

`export_icon.py` uses Pillow to rasterize each icon size independently with
8x supersampling. `byakugan.ico` includes 16, 20, 24, 32, 40, 48, 64, 128 and
256px images. Its cream #FCFCF9 mark sits on a forest #3E5B4C rounded square,
with transparent corners. `byakugan.png` is the standalone transparent mark
at 256px, tinted by the app theme in the header. The wordmark continues to
use Recursive Sans. No symbol font or additional renderer is required.

`byakugan.rc` embeds resource 1 for Explorer, the taskbar and Alt-Tab;
`win_frame.zig` assigns that resource to the window's large and small icons.

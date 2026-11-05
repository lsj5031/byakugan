# Byakugan mark

The existing header identity is U+25C9 `◉` (FISHEYE). No standalone logo was
provided. These assets preserve that mark, rendered directly from Windows'
Segoe UI Symbol glyph, rather than cropping a mockup or introducing artwork.
The font itself is neither redistributed nor installed.

`export_icon.py` uses Pillow to rasterize each icon size independently with
8x supersampling. `byakugan.ico` includes 16, 20, 24, 32, 40, 48, 64, 128 and
256px images. `byakugan.png` is the same transparent mark at 256px, tinted by
the app theme in the header. The icon's green #6B8767 stays visible against
both light and dark taskbars.

`byakugan.rc` embeds resource 1 for Explorer, the taskbar and Alt-Tab;
`win_frame.zig` assigns that resource to the window's large and small icons.

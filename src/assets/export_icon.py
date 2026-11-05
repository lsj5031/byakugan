"""Export Byakugan's existing U+25C9 mark from the Windows symbol font.

Requires Pillow. Run on Windows: python src/assets/export_icon.py
No font is copied or installed. Each size is rasterized independently at 8x
resolution and downsampled, with transparent padding and no background matte.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

DEST = Path(__file__).parent
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)


def mark(size):
    scale = 8
    side = size * scale
    font = ImageFont.truetype(r"C:\Windows\Fonts\seguisym.ttf", side)
    mask = Image.new("L", (side * 2, side * 2))
    ImageDraw.Draw(mask).text((side // 2, 0), "◉", font=font, fill=255)
    mask = mask.crop(mask.getbbox())
    mask.thumbnail((round(side * 0.84), round(side * 0.84)), Image.Resampling.LANCZOS)
    alpha = Image.new("L", (side, side))
    alpha.paste(mask, ((side - mask.width) // 2, (side - mask.height) // 2))
    alpha = alpha.resize((size, size), Image.Resampling.LANCZOS)
    image = Image.new("RGBA", (size, size), (0x6B, 0x87, 0x67, 0))
    image.putalpha(alpha)
    return image


if __name__ == "__main__":
    images = [mark(size) for size in SIZES]
    images[-1].save(DEST / "byakugan.png")
    images[-1].save(
        DEST / "byakugan.ico",
        sizes=[(size, size) for size in SIZES],
        append_images=images[:-1],
    )

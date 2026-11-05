"""Export the selected Partition vector mark and Windows app icon.

Requires Pillow. Run: python src/assets/export_icon.py
The SVG polygons are the single geometry source. Each size is rasterized at
8x resolution and downsampled; no font or external SVG renderer is needed.
"""
from pathlib import Path
from xml.etree import ElementTree

from PIL import Image, ImageDraw

DEST = Path(__file__).parent
SIZES = (16, 20, 24, 32, 40, 48, 64, 128, 256)
FOREST = (0x3E, 0x5B, 0x4C)
CREAM = (0xFC, 0xFC, 0xF9)


def polygons():
    root = ElementTree.parse(DEST / "byakugan.svg").getroot()
    if root.attrib.get("viewBox") != "0 0 64 64":
        raise ValueError("Partition source must use the 64-unit viewBox")
    shapes = []
    for element in root:
        if element.tag != "{http://www.w3.org/2000/svg}polygon":
            raise ValueError("Exporter supports only the source mark's polygons")
        points = [tuple(map(float, pair.split(","))) for pair in element.attrib["points"].split()]
        shapes.append(points)
    return shapes


def mark(size, shapes, tile=False):
    scale = 8
    side = size * scale
    image = Image.new("RGBA", (side, side), (*FOREST, 0))
    draw = ImageDraw.Draw(image)
    if tile:
        draw.rounded_rectangle((0, 0, side - 1, side - 1), radius=side / 4, fill=(*FOREST, 255))
    width = side * (42 / 64 if tile else 1)
    offset = (side - width) / 2
    for polygon in shapes:
        points = [(offset + x * width / 64, offset + y * width / 64) for x, y in polygon]
        draw.polygon(points, fill=(*(CREAM if tile else FOREST), 255))
    return image.resize((size, size), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    shapes = polygons()
    mark(256, shapes).save(DEST / "byakugan.png")
    images = [mark(size, shapes, tile=True) for size in SIZES]
    images[-1].save(
        DEST / "byakugan.ico",
        sizes=[(size, size) for size in SIZES],
        append_images=images[:-1],
    )

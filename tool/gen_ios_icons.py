from PIL import Image
from pathlib import Path

src = Path(__file__).resolve().parents[1] / "assets" / "icon" / "ic_launcher.png"
icon_dir = (
    Path(__file__).resolve().parents[1]
    / "ios"
    / "Runner"
    / "Assets.xcassets"
    / "AppIcon.appiconset"
)
launch_dir = (
    Path(__file__).resolve().parents[1]
    / "ios"
    / "Runner"
    / "Assets.xcassets"
    / "LaunchImage.imageset"
)
base = Image.open(src).convert("RGBA")
brand = (255, 204, 127)  # #FFCC7F

icons = [
    ("Icon-App-20x20@1x.png", 20),
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40),
    ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-76x76@1x.png", 76),
    ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167),
    ("Icon-App-1024x1024@1x.png", 1024),
]


def fit_square(im: Image.Image, size: int) -> Image.Image:
    canvas = Image.new("RGBA", (size, size), (*brand, 255))
    im2 = im.copy()
    im2.thumbnail((size, size), Image.Resampling.LANCZOS)
    x = (size - im2.width) // 2
    y = (size - im2.height) // 2
    canvas.paste(im2, (x, y), im2)
    if size == 1024:
        out = Image.new("RGB", (size, size), brand)
        out.paste(canvas, mask=canvas.split()[-1])
        return out
    return canvas


for name, size in icons:
    img = fit_square(base, size)
    img.save(icon_dir / name, "PNG")
    print("icon", name, size)

launches = [
    ("LaunchImage.png", 168, 185, 100),
    ("LaunchImage@2x.png", 336, 370, 160),
    ("LaunchImage@3x.png", 504, 555, 220),
]
for name, w, h, logo in launches:
    layer = Image.new("RGBA", (w, h), (*brand, 255))
    mark = base.copy()
    mark.thumbnail((logo, logo), Image.Resampling.LANCZOS)
    x = (w - mark.width) // 2
    y = (h - mark.height) // 2
    layer.paste(mark, (x, y), mark)
    layer.convert("RGB").save(launch_dir / name, "PNG")
    print("launch", name, w, h)

print("done")

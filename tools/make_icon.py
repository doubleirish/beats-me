"""Generates the Android launcher icons (music note on a gradient). Requires Pillow."""
from pathlib import Path
from PIL import Image, ImageDraw

RES = Path(__file__).resolve().parent.parent / "android" / "app" / "src" / "main" / "res"
SIZES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
S = 1024  # master size


def gradient():
    img = Image.new("RGB", (S, S))
    px = img.load()
    c1, c2 = (124, 58, 237), (236, 72, 153)
    for y in range(S):
        for x in range(S):
            t = (x + y) / (2 * S - 2)
            px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))
    return img


def note():
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    w = (255, 255, 255, 255)
    # beamed pair of eighth notes
    d.ellipse((290, 600, 470, 740), fill=w)
    d.ellipse((580, 540, 760, 680), fill=w)
    d.rectangle((438, 330, 478, 670), fill=w)
    d.rectangle((728, 270, 768, 610), fill=w)
    d.polygon([(438, 330), (768, 270), (768, 370), (438, 430)], fill=w)
    return layer


def main():
    base = gradient().convert("RGBA")
    full = Image.alpha_composite(base, note())
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, S - 1, S - 1), radius=S // 5, fill=255)
    rounded = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rounded.paste(full, mask=mask)
    for name, px in SIZES.items():
        out = RES / f"mipmap-{name}" / "ic_launcher.png"
        rounded.resize((px, px), Image.LANCZOS).save(out)
        print("wrote", out)


if __name__ == "__main__":
    main()

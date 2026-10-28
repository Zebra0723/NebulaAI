"""Draws Resources/AppIcon.png: Nebula's mark (a ring touched by a disc) on a deep squircle."""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# macOS icon grid: 824px squircle-ish rounded square centred.
pad = 100
body = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(body)
d.rounded_rectangle([pad, pad, S - pad, S - pad], radius=185, fill=(14, 17, 24, 255))
# A faint vertical light, top to bottom.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
for i in range(360):
    a = int(46 * (1 - i / 360))
    g.rounded_rectangle([pad, pad + i, S - pad, pad + i + 2], radius=0, fill=(143, 239, 213, a // 6))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([pad, pad, S - pad, S - pad], radius=185, fill=255)
body = Image.alpha_composite(body, Image.composite(glow, Image.new("RGBA", (S, S)), mask))
img = Image.alpha_composite(img, body)

mint = (143, 239, 213, 255)
c = S // 2
r = 230
ring = Image.new("RGBA", (S, S), (0, 0, 0, 0))
rd = ImageDraw.Draw(ring)
rd.ellipse([c - r, c - r, c + r, c + r], outline=mint, width=34)
halo = ring.filter(ImageFilter.GaussianBlur(28))
img = Image.alpha_composite(img, Image.eval(halo, lambda v: v // 2))
img = Image.alpha_composite(img, ring)
dot = Image.new("RGBA", (S, S), (0, 0, 0, 0))
dd = ImageDraw.Draw(dot)
dr = 84
dx, dy = c + 163, c - 163
dd.ellipse([dx - dr, dy - dr, dx + dr, dy + dr], fill=(236, 239, 244, 255))
img = Image.alpha_composite(img, dot)
img.save(sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png")

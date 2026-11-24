#!/usr/bin/env python3
"""Draws Resources/AppIcon.png (1024 px master, saved at 512): a 4x6 label with a torn-off top edge."""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# macOS-style squircle background with a warm amber gradient
bg = Image.new("RGBA", (S, S))
d = ImageDraw.Draw(bg)
for y in range(S):
    t = y / S
    r = int(255 * (1 - t) + 236 * t); g = int(171 * (1 - t) + 94 * t); b = int(64 * (1 - t) + 34 * t)
    d.line([(0, y), (S, y)], fill=(r, g, b, 255))
mask = Image.new("L", (S, S), 0)
m = 100
ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], radius=185, fill=255)
img.paste(bg, (0, 0), mask)

# label paper (portrait 4x6), slightly tilted, with a zig-zag torn top edge
lw, lh = 420, 630
paper = Image.new("RGBA", (lw + 80, lh + 80), (0, 0, 0, 0))
pd = ImageDraw.Draw(paper)
ox, oy = 40, 40
teeth = 14
pts = [(ox, oy + lh)]
pts.append((ox, oy + 18))
step = lw / teeth
for i in range(teeth + 1):
    x = ox + i * step
    pts.append((x, oy + (0 if i % 2 else 18)))
pts += [(ox + lw, oy + 18), (ox + lw, oy + lh)]
pd.polygon(pts, fill=(255, 255, 255, 255))
ink = (24, 24, 28, 255)
# address lines
for i, w in enumerate((230, 300, 180)):
    pd.rounded_rectangle([ox + 34, oy + 62 + i * 30, ox + 34 + w, oy + 76 + i * 30], radius=6, fill=ink)
pd.rectangle([ox + 20, oy + 175, ox + lw - 20, oy + 181], fill=ink)
# 2D code block
for r in range(9):
    for c in range(9):
        if (r * 7 + c * 3 + r * c) % 3 != 0 or r in (0, 8) or c in (0, 8):
            pd.rectangle([ox + 34 + c * 13, oy + 205 + r * 13, ox + 44 + c * 13, oy + 215 + r * 13], fill=ink)
pd.rounded_rectangle([ox + 170, oy + 210, ox + 380, oy + 236], radius=6, fill=ink)
pd.rounded_rectangle([ox + 170, oy + 250, ox + 330, oy + 272], radius=6, fill=ink)
pd.rectangle([ox + 20, oy + 340, ox + lw - 20, oy + 346], fill=ink)
# tracking barcode with crisp whole-module bars
x = ox + 46
pattern = [2,1,1,2,1,4,3,1,1,1,2,3,2,2,1,1,3,2,1,2,2,3,1,1,2,1,4,1,1,2,3,1,2,2,1,3,1,1,2,2]
for k, mod in enumerate(pattern):
    w = mod * 8
    if k % 2 == 0:
        pd.rectangle([x, oy + 375, x + w - 1, oy + 560], fill=ink)
    x += w
    if x > ox + lw - 46:
        break
shadow = paper.split()[3].filter(ImageFilter.GaussianBlur(18))
sh = Image.new("RGBA", paper.size, (60, 25, 0, 120))
sh.putalpha(shadow.point(lambda v: int(v * 0.55)))
angle = -7
sh = sh.rotate(angle, resample=Image.BICUBIC, expand=True)
paper = paper.rotate(angle, resample=Image.BICUBIC, expand=True)
cx, cy = S // 2, S // 2 + 30
img.alpha_composite(sh, (cx - sh.width // 2 + 10, cy - sh.height // 2 + 22))
img.alpha_composite(paper, (cx - paper.width // 2, cy - paper.height // 2))
img.resize((512, 512), Image.LANCZOS).save("Resources/AppIcon.png")
print("wrote Resources/AppIcon.png")

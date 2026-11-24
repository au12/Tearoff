#!/usr/bin/env python3
"""Installer backgrounds: the app icon in the bottom-left of the step list (transparent elsewhere,
so the pages stay readable). 2x resolution, scaled proportionally by Installer."""
from PIL import Image

W, H = 1240, 836          # 620 x 418 pt @2x (Installer's content area)
icon = Image.open("Resources/AppIcon.png").convert("RGBA").resize((236, 236), Image.LANCZOS)
for name, alpha in (("background.png", 1.0), ("background-dark.png", 0.92)):
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ic = icon.copy()
    if alpha < 1:
        a = ic.split()[3].point(lambda v: int(v * alpha))
        ic.putalpha(a)
    img.alpha_composite(ic, (52, H - 236 - 44))
    img.save(f"pkg/resources/{name}")
    print("wrote", name)

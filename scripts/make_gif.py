#!/usr/bin/env python3
"""Turns the Setup Assistant animation frames (Tearoff --render-pluck DIR) into an animated GIF.

    python3 scripts/make_gif.py out/pluck docs/how-it-works.gif [fps]
"""
import glob
import os
import sys

from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
fps = float(sys.argv[3]) if len(sys.argv) > 3 else 12
paths = sorted(glob.glob(os.path.join(src, "frame-*.png")))
if not paths:
    sys.exit("no frames in " + src)
frames = [Image.open(p).convert("RGB") for p in paths]
# one palette for every frame (no shimmer), built from frames across the whole loop
sample = Image.new("RGB", (frames[0].width, frames[0].height * 4))
for k, i in enumerate(range(0, len(frames), max(1, len(frames) // 4))):
    if k < 4:
        sample.paste(frames[i], (0, frames[0].height * k))
palette = sample.quantize(colors=96, method=Image.Quantize.MEDIANCUT)
quantized = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
quantized[0].save(dst, save_all=True, append_images=quantized[1:], duration=int(1000 / fps), loop=0, optimize=True,
                  disposal=1)
print(f"{dst}: {len(frames)} frames, {os.path.getsize(dst) / 1e6:.1f} MB")

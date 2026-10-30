#!/usr/bin/env python3
"""Build a large, smooth king for the Home screen hero.

The piece sheet's 170 px cells come from a small JPEG, so blown up to hero
size (~230 px) their edges look rough. This redraws the white king at
OUT x OUT pixels: the source is enlarged UP times, smoothed, and cut into two
clean shapes (the black strokes and the white fill) with hard thresholds, then
scaled down so every edge is evenly anti-aliased.

Input:  assets/source/pieces-reference.jpg (the white king is the first piece)
Output: assets/hero-king.png (OUT x OUT, transparent background)

Needs numpy, Pillow and scipy.
"""
import pathlib

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "source" / "pieces-reference.jpg"
OUTPUT = ROOT / "assets" / "hero-king.png"
OUT = 512
UP = 8  # work at 8x the source size
BLUR = 2.2  # smoothing (at UP size) that rounds off the JPEG's blocky edges
STROKE = 140  # darker than this (after smoothing) is the black outline
SEAL = 6  # stroke thickening (at UP size) so the fill can't leak through gaps


def crop_king(gray: np.ndarray) -> tuple[slice, slice]:
    ink = gray < 200
    rows = np.flatnonzero(ink.any(axis=1))
    top = rows[0]
    # The first row of pieces ends at the first blank line after it starts.
    blank = np.flatnonzero(~ink[top:].any(axis=1))
    bottom = top + blank[0]
    cols = np.flatnonzero(ink[top:bottom].any(axis=0))
    left = cols[0]
    gaps = np.flatnonzero(~ink[top:bottom, left:].any(axis=0))
    right = left + gaps[0]
    pad = 3
    return slice(max(0, top - pad), bottom + pad), slice(max(0, left - pad), right + pad)


def main() -> None:
    source = Image.open(SOURCE).convert("L")
    gray = np.asarray(source).astype(np.float32)
    rows, cols = crop_king(gray)
    king = Image.fromarray(gray[rows, cols].astype(np.uint8))
    big = np.asarray(king.resize((king.width * UP, king.height * UP), Image.BICUBIC)).astype(np.float32)
    smooth = ndimage.gaussian_filter(big, BLUR)

    stroke = smooth < STROKE
    # Background: light pixels reachable from the border once the strokes are
    # thickened, grown back over the halo; everything else is the piece.
    light = ~ndimage.binary_dilation(stroke, iterations=SEAL)
    labels, _ = ndimage.label(light)
    border = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    outside = np.isin(labels, border[border != 0])
    outside = ndimage.binary_dilation(outside, iterations=SEAL) & ~stroke
    piece = ~outside
    # Drop specks.
    labels, count = ndimage.label(piece)
    sizes = ndimage.sum(np.ones_like(smooth), labels, range(1, count + 1))
    piece = np.isin(labels, np.flatnonzero(sizes >= sizes.max() * 0.002) + 1)

    h, w = piece.shape
    side = int(max(h, w) * 1.04)
    canvas = np.zeros((side, side, 4), dtype=np.float32)
    y0, x0 = (side - h) // 2, (side - w) // 2
    region = canvas[y0 : y0 + h, x0 : x0 + w]
    value = np.where(stroke, 0.0, 255.0)
    region[..., 0] = value
    region[..., 1] = value
    region[..., 2] = value
    region[..., 3] = np.where(piece, 255.0, 0.0)
    # Premultiplied downscale: transparent pixels add no colour to the edge.
    image = Image.fromarray(canvas.astype(np.uint8), "RGBA").convert("RGBa")
    image = image.resize((OUT, OUT), Image.LANCZOS).convert("RGBA")
    image.save(OUTPUT)
    print(f"wrote {OUTPUT} ({OUT}x{OUT})")


if __name__ == "__main__":
    main()

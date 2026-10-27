#!/usr/bin/env python3
"""Cut the reference piece drawing into a transparent sprite sheet for Roblox.

Input:  assets/source/pieces-reference.jpg (two rows: white then black; columns K Q B N R P)
Output: assets/pieces.png, a 6 x 2 grid of CELL-pixel cells in the same order,
        and assets/pieces.rgba, the same pixels as raw RGBA bytes (row-major,
        no header). Studio can't decode PNGs from Luau, so tools/studio_sync
        style import code reads the raw file into an EditableImage and
        publishes it with AssetService:CreateAssetAsync. 1020x340 keeps it
        under the 1024px EditableImage limit.

The source is a small JPEG, so it is first enlarged UP times; working at that
size keeps the cut smooth instead of following the JPEG's blocky pixels.
The white background is removed by flood-filling light pixels from the image
border, so the white fill inside each white piece (and the white detail lines
inside the black pieces) stays opaque. The dark strokes are thickened by SEAL
pixels before the fill so it can't leak through hairline gaps in an outline,
and then the background is grown back over the light halo that leaves. The
outer edge gets a soft alpha from the stroke's darkness, and stray specks
(JPEG noise) are dropped.

Needs numpy, Pillow and scipy.
"""
import pathlib

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "source" / "pieces-reference.jpg"
OUTPUT = ROOT / "assets" / "pieces.png"
RAW = ROOT / "assets" / "pieces.rgba"
CELL = 170
UP = 4  # work at 4x the source size
LIGHT = 200  # pixels at least this bright can be background
SEAL = 4  # pixels (at UP size) of stroke thickening used to seal outline gaps
EDGE = 3  # width (at UP size) of the soft outer edge
NOTCH = 400  # light pockets smaller than this (at UP size) can be cut-off background
SPECK = 60  # opaque bits smaller than this (at UP size) are JPEG noise


def background_mask(gray: np.ndarray) -> np.ndarray:
    light = ~ndimage.binary_dilation(gray < LIGHT, iterations=SEAL)
    labels, _ = ndimage.label(light)
    border = np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))
    bg = np.isin(labels, border[border != 0])
    holes = light & ~bg  # the white fill inside pieces
    # Reclaim the halo the sealing left around each outline.
    bg |= ndimage.binary_dilation(bg, iterations=SEAL) & (gray >= LIGHT)
    # Light notches the sealing cut off (between a queen's points, say) are
    # small, touch the background and hold no white fill: background too.
    notches, count = ndimage.label((gray >= LIGHT) & ~bg)
    if count:
        index = range(1, count + 1)
        sizes = ndimage.sum(np.ones_like(gray), notches, index)
        filled = ndimage.maximum(holes, notches, index)
        touching = ndimage.maximum(ndimage.binary_dilation(bg), notches, index)
        drop = np.flatnonzero((sizes < NOTCH) & (filled == 0) & (touching > 0)) + 1
        bg |= np.isin(notches, drop)
    return bg


def runs(flags: np.ndarray, min_len: int):
    out, start = [], None
    for i, flag in enumerate(list(flags) + [False]):
        if flag and start is None:
            start = i
        elif not flag and start is not None:
            if i - start >= min_len:
                out.append((start, i))
            start = None
    return out


def main() -> None:
    source = Image.open(SOURCE).convert("RGB")
    big = source.resize((source.width * UP, source.height * UP), Image.BICUBIC)
    rgb = np.asarray(big).astype(np.float32)
    gray = rgb.mean(axis=2)
    bg = background_mask(gray)

    # Drop specks: opaque islands too small to be part of a piece.
    labels, count = ndimage.label(~bg)
    sizes = ndimage.sum(np.ones_like(gray), labels, range(1, count + 1))
    bg |= np.isin(labels, np.flatnonzero(sizes < SPECK) + 1)

    # Opaque everywhere except the background. The outer band is the outline,
    # so it is drawn black with an alpha from how dark the source is there,
    # which turns the grey anti-aliasing into a soft edge instead of a halo.
    alpha = np.where(bg, 0.0, 1.0)
    color = np.clip(rgb, 0, 255)
    band = ndimage.binary_dilation(bg, iterations=EDGE) & ~bg
    color[band] = 0
    alpha[band] = np.clip((255 - gray[band]) / (255 - 110), 0, 1)
    rgba = np.dstack([color, alpha * 255]).astype(np.uint8)

    solid = ~bg
    row_bands = runs(solid.any(axis=1), 20 * UP)
    assert len(row_bands) == 2, f"expected 2 rows of pieces, found {row_bands}"

    sheet = Image.new("RGBA", (CELL * 6, CELL * 2), (0, 0, 0, 0))
    image = Image.fromarray(rgba, "RGBA")
    for r, (y0, y1) in enumerate(row_bands):
        cols = runs(solid[y0:y1].any(axis=0), 20 * UP)
        assert len(cols) == 6, f"expected 6 pieces in row {r}, found {cols}"
        for c, (x0, x1) in enumerate(cols):
            ys = np.where(solid[y0:y1, x0:x1].any(axis=1))[0]
            piece = image.crop((x0, y0 + ys[0], x1, y0 + ys[-1] + 1))
            scale = (CELL * 0.86) / max(piece.width, piece.height)
            # Resize premultiplied so transparent pixels don't bleed colour into the edge.
            piece = piece.convert("RGBa").resize(
                (round(piece.width * scale), round(piece.height * scale)), Image.LANCZOS
            ).convert("RGBA")
            px = c * CELL + (CELL - piece.width) // 2
            py = r * CELL + round(CELL * 0.93) - piece.height
            sheet.alpha_composite(piece, (px, py))
    sheet.save(OUTPUT)
    RAW.write_bytes(sheet.tobytes())
    print(f"wrote {OUTPUT} ({sheet.width}x{sheet.height})")


if __name__ == "__main__":
    main()

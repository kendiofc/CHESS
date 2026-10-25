#!/usr/bin/env python3
"""Cut the reference piece drawing into a transparent sprite sheet for Roblox.

Input:  assets/source/pieces-reference.jpg (two rows: white then black; columns K Q B N R P)
Output: assets/pieces.png, a 6 x 2 grid of CELL-pixel cells in the same order.

The white background is removed by flood-filling light pixels from the image
border, so the white fill inside each white piece (and the white detail lines
inside the black pieces) stays opaque. The dark strokes are thickened by SEAL
pixels before the fill so it can't leak through hairline gaps in an outline,
and then the background is grown back over the light halo that leaves.
"""
import pathlib
from collections import deque

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "source" / "pieces-reference.jpg"
OUTPUT = ROOT / "assets" / "pieces.png"
CELL = 256
LIGHT = 200  # pixels at least this bright can be background
SEAL = 2  # pixels of stroke thickening used to seal outline gaps


def grow(mask: np.ndarray, steps: int) -> np.ndarray:
    out = mask.copy()
    for _ in range(steps):
        step = out.copy()
        step[1:, :] |= out[:-1, :]
        step[:-1, :] |= out[1:, :]
        step[:, 1:] |= out[:, :-1]
        step[:, :-1] |= out[:, 1:]
        out = step
    return out


def background_mask(gray: np.ndarray) -> np.ndarray:
    h, w = gray.shape
    light = (gray >= LIGHT) & ~grow(gray < LIGHT, SEAL)
    bg = np.zeros_like(light)
    queue = deque()
    for x in range(w):
        for y in (0, h - 1):
            if light[y, x] and not bg[y, x]:
                bg[y, x] = True
                queue.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if light[y, x] and not bg[y, x]:
                bg[y, x] = True
                queue.append((y, x))
    while queue:
        y, x = queue.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and light[ny, nx] and not bg[ny, nx]:
                bg[ny, nx] = True
                queue.append((ny, nx))
    # Reclaim the halo the sealing left around each outline.
    return bg | (grow(bg, SEAL) & (gray >= LIGHT))


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
    rgb = np.asarray(Image.open(SOURCE).convert("RGB")).astype(np.float32)
    gray = rgb.mean(axis=2)
    bg = background_mask(gray)

    # Opaque everywhere except the flood-filled background; soften the outer
    # anti-aliased edge by turning grey border pixels into partly transparent black.
    rgba = np.zeros(gray.shape + (4,), dtype=np.uint8)
    rgba[..., :3] = rgb.astype(np.uint8)
    rgba[..., 3] = np.where(bg, 0, 255)
    near_bg = np.zeros_like(bg)
    near_bg[1:, :] |= bg[:-1, :]
    near_bg[:-1, :] |= bg[1:, :]
    near_bg[:, 1:] |= bg[:, :-1]
    near_bg[:, :-1] |= bg[:, 1:]
    edge = near_bg & ~bg & (gray > 90)
    rgba[edge, :3] = 0
    rgba[edge, 3] = np.clip((255 - gray[edge]) * 1.6, 0, 255).astype(np.uint8)

    solid = ~bg
    row_bands = runs(solid.any(axis=1), 20)
    assert len(row_bands) == 2, f"expected 2 rows of pieces, found {row_bands}"

    sheet = Image.new("RGBA", (CELL * 6, CELL * 2), (0, 0, 0, 0))
    source = Image.fromarray(rgba, "RGBA")
    for r, (y0, y1) in enumerate(row_bands):
        cols = runs(solid[y0:y1].any(axis=0), 20)
        assert len(cols) == 6, f"expected 6 pieces in row {r}, found {cols}"
        for c, (x0, x1) in enumerate(cols):
            ys = np.where(solid[y0:y1, x0:x1].any(axis=1))[0]
            piece = source.crop((x0, y0 + ys[0], x1, y0 + ys[-1] + 1))
            scale = (CELL * 0.86) / max(piece.width, piece.height)
            piece = piece.resize((round(piece.width * scale), round(piece.height * scale)), Image.LANCZOS)
            px = c * CELL + (CELL - piece.width) // 2
            py = r * CELL + round(CELL * 0.93) - piece.height
            sheet.alpha_composite(piece, (px, py))
    sheet.save(OUTPUT)
    print(f"wrote {OUTPUT} ({sheet.width}x{sheet.height})")


if __name__ == "__main__":
    main()

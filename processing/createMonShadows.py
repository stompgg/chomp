#!/usr/bin/env python3
"""Generate per-frame ground shadows for each front idle sprite.

Overhead-light model: every occupied column of the silhouette projects onto the
ground; the footprint is inflated vertically into an ellipse-like blob whose
edge follows the column-mass profile (hard 1-bit edge, flat black — consumers
set the render opacity). One shadow frame per idle frame, packed into
mon_shadow.png + mon_shadow.json in the imgs directory.
"""

import math
import sys
from pathlib import Path
from PIL import Image

from createMonSpritesheets import (
    FRAME_SIZE,
    build_spritesheet,
    compact_json,
    extract_frames,
    find_96x96_gifs,
    save_and_compress_png,
)

ASPECT = 0.22        # max half-height as a fraction of the footprint half-width
MIN_HALF_HEIGHT = 3
SMOOTH_RADIUS = 4    # box-smooth radius for the column-mass profile
MASS_BLEND = 0.4     # how much column mass modulates the base ellipse edge


def column_mass(frame: Image.Image) -> list[int]:
    """Solid-pixel count per column (the 'mass' overhead at each x)."""
    alpha = frame.getchannel("A").load()
    return [
        sum(1 for y in range(frame.height) if alpha[x, y] > 0)
        for x in range(frame.width)
    ]


def smooth(values: list[float], radius: int) -> list[float]:
    out = []
    for i in range(len(values)):
        lo, hi = max(0, i - radius), min(len(values), i + radius + 1)
        out.append(sum(values[lo:hi]) / (hi - lo))
    return out


def shadow_frame(frame: Image.Image) -> tuple[Image.Image, float]:
    """96x96 1-bit shadow blob, columns aligned to the source sprite,
    vertically centered on the frame's middle row. Returns (image, footprint cx)."""
    mass = smooth([float(m) for m in column_mass(frame)], SMOOTH_RADIUS)
    occupied = [x for x, m in enumerate(mass) if m > 0]
    img = Image.new("RGBA", (FRAME_SIZE, FRAME_SIZE), (0, 0, 0, 0))
    if not occupied:
        return img, FRAME_SIZE / 2

    x0, x1 = min(occupied), max(occupied)
    cx = (x0 + x1) / 2
    rx = max(1.0, (x1 - x0) / 2)
    peak = max(mass)
    h_max = max(MIN_HALF_HEIGHT, round(rx * ASPECT))
    cy = FRAME_SIZE // 2
    px = img.load()

    for x in range(x0, x1 + 1):
        u = (x - cx) / rx
        base = math.sqrt(max(0.0, 1.0 - u * u))
        half = round(h_max * base * ((1 - MASS_BLEND) + MASS_BLEND * mass[x] / peak))
        for y in range(cy - half, cy + half + 1):
            px[x, y] = (0, 0, 0, 255)
    return img, cx


def create_shadows(imgs_dir: Path) -> None:
    front_gifs = [
        g for g in find_96x96_gifs(str(imgs_dir))
        if g.endswith("_front.gif") and "_front_damage" not in Path(g).name.lower()
    ]
    if not front_gifs:
        print(f"No *_front.gif files in {imgs_dir}")
        return

    metadata: dict = {}
    all_frames: list[Image.Image] = []
    entries: list[tuple[str, int, int, int, float]] = []  # (name, start, count, ms, cx)

    for gif in front_gifs:
        name = Path(gif).name.replace("_front.gif", "")
        frames, ms = extract_frames(gif)
        shadows = [shadow_frame(f) for f in frames]
        start = len(all_frames)
        all_frames.extend(img for img, _ in shadows)
        entries.append((name, start, len(shadows), ms, shadows[0][1]))
        widths = [img.getchannel("A").getbbox() for img, _ in shadows]
        w0 = widths[0][2] - widths[0][0] if widths[0] else 0
        print(f"{name}: {len(shadows)} shadow frames, footprint ~{w0}px wide")

    sheet, positions = build_spritesheet(all_frames, frame_size=FRAME_SIZE)
    save_and_compress_png(sheet, imgs_dir / "mon_shadow.png", "Shadow spritesheet")

    for name, start, count, ms, cx in entries:
        metadata[name] = {
            "msPerFrame": ms,
            "cx": cx,
            "frames": [list(positions[start + i]) for i in range(count)],
        }
    json_path = imgs_dir / "mon_shadow.json"
    json_path.write_text(compact_json(metadata))
    print(f"✅ Metadata saved to: {json_path}")
    print(f"Sheet size: {sheet.size[0]}x{sheet.size[1]}")


def main():
    target = Path(sys.argv[1]) if len(sys.argv) >= 2 else Path(__file__).parent.parent / "drool" / "imgs"
    if not target.is_dir():
        print(f"Error: Directory '{target}' does not exist")
        sys.exit(1)
    create_shadows(target)


if __name__ == "__main__":
    main()

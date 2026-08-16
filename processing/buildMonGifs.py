#!/usr/bin/env python3
"""Slice horizontal sprite sheets back into animated GIFs.

The reverse of createMonSpritesheets.py, for art delivered as a single-row
strip. Input files follow the existing sprite naming ({mon}_{category}.png);
the frame size is the sheet height, so the frame count is width // height.
Frame duration comes from the category's existing convention.

Usage:
  buildMonGifs.py                       # every recognized sheet in drool/imgs
  buildMonGifs.py sheets/               # a directory of sheets
  buildMonGifs.py aurox_front.png ...   # explicit files
  buildMonGifs.py --out-dir drool/imgs --force
  buildMonGifs.py --ms 150              # override the category duration
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

# Frame duration per category, measured from the existing GIFs in drool/imgs.
CATEGORY_MS = {
    "front": 100,
    "back": 200,
    "front_damage": 100,
    "mini": 200,
}

# Input suffixes that normalize onto a canonical category.
CATEGORY_ALIASES = {
    "hurt": "front_damage",
    "damage": "front_damage",
    "damage_front": "front_damage",
}

# Packed outputs of the forward pipeline — never inputs.
PACKED_SHEETS = {
    "mon_spritesheet.png",
    "mon_switch.png",
    "mon_mini.png",
    "mon_micro.png",
    "mon_shadow.png",
}

ALPHA_THRESHOLD = 128  # GIF alpha is 1-bit; anything fainter drops out
LOOP = 0
DISPOSAL = 2


def classify(png: Path) -> tuple[str, str] | None:
    """Split {mon}_{category}.png into (mon, canonical category), or None if the
    suffix is not a known sprite category."""
    if "_" not in png.stem:
        return None
    mon, suffix = png.stem.split("_", 1)
    category = CATEGORY_ALIASES.get(suffix, suffix)
    return (mon, category) if category in CATEGORY_MS else None


def slice_sheet(sheet: Image.Image) -> list[np.ndarray]:
    """Cut a single-row sheet into square frames of side == sheet height."""
    width, size = sheet.size
    if width % size:
        raise ValueError(f"width {width} is not a multiple of height {size}")
    rgba = np.asarray(sheet.convert("RGBA"))
    return [rgba[:, i * size : (i + 1) * size] for i in range(width // size)]


def pack_rgb(rgb: np.ndarray) -> np.ndarray:
    """(N, 3) uint8 -> (N,) int32 sort key, so colours dedupe in one pass."""
    channels = rgb.astype(np.int32)
    return (channels[:, 0] << 16) | (channels[:, 1] << 8) | channels[:, 2]


def save_gif(frames: list[np.ndarray], out_path: Path, duration: int) -> None:
    """Write an indexed GIF with a shared palette + transparent index 0."""
    masks = [f[..., 3] >= ALPHA_THRESHOLD for f in frames]
    opaque = [pack_rgb(f[m][:, :3]) for f, m in zip(frames, masks)]
    colors = np.unique(np.concatenate(opaque)) if any(len(o) for o in opaque) else np.empty(0, np.int32)
    if len(colors) > 255:
        raise ValueError(f"too many colours for a GIF palette: {len(colors)}")

    flat = [0, 0, 0]  # transparent placeholder
    for key in colors.tolist():
        flat.extend(((key >> 16) & 0xFF, (key >> 8) & 0xFF, key & 0xFF))
    flat.extend([0] * (768 - len(flat)))

    pal_frames = []
    for frame, mask, keys in zip(frames, masks, opaque):
        idx = np.zeros(frame.shape[:2], dtype=np.uint8)
        idx[mask] = np.searchsorted(colors, keys) + 1
        img = Image.fromarray(idx, mode="P")
        img.putpalette(flat)
        pal_frames.append(img)

    pal_frames[0].save(
        out_path,
        save_all=True,
        append_images=pal_frames[1:],
        duration=duration,
        loop=LOOP,
        disposal=DISPOSAL,
        transparency=0,
        optimize=False,
    )


def convert(png: Path, out_dir: Path, ms: int | None, force: bool, dry_run: bool) -> bool:
    classified = classify(png)
    if classified is None:
        print(f"  ⚠ Skipping {png.name}: unrecognized category (expected one of {', '.join(sorted(CATEGORY_MS))})")
        return False
    mon, category = classified

    gif_path = out_dir / f"{mon}_{category}.gif"
    if gif_path.exists() and not force:
        print(f"  ⚠ Skipping {png.name}: {gif_path.name} exists (pass --force to overwrite)")
        return False

    with Image.open(png) as sheet:
        frames = slice_sheet(sheet)
    duration = ms if ms is not None else CATEGORY_MS[category]

    partial = sum(int(np.count_nonzero((f[..., 3] > 0) & (f[..., 3] < ALPHA_THRESHOLD))) for f in frames)
    if partial:
        print(f"  ⚠ {png.name}: dropped {partial} px below alpha {ALPHA_THRESHOLD}")

    size = frames[0].shape[0]
    if dry_run:
        print(f"  · {png.name} -> {gif_path.name} ({len(frames)} x {size}px @ {duration}ms)")
        return True

    save_gif(frames, gif_path, duration)
    print(f"  ✓ {png.name} -> {gif_path.name} ({len(frames)} x {size}px @ {duration}ms)")
    return True


def collect(inputs: list[str], default_dir: Path) -> list[Path]:
    if not inputs:
        return [p for p in sorted(default_dir.glob("*.png")) if p.name not in PACKED_SHEETS]
    paths = []
    for raw in inputs:
        path = Path(raw)
        if path.is_dir():
            paths.extend(p for p in sorted(path.glob("*.png")) if p.name not in PACKED_SHEETS)
        else:
            paths.append(path)
    return paths


def main() -> None:
    base = Path(__file__).parent.parent
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="*", help="sheet PNGs or a directory (default: drool/imgs)")
    parser.add_argument("--out-dir", help="where to write the GIFs (default: alongside each sheet)")
    parser.add_argument("--ms", type=int, help="override the category frame duration")
    parser.add_argument("--force", action="store_true", help="overwrite existing GIFs")
    parser.add_argument("--dry-run", action="store_true", help="report what would be written")
    args = parser.parse_args()

    default_dir = base / "drool" / "imgs"
    sheets = collect(args.inputs, default_dir)
    if not sheets:
        print("No PNG sheets found")
        sys.exit(1)

    missing = [p for p in sheets if not p.is_file()]
    if missing:
        print(f"Error: no such file: {missing[0]}")
        sys.exit(1)

    out_dir = Path(args.out_dir) if args.out_dir else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Converting {len(sheets)} sheet(s)")
    converted = 0
    for png in sheets:
        try:
            converted += convert(png, out_dir or png.parent, args.ms, args.force, args.dry_run)
        except ValueError as e:
            print(f"  ✗ {png.name}: {e}")

    if not converted:
        print("\nNothing converted")
        sys.exit(1)
    print(f"\n✅ Done — {converted} GIF(s)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Generate 16x16 icons from 32x32 *_mini.gif files.

Pixel-art-aware downscale pipeline (per GIF, shared across all frames):

  1. Collect the source palette (every unique RGB used by an opaque pixel
     across all frames) — this becomes the snap-target later.
  2. Smooth jagged 1-px notches on the alpha mask with a 3x3 median filter
     (RGB untouched). Optional.
  3. Downscale 32 -> 16 using alpha-weighted 2x2 area averaging so
     transparent pixels do not bleed colour into edge pixels.
  4. Threshold the averaged alpha back to a binary mask.
  5. If the silhouette is too thin (opaque-count below FATTEN_RATIO * 1/4 of
     the source opaque-count), dilate by 1 px using the mean colour of
     opaque 4-neighbours.
  6. Snap every opaque pixel's RGB to the nearest source palette entry so
     the final colours feel consistent with the original 32x32 image.
  7. Save the frames as a transparent GIF with the same duration / loop as
     the source.

Usage:
  make_icons.py                          # all *_mini.gif -> icons/*_icon.gif
  make_icons.py aurox_mini.gif           # one file
  make_icons.py --out-dir icons16        # custom output dir
  make_icons.py --no-smooth              # skip alpha median filter
  make_icons.py --no-fatten              # never dilate
  make_icons.py --debug                  # also write an 8x-upscaled preview PNG
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ALPHA_THRESHOLD = 96       # alpha >= this -> opaque after downscale
FATTEN_RATIO = 0.80        # dilate if opaque_px < this * expected
TARGET_SIZE = 16


def load_frames(path: Path) -> tuple[list[np.ndarray], int]:
    im = Image.open(path)
    duration = im.info.get("duration", 200)
    frames = []
    for i in range(im.n_frames):
        im.seek(i)
        frames.append(np.array(im.convert("RGBA")))
    return frames, duration


def extract_palette(frames: list[np.ndarray]) -> np.ndarray:
    """Return all unique opaque RGB colours across frames, ordered by frequency."""
    pixels = []
    for f in frames:
        mask = f[..., 3] > 0
        pixels.append(f[mask][:, :3])
    all_px = np.concatenate(pixels)
    unique, counts = np.unique(all_px, axis=0, return_counts=True)
    order = np.argsort(-counts)
    return unique[order]


def smooth_alpha(frame: np.ndarray) -> np.ndarray:
    """Round 1-px notches on the alpha mask. RGB is left alone."""
    img = Image.fromarray(frame)
    r, g, b, a = img.split()
    a = a.filter(ImageFilter.MedianFilter(3))
    return np.array(Image.merge("RGBA", (r, g, b, a)))


def downscale(frame: np.ndarray, target: int) -> np.ndarray:
    """Alpha-weighted 2x2 (or NxN) area average to (target, target, 4) RGBA."""
    src_h, src_w = frame.shape[:2]
    bh, bw = src_h // target, src_w // target
    out = np.zeros((target, target, 4), dtype=np.uint8)
    f = frame.astype(np.float32)
    for y in range(target):
        for x in range(target):
            block = f[y * bh:(y + 1) * bh, x * bw:(x + 1) * bw]
            a = block[..., 3]
            total_a = a.sum()
            avg_a = a.mean()
            if total_a == 0:
                continue
            w = (a / total_a)[..., None]
            rgb = (block[..., :3] * w).sum(axis=(0, 1))
            out[y, x, :3] = np.clip(rgb, 0, 255).astype(np.uint8)
            out[y, x, 3] = int(round(avg_a))
    return out


def binarize_alpha(frame: np.ndarray, threshold: int = ALPHA_THRESHOLD) -> np.ndarray:
    """Snap alpha to {0, 255}."""
    out = frame.copy()
    opaque = out[..., 3] >= threshold
    out[..., 3] = np.where(opaque, 255, 0).astype(np.uint8)
    # Zero out RGB on transparent pixels so palette-snap never sees them.
    out[~opaque, :3] = 0
    return out


def fatten(frame: np.ndarray) -> np.ndarray:
    """Dilate silhouette by 1 px; new pixels take the mean of opaque 4-neighbours."""
    out = frame.copy()
    h, w = out.shape[:2]
    opaque = out[..., 3] == 255
    additions: list[tuple[int, int, np.ndarray]] = []
    for y in range(h):
        for x in range(w):
            if opaque[y, x]:
                continue
            neigh = []
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and opaque[ny, nx]:
                    neigh.append(out[ny, nx, :3])
            if neigh:
                additions.append((y, x, np.mean(neigh, axis=0).astype(np.uint8)))
    for y, x, rgb in additions:
        out[y, x, :3] = rgb
        out[y, x, 3] = 255
    return out


def snap_palette(frame: np.ndarray, palette: np.ndarray) -> np.ndarray:
    """For every opaque pixel, replace RGB with the nearest palette entry."""
    out = frame.copy()
    opaque = out[..., 3] == 255
    if not opaque.any():
        return out
    px = out[opaque][:, :3].astype(np.int32)
    pal = palette.astype(np.int32)
    diffs = px[:, None, :] - pal[None, :, :]
    dists = np.sum(diffs * diffs, axis=2)
    nearest = pal[np.argmin(dists, axis=1)]
    out_rgb = out[..., :3].copy()
    out_rgb[opaque] = nearest.astype(np.uint8)
    out[..., :3] = out_rgb
    return out


def save_gif(frames_rgba: list[np.ndarray], out_path: Path, duration: int, loop: int) -> None:
    """Write an indexed GIF with a shared palette + transparent index 0."""
    seen: dict[tuple, int] = {}
    colors: list[tuple] = []
    for f in frames_rgba:
        opaque = f[..., 3] == 255
        for px in f[opaque][:, :3]:
            t = (int(px[0]), int(px[1]), int(px[2]))
            if t not in seen:
                seen[t] = len(colors) + 1  # index 0 reserved for transparent
                colors.append(t)
    if len(colors) > 255:
        raise ValueError(f"Too many colours for GIF palette: {len(colors)}")

    flat = [0, 0, 0]  # transparent placeholder
    for c in colors:
        flat.extend(c)
    flat.extend([0] * (768 - len(flat)))

    pal_frames = []
    for f in frames_rgba:
        h, w = f.shape[:2]
        idx = np.zeros((h, w), dtype=np.uint8)
        opaque = f[..., 3] == 255
        ys, xs = np.where(opaque)
        for y, x in zip(ys, xs):
            t = (int(f[y, x, 0]), int(f[y, x, 1]), int(f[y, x, 2]))
            idx[y, x] = seen[t]
        img = Image.fromarray(idx, mode="P")
        img.putpalette(flat)
        pal_frames.append(img)

    pal_frames[0].save(
        out_path,
        save_all=True,
        append_images=pal_frames[1:],
        duration=duration,
        loop=loop,
        disposal=2,
        transparency=0,
        optimize=False,
    )


def process(
    src: Path,
    dst: Path,
    *,
    smooth: bool = True,
    allow_fatten: bool = True,
    debug: bool = False,
) -> None:
    frames, duration = load_frames(src)
    palette = extract_palette(frames)

    processed = []
    for fi, frame in enumerate(frames):
        src_opaque = int((frame[..., 3] > 0).sum())

        f = smooth_alpha(frame) if smooth else frame
        f = downscale(f, TARGET_SIZE)
        f = binarize_alpha(f)

        cur_opaque = int((f[..., 3] == 255).sum())
        expected = src_opaque / 4
        if allow_fatten and cur_opaque < FATTEN_RATIO * expected:
            f = fatten(f)
            after = int((f[..., 3] == 255).sum())
            print(f"  frame {fi}: fattened {cur_opaque} -> {after} (expected ~{expected:.0f})")

        f = snap_palette(f, palette)
        processed.append(f)

    save_gif(processed, dst, duration=duration, loop=0)

    if debug:
        # 8x-upscaled PNG of frame 0 for eyeballing.
        big = Image.fromarray(processed[0]).resize(
            (TARGET_SIZE * 8, TARGET_SIZE * 8), Image.NEAREST
        )
        big.save(dst.with_suffix(".preview.png"))


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("files", nargs="*", help="Input GIFs (default: *_mini.gif in cwd)")
    p.add_argument("--out-dir", default="icons", help="Output directory (default: icons/)")
    p.add_argument("--no-smooth", action="store_true", help="Skip alpha median filter")
    p.add_argument("--no-fatten", action="store_true", help="Skip silhouette dilation")
    p.add_argument("--debug", action="store_true", help="Also write 8x preview PNGs")
    args = p.parse_args()

    if args.files:
        files = [Path(f) for f in args.files]
    else:
        files = sorted(Path.cwd().glob("*_mini.gif"))
    if not files:
        print("No input files", file=sys.stderr)
        return 1

    out_dir = Path(args.out_dir)
    out_dir.mkdir(exist_ok=True)

    for f in files:
        stem = f.stem.replace("_mini", "_icon")
        dst = out_dir / f"{stem}.gif"
        print(f"{f.name} -> {dst}")
        process(
            f, dst,
            smooth=not args.no_smooth,
            allow_fatten=not args.no_fatten,
            debug=args.debug,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())

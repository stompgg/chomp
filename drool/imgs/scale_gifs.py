#!/usr/bin/env python3
"""Scale GIFs with ImageMagick using nearest-neighbor (preserves pixel art).

Single-step:
  scale_gifs.py --suffix _mini --scale 800      # 8x upscale
  scale_gifs.py --suffix _mini --scale 50       # 0.5x downscale

Two-step (downscale first, then upscale — pixelates while changing size):
  scale_gifs.py --suffix _mini --down 25 --up 800   # net 2x, pixelated
"""

import argparse
import subprocess
import sys
from pathlib import Path


def magick_resize(src: Path, dst: Path, percent: float) -> None:
    subprocess.run(
        [
            "magick", str(src),
            "-filter", "point",
            "-interpolate", "nearest",
            "-resize", f"{percent}%",
            str(dst),
        ],
        check=True,
    )


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("--suffix", required=True,
                   help="Input filename suffix (e.g. _mini matches *_mini.gif)")
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument("--scale", type=float,
                      help="Single-step scale percent (e.g. 800 = 8x, 50 = 0.5x)")
    mode.add_argument("--down", type=float,
                      help="Two-step: downscale percent (requires --up)")
    p.add_argument("--up", type=float,
                   help="Two-step: upscale percent (requires --down)")
    args = p.parse_args()

    if (args.down is None) != (args.up is None):
        p.error("--down and --up must be used together")

    steps = [args.scale] if args.scale is not None else [args.down, args.up]

    net_ratio = 1.0
    for s in steps:
        net_ratio *= s / 100
    tag = f"_{net_ratio:g}x"

    pattern = f"*{args.suffix}.gif"
    files = sorted(Path.cwd().glob(pattern))
    if not files:
        print(f"No files matching {pattern}", file=sys.stderr)
        return 1

    out_dir = Path.cwd() / "scaled"
    out_dir.mkdir(exist_ok=True)

    for f in files:
        out = out_dir / f"{f.stem}{tag}.gif"

        if len(steps) == 1:
            magick_resize(f, out, steps[0])
        else:
            tmp = out_dir / f"{f.stem}_tmp_down.gif"
            try:
                magick_resize(f, tmp, steps[0])
                magick_resize(tmp, out, steps[1])
            finally:
                tmp.unlink(missing_ok=True)

        print(f"Scaled: {f.name} → scaled/{out.name}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

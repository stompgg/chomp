#!/usr/bin/env python3
"""Rename *_damage_front.png sheets to *_front_damage.png and convert them to
4-frame 96x96 animated GIFs that match the existing front-gif format."""

import sys
from pathlib import Path
from PIL import Image

FRAME_SIZE = 96
NUM_FRAMES = 4
FRAME_DURATION_MS = 100  # matches existing {mon}_front.gif frame timing


def rename_damage_pngs(source_dir: Path) -> list[Path]:
    """Rename *_damage_front.png -> *_front_damage.png in place. Returns the
    full set of *_front_damage.png paths (including any that were already
    correctly named)."""
    for old in sorted(source_dir.glob("*_damage_front.png")):
        new = old.with_name(old.name.replace("_damage_front.png", "_front_damage.png"))
        if new.exists() and new != old:
            print(f"  ⚠ Skipping rename, target exists: {new.name}")
            continue
        old.rename(new)
        print(f"  ✓ Renamed {old.name} -> {new.name}")
    return sorted(source_dir.glob("*_front_damage.png"))


def png_sheet_to_gif(png_path: Path, gif_path: Path) -> None:
    """Slice a horizontal NUM_FRAMES x 1 sprite sheet into individual frames and
    save as an animated GIF."""
    sheet = Image.open(png_path).convert("RGBA")
    expected = (FRAME_SIZE * NUM_FRAMES, FRAME_SIZE)
    if sheet.size != expected:
        raise ValueError(f"{png_path.name}: expected {expected[0]}x{expected[1]}, got {sheet.size[0]}x{sheet.size[1]}")

    frames = [
        sheet.crop((i * FRAME_SIZE, 0, (i + 1) * FRAME_SIZE, FRAME_SIZE))
        for i in range(NUM_FRAMES)
    ]
    frames[0].save(
        gif_path,
        save_all=True,
        append_images=frames[1:],
        duration=FRAME_DURATION_MS,
        loop=0,
        disposal=2,
        transparency=0,
        optimize=False,
    )


def run(source_dir: str = None, output_dir: str = None) -> bool:
    base = Path(__file__).parent.parent
    src = Path(source_dir) if source_dir else base / "drool" / "imgs"
    out = Path(output_dir) if output_dir else base / "drool" / "imgs"

    if not src.is_dir():
        print(f"Error: source dir '{src}' does not exist")
        return False
    out.mkdir(parents=True, exist_ok=True)

    print(f"Renaming damage sheets in: {src}")
    pngs = rename_damage_pngs(src)
    if not pngs:
        print("No *_damage_front.png or *_front_damage.png files found")
        return False

    print(f"\nConverting {len(pngs)} sheets to GIFs in: {out}")
    for png in pngs:
        gif_path = out / (png.stem + ".gif")
        png_sheet_to_gif(png, gif_path)
        print(f"  ✓ {png.name} -> {gif_path.name}")

    print("\n✅ Done!")
    return True


def main() -> None:
    src = sys.argv[1] if len(sys.argv) >= 2 else None
    out = sys.argv[2] if len(sys.argv) >= 3 else None
    if not run(src, out):
        sys.exit(1)


if __name__ == "__main__":
    main()

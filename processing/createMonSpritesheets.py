#!/usr/bin/env python3
"""Create spritesheets from 96x96 GIF files with JSON metadata."""

import json
import math
import random
import subprocess
import sys
from pathlib import Path
from PIL import Image

FRAME_SIZE = 96
MORPH_FRAMES = 8

def find_96x96_gifs(directory: str) -> list[str]:
    """Find all 96x96 GIF files in the target directory."""
    result = []
    for f in sorted(Path(directory).glob("*.gif")):
        try:
            with Image.open(f) as img:
                if img.size == (FRAME_SIZE, FRAME_SIZE):
                    result.append(str(f))
        except Exception as e:
            print(f"Warning: Could not read {f}: {e}")
    return result


def extract_frames(gif_path: str) -> tuple[list[Image.Image], int]:
    """Extract all frames from a GIF file."""
    with Image.open(gif_path) as img:
        frame_rate = img.info.get('duration', 100)
        return [img.seek(i) or img.convert('RGBA').copy() for i in range(img.n_frames)], frame_rate


def to_white_silhouette(frame: Image.Image) -> Image.Image:
    """Convert frame to white pixels preserving transparency."""
    result = Image.new('RGBA', frame.size, (0, 0, 0, 0))
    result.putdata([(255, 255, 255, 255) if p[3] > 0 else (0, 0, 0, 0) for p in frame.getdata()])
    return result


def create_morph_animation(start_frame: Image.Image, is_back: bool = False) -> list[Image.Image]:
    """Create morphing animation from sprite to diamond shape."""
    w, h = start_frame.size
    cx, cy = (w // 4, int(h * 0.65)) if is_back else (w // 2, h // 2)
    dw, dh = 4.0, 7.0  # half diamond dimensions

    # Get white pixel positions
    white_pixels = [(x, y) for y in range(h) for x in range(w) if start_frame.getpixel((x, y))[3] > 0]
    diamond_pixels = [(x, y) for y in range(h) for x in range(w) if abs(x - cx) / dw + abs(y - cy) / dh <= 1.0]
    total_start, total_final = len(white_pixels), len(diamond_pixels)

    # Assign targets with bezier control points
    pixel_data = []
    edge_dist = min(dw, dh) * 0.8
    for i, (sx, sy) in enumerate(white_pixels):
        if i < total_final:
            tx, ty = diamond_pixels[i]
        else:
            angle = random.uniform(0, 2 * math.pi)
            tx, ty = cx + int(edge_dist * math.cos(angle)), cy + int(edge_dist * math.sin(angle))
        pixel_data.append((sx, sy, tx, ty, (sx + tx) / 2 + random.uniform(-8, 8), (sy + ty) / 2 + random.uniform(-8, 8), i < total_final))

    frames = []
    for f in range(MORPH_FRAMES):
        frame = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        progress = f / (MORPH_FRAMES - 1)
        t = 0.5 * (1 - math.cos(progress * math.pi))  # eased progress
        deform = math.sin(progress * math.pi) * 3
        visible_count = max(int(total_start * (1 - progress * 0.4) + total_final * progress * 0.4), total_final)

        for i, (sx, sy, tx, ty, ctrlx, ctrly, survives) in enumerate(pixel_data):
            # Bezier interpolation
            px = (1-t)**2 * sx + 2*(1-t)*t * ctrlx + t**2 * tx
            py = (1-t)**2 * sy + 2*(1-t)*t * ctrly + t**2 * ty
            # Radial deformation
            dx, dy = px - cx, py - cy
            dist = (dx**2 + dy**2)**0.5
            if dist > 0:
                factor = 1 + deform * math.sin(progress * 2 * math.pi) / dist
                px, py = cx + dx * factor, cy + dy * factor
            x, y = int(round(px)), int(round(py))
            if (survives or i < visible_count) and 0 <= x < w and 0 <= y < h:
                frame.putpixel((x, y), (255, 255, 255, 255))
        frames.append(frame)
    return frames


def build_spritesheet(frames: list[Image.Image]) -> tuple[Image.Image, list[tuple[int, int]]]:
    """Create spritesheet image and return frame positions."""
    cols = math.ceil(math.sqrt(len(frames)))
    rows = math.ceil(len(frames) / cols)
    sheet = Image.new('RGBA', (cols * FRAME_SIZE, rows * FRAME_SIZE), (0, 0, 0, 0))
    positions = []
    for i, frame in enumerate(frames):
        x, y = (i % cols) * FRAME_SIZE, (i // cols) * FRAME_SIZE
        sheet.paste(frame, (x, y))
        positions.append((x, y))
    return sheet, positions


def run_pngout(png_path: Path) -> None:
    """Run pngout compression on a PNG file."""
    try:
        result = subprocess.run(
            ["pngout", str(png_path)],
            capture_output=True,
            text=True,
            timeout=60
        )
        if result.returncode == 0:
            print(f"  ✓ Compressed with pngout")
        else:
            print(f"  ⚠ pngout warning (non-zero exit): {result.returncode}")
    except FileNotFoundError:
        print(f"  ⚠ pngout not found, skipping compression")
    except subprocess.TimeoutExpired:
        print(f"  ⚠ pngout timed out")
    except Exception as e:
        print(f"  ⚠ pngout error: {e}")


def save_and_compress_png(sheet: Image.Image, path: Path, description: str) -> None:
    """Save a PNG and run pngout compression on it."""
    sheet.save(path, "PNG")
    print(f"✅ {description} saved: {sheet.size[0]}x{sheet.size[1]} -> {path}")
    run_pngout(path)


def create_spritesheets(gif_files: list[str], output_dir: str):
    """Create main and switch spritesheets with combined metadata."""
    metadata = {}
    all_frames, all_switch_frames = [], []

    for gif_path in gif_files:
        name = Path(gif_path).name
        frames, frame_rate = extract_frames(gif_path)
        print(f"Extracted {len(frames)} frames from {name} (frame rate: {frame_rate}ms)")

        # Main animation frames
        frame_start = len(all_frames)
        all_frames.extend(frames)
        metadata[name] = {"msPerFrame": frame_rate, "_main_start": frame_start, "_main_count": len(frames)}

        # Switch animation frames
        white = to_white_silhouette(frames[0])
        morph = create_morph_animation(white, is_back="back" in name.lower())
        switch_start = len(all_switch_frames)
        all_switch_frames.extend(morph)
        metadata[name]["_switch_start"] = switch_start
        metadata[name]["_switch_count"] = len(morph)
        print(f"Generated {len(morph)} switch frames for {name}")

    # Build main spritesheet
    sheet, positions = build_spritesheet(all_frames)
    output_path = Path(output_dir)

    # Save to output directory
    main_sheet_path = output_path / "mon_spritesheet.png"
    save_and_compress_png(sheet, main_sheet_path, "Spritesheet")

    # Build switch spritesheet
    switch_sheet, switch_positions = build_spritesheet(all_switch_frames)
    switch_sheet_path = output_path / "mon_switch.png"
    save_and_compress_png(switch_sheet, switch_sheet_path, "Switch spritesheet")

    # Determine munch output location (similar to drool/combine.py)
    base_path = Path(__file__).parent
    game_dir = base_path.parent.parent
    munch_assets_dir = game_dir / "munch" / "src" / "assets" / "mons" / "all"

    # Copy to munch if directory exists
    if munch_assets_dir.exists():
        print(f"\n📋 Copying to munch repository: {munch_assets_dir}")

        munch_main_path = munch_assets_dir / "mon_spritesheet.png"
        save_and_compress_png(sheet, munch_main_path, "Munch spritesheet")

        munch_switch_path = munch_assets_dir / "mon_switch.png"
        save_and_compress_png(switch_sheet, munch_switch_path, "Munch switch spritesheet")
    else:
        print(f"\n⚠ Munch directory not found, skipping copy: {munch_assets_dir}")

    # Finalize metadata
    for name, data in metadata.items():
        main_start, main_count = data.pop("_main_start"), data.pop("_main_count")
        switch_start, switch_count = data.pop("_switch_start"), data.pop("_switch_count")
        data["frames"] = [list(positions[main_start + i]) for i in range(main_count)]
        switch_frames = [list(switch_positions[switch_start + i]) for i in range(switch_count)]
        data["switchOut"] = {"msPerFrame": 100, "frames": switch_frames}
        data["switchIn"] = {"msPerFrame": 100, "frames": switch_frames[::-1]}

    # Save JSON with compact coordinate arrays
    json_path = Path(output_dir) / "spritesheet.json"
    json_path.write_text(compact_json(metadata))
    print(f"✅ Metadata saved to: {json_path}")

def compact_json(obj, indent=2):
    """JSON with objects indented but all arrays inline."""
    def format_value(v, level):
        if isinstance(v, dict):
            if not v:
                return '{}'
            items = []
            for k, val in v.items():
                items.append(' ' * (level + indent) + json.dumps(k) + ': ' + format_value(val, level + indent))
            return '{\n' + ',\n'.join(items) + '\n' + ' ' * level + '}'
        elif isinstance(v, list):
            return json.dumps(v)  # All arrays inline, no indentation
        else:
            return json.dumps(v)
    
    return format_value(obj, 0)

def run(target_dir: str = None) -> bool:
    """
    Run mon spritesheet generation. Returns True on success, False on failure.

    Args:
        target_dir: Directory containing GIF files. Defaults to drool/imgs/
    """
    if target_dir is None:
        target_dir = str(Path(__file__).parent.parent / "drool" / "imgs")

    if not Path(target_dir).is_dir():
        print(f"Error: Directory '{target_dir}' does not exist")
        return False

    print(f"Searching for 96x96 GIF files in: {target_dir}\n")
    gif_files = find_96x96_gifs(target_dir)

    if not gif_files:
        print("No 96x96 GIF files found")
        return False

    print(f"Found {len(gif_files)} GIF files:")
    for gif in gif_files:
        print(f"  - {Path(gif).name}")

    print("\n" + "=" * 50)
    create_spritesheets(gif_files, target_dir)
    print("\n✅ Done!")
    return True


def main():
    """CLI entry point."""
    target_dir = sys.argv[1] if len(sys.argv) >= 2 else None
    if not run(target_dir):
        sys.exit(1)


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""Create spritesheets from attack animation PNG files with JSON metadata."""

import hashlib
import json
import math
import subprocess
import sys
from pathlib import Path
from PIL import Image

DEFAULT_FRAME_SIZE = 96

# Special case: files with non-standard frame sizes (width, height)
# For most files, width == height (square frames)
# The chain_expansion pair is full-field: 360x180 for the desktop canvas (2:1),
# 240x180 for mobile's (4:3) — the same field drawn at two aspects, not scaled.
SPECIAL_FRAME_SIZES = {
    "stat_boost_player": (106, 106),
    "stat_debuff_player": (128, 128),  # Source 128x128, cropped to 106x106
    "chain_expansion": (360, 180),
    "chain_expansion_sm": (240, 180),
}

# Special case: files that need cropping (top, right, bottom, left) - applied before flip
FRAME_CROP = {
    "stat_debuff_player": (22, 11, 0, 11),  # Crop 128x128 to 106x106
}

# Special case: gachachacha variants share many frames
GACHACHACHA_VARIANTS = ["gachachacha_bunnies", "gachachacha_carrots", "gachachacha_skulls"]

# Special case: files that need vertical flip applied to each frame
VERTICAL_FLIP_FILES = {"stat_boost_enemy", "stat_debuff_player"}

# Output files to exclude from input scanning
OUTPUT_FILES = {"attack_spritesheet.png", "non_standard_spritesheet.png"}


def find_valid_attack_pngs(directory: str) -> list[tuple[str, int, int, tuple[int, int], tuple[int, int]]]:
    """Find all PNG files whose dimensions are evenly divisible by their frame size.

    Returns list of (path, cols, rows, source_frame_size, output_frame_size) tuples.
    Frame sizes are (width, height) tuples.
    """
    result = []
    for f in sorted(Path(directory).glob("*.png")):
        if f.name in OUTPUT_FILES:
            continue
        try:
            name = f.stem
            size_info = SPECIAL_FRAME_SIZES.get(name)
            if size_info:
                source_w, source_h = size_info
                # Calculate output size after cropping
                crop = FRAME_CROP.get(name)
                if crop:
                    top, right, bottom, left = crop
                    output_w = source_w - left - right
                    output_h = source_h - top - bottom
                else:
                    output_w, output_h = source_w, source_h
            else:
                source_w = source_h = output_w = output_h = DEFAULT_FRAME_SIZE

            with Image.open(f) as img:
                w, h = img.size
                if w % source_w == 0 and h % source_h == 0:
                    cols = w // source_w
                    rows = h // source_h
                    result.append((str(f), cols, rows, (source_w, source_h), (output_w, output_h)))
                else:
                    print(f"⚠ Skipping {f.name}: {w}x{h} not divisible by {source_w}x{source_h}")
        except Exception as e:
            print(f"Warning: Could not read {f}: {e}")
    return result


def extract_frames_from_spritesheet(
    png_path: str, cols: int, rows: int, frame_size: tuple[int, int] = (DEFAULT_FRAME_SIZE, DEFAULT_FRAME_SIZE),
    crop: tuple[int, int, int, int] | None = None, vertical_flip: bool = False
) -> list[Image.Image]:
    """Extract all frames from a spritesheet PNG (left-to-right, top-to-bottom).

    Args:
        frame_size: (width, height) of each frame
        crop: Optional (top, right, bottom, left) pixels to crop from each frame.
              Applied before vertical flip.
    """
    frames = []
    frame_w, frame_h = frame_size
    with Image.open(png_path) as img:
        img = img.convert('RGBA')
        for row in range(rows):
            for col in range(cols):
                x = col * frame_w
                y = row * frame_h
                frame = img.crop((x, y, x + frame_w, y + frame_h))
                if crop:
                    top, right, bottom, left = crop
                    frame = frame.crop((left, top, frame_w - right, frame_h - bottom))
                if vertical_flip:
                    frame = frame.transpose(Image.FLIP_TOP_BOTTOM)
                frames.append(frame.copy())
    return frames


def frame_hash(frame: Image.Image) -> str:
    """Compute a hash for a frame to detect duplicates."""
    return hashlib.md5(frame.tobytes()).hexdigest()


def process_gachachacha_variants(
    variant_data: list[tuple[str, int, int, tuple[int, int]]]
) -> tuple[list[Image.Image], dict[str, list[int]]]:
    """Process gachachacha variants, deduplicating shared frames.

    Returns:
        - List of unique frames (shared frames first, then unique frames per variant)
        - Dict mapping variant name to list of frame indices
    """
    # Extract frames from all variants
    variant_frames: dict[str, list[Image.Image]] = {}
    for png_path, cols, rows, source_size in variant_data:
        name = Path(png_path).stem
        variant_frames[name] = extract_frames_from_spritesheet(png_path, cols, rows, source_size)
        print(f"Extracted {len(variant_frames[name])} frames from {Path(png_path).name} ({cols}x{rows} grid)")

    # All variants should have same frame count
    frame_count = len(next(iter(variant_frames.values())))
    variant_names = list(variant_frames.keys())

    # Identify shared vs unique frames by comparing hashes
    unique_frames: list[Image.Image] = []
    frame_hash_to_index: dict[str, int] = {}
    variant_indices: dict[str, list[int]] = {name: [] for name in variant_names}

    for frame_idx in range(frame_count):
        # Get frames and hashes for this position across all variants
        frames_at_pos = [(name, variant_frames[name][frame_idx]) for name in variant_names]
        hashes_at_pos = [(name, frame_hash(frame)) for name, frame in frames_at_pos]

        # Check if all variants have the same frame at this position
        all_same = len(set(h for _, h in hashes_at_pos)) == 1

        if all_same:
            # Shared frame - use first variant's frame, reuse index for all
            h = hashes_at_pos[0][1]
            if h not in frame_hash_to_index:
                frame_hash_to_index[h] = len(unique_frames)
                unique_frames.append(frames_at_pos[0][1])
            idx = frame_hash_to_index[h]
            for name in variant_names:
                variant_indices[name].append(idx)
        else:
            # Different frames - add each variant's unique frame
            for name, frame in frames_at_pos:
                h = frame_hash(frame)
                if h not in frame_hash_to_index:
                    frame_hash_to_index[h] = len(unique_frames)
                    unique_frames.append(frame)
                variant_indices[name].append(frame_hash_to_index[h])

    total_original = frame_count * len(variant_names)
    print(f"  → Deduplicated: {total_original} frames -> {len(unique_frames)} unique frames")

    return unique_frames, variant_indices


def build_spritesheet(frames: list[Image.Image], frame_size: tuple[int, int]) -> tuple[Image.Image, list[tuple[int, int]]]:
    """Create spritesheet image and return frame positions.

    Args:
        frames: List of frames to pack into spritesheet
        frame_size: (width, height) of each frame
    """
    frame_w, frame_h = frame_size
    cols = math.ceil(math.sqrt(len(frames)))
    rows = math.ceil(len(frames) / cols)
    sheet = Image.new('RGBA', (cols * frame_w, rows * frame_h), (0, 0, 0, 0))
    positions = []
    for i, frame in enumerate(frames):
        x, y = (i % cols) * frame_w, (i // cols) * frame_h
        sheet.paste(frame, (x, y))
        positions.append((x, y))
    return sheet, positions


def run_oxipng(png_path: Path) -> None:
    """Run oxipng compression on a PNG file."""
    try:
        result = subprocess.run(
            ["oxipng", "-o", "6", "--strip", "safe", str(png_path)],
            capture_output=True,
            text=True,
            timeout=300
        )
        if result.returncode == 0:
            print(f"  ✓ Compressed with oxipng")
        else:
            print(f"  ⚠ oxipng warning (non-zero exit): {result.returncode}")
    except FileNotFoundError:
        print(f"  ⚠ oxipng not found, skipping compression")
    except subprocess.TimeoutExpired:
        print(f"  ⚠ oxipng timed out")
    except Exception as e:
        print(f"  ⚠ oxipng error: {e}")


def save_and_compress_png(sheet: Image.Image, path: Path, description: str) -> None:
    """Save a PNG and run oxipng compression on it."""
    sheet.save(path, "PNG")
    print(f"✅ {description} saved: {sheet.size[0]}x{sheet.size[1]} -> {path}")
    run_oxipng(path)


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
            return json.dumps(v)
        else:
            return json.dumps(v)
    return format_value(obj, 0)


def process_size_group(
    size_files: list[tuple[str, int, int, tuple[int, int]]], output_size: tuple[int, int]
) -> tuple[list[Image.Image], dict[str, dict]]:
    """Process a group of files with the same output frame size.

    Returns:
        - List of extracted frames
        - Dict of metadata entries (with internal indices, not yet converted to positions)
    """
    all_frames = []
    size_metadata = {}

    # Separate gachachacha variants from regular files
    gachachacha_files = []
    regular_files = []
    for png_path, cols, rows, source_size in size_files:
        name = Path(png_path).stem
        if name in GACHACHACHA_VARIANTS:
            gachachacha_files.append((png_path, cols, rows, source_size))
        else:
            regular_files.append((png_path, cols, rows, source_size))

    # Process regular files
    for png_path, cols, rows, source_size in regular_files:
        name = Path(png_path).stem
        vertical_flip = name in VERTICAL_FLIP_FILES
        crop = FRAME_CROP.get(name)
        frames = extract_frames_from_spritesheet(png_path, cols, rows, source_size, crop, vertical_flip)
        flip_note = " (flipped)" if vertical_flip else ""
        crop_note = " (cropped)" if crop else ""
        source_w, source_h = source_size
        print(f"Extracted {len(frames)} frames from {Path(png_path).name} ({cols}x{rows} grid @ {source_w}x{source_h}){crop_note}{flip_note}")

        frame_start = len(all_frames)
        all_frames.extend(frames)
        size_metadata[name] = {"_start": frame_start, "_count": len(frames), "_size": output_size}

    # Process gachachacha variants with deduplication
    if gachachacha_files:
        print(f"\nProcessing gachachacha variants with deduplication...")
        gacha_frames, gacha_indices = process_gachachacha_variants(gachachacha_files)
        gacha_frame_start = len(all_frames)
        all_frames.extend(gacha_frames)

        # Store indices (will be converted to positions later)
        for name, indices in gacha_indices.items():
            size_metadata[name] = {"_gacha_start": gacha_frame_start, "_gacha_indices": indices, "_size": output_size}

    return all_frames, size_metadata


def finalize_metadata(
    size_metadata: dict[str, dict], positions: list[tuple[int, int]], existing_metadata: dict
) -> dict[str, dict]:
    """Convert internal metadata indices to actual frame positions."""
    result = {}
    for name, data in size_metadata.items():
        anim_w, anim_h = data.pop("_size")
        # Get existing msPerFrame or use default
        existing_ms = existing_metadata.get(name, {}).get("msPerFrame", 100)

        if "_start" in data:
            # Regular attack
            start, count = data.pop("_start"), data.pop("_count")
            data["msPerFrame"] = existing_ms
            data["width"] = anim_w
            data["height"] = anim_h
            data["frames"] = [list(positions[start + i]) for i in range(count)]
        elif "_gacha_start" in data:
            # Gachachacha variant - use deduplicated indices
            gacha_start = data.pop("_gacha_start")
            indices = data.pop("_gacha_indices")
            data["msPerFrame"] = existing_ms
            data["width"] = anim_w
            data["height"] = anim_h
            data["frames"] = [list(positions[gacha_start + idx]) for idx in indices]

        result[name] = data
    return result


def create_attack_spritesheets(png_files: list[tuple[str, int, int, tuple[int, int], tuple[int, int]]], output_dir: str):
    """Create combined attack spritesheet with metadata."""
    output_path = Path(output_dir)

    # Load existing JSON files to preserve msPerFrame values
    standard_json_path = output_path / "attack_spritesheet.json"
    non_standard_json_path = output_path / "non_standard_spritesheet.json"
    existing_metadata = {}
    for json_path in [standard_json_path, non_standard_json_path]:
        if json_path.exists():
            try:
                existing_metadata.update(json.loads(json_path.read_text()))
                print(f"📖 Loaded existing metadata from {json_path}")
            except Exception as e:
                print(f"⚠ Could not load existing JSON {json_path}: {e}")

    # Group files by OUTPUT frame size (after cropping)
    # Key is (width, height) tuple
    files_by_size: dict[tuple[int, int], list[tuple[str, int, int, tuple[int, int]]]] = {}
    for png_path, cols, rows, source_size, output_size in png_files:
        if output_size not in files_by_size:
            files_by_size[output_size] = []
        files_by_size[output_size].append((png_path, cols, rows, source_size))

    standard_metadata = {}
    non_standard_metadata = {}

    # Determine munch output location
    base_path = Path(__file__).parent
    game_dir = base_path.parent.parent
    munch_assets_dir = game_dir / "munch" / "src" / "assets" / "attacks"

    # Separate standard (96x96) from non-standard sizes
    standard_size = (DEFAULT_FRAME_SIZE, DEFAULT_FRAME_SIZE)
    standard_files = files_by_size.pop(standard_size, [])
    non_standard_sizes = files_by_size  # Everything else

    # Process standard 96x96 frames
    if standard_files:
        print(f"\n{'=' * 50}")
        print(f"Processing {DEFAULT_FRAME_SIZE}x{DEFAULT_FRAME_SIZE} frames (standard)...")
        print(f"{'=' * 50}")

        all_frames, size_metadata = process_size_group(standard_files, standard_size)

        if all_frames:
            sheet, positions = build_spritesheet(all_frames, standard_size)
            sheet_path = output_path / "attack_spritesheet.png"
            save_and_compress_png(sheet, sheet_path, f"Attack spritesheet ({DEFAULT_FRAME_SIZE}x{DEFAULT_FRAME_SIZE})")

            if munch_assets_dir.exists():
                print(f"\n📋 Copying to munch repository: {munch_assets_dir}")
                munch_sheet_path = munch_assets_dir / "attack_spritesheet.png"
                save_and_compress_png(sheet, munch_sheet_path, f"Munch attack spritesheet ({DEFAULT_FRAME_SIZE}x{DEFAULT_FRAME_SIZE})")

            standard_metadata.update(finalize_metadata(size_metadata, positions, existing_metadata))

    # Process non-standard frames - combine all sizes into one spritesheet
    if non_standard_sizes:
        print(f"\n{'=' * 50}")
        print(f"Processing non-standard frames ({len(non_standard_sizes)} size groups)...")
        print(f"{'=' * 50}")

        # Build individual grids for each size, then stack vertically
        grid_images: list[tuple[Image.Image, list[tuple[int, int]], dict[str, dict]]] = []

        for output_size in sorted(non_standard_sizes.keys()):
            size_files = non_standard_sizes[output_size]
            output_w, output_h = output_size
            print(f"\n--- {output_w}x{output_h} frames ---")

            all_frames, size_metadata = process_size_group(size_files, output_size)

            if all_frames:
                sheet, positions = build_spritesheet(all_frames, output_size)
                grid_images.append((sheet, positions, size_metadata))
                print(f"  → Built grid: {sheet.size[0]}x{sheet.size[1]}")

        if grid_images:
            # Calculate combined image dimensions
            max_width = max(img.size[0] for img, _, _ in grid_images)
            total_height = sum(img.size[1] for img, _, _ in grid_images)

            # Create combined image and adjust positions
            combined = Image.new('RGBA', (max_width, total_height), (0, 0, 0, 0))
            y_offset = 0

            for sheet, positions, size_metadata in grid_images:
                combined.paste(sheet, (0, y_offset))

                # Adjust positions with y_offset and finalize metadata
                adjusted_positions = [(x, y + y_offset) for x, y in positions]
                non_standard_metadata.update(finalize_metadata(size_metadata, adjusted_positions, existing_metadata))

                y_offset += sheet.size[1]

            # Save combined non-standard spritesheet
            sheet_path = output_path / "non_standard_spritesheet.png"
            save_and_compress_png(combined, sheet_path, f"Non-standard spritesheet (combined)")

            if munch_assets_dir.exists():
                print(f"\n📋 Copying to munch repository: {munch_assets_dir}")
                munch_sheet_path = munch_assets_dir / "non_standard_spritesheet.png"
                save_and_compress_png(combined, munch_sheet_path, f"Munch non-standard spritesheet (combined)")

    if not munch_assets_dir.exists():
        print(f"\n⚠ Munch directory not found, skipping copy: {munch_assets_dir}")

    # Save JSON files separately
    if standard_metadata:
        standard_json_path.write_text(compact_json(standard_metadata))
        print(f"\n✅ Standard metadata saved to: {standard_json_path}")
    if non_standard_metadata:
        non_standard_json_path.write_text(compact_json(non_standard_metadata))
        print(f"✅ Non-standard metadata saved to: {non_standard_json_path}")


def run(target_dir: str = None) -> bool:
    """
    Run attack spritesheet generation. Returns True on success, False on failure.

    Args:
        target_dir: Directory containing attack PNG files. Defaults to drool/imgs/attacks/
    """
    if target_dir is None:
        target_dir = str(Path(__file__).parent.parent / "drool" / "imgs" / "attacks")

    if not Path(target_dir).is_dir():
        print(f"Error: Directory '{target_dir}' does not exist")
        return False

    print(f"Searching for attack PNG files in: {target_dir}\n")
    png_files = find_valid_attack_pngs(target_dir)

    if not png_files:
        print("No valid attack PNG files found (dimensions must be divisible by frame size)")
        return False

    print(f"\nFound {len(png_files)} valid PNG files:")
    for png_path, cols, rows, source_size, output_size in png_files:
        source_w, source_h = source_size
        output_w, output_h = output_size
        if source_size != output_size:
            size_info = f"{source_w}x{source_h}→{output_w}x{output_h}"
        else:
            size_info = f"{output_w}x{output_h}"
        print(f"  - {Path(png_path).name} ({cols}x{rows} = {cols * rows} frames @ {size_info})")

    create_attack_spritesheets(png_files, target_dir)
    print("\n✅ Done!")
    return True


def main():
    """CLI entry point."""
    target_dir = sys.argv[1] if len(sys.argv) >= 2 else None
    if not run(target_dir):
        sys.exit(1)


if __name__ == "__main__":
    main()


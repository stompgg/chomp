#!/usr/bin/env python3
"""
Script to combine mons.csv, moves.csv, and abilities.csv into a TypeScript const data structure.
"""

import csv
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Any


def to_address_key(name: str) -> str:
    """Convert name to UPPER_SNAKE_CASE for address key."""
    return re.sub(r"_+", "_", re.sub(r"[^a-zA-Z0-9]", "_", name)).strip("_").upper()


def to_spritesheet_key(name: str) -> str:
    """Convert name to lowercase_snake_case for spritesheet key."""
    return re.sub(r"_+", "_", re.sub(r"[^a-zA-Z0-9]", "_", name)).strip("_").lower()


def read_csv(file_path: str) -> List[Dict[str, str]]:
    """Read a CSV file and return list of row dicts."""
    with open(file_path, "r", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def read_json(file_path: str) -> Dict[str, Any]:
    """Read a JSON file and return the data."""
    with open(file_path, "r", encoding="utf-8") as f:
        return json.load(f)


def build_sprite_config(
    spritesheet_url: str,
    source: Dict[str, Any],
    frame_width: int,
    frame_height: int,
    loop: bool,
) -> Dict[str, Any]:
    """Build a sprite animation config from source data."""
    return {
        "spritesheetUrl": spritesheet_url,
        "frames": source["frames"],
        "frameWidth": frame_width,
        "frameHeight": frame_height,
        "frameDurationMs": source.get("msPerFrame", 100),
        "loop": loop,
    }


def build_attack_sprite(
    move_name: str,
    attack_spritesheet_data: Dict[str, Any],
    non_standard_spritesheet_data: Dict[str, Any]
) -> Dict[str, Any] | None:
    """Build sprite config for an attack move, or None if no sprite data exists."""
    key = to_spritesheet_key(move_name)

    # Check standard spritesheet first (96x96)
    if key in attack_spritesheet_data:
        source_data = attack_spritesheet_data[key]
        return build_sprite_config(
            "/assets/attacks/attack_spritesheet.png",
            source_data,
            frame_width=source_data.get("width", 96),
            frame_height=source_data.get("height", 96),
            loop=False,
        )

    # Check non-standard spritesheet (variable sizes)
    if key in non_standard_spritesheet_data:
        source_data = non_standard_spritesheet_data[key]
        return build_sprite_config(
            "/assets/attacks/non_standard_spritesheet.png",
            source_data,
            frame_width=source_data.get("width", 106),
            frame_height=source_data.get("height", 106),
            loop=False,
        )

    return None


def build_sprites(mon_name_lower: str, spritesheet_data: Dict[str, Any]) -> Dict[str, Any]:
    """Build sprite configurations for a mon."""
    sprites = {}
    
    # Define sprite variants: (side, output_key, data_key, spritesheet, loops)
    SPRITE_VARIANTS = [
        ("front", "frontIdle", None, "mon_spritesheet.png", True),
        ("front", "frontSwitchIn", "switchIn", "mon_switch.png", False),
        ("front", "frontSwitchOut", "switchOut", "mon_switch.png", False),
        ("back", "backIdle", None, "mon_spritesheet.png", True),
        ("back", "backSwitchIn", "switchIn", "mon_switch.png", False),
        ("back", "backSwitchOut", "switchOut", "mon_switch.png", False),
    ]
    
    for side, output_key, data_key, sheet, loops in SPRITE_VARIANTS:
        side_data = spritesheet_data.get(f"{mon_name_lower}_{side}.gif", {})
        if not side_data:
            continue
            
        # For idle animations, use root-level frames; for switch animations, use nested data
        source = side_data if data_key is None else side_data.get(data_key, {})
        if not source or "frames" not in source:
            continue
            
        sprites[output_key] = build_sprite_config(
            f"/assets/mons/all/{sheet}",
            source,
            frame_width=96,
            frame_height=96,
            loop=loops,
        )
    
    return sprites


def read_mons_data(file_path: str, spritesheet_data: Dict[str, Any]) -> Dict[int, Dict[str, Any]]:
    """Read mons.csv and return a dictionary keyed by mon ID."""
    mons_data = {}
    
    for row in read_csv(file_path):
        mon_id = int(row["Id"])
        mon_name_lower = row["Name"].lower()
        
        mons_data[mon_id] = {
            "id": mon_id,
            "name": row["Name"],
            "flavor": row.get("Flavor", ""),
            "mini": f"/assets/mons/all/{mon_name_lower}_mini.gif",
            "sprites": build_sprites(mon_name_lower, spritesheet_data),
            "stats": {
                "hp": int(row["HP"]),
                "attack": int(row["Attack"]),
                "defense": int(row["Defense"]),
                "specialAttack": int(row["SpecialAttack"]),
                "specialDefense": int(row["SpecialDefense"]),
                "speed": int(row["Speed"]),
                "bst": int(row["BST"]),
            },
            "type1": row["Type1"],
            "type2": row["Type2"] if row["Type2"] != "NA" else None,
            "moves": [],
            "ability": {"address": "", "name": "", "effect": ""},
        }
    
    return mons_data


def read_moves_data(
    file_path: str,
    attack_spritesheet_data: Dict[str, Any],
    non_standard_spritesheet_data: Dict[str, Any]
) -> tuple[Dict[str, List[Dict[str, Any]]], set[str]]:
    """Read moves.csv and return a dictionary keyed by mon name, plus set of all move keys."""
    moves_by_mon: Dict[str, List[Dict[str, Any]]] = {}
    all_move_keys: set[str] = set()

    def parse_int_or_unknown(val: str) -> int | str:
        return int(val) if val.isdigit() else '?'

    for row in read_csv(file_path):
        mon_name = row["Mon"]
        move_name = row["Name"]
        move_key = to_spritesheet_key(move_name)
        all_move_keys.add(move_key)

        move_data: Dict[str, Any] = {
            "address": f"Address.{to_address_key(move_name)}",
            "name": move_name,
            "power": parse_int_or_unknown(row["Power"]),
            "stamina": parse_int_or_unknown(row["Stamina"]),
            "accuracy": parse_int_or_unknown(row["Accuracy"]),
            "priority": parse_int_or_unknown(row["Priority"]),
            "type": row["Type"],
            "class": row["Class"],
            "description": row["DevDescription"],
            "extraDataNeeded": row["ExtraData"] == "Yes",
        }
        sprite = build_attack_sprite(move_name, attack_spritesheet_data, non_standard_spritesheet_data)
        if sprite:
            move_data["sprite"] = sprite
        moves_by_mon.setdefault(mon_name, []).append(move_data)

    return moves_by_mon, all_move_keys


def find_non_standard_sprites(
    attack_spritesheet_data: Dict[str, Any],
    non_standard_spritesheet_data: Dict[str, Any],
    matched_move_keys: set[str]
) -> Dict[str, Dict[str, Any]]:
    """Find spritesheet animations that don't match any move on a mon."""
    non_standard: Dict[str, Dict[str, Any]] = {}

    # Check standard spritesheet for unmatched animations
    for key, source_data in attack_spritesheet_data.items():
        if key not in matched_move_keys:
            non_standard[key] = build_sprite_config(
                "/assets/attacks/attack_spritesheet.png",
                source_data,
                frame_width=source_data.get("width", 96),
                frame_height=source_data.get("height", 96),
                loop=False,
            )

    # Check non-standard spritesheet for unmatched animations
    for key, source_data in non_standard_spritesheet_data.items():
        if key not in matched_move_keys:
            non_standard[key] = build_sprite_config(
                "/assets/attacks/non_standard_spritesheet.png",
                source_data,
                frame_width=source_data.get("width", 106),
                frame_height=source_data.get("height", 106),
                loop=False,
            )

    return non_standard


def read_abilities_data(file_path: str) -> Dict[str, Dict[str, str]]:
    """Read abilities.csv and return a dictionary keyed by mon name."""
    return {
        row["Mon"]: {
            "address": f"Address.{to_address_key(row['Name'])}",
            "name": row["Name"],
            "effect": row["Effect"],
        }
        for row in read_csv(file_path)
    }


def combine_data(
    mons_data: Dict[int, Dict[str, Any]],
    moves_by_mon: Dict[str, List[Dict[str, Any]]],
    abilities_by_mon: Dict[str, Dict[str, str]],
) -> Dict[int, Dict[str, Any]]:
    """Combine all data sources into a single structure."""
    for mon_data in mons_data.values():
        mon_name = mon_data["name"]
        mon_data["moves"] = moves_by_mon.get(mon_name, [])
        mon_data["ability"] = abilities_by_mon.get(mon_name, mon_data["ability"])
    return mons_data


def collapse_frame_arrays(json_str: str) -> str:
    """Collapse frame arrays like [[0,0], [96,0]] back to single lines."""
    # Match "frames": followed by a multi-line array of coordinate pairs
    def collapse_match(m: re.Match) -> str:
        content = m.group(1)
        # Remove newlines and excess whitespace, normalize to compact format
        collapsed = re.sub(r"\s+", " ", content).strip()
        # Clean up spacing around brackets
        collapsed = re.sub(r"\[ +", "[", collapsed)
        collapsed = re.sub(r" +\]", "]", collapsed)
        return f'"frames": {collapsed}'
    
    return re.sub(
        r'"frames": (\[\s*\[[\d\s,\[\]]+\])',
        collapse_match,
        json_str,
        flags=re.MULTILINE
    )


def generate_typescript_const(data: Dict[int, Dict[str, Any]], output_file: str):
    """Generate TypeScript const declaration and write to file."""
    json_str = json.dumps(data, indent=2, ensure_ascii=False)
    
    # Collapse frame arrays to single lines
    json_str = collapse_frame_arrays(json_str)
    
    # Replace string keys with integer keys
    json_str = re.sub(r'"(\d+)":', r"\1:", json_str)
    
    # Replace address string references with Address object references
    json_str = re.sub(r'"Address\.([A-Z0-9_]+)"', r"Address.\1", json_str)
    
    # Replace string values with enum references
    ENUM_REPLACEMENTS = {
        "Type": ["Yin", "Yang", "Earth", "Liquid", "Fire", "Metal", "Ice", 
                 "Nature", "Lightning", "Mythic", "Air", "Math", "Cyber", "Wild", "Cosmic"],
        "MoveClass": ["Physical", "Special", "Other", "Self"],
    }
    for enum_name, values in ENUM_REPLACEMENTS.items():
        for val in values:
            json_str = json_str.replace(f'"{val}"', f"{enum_name}.{val}")

    typescript_content = f"""// Auto-generated type file
import {{ Address }} from './address';
import {{ LowercaseHex, Type }} from '../types/structs';
import {{ SpriteAnimationConfig }} from '../types/animation';

export enum MoveClass {{
  Physical = 'Physical',
  Special = 'Special',
  Other = 'Other',
  Self = 'Self',
}};

export const MonMetadata = {json_str} as const;

export type Move = {{
  readonly address: LowercaseHex;
  readonly name: string;
  readonly power: number | '?';
  readonly stamina: number | '?';
  readonly accuracy: number | '?';
  readonly priority: number | '?';
  readonly type: Type;
  readonly class: MoveClass;
  readonly description: string;
  readonly extraDataNeeded: boolean;
  readonly sprite?: SpriteAnimationConfig;
}};

export type Mon = {{
  readonly id: number;
  readonly name: string;
  readonly flavor: string;
  readonly mini: string;
  readonly sprites: {{
    readonly frontIdle: SpriteAnimationConfig;
    readonly frontSwitchIn: SpriteAnimationConfig;
    readonly frontSwitchOut: SpriteAnimationConfig;
    readonly backIdle: SpriteAnimationConfig;
    readonly backSwitchIn: SpriteAnimationConfig;
    readonly backSwitchOut: SpriteAnimationConfig;
  }};
  readonly stats: {{
    readonly hp: number;
    readonly attack: number;
    readonly defense: number;
    readonly specialAttack: number;
    readonly specialDefense: number;
    readonly speed: number;
    readonly bst: number;
  }};
  readonly type1: Type;
  readonly type2: Type | null;
  readonly moves: readonly [Move, Move, Move, Move, ...Array<Move>];
  readonly ability: {{
    readonly address: LowercaseHex;
    readonly name: string;
    readonly effect: string;
  }};
}};

export type MonDatabase = Record<number, Mon>;
"""

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(typescript_content)


def generate_non_standard_sprites_file(sprites: Dict[str, Dict[str, Any]], output_file: str):
    """Generate TypeScript file for non-standard attack sprites not matched to any mon's moves."""
    json_str = json.dumps(sprites, indent=2, ensure_ascii=False)

    # Collapse frame arrays to single lines
    json_str = collapse_frame_arrays(json_str)

    typescript_content = f"""// Auto-generated file for non-standard attack sprites not matched to any mon's moves
import {{ SpriteAnimationConfig }} from '../types/animation';

export const NonStandardAttackSprites: Record<string, SpriteAnimationConfig> = {json_str};
"""

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(typescript_content)


def run() -> bool:
    """Run TypeScript generation. Returns True on success, False on failure."""
    # Data is in drool/ directory (sibling to processing/)
    base_path = Path(__file__).parent.parent / "drool"

    files = {
        "mons": base_path / "mons.csv",
        "moves": base_path / "moves.csv",
        "abilities": base_path / "abilities.csv",
        "spritesheet": base_path / "imgs" / "spritesheet.json",
        "attack_spritesheet": base_path / "imgs" / "attacks" / "attack_spritesheet.json",
        "non_standard_spritesheet": base_path / "imgs" / "attacks" / "non_standard_spritesheet.json",
    }

    # Determine output location
    game_dir = base_path.parent.parent
    munch_data_dir = game_dir / "munch" / "src" / "app" / "data"
    munch_output = munch_data_dir / "mon.ts"
    output_file = munch_output if munch_data_dir.exists() else base_path / "mon_data.ts"
    print(f"Output target: {output_file}")

    # Verify required input files exist (non_standard_spritesheet is optional)
    required_files = {k: v for k, v in files.items() if k != "non_standard_spritesheet"}
    missing = [name for name, path in required_files.items() if not path.exists()]
    if missing:
        print(f"Error: Missing files: {', '.join(missing)}")
        return False

    print("Reading CSV files and spritesheet data...")

    spritesheet_data = read_json(str(files["spritesheet"]))
    attack_spritesheet_data = read_json(str(files["attack_spritesheet"]))

    # Load non-standard spritesheet if it exists
    non_standard_spritesheet_data = {}
    if files["non_standard_spritesheet"].exists():
        non_standard_spritesheet_data = read_json(str(files["non_standard_spritesheet"]))
        print(f"  ✓ Loaded non-standard attack spritesheet")

    mons_data = read_mons_data(str(files["mons"]), spritesheet_data)
    moves_by_mon, all_move_keys = read_moves_data(str(files["moves"]), attack_spritesheet_data, non_standard_spritesheet_data)
    abilities_by_mon = read_abilities_data(str(files["abilities"]))

    print(f"Loaded {len(mons_data)} mons, moves for {len(moves_by_mon)} mons, abilities for {len(abilities_by_mon)} mons")

    combined_data = combine_data(mons_data, moves_by_mon, abilities_by_mon)
    generate_typescript_const(combined_data, str(output_file))
    print(f"✅ Generated TypeScript const in {output_file}")

    # Find and generate non-standard sprites not matched to any mon's moves
    non_standard = find_non_standard_sprites(attack_spritesheet_data, non_standard_spritesheet_data, all_move_keys)
    if non_standard:
        non_standard_output = munch_data_dir / "non-standard-sprites.ts" if munch_data_dir.exists() else base_path / "non_standard_sprites.ts"
        generate_non_standard_sprites_file(non_standard, str(non_standard_output))
        print(f"✅ Generated non-standard sprites ({len(non_standard)} animations) in {non_standard_output}")
    else:
        print("✅ All non-standard spritesheet animations matched to moves")

    return True


def main():
    """CLI entry point."""
    if not run():
        sys.exit(1)


if __name__ == "__main__":
    main()
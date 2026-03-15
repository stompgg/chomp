#!/usr/bin/env python3
"""
Pack JSON move definitions into uint256 inline slot values.

Packed format (256 bits total):
[basePower:8 | moveClass:2 | priority:2 | moveType:4 | stamina:4 | effectAccuracy:8 | unused:68 | effect:160]
 bits 255-248  247-246       245-244      243-240      239-236     235-228            227-160     159-0

Fields omitted from packing (always use defaults at runtime):
  accuracy=100, critRate=5, volatility=10
"""

import json
import os
from typing import Dict, Optional, Tuple


TYPE_MAP = {
    "Yin": 0, "Yang": 1, "Earth": 2, "Liquid": 3, "Fire": 4,
    "Metal": 5, "Ice": 6, "Nature": 7, "Lightning": 8, "Mythic": 9,
    "Air": 10, "Math": 11, "Cyber": 12, "Wild": 13, "Cosmic": 14, "None": 15
}

CLASS_MAP = {"Physical": 0, "Special": 1, "Self": 2, "Other": 3}


def pack_move(move_json: dict, effect_address: int = 0) -> int:
    """Pack a JSON move definition into a uint256 value.

    Args:
        move_json: Parsed JSON move data with keys: basePower, staminaCost, moveType,
                   moveClass, effectAccuracy, and optionally priority (offset from default).
        effect_address: Deployed address of the IEffect contract (0 for no effect).

    Returns:
        Packed uint256 value with inline move data.
    """
    base_power = move_json["basePower"]
    move_class = CLASS_MAP[move_json["moveClass"]]
    priority_offset = move_json.get("priority", 0)  # offset from DEFAULT_PRIORITY
    move_type = TYPE_MAP[move_json["moveType"]]
    stamina = move_json["staminaCost"]
    effect_accuracy = move_json["effectAccuracy"]

    # Validate ranges
    assert 0 <= base_power <= 255, f"basePower {base_power} out of range [0, 255]"
    assert 0 <= move_class <= 3, f"moveClass {move_class} out of range [0, 3]"
    assert 0 <= priority_offset <= 3, f"priority offset {priority_offset} out of range [0, 3]"
    assert 0 <= move_type <= 15, f"moveType {move_type} out of range [0, 15]"
    assert 0 <= stamina <= 15, f"stamina {stamina} out of range [0, 15]"
    assert 0 <= effect_accuracy <= 255, f"effectAccuracy {effect_accuracy} out of range [0, 255]"
    assert 0 <= effect_address < (1 << 160), f"effect address out of range"

    packed = base_power << 248
    packed |= move_class << 246
    packed |= priority_offset << 244
    packed |= move_type << 240
    packed |= stamina << 236
    packed |= effect_accuracy << 228
    # bits 227-160 are unused (zero)
    packed |= effect_address  # lower 160 bits

    return packed


def find_json_moves(src_path: str) -> Dict[str, Dict[str, dict]]:
    """Find all JSON move files under src/mons/*/.

    Returns:
        Dict of {mon_dir_name: {move_name: parsed_json}}.
        e.g. {"gorillax": {"Blow": {...}, "PoundGround": {...}}}
    """
    mons_path = os.path.join(src_path, "mons")
    result = {}

    if not os.path.isdir(mons_path):
        return result

    for mon_dir in sorted(os.listdir(mons_path)):
        mon_dir_path = os.path.join(mons_path, mon_dir)
        if not os.path.isdir(mon_dir_path):
            continue

        for filename in sorted(os.listdir(mon_dir_path)):
            if not filename.endswith(".json"):
                continue

            move_name = filename[:-5]  # strip .json
            filepath = os.path.join(mon_dir_path, filename)

            with open(filepath, "r", encoding="utf-8") as f:
                move_data = json.load(f)

            if mon_dir not in result:
                result[mon_dir] = {}
            result[mon_dir][move_name] = move_data

    return result


def pack_all_moves(src_path: str, effect_addresses: Optional[Dict[str, int]] = None) -> Dict[str, Dict[str, Tuple[int, dict]]]:
    """Find and pack all JSON moves.

    Args:
        src_path: Path to the src/ directory.
        effect_addresses: Optional mapping of effect name -> deployed address.
                         e.g. {"ZapStatus": 0x1234...}

    Returns:
        Dict of {mon_dir_name: {move_name: (packed_uint256, json_data)}}.
    """
    if effect_addresses is None:
        effect_addresses = {}

    json_moves = find_json_moves(src_path)
    result = {}

    for mon_dir, moves in json_moves.items():
        result[mon_dir] = {}
        for move_name, move_data in moves.items():
            effect_name = move_data.get("effect")
            effect_addr = 0
            if effect_name is not None:
                if effect_name not in effect_addresses:
                    raise ValueError(
                        f"Effect '{effect_name}' required by {mon_dir}/{move_name} "
                        f"not found in effect_addresses. Available: {list(effect_addresses.keys())}"
                    )
                effect_addr = effect_addresses[effect_name]

            packed = pack_move(move_data, effect_addr)
            result[mon_dir][move_name] = (packed, move_data)

    return result


def main():
    """CLI: pack all JSON moves and print results."""
    import sys

    src_path = "src"
    if len(sys.argv) > 1:
        src_path = sys.argv[1]

    json_moves = find_json_moves(src_path)

    print(f"Found JSON moves in {len(json_moves)} mon directories:\n")

    for mon_dir, moves in sorted(json_moves.items()):
        for move_name, move_data in sorted(moves.items()):
            # Pack with effect_address=0 for display (real addresses come at deploy time)
            packed = pack_move(move_data, effect_address=0)
            effect_info = f" (effect: {move_data['effect']})" if move_data.get("effect") else ""
            print(f"  {mon_dir}/{move_name}: 0x{packed:064x}{effect_info}")
            # Verify detection: upper 96 bits must be non-zero
            assert packed >> 160 != 0, f"Packed value for {move_name} would be misdetected as address!"

    total = sum(len(m) for m in json_moves.values())
    print(f"\n{total} moves packed successfully.")


if __name__ == "__main__":
    main()

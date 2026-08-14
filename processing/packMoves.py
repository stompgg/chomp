#!/usr/bin/env python3
"""
Pack inline move definitions into uint256 inline slot values.

Every packed value is sourced from the move's drool/moves.csv row; the per-move .json file
only marks the move as inline and names its effect contract.

Packed format (256 bits total):
[basePower:8 | moveClass:2 | priority:2 | moveType:4 | stamina:4 | effectAccuracy:8 | unused:68 | effect:160]
 bits 255-248  247-246       245-244      243-240      239-236     235-228            227-160     159-0

Fields omitted from packing (always use defaults at runtime):
  accuracy=100, critRate=5, volatility=10
"""

import csv
import json
import os
import re
from typing import Dict, Optional


from types_enum import TYPE_INDEX as TYPE_MAP  # name -> enum index, from src/Enums.sol

CLASS_MAP = {"Physical": 0, "Special": 1, "Self": 2, "Other": 3}


def parse_constants(raw: str) -> Dict[str, int]:
    """Parse the Constants column ('NAME=VAL;NAME=VAL') into a {NAME: int} dict."""
    consts: Dict[str, int] = {}
    for part in (raw or "").split(";"):
        part = part.strip()
        if not part:
            continue
        name, _, val = part.partition("=")
        consts[name.strip()] = int(val.strip())
    return consts


def contract_name_from_move(move_name: str) -> str:
    """Move display name -> its contract/file base name ('Pound Ground' -> 'PoundGround')."""
    return re.sub(r"\W+", "", move_name.replace(" ", ""))


def inline_params_from_csv(row: dict) -> dict:
    """Build an inline move's packing params from its moves.csv row.

    moves.csv is the source of truth for every packed field; the .json file supplies only
    `effect`. CSV Priority is already the offset from DEFAULT_PRIORITY that the inline word
    stores, so it maps across unchanged (unlike deployed words, which store absolute priority).
    """
    consts = parse_constants(row.get("Constants", ""))
    return {
        "basePower": int(row["Power"]),
        "staminaCost": int(row["Stamina"]),
        "moveType": row["Type"].strip(),
        "moveClass": row["Class"].strip(),
        "priority": int((row.get("Priority") or "0").strip() or "0"),
        "effectAccuracy": consts.get("EFFECT_ACCURACY", 0),
    }


def pack_move(move_params: dict, effect_address: int = 0) -> int:
    """Pack an inline move definition into a uint256 value.

    Args:
        move_params: Params from inline_params_from_csv: basePower, staminaCost, moveType,
                     moveClass, effectAccuracy, and priority (offset from default).
        effect_address: Deployed address of the IEffect contract (0 for no effect).

    Returns:
        Packed uint256 value with inline move data.
    """
    base_power = move_params["basePower"]
    move_class = CLASS_MAP[move_params["moveClass"]]
    priority_offset = move_params.get("priority", 0)  # offset from DEFAULT_PRIORITY
    move_type = TYPE_MAP[move_params["moveType"]]
    stamina = move_params["staminaCost"]
    effect_accuracy = move_params["effectAccuracy"]

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
    """Find all JSON move files under src/mons/*/. A file's presence marks its move as inline.

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


def load_moves_csv(moves_csv_path: str) -> Dict[str, dict]:
    """Load moves.csv keyed by contract name ('PoundGround' -> row)."""
    with open(moves_csv_path, "r", newline="", encoding="utf-8") as f:
        return {contract_name_from_move(row["Name"].strip()): row for row in csv.DictReader(f)}


ABILITY_TYPE_MAP = {
    "singleton-local": 1,
    "singleton-global": 2,
}


def detect_inline_ability(sol_path: str) -> Optional[int]:
    """Check if a .sol file has an @inline-ability magic comment.

    Returns:
        The ability type ID (1 for singleton-local, 2 for singleton-global),
        or None if not an inline ability.
    """
    import re
    try:
        with open(sol_path, "r", encoding="utf-8") as f:
            for line in f:
                m = re.match(r'//\s*@inline-ability:\s*(\S+)', line)
                if m:
                    ability_type = m.group(1)
                    if ability_type not in ABILITY_TYPE_MAP:
                        raise ValueError(f"Unknown inline ability type '{ability_type}' in {sol_path}")
                    return ABILITY_TYPE_MAP[ability_type]
    except FileNotFoundError:
        pass
    return None


def pack_ability(ability_type_id: int, effect_address: int) -> int:
    """Pack an inline ability into a uint256 value.

    Format: [abilityTypeId:8 | unused:88 | effectAddr:160]

    Args:
        ability_type_id: The ability type (1 = singleton-local, 2 = singleton-global)
        effect_address: Deployed address of the ability contract (same contract that
                       implements IEffect lifecycle hooks).

    Returns:
        Packed uint256 value with inline ability data.
    """
    assert 1 <= ability_type_id <= 255, f"ability_type_id {ability_type_id} out of range [1, 255]"
    assert 0 <= effect_address < (1 << 160), f"effect address out of range"

    return (ability_type_id << 248) | effect_address


def main():
    """CLI: pack all inline moves and print results."""
    import sys

    src_path = sys.argv[1] if len(sys.argv) > 1 else "src"
    moves_csv_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join("drool", "moves.csv")

    json_moves = find_json_moves(src_path)
    csv_rows = load_moves_csv(moves_csv_path)

    print(f"Found JSON moves in {len(json_moves)} mon directories:\n")

    for mon_dir, moves in sorted(json_moves.items()):
        for move_name, move_data in sorted(moves.items()):
            # Pack with effect_address=0 for display (real addresses come at deploy time)
            packed = pack_move(inline_params_from_csv(csv_rows[move_name]), effect_address=0)
            effect_info = f" (effect: {move_data['effect']})" if move_data.get("effect") else ""
            print(f"  {mon_dir}/{move_name}: 0x{packed:064x}{effect_info}")
            # Verify detection: upper 96 bits must be non-zero
            assert packed >> 160 != 0, f"Packed value for {move_name} would be misdetected as address!"

    total = sum(len(m) for m in json_moves.values())
    print(f"\n{total} moves packed successfully.")


if __name__ == "__main__":
    main()

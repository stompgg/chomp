#!/usr/bin/env python3
"""Address collection + packing for the deploy pipeline.

Turns the raw (name, address) pairs that forge emits into the values the
TypeScript generators expect: inline abilities packed as (type_id << 248) | address,
and inline JSON moves packed with their resolved effect-contract address OR'd in.
"""

import csv
import json
import re
from pathlib import Path

from packMoves import detect_inline_ability, pack_ability, pack_move
from generateSolidity import contract_name_from_move_or_ability, get_mon_directory_name


def collect_inline_move_addresses(
    chomp_dir: Path,
    deployed_addresses: list[tuple[str, str]],
) -> list[tuple[str, str]]:
    """Find all JSON inline moves, pack them, and return as (move_display_name, hex_value) tuples.

    Uses CSV move names (e.g. "Pound Ground") so the Address keys match what
    generateMonsTypeScript.py expects.

    Resolves effect contract addresses from deployed_addresses so the packed
    values match on-chain (where SetupMons.s.sol OR's the effect address in).
    """
    src_dir = chomp_dir / "src"
    moves_csv = chomp_dir / "drool" / "moves.csv"

    # Build lookup from contract name (SCREAMING_SNAKE) to address
    addr_lookup = {}
    for name, address in deployed_addresses:
        key = name.upper().replace(" ", "_").replace("-", "_")
        addr_lookup[key] = address

    results = []
    with open(moves_csv, "r", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            move_name = row["Name"].strip()
            mon_name = row["Mon"].strip()
            contract_name = contract_name_from_move_or_ability(move_name)
            json_path = src_dir / "mons" / get_mon_directory_name(mon_name) / f"{contract_name}.json"
            if not json_path.exists():
                continue
            with open(json_path, "r", encoding="utf-8") as jf:
                move_data = json.load(jf)

            # Resolve the effect contract address if the move has one
            effect_address = 0
            effect_name = move_data.get("effect", "")
            if effect_name:
                # Convert PascalCase to SCREAMING_SNAKE_CASE for lookup
                snake = re.sub(r'(?<!^)(?=[A-Z])', '_', effect_name).upper()
                addr_str = addr_lookup.get(snake, "")
                if addr_str:
                    effect_address = int(addr_str, 16)

            packed = pack_move(move_data, effect_address=effect_address)
            results.append((move_name, f"0x{packed:064x}"))

    return results


def _find_ability_sol_path(ability_name: str, chomp_dir: Path) -> Path | None:
    """Find the .sol file for an ability by searching src/mons/*/."""
    contract_name = contract_name_from_move_or_ability(ability_name)

    mons_dir = chomp_dir / "src" / "mons"
    if not mons_dir.exists():
        return None

    for mon_dir in mons_dir.iterdir():
        if mon_dir.is_dir():
            sol_path = mon_dir / f"{contract_name}.sol"
            if sol_path.exists():
                return sol_path
    return None


def pack_inline_ability_addresses(
    deployed_addresses: list[tuple[str, str]],
    chomp_dir: Path,
) -> list[tuple[str, str]]:
    """For each deployed ability, check if inline and pack if needed.

    Uses the @inline-ability magic comment in .sol files to detect inline abilities.
    For inline abilities, packs as (type_id << 248) | address.
    For external abilities, returns the raw address.
    """
    results = []
    packed_count = 0

    for name, address in deployed_addresses:
        sol_path = _find_ability_sol_path(name, chomp_dir)
        if sol_path:
            ability_type_id = detect_inline_ability(str(sol_path))
            if ability_type_id is not None:
                addr_int = int(address, 16)
                packed = pack_ability(ability_type_id, addr_int)
                results.append((name, f"0x{packed:064x}"))
                packed_count += 1
                continue

        # Not inline or not found - use raw address as-is
        results.append((name, address))

    if packed_count > 0:
        print(f"Packed {packed_count} inline abilities")

    return results

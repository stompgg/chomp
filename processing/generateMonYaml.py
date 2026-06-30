"""
Joins drool/mons.csv, drool/moves.csv, and drool/abilities.csv into a single
YAML doc keyed by mon name, with stats / ability / moves as sub-sections.

Usage:
    python processing/generateMonYaml.py
"""

import csv
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DROOL_DIR = os.path.join(SCRIPT_DIR, "..", "drool")

MONS_CSV = os.path.join(DROOL_DIR, "mons.csv")
MOVES_CSV = os.path.join(DROOL_DIR, "moves.csv")
ABILITIES_CSV = os.path.join(DROOL_DIR, "abilities.csv")
OUTPUT_YAML = os.path.join(DROOL_DIR, "mons.yaml")

MON_STAT_FIELDS = [
    ("Id", "id"),
    ("HP", "hp"),
    ("Attack", "attack"),
    ("Defense", "defense"),
    ("SpecialAttack", "special_attack"),
    ("SpecialDefense", "special_defense"),
    ("Speed", "speed"),
    ("Type1", "type1"),
    ("Type2", "type2"),
    ("Flavor", "flavor"),
]

MOVE_FIELDS = [
    ("Power", "power"),
    ("Stamina", "stamina"),
    ("Accuracy", "accuracy"),
    ("Priority", "priority"),
    ("Type", "type"),
    ("Class", "class"),
    ("DevDescription", "description"),
    ("InputType", "input_type"),
    ("UnlockLevel", "unlock_level"),
]


def read_csv_rows(path):
    with open(path, newline="", encoding="utf-8") as f:
        return [row for row in csv.DictReader(f) if any(v.strip() for v in row.values())]


def yaml_scalar(raw_value):
    """Render a CSV string as a YAML scalar: plain if it's an integer, else double-quoted."""
    try:
        return str(int(raw_value))
    except ValueError:
        escaped = raw_value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'


def emit_kv(lines, indent, key, raw_value):
    lines.append(f"{indent}{key}: {yaml_scalar(raw_value)}")


def build_mon_order_and_stats():
    mon_order = []
    stats_by_mon = {}
    for row in read_csv_rows(MONS_CSV):
        name = row["Name"]
        mon_order.append(name)
        stats_by_mon[name] = row
    return mon_order, stats_by_mon


def build_abilities_by_mon():
    abilities_by_mon = {}
    for row in read_csv_rows(ABILITIES_CSV):
        abilities_by_mon[row["Mon"]] = row
    return abilities_by_mon


def build_moves_by_mon():
    moves_by_mon = {}
    for row in read_csv_rows(MOVES_CSV):
        moves_by_mon.setdefault(row["Mon"], []).append(row)
    return moves_by_mon


def render_yaml(mon_order, stats_by_mon, abilities_by_mon, moves_by_mon):
    lines = []
    for mon_name in mon_order:
        lines.append(f"{mon_name}:")

        lines.append("  stats:")
        stats_row = stats_by_mon[mon_name]
        for csv_field, yaml_key in MON_STAT_FIELDS:
            value = stats_row[csv_field]
            if csv_field == "Type2" and value == "NA":
                continue
            emit_kv(lines, "    ", yaml_key, value)

        ability_row = abilities_by_mon.get(mon_name)
        lines.append("  ability:")
        if ability_row:
            emit_kv(lines, "    ", "name", ability_row["Name"])
            emit_kv(lines, "    ", "effect", ability_row["Effect"])

        moves = moves_by_mon.get(mon_name, [])
        lines.append("  moves:")
        for move_row in moves:
            emit_kv(lines, "    - ", "name", move_row["Name"])
            for csv_field, yaml_key in MOVE_FIELDS:
                emit_kv(lines, "      ", yaml_key, move_row[csv_field])

    return "\n".join(lines) + "\n"


def main():
    mon_order, stats_by_mon = build_mon_order_and_stats()
    abilities_by_mon = build_abilities_by_mon()
    moves_by_mon = build_moves_by_mon()

    yaml_text = render_yaml(mon_order, stats_by_mon, abilities_by_mon, moves_by_mon)

    with open(OUTPUT_YAML, "w", encoding="utf-8") as f:
        f.write(yaml_text)

    print(f"Wrote {OUTPUT_YAML} ({len(mon_order)} mons)")


if __name__ == "__main__":
    main()

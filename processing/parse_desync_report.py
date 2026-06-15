#!/usr/bin/env python3
"""Convert a battle desync report (markdown) into faithful-replay test data.

Usage:
    python processing/parse_desync_report.py test/fixtures/desync_reports/<report>.md [--json]

Emits a Solidity snippet (team monIds + per-slot MonStats + the deduped `Turn[]` move sequence)
ready to paste into a `RealMonReplayGasTest`-style replay test, so any real prod game becomes a
gas + equivalence regression. `--json` emits the structured form instead.

The report gives leveled/facffeted stats (which differ from base CSV stats) + the per-turn
moveIndex/salt/extraData with the exact prod salts. Stamina is not logged, so it defaults to 5
(the game default); the replay test can also pull real stamina from the registry if preferred.
Duplicate turnIds (a resubmission/desync artifact) are deduped to the first occurrence.
"""
import csv
import json
import re
import sys
from pathlib import Path

# Type enum index -> Solidity Type member (Enums.sol order), single-sourced.
from types_enum import TYPE_NAMES

REPO = Path(__file__).resolve().parent.parent
DEFAULT_STAMINA = 5


def load_name_to_id():
    name_to_id = {}
    with open(REPO / "drool" / "mons.csv") as f:
        for row in csv.DictReader(f):
            name_to_id[row["Name"].strip().lower()] = int(row["Id"])
    return name_to_id


def parse_int(tok):
    # Strip JS BigInt 'n' suffix and any commas.
    return int(re.sub(r"[n,]", "", tok.strip()))


def parse_report(text, name_to_id):
    players = {0: [], 1: []}
    cur_player = None
    mon_re = re.compile(
        r"-\s*\d+:\s*(\w+)\s*\{hp:(\d+),\s*atk:(\d+),\s*def:(\d+),\s*spAtk:(\d+),"
        r"\s*spDef:(\d+),\s*spe:(\d+),\s*type:([\d/]+)\}"
    )
    for line in text.splitlines():
        ph = re.match(r"###\s*Player\s*(\d)", line)
        if ph:
            cur_player = int(ph.group(1))
            continue
        m = mon_re.search(line)
        if m and cur_player is not None:
            name, hp, atk, df, spa, spd, spe, types = m.groups()
            t = [int(x) for x in types.split("/")]
            t1, t2 = t[0], (t[1] if len(t) > 1 else 15)  # 15 = None
            players[cur_player].append({
                "name": name, "monId": name_to_id[name.lower()],
                "hp": int(hp), "atk": int(atk), "def": int(df),
                "spAtk": int(spa), "spDef": int(spd), "spe": int(spe),
                "type1": t1, "type2": t2,
            })

    # Turns: split on "## Turn", parse each block's turnId + p0/p1 sub-blocks.
    turns = {}
    blocks = re.split(r"^##\s+Turn\b", text, flags=re.MULTILINE)[1:]
    for b in blocks:
        tid_m = re.search(r"turnId:\s*(\d+)", b)
        if not tid_m:
            continue
        tid = int(tid_m.group(1))
        if tid in turns:  # dedupe resubmissions: keep first occurrence
            continue
        turn = {"turnId": tid}
        for side in ("p0", "p1"):
            # Match "p0:\n  moveIndex: Xn\n  salt: Yn\n  extraData: Zn"  OR  "p0: {}"
            sub = re.search(
                rf"{side}:\s*\n\s*moveIndex:\s*(\d+)n?\s*\n\s*salt:\s*(\d+)n?\s*\n\s*extraData:\s*(\d+)n?",
                b,
            )
            if sub:
                turn[side] = {
                    "present": True,
                    "moveIndex": int(sub.group(1)),
                    "salt": int(sub.group(2)),
                    "extraData": int(sub.group(3)),
                }
            else:
                turn[side] = {"present": False, "moveIndex": 126, "salt": 0, "extraData": 0}
        turns[tid] = turn
    return players, [turns[k] for k in sorted(turns)]


def to_solidity(players, turns):
    out = []
    p0_ids = ", ".join(str(m["monId"]) for m in players[0])
    p1_ids = ", ".join(str(m["monId"]) for m in players[1])
    out.append(f"    uint256[{len(players[0])}] P0_IDS = [uint256({p0_ids.split(', ',1)[0]}), {p0_ids.split(', ',1)[1]}];")
    out.append(f"    uint256[{len(players[1])}] P1_IDS = [uint256({p1_ids.split(', ',1)[0]}), {p1_ids.split(', ',1)[1]}];")
    out.append("")
    for pi, fn in ((0, "_p0Stats"), (1, "_p1Stats")):
        out.append(f"    function {fn}() internal pure returns (MonStats[{len(players[pi])}] memory s) {{")
        for i, m in enumerate(players[pi]):
            t1 = f"Type.{TYPE_NAMES[m['type1']]}"
            t2 = f"Type.{TYPE_NAMES[m['type2']]}"
            out.append(
                f"        s[{i}] = _mk({m['hp']}, {DEFAULT_STAMINA}, {m['spe']}, {m['atk']}, "
                f"{m['def']}, {m['spAtk']}, {m['spDef']}, {t1}, {t2}); // {m['name']}"
            )
        out.append("    }")
        out.append("")
    out.append(f"    function _plan() internal pure returns (Turn[] memory t) {{")
    out.append(f"        t = new Turn[]({len(turns)});")
    for i, tn in enumerate(turns):
        p0, p1 = tn["p0"], tn["p1"]
        out.append(
            f"        t[{i}] = Turn({p0['moveIndex']},{p0['extraData']},{p0['salt']},{str(p0['present']).lower()}, "
            f"{p1['moveIndex']},{p1['extraData']},{p1['salt']},{str(p1['present']).lower()});"
        )
    out.append("    }")
    return "\n".join(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    text = Path(path).read_text()
    players, turns = parse_report(text, load_name_to_id())
    if "--json" in sys.argv:
        print(json.dumps({"players": players, "turns": turns}, indent=2))
    else:
        print(f"// Generated from {path} ({len(turns)} turns, deduped)")
        print(to_solidity(players, turns))


if __name__ == "__main__":
    main()

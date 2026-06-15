#!/usr/bin/env python3
"""Single source of truth for the Type enum, parsed from src/Enums.sol.

Every processing script that needs the type list / name→index mapping imports from
here instead of hardcoding it, so a change to Enums.sol propagates automatically.
"""

import re
from pathlib import Path

ENUMS_SOL = Path(__file__).resolve().parent.parent / "src" / "Enums.sol"


def _parse_type_names() -> list[str]:
    m = re.search(r"enum\s+Type\s*\{([^}]*)\}", ENUMS_SOL.read_text())
    if not m:
        raise RuntimeError(f"Type enum not found in {ENUMS_SOL}")
    return [n.strip() for n in m.group(1).split(",") if n.strip()]


# Enum order, including the trailing `None` sentinel.
TYPE_NAMES: list[str] = _parse_type_names()
# Name -> enum index (e.g. {"Yin": 0, ..., "None": 14}).
TYPE_INDEX: dict[str, int] = {name: i for i, name in enumerate(TYPE_NAMES)}
# Real types only (excludes the `None` single-type sentinel).
REAL_TYPE_NAMES: list[str] = [n for n in TYPE_NAMES if n != "None"]

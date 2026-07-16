#!/usr/bin/env python3
"""
Static check that every IEffect contract's getStepsBitmap() correctly sets
ALWAYS_APPLIES_BIT (0x8000) when-and-only-when the contract has no real
shouldApply() gating logic of its own.

Background: Engine._addEffectInternal skips the external shouldApply() call
entirely when ALWAYS_APPLIES_BIT is set on the returned bitmap (see
src/Constants.sol / src/Engine.sol). BasicEffect's default shouldApply()
unconditionally returns true, so any contract that inherits BasicEffect
directly and does not override shouldApply() can safely set the bit to skip
a wasted external call. Contracts that inherit StatusEffect (or otherwise
override shouldApply() with real gating logic) must NOT set the bit, since
that would make the Engine skip their gating entirely.

This script has no CSV to check against - it's pure Solidity source
inspection, run over every contract under src/ that participates in the
IEffect hierarchy (declares `is ... BasicEffect ...` or `is ... StatusEffect ...`).
"""

import os
import re
import sys

ALWAYS_APPLIES_BIT = 0x8000

CONTRACT_RE = re.compile(r"\bcontract\s+(\w+)\s+is\s+([^{]+?)\s*\{", re.DOTALL)
STEPS_FN_RE = re.compile(r"function\s+getStepsBitmap\s*\([^)]*\)[^{]*\{(.*?)\}", re.DOTALL)
RETURN_RE = re.compile(r"return\s+([^;]+);")
SHOULD_APPLY_FN_RE = re.compile(r"\bfunction\s+shouldApply\s*\(")


def find_sol_files(src_path):
    for root, _dirs, files in os.walk(src_path):
        for f in files:
            if f.endswith(".sol"):
                yield os.path.join(root, f)


def parse_steps_expr(expr):
    """Return (has_always_bit, is_literal) for a getStepsBitmap() return expression."""
    expr = expr.strip()
    if "ALWAYS_APPLIES_BIT" in expr:
        return True, True
    # Try to parse the whole expression as a constant int (hex or decimal literal,
    # optionally OR'd together, e.g. "0x8000 | 0x04").
    parts = [p.strip() for p in expr.split("|")]
    total = 0
    for p in parts:
        try:
            total |= int(p, 0)
        except ValueError:
            return False, False
    return (total & ALWAYS_APPLIES_BIT) != 0, True


def check_file(path):
    """Return a list of (severity, message) issues found in this file."""
    with open(path, "r") as f:
        text = f.read()

    issues = []
    for match in CONTRACT_RE.finditer(text):
        name, bases_str = match.group(1), match.group(2)
        bases = [b.strip() for b in bases_str.split(",")]

        is_status = "StatusEffect" in bases
        is_basic = "BasicEffect" in bases
        if not is_status and not is_basic:
            continue

        steps_match = STEPS_FN_RE.search(text)
        if not steps_match:
            # Abstract base / interface with no getStepsBitmap body - not our concern.
            continue
        return_match = RETURN_RE.search(steps_match.group(1))
        if not return_match:
            issues.append(("warn", f"{name}: could not find a return statement in getStepsBitmap()"))
            continue

        has_bit, parsed_ok = parse_steps_expr(return_match.group(1))
        if not parsed_ok:
            issues.append((
                "warn",
                f"{name}: getStepsBitmap() returns a non-literal expression "
                f"({return_match.group(1).strip()!r}) - could not verify ALWAYS_APPLIES_BIT usage",
            ))
            continue

        has_own_should_apply = bool(SHOULD_APPLY_FN_RE.search(text))

        if is_status or has_own_should_apply:
            # Real gating logic (either inherited from StatusEffect or defined locally) -
            # the bit must NOT be set, or the Engine will bypass that logic entirely.
            if has_bit:
                issues.append((
                    "error",
                    f"{name}: has custom shouldApply() gating but ALWAYS_APPLIES_BIT is set - "
                    f"this makes the Engine skip the gate entirely",
                ))
        else:
            # Relies on BasicEffect's default (unconditional true) shouldApply() -
            # the bit should be set to skip the wasted external call.
            if not has_bit:
                issues.append((
                    "error",
                    f"{name}: relies on BasicEffect's default shouldApply() (always true) but "
                    f"ALWAYS_APPLIES_BIT is not set in getStepsBitmap() - missed optimization "
                    f"(see src/Constants.sol ALWAYS_APPLIES_BIT)",
                ))

    return issues


def run(src_path="src/"):
    all_issues = []
    for path in sorted(find_sol_files(src_path)):
        rel = os.path.relpath(path)
        for severity, message in check_file(path):
            all_issues.append((severity, rel, message))

    errors = [i for i in all_issues if i[0] == "error"]
    warnings = [i for i in all_issues if i[0] == "warn"]

    for _severity, rel, message in warnings:
        print(f"WARNING {rel}: {message}")
    for _severity, rel, message in errors:
        print(f"ERROR {rel}: {message}")

    if errors:
        print(f"\n❌ {len(errors)} effect bitmap issue(s) found.")
        return False

    print(f"\n✅ All {sum(1 for _ in find_sol_files(src_path))} Solidity files checked - effect bitmaps OK.")
    return True


def main():
    src_path = sys.argv[1] if len(sys.argv) > 1 else "src/"
    if not run(src_path):
        sys.exit(1)


if __name__ == "__main__":
    main()

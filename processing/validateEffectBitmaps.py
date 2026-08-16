#!/usr/bin/env python3
"""
Static checks on every IEffect contract's getStepsBitmap() under src/:

1. ALWAYS_APPLIES_BIT (0x8000) is set when-and-only-when the contract has no shouldApply()
   gating logic of its own. Engine._addEffectInternal skips the external shouldApply() call
   entirely when the bit is set; BasicEffect's default shouldApply() unconditionally returns
   true, so any contract relying on it should set the bit (skipping a wasted external call),
   and any contract with a real shouldApply() override must NOT set it.

2. Status class bits (10-13): deployable ids are 1..14, unique across src/ (two statuses
   sharing an id would make the Engine treat one as a re-apply of the other). Id 15 is
   reserved for test-only mocks (test/mocks/TestStatusClass.sol) and rejected in src/.

3. HAS_REAPPLY_BIT (0x4000) is set when-and-only-when the contract implements onReapply()
   (the Engine calls it on a same-class re-apply iff the bit is set), and requires a nonzero
   status class.

Pure Solidity source inspection over every contract in the IEffect hierarchy (declares
`is ... BasicEffect ...` or `is ... StatusEffect ...`). Bitmap expressions may reference
constants declared in the same file (e.g. STATUS_CLASS) plus the shared Constants.sol names.
"""

import os
import re
import sys

ALWAYS_APPLIES_BIT = 0x8000
HAS_REAPPLY_BIT = 0x4000
STATUS_CLASS_SHIFT = 10
STATUS_CLASS_MASK = 0xF

# Shared names resolvable inside bitmap expressions (mirrors src/Constants.sol and
# test/mocks/TestStatusClass.sol).
KNOWN_CONSTANTS = {
    "ALWAYS_APPLIES_BIT": ALWAYS_APPLIES_BIT,
    "HAS_REAPPLY_BIT": HAS_REAPPLY_BIT,
    "STATUS_CLASS_SHIFT": STATUS_CLASS_SHIFT,
    "STATUS_CLASS_MASK": STATUS_CLASS_MASK,
    "TEST_STATUS_CLASS": 15,
}

CONTRACT_RE = re.compile(r"\bcontract\s+(\w+)\s+is\s+([^{]+?)\s*\{", re.DOTALL)
STEPS_FN_RE = re.compile(r"function\s+getStepsBitmap\s*\([^)]*\)[^{]*\{(.*?)\}", re.DOTALL)
RETURN_RE = re.compile(r"return\s+([^;]+);")
SHOULD_APPLY_FN_RE = re.compile(r"\bfunction\s+shouldApply\s*\(")
ON_REAPPLY_FN_RE = re.compile(r"\bfunction\s+onReapply\s*\(")
CONSTANT_DECL_RE = re.compile(
    r"\buint\d*\s+(?:public\s+|private\s+|internal\s+)?constant\s+(\w+)\s*=\s*([^;]+);"
)
SAFE_EXPR_RE = re.compile(r"^[\s0-9a-fA-FxX|&()<>+]*$")


def _collect_constants(text):
    """Same-file constant declarations, resolved iteratively so one constant may
    reference another (or the shared KNOWN_CONSTANTS)."""
    consts = dict(KNOWN_CONSTANTS)
    decls = CONSTANT_DECL_RE.findall(text)
    for _ in range(len(decls) + 1):
        progressed = False
        for name, expr in decls:
            if name in consts and name not in KNOWN_CONSTANTS:
                continue
            val = _eval_expr(expr, consts)
            if val is not None:
                if consts.get(name) != val:
                    progressed = True
                consts[name] = val
        if not progressed:
            break
    return consts


def _eval_expr(expr, consts):
    """Evaluate a Solidity constant expression of hex/dec literals, |, &, <<, >>, and
    parentheses. uintN(...) casts are stripped. Returns None if unresolvable."""
    expr = expr.strip()
    expr = re.sub(r"\buint\d*\s*\(", "(", expr)
    for name, val in sorted(consts.items(), key=lambda kv: -len(kv[0])):
        expr = re.sub(r"\b" + re.escape(name) + r"\b", str(val), expr)
    # Unresolved identifier = a letter-initiated token (hex literals like 0x801D start with a
    # digit, so their letter digits don't trip this).
    if not SAFE_EXPR_RE.match(expr) or re.search(r"(?<!\w)[a-zA-Z_]\w*", expr):
        return None
    try:
        return eval(expr, {"__builtins__": {}}, {})  # noqa: S307 - char-whitelisted arithmetic
    except Exception:
        return None


def check_file(path, class_registry):
    """Return a list of (severity, message) issues found in this file."""
    with open(path, "r") as f:
        text = f.read()

    issues = []
    for match in CONTRACT_RE.finditer(text):
        name, bases_str = match.group(1), match.group(2)
        bases = [b.strip() for b in bases_str.split(",")]

        if "StatusEffect" not in bases and "BasicEffect" not in bases:
            continue

        steps_match = STEPS_FN_RE.search(text)
        if not steps_match:
            # Abstract base / interface with no getStepsBitmap body - not our concern.
            continue
        return_match = RETURN_RE.search(steps_match.group(1))
        if not return_match:
            issues.append(("warn", f"{name}: could not find a return statement in getStepsBitmap()"))
            continue

        bitmap = _eval_expr(return_match.group(1), _collect_constants(text))
        if bitmap is None:
            issues.append((
                "error",
                f"{name}: getStepsBitmap() returns an unresolvable expression "
                f"({return_match.group(1).strip()!r}) - cannot verify bitmap invariants",
            ))
            continue

        has_always = (bitmap & ALWAYS_APPLIES_BIT) != 0
        has_reapply_bit = (bitmap & HAS_REAPPLY_BIT) != 0
        status_class = (bitmap >> STATUS_CLASS_SHIFT) & STATUS_CLASS_MASK

        has_own_should_apply = bool(SHOULD_APPLY_FN_RE.search(text))
        has_own_on_reapply = bool(ON_REAPPLY_FN_RE.search(text))

        # Rule 1: ALWAYS_APPLIES_BIT <=> no shouldApply override.
        if has_own_should_apply and has_always:
            issues.append((
                "error",
                f"{name}: has custom shouldApply() gating but ALWAYS_APPLIES_BIT is set - "
                f"this makes the Engine skip the gate entirely",
            ))
        elif not has_own_should_apply and not has_always:
            issues.append((
                "error",
                f"{name}: relies on BasicEffect's default shouldApply() (always true) but "
                f"ALWAYS_APPLIES_BIT is not set in getStepsBitmap() - missed optimization "
                f"(see src/Constants.sol ALWAYS_APPLIES_BIT)",
            ))

        # Rule 2: status class range + uniqueness (deployable ids are 1..14; 15 is test-only).
        if status_class == 15:
            issues.append((
                "error",
                f"{name}: status class 15 is reserved for test mocks "
                f"(test/mocks/TestStatusClass.sol) - deployable statuses use 1..14",
            ))
        elif status_class != 0:
            prior = class_registry.get(status_class)
            if prior is not None:
                issues.append((
                    "error",
                    f"{name}: status class {status_class} already used by {prior} - the Engine "
                    f"would treat one as a re-apply of the other",
                ))
            else:
                class_registry[status_class] = name

        # Rule 3: HAS_REAPPLY_BIT <=> onReapply implemented, and requires a class.
        if has_reapply_bit and not has_own_on_reapply:
            issues.append((
                "error",
                f"{name}: HAS_REAPPLY_BIT is set but onReapply() is not implemented - the "
                f"Engine's same-class re-apply call would revert",
            ))
        elif has_own_on_reapply and not has_reapply_bit:
            issues.append((
                "error",
                f"{name}: implements onReapply() but HAS_REAPPLY_BIT is not set - the Engine "
                f"would never call it",
            ))
        if has_reapply_bit and status_class == 0:
            issues.append((
                "error",
                f"{name}: HAS_REAPPLY_BIT requires a nonzero status class (bits 10-13)",
            ))

    return issues


def run(src_path="src/"):
    all_issues = []
    class_registry = {}
    for path in sorted(find_sol_files(src_path)):
        rel = os.path.relpath(path)
        for severity, message in check_file(path, class_registry):
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

    used = ", ".join(f"{c}={n}" for c, n in sorted(class_registry.items()))
    print(f"\n✅ All {sum(1 for _ in find_sol_files(src_path))} Solidity files checked - effect bitmaps OK.")
    print(f"   Status classes in use: {used or '(none)'}")
    return True


def find_sol_files(src_path):
    for root, _dirs, files in os.walk(src_path):
        for f in files:
            if f.endswith(".sol"):
                yield os.path.join(root, f)


def main():
    src_path = sys.argv[1] if len(sys.argv) > 1 else "src/"
    if not run(src_path):
        sys.exit(1)


if __name__ == "__main__":
    main()

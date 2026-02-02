"""
Yul/Assembly transpiler for inline assembly blocks.

This module handles the conversion of Yul (inline assembly) code to
TypeScript equivalents for storage operations and other low-level functions.
"""

import re
from typing import Dict, List


# =============================================================================
# PRECOMPILED REGEX PATTERNS
# =============================================================================

# Patterns for normalizing Yul code from the tokenizer
YUL_NORMALIZE_PATTERNS = [
    (re.compile(r':\s*='), ':='),           # ": =" -> ":="
    (re.compile(r'\s*\.\s*'), '.'),         # " . " -> "."
    (re.compile(r'(\w)\s+\('), r'\1('),     # "func (" -> "func("
    (re.compile(r'\(\s+'), '('),            # "( " -> "("
    (re.compile(r'\s+\)'), ')'),            # " )" -> ")"
    (re.compile(r'\s+,'), ','),             # " ," -> ","
    (re.compile(r',\s+'), ', '),            # normalize comma spacing
]

# Patterns for parsing Yul constructs
YUL_LET_PATTERN = re.compile(
    r'let\s+(\w+)\s*:=\s*([^{}\n]+?)(?=\s+(?:let|if|for|switch|sstore|mstore|revert|log\d)\b|\s*}|\s*$)'
)
YUL_SLOT_PATTERN = re.compile(r'(\w+)\.slot')
YUL_IF_PATTERN = re.compile(r'if\s+([^{]+)\s*\{([^}]*)\}')
YUL_IF_STRIP_PATTERN = re.compile(r'if\s+[^{]+\{[^}]*\}')
YUL_CALL_PATTERN = re.compile(r'\b(sstore|mstore|revert|log[0-4])\s*\(([^)]+)\)')


class YulTranspiler:
    """
    Transpiler for Yul/inline assembly code.

    Converts Yul assembly blocks to equivalent TypeScript code for
    simulation purposes.

    Key Yul operations and their TypeScript equivalents:
    - sload(slot) → this._storageRead(slotKey)
    - sstore(slot, value) → this._storageWrite(slotKey, value)
    - var.slot → get storage key for variable
    - mstore/mload → memory operations (usually no-op for simulation)
    """

    def __init__(self, known_constants: set = None):
        """Initialize with optional set of known constant names.

        Args:
            known_constants: Set of constant names that should be prefixed with 'Constants.'
        """
        self._known_constants = known_constants or set()

    def transpile(self, yul_code: str) -> str:
        """
        Transpile a Yul assembly block to TypeScript.

        Args:
            yul_code: The raw Yul code string

        Returns:
            TypeScript code equivalent
        """
        code = self._normalize(yul_code)
        slot_vars: Dict[str, str] = {}
        return self._transpile_block(code, slot_vars)

    def _normalize(self, code: str) -> str:
        """Normalize Yul code by fixing tokenizer spacing."""
        code = ' '.join(code.split())
        for pattern, replacement in YUL_NORMALIZE_PATTERNS:
            code = pattern.sub(replacement, code)
        return code

    def _transpile_block(self, code: str, slot_vars: Dict[str, str]) -> str:
        """Transpile a block of Yul code to TypeScript."""
        lines = []

        # Parse let bindings: let var := expr
        for match in YUL_LET_PATTERN.finditer(code):
            var_name = match.group(1)
            expr = match.group(2).strip()

            # Check if this is a .slot access (storage key)
            slot_match = YUL_SLOT_PATTERN.match(expr)
            if slot_match:
                storage_var = slot_match.group(1)
                slot_vars[var_name] = storage_var
                lines.append(f'const {var_name} = this._getStorageKey({storage_var} as any);')
            else:
                ts_expr = self._transpile_expr(expr, slot_vars)
                lines.append(f'let {var_name} = {ts_expr};')

        # Parse if statements: if cond { body }
        for match in YUL_IF_PATTERN.finditer(code):
            cond = match.group(1).strip()
            body = match.group(2).strip()

            ts_cond = self._transpile_expr(cond, slot_vars)
            ts_body = self._transpile_block(body, slot_vars)

            lines.append(f'if ({ts_cond}) {{')
            for line in ts_body.split('\n'):
                if line.strip():
                    lines.append(f'  {line}')
            lines.append('}')

        # Parse standalone function calls (sstore, mstore, etc.)
        # Remove if block contents to avoid matching calls inside them
        code_without_ifs = YUL_IF_STRIP_PATTERN.sub('', code)
        for match in YUL_CALL_PATTERN.finditer(code_without_ifs):
            func = match.group(1)
            args = match.group(2)
            ts_stmt = self._transpile_call(func, args, slot_vars)
            if ts_stmt:
                lines.append(ts_stmt)

        return '\n'.join(lines) if lines else '// Assembly: no-op'

    def _split_args(self, args_str: str) -> List[str]:
        """Split Yul function arguments respecting nested parentheses."""
        args = []
        current = ''
        depth = 0
        for char in args_str:
            if char == '(':
                depth += 1
                current += char
            elif char == ')':
                depth -= 1
                current += char
            elif char == ',' and depth == 0:
                if current.strip():
                    args.append(current.strip())
                current = ''
            else:
                current += char
        if current.strip():
            args.append(current.strip())
        return args

    def _transpile_expr(self, expr: str, slot_vars: Dict[str, str]) -> str:
        """Transpile a Yul expression to TypeScript."""
        expr = expr.strip()

        # sload(slot) - storage read
        sload_match = re.match(r'sload\((\w+)\)', expr)
        if sload_match:
            slot = sload_match.group(1)
            if slot in slot_vars:
                return f'this._storageRead({slot_vars[slot]} as any)'
            return f'this._storageRead({slot})'

        # Function calls (including no-argument calls)
        call_match = re.match(r'(\w+)\((.*)\)', expr)
        if call_match:
            func_name = call_match.group(1)
            args_str = call_match.group(2)

            # Special functions
            if func_name == 'sload':
                args = self._split_args(args_str)
                if args:
                    slot = args[0]
                    if slot in slot_vars:
                        return f'this._storageRead({slot_vars[slot]} as any)'
                    return f'this._storageRead({slot})'
            elif func_name == 'add':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) + BigInt({right}))'
            elif func_name == 'sub':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) - BigInt({right}))'
            elif func_name == 'mul':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) * BigInt({right}))'
            elif func_name == 'div':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) / BigInt({right}))'
            elif func_name == 'mod':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) % BigInt({right}))'
            elif func_name == 'and':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) & BigInt({right}))'
            elif func_name == 'or':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) | BigInt({right}))'
            elif func_name == 'xor':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) ^ BigInt({right}))'
            elif func_name == 'not':
                args = self._split_args(args_str)
                if args:
                    operand = self._transpile_expr(args[0], slot_vars)
                    return f'(~BigInt({operand}))'
            elif func_name == 'shl':
                args = self._split_args(args_str)
                if len(args) == 2:
                    shift = self._transpile_expr(args[0], slot_vars)
                    val = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({val}) << BigInt({shift}))'
            elif func_name == 'shr':
                args = self._split_args(args_str)
                if len(args) == 2:
                    shift = self._transpile_expr(args[0], slot_vars)
                    val = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({val}) >> BigInt({shift}))'
            elif func_name == 'eq':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) === BigInt({right}) ? 1n : 0n)'
            elif func_name == 'lt':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) < BigInt({right}) ? 1n : 0n)'
            elif func_name == 'gt':
                args = self._split_args(args_str)
                if len(args) == 2:
                    left = self._transpile_expr(args[0], slot_vars)
                    right = self._transpile_expr(args[1], slot_vars)
                    return f'(BigInt({left}) > BigInt({right}) ? 1n : 0n)'
            elif func_name == 'iszero':
                args = self._split_args(args_str)
                if args:
                    operand = self._transpile_expr(args[0], slot_vars)
                    return f'(BigInt({operand}) === 0n ? 1n : 0n)'
            elif func_name in ('mload', 'calldataload'):
                # Memory/calldata operations - return placeholder
                return '0n'
            elif func_name == 'caller':
                return 'this._msgSender()'
            elif func_name == 'timestamp':
                return 'BigInt(Math.floor(Date.now() / 1000))'
            elif func_name == 'number':
                return '0n  // block number placeholder'
            elif func_name == 'gas':
                return '1000000n  // gas placeholder'
            elif func_name == 'returndatasize':
                return '0n'

            # Generic function call transpilation
            args = self._split_args(args_str)
            ts_args = [self._transpile_expr(a, slot_vars) for a in args]
            return f'{func_name}({", ".join(ts_args)})'

        # .slot access
        slot_match = YUL_SLOT_PATTERN.match(expr)
        if slot_match:
            var_name = slot_match.group(1)
            return f'this._getStorageKey({var_name} as any)'

        # Variable reference (check if it's a slot variable)
        if expr in slot_vars:
            return expr

        # Hex/numeric literals
        if expr.startswith('0x'):
            return f'BigInt("{expr}")'
        if expr.isdigit():
            return f'{expr}n'

        # Check if identifier is a known constant from type registry
        if expr in self._known_constants:
            return f'Constants.{expr}'

        # Return as-is (identifier)
        return expr

    def _transpile_call(
        self,
        func: str,
        args_str: str,
        slot_vars: Dict[str, str]
    ) -> str:
        """Transpile a Yul function call statement to TypeScript."""
        args = self._split_args(args_str)

        if func == 'sstore' and len(args) >= 2:
            slot = args[0]
            value = self._transpile_expr(args[1], slot_vars)
            if slot in slot_vars:
                return f'this._storageWrite({slot_vars[slot]} as any, {value});'
            return f'this._storageWrite({slot}, {value});'
        elif func == 'mstore':
            # Memory store - usually no-op for simulation
            return '// mstore (no-op for simulation)'
        elif func == 'revert':
            if args:
                return f'throw new Error("Revert");'
            return 'throw new Error("Revert");'
        elif func.startswith('log'):
            # Log operations - emit event equivalent
            return f'// {func}({", ".join(args)})'

        return ''

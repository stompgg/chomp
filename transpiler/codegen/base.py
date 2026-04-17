"""
Base generator class with shared utilities.

This module provides the BaseGenerator class that contains common utilities
used across all specialized generator classes in the code generation pipeline.
"""

from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext

from ..parser.ast_nodes import (
    Expression,
    Identifier,
    MemberAccess,
    IndexAccess,
    FunctionCall,
    TypeCast,
    TypeName,
)


class BaseGenerator:
    """
    Base class for all code generators.

    Provides shared utilities for:
    - Indentation management
    - Type name resolution
    - Expression type analysis
    - Value formatting
    """

    def __init__(self, ctx: 'CodeGenerationContext'):
        """
        Initialize the base generator.

        Args:
            ctx: The code generation context containing all state
        """
        self._ctx = ctx

    # =========================================================================
    # INDENTATION
    # =========================================================================

    def indent(self) -> str:
        """Return the current indentation string."""
        return self._ctx.indent()

    @property
    def indent_level(self) -> int:
        """Get the current indentation level."""
        return self._ctx.indent_level

    @indent_level.setter
    def indent_level(self, value: int):
        """Set the current indentation level."""
        self._ctx.indent_level = value

    # =========================================================================
    # NAME RESOLUTION
    # =========================================================================

    def get_qualified_name(self, name: str) -> str:
        """Get the qualified name for a type, adding appropriate prefix if needed.

        Handles Structs., Enums., Constants. prefixes based on the current file context.
        Uses cached lookup for performance optimization.
        """
        return self._ctx.get_qualified_name(name)

    # =========================================================================
    # VALUE FORMATTING
    # =========================================================================

    def _to_padded_address(self, val: str) -> str:
        """Convert a numeric or hex value to a 40-char padded hex address string."""
        if val.startswith('0x') or val.startswith('0X'):
            hex_val = val[2:].lower()
        else:
            hex_val = hex(int(val))[2:]
        return f'"0x{hex_val.zfill(40)}"'

    def _to_padded_bytes32(self, val: str) -> str:
        """Convert a numeric or hex value to a 64-char padded hex bytes32 string."""
        if val == '0':
            return '"0x' + '0' * 64 + '"'
        elif val.startswith('0x') or val.startswith('0X'):
            hex_val = val[2:].lower()
            return f'"0x{hex_val.zfill(64)}"'
        else:
            hex_val = hex(int(val))[2:]
            return f'"0x{hex_val.zfill(64)}"'

    # =========================================================================
    # EXPRESSION ANALYSIS
    # =========================================================================

    def _get_base_var_name(self, expr: Expression) -> Optional[str]:
        """Extract the root variable name from an expression.

        For nested expressions like a.b.c or a[x][y], returns the root 'a'.

        Special case: `this.X` returns 'X' (the state variable name), not 'this',
        because `this` itself isn't a useful key in var_types — the state variable
        lives in var_types under its own name.
        """
        if isinstance(expr, Identifier):
            return None if expr.name == 'this' else expr.name
        if isinstance(expr, MemberAccess):
            # For nested access like a.b.c, walk toward the root. If the deepest
            # identifier is `this` (returns None), fall back to the immediate member
            # so `this.globalKV` resolves to 'globalKV' rather than vanishing.
            base = self._get_base_var_name(expr.expression)
            return base if base is not None else expr.member
        if isinstance(expr, IndexAccess):
            # For nested index like a[x][y], get the root 'a'
            return self._get_base_var_name(expr.base)
        return None

    def _is_bigint_typed_identifier(self, expr: Expression) -> bool:
        """Check if expression is an identifier with uint/int type (bigint in TypeScript)."""
        if isinstance(expr, Identifier):
            name = expr.name
            if name in self._ctx.var_types:
                type_name = self._ctx.var_types[name].name or ''
                return type_name.startswith('uint') or type_name.startswith('int')
        return False

    def _is_already_address_type(self, expr: Expression) -> bool:
        """Check if expression is already an address type (doesn't need ._contractAddress).

        Returns True for expressions like msg.sender, tx.origin, etc. that are
        already strings representing addresses in the TypeScript runtime.
        """
        # Check for msg.sender, msg.origin patterns
        if isinstance(expr, MemberAccess):
            if isinstance(expr.expression, Identifier):
                base_name = expr.expression.name
                member = expr.member
                # msg.sender is already an address string
                if base_name == 'msg' and member == 'sender':
                    return True
                # tx.origin is already an address string
                if base_name == 'tx' and member == 'origin':
                    return True
                # Check if this is a struct field that's already an address type
                if base_name in self._ctx.var_types:
                    type_info = self._ctx.var_types[base_name]
                    if type_info.name and type_info.name in self._ctx.known_struct_fields:
                        struct_fields = self._ctx.known_struct_fields[type_info.name]
                        if member in struct_fields:
                            field_info = struct_fields[member]
                            field_type = field_info[0] if isinstance(field_info, tuple) else field_info
                            if field_type == 'address':
                                return True
        # Check if it's a simple identifier with address type
        if isinstance(expr, Identifier):
            if expr.name in self._ctx.var_types:
                type_info = self._ctx.var_types[expr.name]
                if type_info.name == 'address':
                    return True
        return False

    def _is_numeric_type_cast(self, expr: Expression) -> bool:
        """Check if expression is a numeric type cast (uint160, uint256, etc.).

        Returns True for expressions that cast to integer types and produce bigint values.
        This is used to properly handle address(uint160(...)) patterns.
        """
        # Check for TypeCast to numeric types
        if isinstance(expr, TypeCast):
            type_name = expr.type_name.name
            if type_name.startswith('uint') or type_name.startswith('int'):
                return True
        # Check for function call casts like uint160(x)
        if isinstance(expr, FunctionCall):
            if isinstance(expr.function, Identifier):
                func_name = expr.function.name
                if func_name.startswith('uint') or func_name.startswith('int'):
                    return True
        return False

    def _resolve_access_type(self, expr: Expression):
        """Resolve the TypeName at a given expression point.

        For nested mapping/array access like ``this.m[a][b]``, descends through
        the outer mapping's value_type so the returned TypeName describes the
        container AT THIS LEVEL — critical for picking the right key_type on
        the inner-most access.
        """
        if isinstance(expr, Identifier):
            if expr.name == 'this':
                return None
            return self._ctx.var_types.get(expr.name)
        if isinstance(expr, MemberAccess):
            # this.X → state variable type; other member accesses aren't tracked here.
            if isinstance(expr.expression, Identifier) and expr.expression.name == 'this':
                return self._ctx.var_types.get(expr.member)
            base_type = self._resolve_access_type(expr.expression)
            return base_type  # best-effort — struct field resolution happens elsewhere
        if isinstance(expr, IndexAccess):
            base_type = self._resolve_access_type(expr.base)
            if base_type is None:
                return None
            if base_type.is_mapping:
                return base_type.value_type
            if base_type.is_array:
                # Array element type — strip one level of array-ness
                from ..parser.ast_nodes import TypeName as _TypeName
                return _TypeName(
                    name=base_type.name,
                    is_array=False,
                    is_mapping=False,
                    key_type=None,
                    value_type=None,
                )
            return None
        return None

    def _is_likely_array_access(self, access: IndexAccess) -> bool:
        """Determine if this is an array access (needs Number index) vs mapping access.

        Uses type registry for accurate detection instead of name heuristics.
        """
        # Get the base variable name to look up its type
        base_var_name = self._get_base_var_name(access.base)

        if base_var_name and base_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[base_var_name]
            # Check the type - arrays need Number(), mappings don't
            if type_info.is_array:
                return True
            if type_info.is_mapping:
                return False

        # For member access (e.g., config.p0States[j]), check if the member type is array
        if isinstance(access.base, MemberAccess):
            # The member access itself may be accessing an array field in a struct
            # Without full struct type info, use the index type as a hint
            pass

        # Fallback: check if index is a known integer type variable
        if isinstance(access.index, Identifier):
            index_name = access.index.name
            if index_name in self._ctx.var_types:
                index_type = self._ctx.var_types[index_name]
                # If index is declared as uint/int, it's likely an array access
                if index_type.name and (index_type.name.startswith('uint') or index_type.name.startswith('int')):
                    return True

        return False


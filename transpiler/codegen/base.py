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
        For `this.X` (state-variable access) returns 'X' — the state variable
        is keyed by its own name in ``var_types``, not by `this`.
        """
        if isinstance(expr, Identifier):
            return None if expr.name == 'this' else expr.name
        if isinstance(expr, MemberAccess):
            if self._is_this_access(expr):
                return expr.member
            return self._get_base_var_name(expr.expression)
        if isinstance(expr, IndexAccess):
            return self._get_base_var_name(expr.base)
        return None

    @staticmethod
    def _is_this_access(expr: Expression) -> bool:
        """True when ``expr`` is ``this.<member>`` (state-variable access)."""
        return (
            isinstance(expr, MemberAccess)
            and isinstance(expr.expression, Identifier)
            and expr.expression.name == 'this'
        )

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

    def _resolve_access_type(self, expr: Expression) -> Optional[TypeName]:
        """Resolve the TypeName at a given expression point.

        Descends through mapping/array/struct accesses so the returned TypeName
        describes the container AT THIS LEVEL. Critical for nested access like
        ``this.m[a][b]`` where the inner access needs the INNER mapping's
        key_type, not the outer one's.
        """
        if isinstance(expr, Identifier):
            return None if expr.name == 'this' else self._ctx.var_types.get(expr.name)
        if isinstance(expr, MemberAccess):
            if self._is_this_access(expr):
                return self._ctx.var_types.get(expr.member)
            return self._resolve_struct_field_type(expr)
        if isinstance(expr, IndexAccess):
            container = self._resolve_access_type(expr.base)
            return self._step_into_container(container)
        return None

    def _resolve_struct_field_type(self, expr: MemberAccess) -> Optional[TypeName]:
        """Type of a struct-field access, using ``known_struct_fields``."""
        parent_type = self._resolve_access_type(expr.expression)
        if not parent_type or not parent_type.name:
            return None
        struct_fields = self._ctx.known_struct_fields.get(parent_type.name)
        if not struct_fields:
            return None
        field_info = struct_fields.get(expr.member)
        if not field_info:
            return None
        field_type, field_is_array = (
            field_info if isinstance(field_info, tuple) else (field_info, False)
        )
        return self._field_info_to_type_name(field_type, field_is_array)

    @staticmethod
    def _step_into_container(container: Optional[TypeName]) -> Optional[TypeName]:
        """One indexing step: mapping -> value_type, array -> element type."""
        if container is None:
            return None
        if container.is_mapping:
            return container.value_type
        if container.is_array:
            return TypeName(
                name=container.name,
                is_array=False,
                is_mapping=False,
                key_type=None,
                value_type=None,
            )
        return None

    @staticmethod
    def _field_info_to_type_name(field_type: str, field_is_array: bool) -> Optional[TypeName]:
        """Best-effort TypeName for a struct field entry from ``known_struct_fields``.

        The registry stores field types as strings; full AST TypeNames aren't
        retained. We reconstruct enough for downstream access-type resolution:
        mappings get ``is_mapping=True`` with a numeric key (Solidity mappings
        on struct fields always use primitive keys in this codebase) and arrays
        get ``is_array=True``.
        """
        if not field_type:
            return None
        if field_type.startswith('mapping'):
            return TypeName(
                name=field_type,
                is_mapping=True,
                key_type=TypeName(name='uint256'),
                value_type=TypeName(name='uint256'),
            )
        return TypeName(name=field_type, is_array=field_is_array)

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


"""
Base generator class with shared utilities.

This module provides the BaseGenerator class that contains common utilities
used across all specialized generator classes in the code generation pipeline.
"""

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext


class BaseGenerator:
    """
    Base class for all code generators.

    Provides shared utilities for:
    - Indentation management
    - Type name resolution
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


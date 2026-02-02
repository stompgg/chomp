"""
Type conversion utilities for code generation.

This module provides the TypeConverter class that handles Solidity to TypeScript
type conversions during code generation, with context-awareness for tracking
imports and handling complex type scenarios.
"""

from typing import Optional, Set, Dict, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from ..types import TypeRegistry

from .base import BaseGenerator
from ..parser.ast_nodes import TypeName, Expression, Literal, TypeCast, FunctionCall, Identifier
from ..types.mappings import (
    SOLIDITY_TO_TS_MAP,
    DEFAULT_VALUES,
    get_type_max,
    get_type_min,
)


class TypeConverter(BaseGenerator):
    """
    Handles Solidity to TypeScript type conversions.

    This class provides context-aware type conversion that:
    - Converts Solidity types to TypeScript types
    - Tracks used types for import generation
    - Handles special cases like EnumerableSetLib and contract types
    - Provides default values for TypeScript types
    - Generates type cast expressions
    """

    def __init__(
        self,
        ctx: 'CodeGenerationContext',
        registry: Optional['TypeRegistry'] = None,
    ):
        """
        Initialize the type converter.

        Args:
            ctx: The code generation context
            registry: Optional type registry for struct path lookups
        """
        super().__init__(ctx)
        self._registry = registry

    # =========================================================================
    # MAIN TYPE CONVERSION
    # =========================================================================

    def solidity_type_to_ts(self, type_name: TypeName) -> str:
        """Convert Solidity type to TypeScript type.

        This method handles the full conversion including:
        - Mapping types -> Record<K, V>
        - Array types -> T[]
        - Struct/Enum types with qualified names
        - Contract types with reference tracking
        - EnumerableSetLib types

        Args:
            type_name: The TypeName AST node to convert

        Returns:
            The TypeScript type string
        """
        if type_name.is_mapping:
            # Use Record for consistency with state variable generation
            # Record<string, V> allows [] access and works with Solidity mapping semantics
            value = self.solidity_type_to_ts(type_name.value_type)
            return f'Record<string, {value}>'

        name = type_name.name
        ts_type = 'any'

        if name.startswith('uint') or name.startswith('int'):
            ts_type = 'bigint'
        elif name == 'bool':
            ts_type = 'boolean'
        elif name == 'address':
            ts_type = 'string'
        elif name == 'string':
            ts_type = 'string'
        elif name.startswith('bytes'):
            ts_type = 'string'  # hex string
        elif name in self._ctx.known_interfaces:
            ts_type = 'any'  # Interfaces become 'any' in TypeScript
        elif name in self._ctx.known_structs or name in self._ctx.known_enums:
            ts_type = self.get_qualified_name(name)
            # Track external structs (from files other than Structs.ts)
            if self._registry and name in self._registry.struct_paths:
                self._ctx.external_structs_used[name] = self._registry.struct_paths[name]
        elif name in self._ctx.known_contracts:
            # Contract type - track for import generation
            self._ctx.contracts_referenced.add(name)
            ts_type = name
        elif name.startswith('EnumerableSetLib.'):
            # Handle EnumerableSetLib types - runtime exports them directly
            set_type = name.split('.')[1]  # e.g., 'Uint256Set'
            self._ctx.set_types_used.add(set_type)
            ts_type = set_type
        else:
            ts_type = name  # Other custom types

        if type_name.is_array:
            # Handle multi-dimensional arrays
            dimensions = getattr(type_name, 'array_dimensions', 1) or 1
            ts_type = ts_type + '[]' * dimensions

        return ts_type

    def default_value(self, ts_type: str) -> str:
        """Get default value for TypeScript type.

        Args:
            ts_type: The TypeScript type string

        Returns:
            The default value expression as a string
        """
        if ts_type == 'bigint':
            return '0n'
        elif ts_type == 'boolean':
            return 'false'
        elif ts_type == 'string':
            return '""'
        elif ts_type == 'number':
            return '0'
        elif ts_type.endswith('[]'):
            return '[]'
        elif ts_type.startswith('Map<') or ts_type.startswith('Record<'):
            return '{}'
        elif ts_type.startswith('Structs.') or ts_type.startswith('Enums.'):
            # Struct types should be initialized as empty objects
            return f'{{}} as {ts_type}'
        elif ts_type in self._ctx.known_structs:
            return f'{{}} as {ts_type}'
        return 'undefined as any'

    # =========================================================================
    # TYPE CAST GENERATION
    # =========================================================================

    def generate_type_cast(
        self,
        cast: TypeCast,
        generate_expression_fn,
    ) -> str:
        """Generate type cast - simplified for simulation (no strict bit masking).

        Args:
            cast: The TypeCast AST node
            generate_expression_fn: Function to generate expressions (injected to avoid circular deps)

        Returns:
            The TypeScript code for the type cast
        """
        type_name = cast.type_name.name
        inner_expr = cast.expression

        # Handle address literals like address(0xdead) and address(this)
        if type_name == 'address':
            if isinstance(inner_expr, Literal) and inner_expr.kind in ('number', 'hex'):
                return self._to_padded_address(inner_expr.value)
            # Handle address(this) -> this._contractAddress
            if isinstance(inner_expr, Identifier) and inner_expr.name == 'this':
                return 'this._contractAddress'
            # Check if inner expression is already an address type (msg.sender, tx.origin, etc.)
            if self._is_already_address_type(inner_expr):
                return generate_expression_fn(inner_expr)

            # Check if inner expression is a numeric type cast (uint160, uint256, etc.)
            # In this case, the result is a bigint that needs to be converted to hex address string
            is_numeric_cast = self._is_numeric_type_cast(inner_expr)

            expr = generate_expression_fn(inner_expr)
            if expr.startswith('"') or expr.startswith("'"):
                return expr

            # If the inner expression is a numeric cast (like uint160(...)), convert bigint to address string
            if is_numeric_cast:
                return f'`0x${{({expr}).toString(16).padStart(40, "0")}}`'

            # Handle address(someContract) -> someContract._contractAddress
            if expr != 'this' and not expr.startswith('"') and not expr.startswith("'"):
                return f'{expr}._contractAddress'

        # Handle bytes32 literals
        if type_name == 'bytes32':
            if isinstance(inner_expr, Literal) and inner_expr.kind in ('number', 'hex'):
                return self._to_padded_bytes32(inner_expr.value)

        # Handle bytes types
        if type_name.startswith('bytes') and type_name != 'bytes':
            if isinstance(inner_expr, Literal) and inner_expr.kind in ('number', 'hex'):
                return self._to_padded_bytes32(inner_expr.value)

        # For numeric types (uint256, int128, etc.), just generate the inner expression
        # TypeScript's bigint handles the underlying value
        if type_name.startswith('uint') or type_name.startswith('int'):
            expr = generate_expression_fn(inner_expr)
            # Wrap in BigInt() if needed for type conversion
            return f'BigInt({expr})'

        # Default: generate the inner expression
        return generate_expression_fn(inner_expr)

    # =========================================================================
    # TYPE UTILITIES
    # =========================================================================

    def get_type_max(self, type_name: str) -> str:
        """Get the maximum value for a Solidity integer type."""
        return get_type_max(type_name)

    def get_type_min(self, type_name: str) -> str:
        """Get the minimum value for a Solidity integer type."""
        return get_type_min(type_name)

    def is_numeric_type(self, type_name: str) -> bool:
        """Check if a type name is a numeric type (uint/int)."""
        return type_name.startswith('uint') or type_name.startswith('int')

    def is_bytes_type(self, type_name: str) -> bool:
        """Check if a type name is a bytes type."""
        return type_name.startswith('bytes')

    def is_address_type(self, type_name: str) -> bool:
        """Check if a type name is an address type."""
        return type_name == 'address'

    def is_bool_type(self, type_name: str) -> bool:
        """Check if a type name is a boolean type."""
        return type_name == 'bool'

    def is_string_type(self, type_name: str) -> bool:
        """Check if a type name is a string type."""
        return type_name == 'string'

    def is_value_type(self, type_name: str) -> bool:
        """Check if a type name is a value type (not reference type)."""
        return (
            self.is_numeric_type(type_name) or
            self.is_bytes_type(type_name) or
            self.is_address_type(type_name) or
            self.is_bool_type(type_name)
        )

    def is_reference_type(self, type_name: str) -> bool:
        """Check if a type name is a reference type (struct, array, mapping, string)."""
        return (
            type_name == 'string' or
            type_name.endswith('[]') or
            type_name in self._ctx.known_structs or
            type_name.startswith('mapping')
        )

    def get_mapping_value_type(self, type_name: TypeName) -> Optional[str]:
        """Get the value type of a mapping, recursively handling nested mappings."""
        if not type_name.is_mapping:
            return None

        value_type = type_name.value_type
        if value_type.is_mapping:
            return self.get_mapping_value_type(value_type)
        return self.solidity_type_to_ts(value_type)

    def get_array_element_type(self, type_name: TypeName) -> str:
        """Get the element type of an array."""
        if not type_name.is_array:
            return self.solidity_type_to_ts(type_name)

        # Create a copy without the array flag to get the element type
        element_type = TypeName(
            name=type_name.name,
            is_array=False,
            is_mapping=type_name.is_mapping,
            key_type=type_name.key_type,
            value_type=type_name.value_type,
        )
        return self.solidity_type_to_ts(element_type)

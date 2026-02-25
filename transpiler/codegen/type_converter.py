"""
Type conversion utilities for code generation.

This module provides the TypeConverter class that handles Solidity to TypeScript
type conversions during code generation, with context-awareness for tracking
imports and handling complex type scenarios.
"""

from typing import Optional, Set, Dict, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from ..type_system import TypeRegistry

from .base import BaseGenerator
from ..parser.ast_nodes import TypeName, Expression, Literal, TypeCast, FunctionCall, Identifier


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

        # Handle Library.Struct pattern (e.g., SignedCommitLib.SignedCommit)
        # In TypeScript, the struct is exported as a top-level interface
        if '.' in name:
            parts = name.split('.')
            # Check if the last part is a known struct
            struct_name = parts[-1]
            if struct_name in self._ctx.known_structs:
                # Use just the struct name and track it as an external struct
                # The struct comes from the library's module
                library_name = parts[0]
                if self._registry and library_name in self._registry.contract_paths:
                    self._ctx.external_structs_used[struct_name] = self._registry.contract_paths[library_name]
                return struct_name

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
            ts_type = name
            # Track for import generation
            self._ctx.contracts_referenced.add(name)
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
        elif ts_type in self._ctx.known_interfaces or ts_type in self._ctx.known_contracts:
            return '{ _contractAddress: "0x0000000000000000000000000000000000000000" } as any'
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

        # payable(x) is equivalent to address(x) for simulation
        if type_name == 'payable':
            type_name = 'address'

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

        # Handle bytes32 literals and expressions
        if type_name == 'bytes32':
            if isinstance(inner_expr, Literal):
                if inner_expr.kind in ('number', 'hex'):
                    return self._to_padded_bytes32(inner_expr.value)
                elif inner_expr.kind == 'string':
                    # Convert string literal to hex-encoded bytes32
                    # Remove quotes from string value
                    string_val = inner_expr.value.strip('"\'')
                    hex_bytes = string_val.encode('utf-8').hex()
                    # Pad to 64 hex chars (32 bytes)
                    hex_bytes = hex_bytes.ljust(64, '0')
                    return f'"0x{hex_bytes}"'
            # Non-literal: convert bigint to padded hex string at runtime
            # Wrap in parens to ensure correct operator precedence
            expr = generate_expression_fn(inner_expr)
            return f'`0x${{({expr}).toString(16).padStart(64, "0")}}`'

        # Handle bytes types
        if type_name.startswith('bytes') and type_name != 'bytes':
            byte_size = int(type_name[5:]) if type_name[5:].isdigit() else 32
            if isinstance(inner_expr, Literal):
                if inner_expr.kind in ('number', 'hex'):
                    return self._to_padded_bytes32(inner_expr.value)
                elif inner_expr.kind == 'string':
                    # Convert string literal to hex-encoded bytes
                    string_val = inner_expr.value.strip('"\'')
                    hex_bytes = string_val.encode('utf-8').hex()
                    # Pad to appropriate size
                    hex_bytes = hex_bytes.ljust(byte_size * 2, '0')
                    return f'"0x{hex_bytes}"'
            # Non-literal: convert bigint to padded hex string at runtime
            # Wrap in parens to ensure correct operator precedence
            expr = generate_expression_fn(inner_expr)
            return f'`0x${{({expr}).toString(16).padStart({byte_size * 2}, "0")}}`'

        # For numeric types (uint256, int128, etc.), just generate the inner expression
        # TypeScript's bigint handles the underlying value
        if type_name.startswith('uint') or type_name.startswith('int'):
            expr = generate_expression_fn(inner_expr)
            # Wrap in BigInt() if needed for type conversion
            return f'BigInt({expr})'

        # Default: generate the inner expression
        return generate_expression_fn(inner_expr)

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

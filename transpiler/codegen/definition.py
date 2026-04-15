"""
Definition generation for Solidity to TypeScript transpilation.

This module handles the generation of TypeScript code from Solidity type
definitions including structs, enums, and constants.
"""

from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from .expression import ExpressionGenerator
    from .type_converter import TypeConverter

from .base import BaseGenerator
from ..parser.ast_nodes import (
    StructDefinition,
    EnumDefinition,
    StateVariableDeclaration,
    TypeName,
)


class DefinitionGenerator(BaseGenerator):
    """
    Generates TypeScript code from Solidity type definitions.

    This class handles:
    - Struct definitions (as interfaces with factory functions)
    - Enum definitions
    - Constant definitions
    """

    def __init__(
        self,
        ctx: 'CodeGenerationContext',
        type_converter: 'TypeConverter',
        expr_generator: Optional['ExpressionGenerator'] = None,
    ):
        """
        Initialize the definition generator.

        Args:
            ctx: The code generation context
            type_converter: The type converter
            expr_generator: Optional expression generator for constant values
        """
        super().__init__(ctx)
        self._type_converter = type_converter
        self._expr = expr_generator

    # =========================================================================
    # ENUMS
    # =========================================================================

    def generate_enum(self, enum: EnumDefinition) -> str:
        """Generate TypeScript enum.

        Args:
            enum: The enum definition AST node

        Returns:
            TypeScript enum code
        """
        lines = []
        lines.append(f'export enum {enum.name} {{')
        for i, member in enumerate(enum.members):
            lines.append(f'  {member} = {i},')
        lines.append('}\n')
        return '\n'.join(lines)

    # =========================================================================
    # CONSTANTS
    # =========================================================================

    def generate_constant(self, const: StateVariableDeclaration) -> str:
        """Generate TypeScript constant.

        Args:
            const: The state variable declaration (with constant modifier)

        Returns:
            TypeScript const declaration
        """
        ts_type = self._type_converter.solidity_type_to_ts(const.type_name)
        if const.initial_value and self._expr:
            value = self._expr.generate(const.initial_value)
        else:
            value = self._type_converter.default_value(ts_type)
        return f'export const {const.name}: {ts_type} = {value};\n'

    # =========================================================================
    # STRUCTS
    # =========================================================================

    def generate_struct(self, struct: StructDefinition) -> str:
        """Generate TypeScript interface for struct with a factory function.

        In Solidity, reading from a mapping returns a zero-initialized struct.
        We generate a factory function to create properly initialized structs.

        Args:
            struct: The struct definition AST node

        Returns:
            TypeScript interface and factory function code
        """
        lines = []

        # Generate interface
        lines.append(f'export interface {struct.name} {{')
        for member in struct.members:
            ts_type = self._type_converter.solidity_type_to_ts(member.type_name)
            lines.append(f'  {member.name}: {ts_type};')
        lines.append('}\n')

        # Generate factory function for creating default-initialized struct
        lines.append(f'export function createDefault{struct.name}(): {struct.name} {{')
        lines.append('  return {')
        for member in struct.members:
            ts_type = self._type_converter.solidity_type_to_ts(member.type_name)
            default_val = self._type_converter.default_value(ts_type, member.type_name)
            lines.append(f'    {member.name}: {default_val},')
        lines.append('  };')
        lines.append('}\n')

        return '\n'.join(lines)


    # =========================================================================
    # COMBINED
    # =========================================================================

    def generate_all_enums(self, enums: list) -> str:
        """Generate TypeScript code for multiple enums.

        Args:
            enums: List of EnumDefinition AST nodes

        Returns:
            Combined TypeScript enum code
        """
        return '\n'.join(self.generate_enum(e) for e in enums)

    def generate_all_structs(self, structs: list) -> str:
        """Generate TypeScript code for multiple structs.

        Args:
            structs: List of StructDefinition AST nodes

        Returns:
            Combined TypeScript struct code
        """
        return '\n'.join(self.generate_struct(s) for s in structs)

    def generate_all_constants(self, constants: list) -> str:
        """Generate TypeScript code for multiple constants.

        Args:
            constants: List of StateVariableDeclaration AST nodes (constant)

        Returns:
            Combined TypeScript constant code
        """
        return '\n'.join(self.generate_constant(c) for c in constants)

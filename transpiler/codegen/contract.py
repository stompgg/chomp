"""
Contract generation for Solidity to TypeScript transpilation.

This module handles the generation of TypeScript classes from Solidity contract
definitions, including state variables, constructors, methods, and inheritance.
"""

from collections import defaultdict
from typing import List, Dict, Set, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from .expression import ExpressionGenerator
    from .function import FunctionGenerator
    from .definition import DefinitionGenerator
    from .type_converter import TypeConverter
    from ..type_system import TypeRegistry

from .base import BaseGenerator
from ..parser.ast_nodes import (
    ContractDefinition,
    StateVariableDeclaration,
    FunctionDefinition,
    Literal,
)


class ContractGenerator(BaseGenerator):
    """
    Generates TypeScript classes from Solidity contract definitions.

    This class handles:
    - Contract class generation
    - Interface generation
    - State variable generation
    - Mutator method generation (for testing)
    - Inheritance handling
    """

    def __init__(
        self,
        ctx: 'CodeGenerationContext',
        type_converter: 'TypeConverter',
        expr_generator: 'ExpressionGenerator',
        func_generator: 'FunctionGenerator',
        def_generator: 'DefinitionGenerator',
        registry: Optional['TypeRegistry'] = None,
    ):
        """
        Initialize the contract generator.

        Args:
            ctx: The code generation context
            type_converter: The type converter
            expr_generator: The expression generator
            func_generator: The function generator
            def_generator: The definition generator
            registry: Optional type registry
        """
        super().__init__(ctx)
        self._type_converter = type_converter
        self._expr = expr_generator
        self._func = func_generator
        self._def = def_generator
        self._registry = registry

    # =========================================================================
    # MAIN ENTRY POINTS
    # =========================================================================

    def generate_contract(self, contract: ContractDefinition) -> str:
        """Generate TypeScript code for a contract definition.

        Args:
            contract: The contract definition AST node

        Returns:
            TypeScript code for the contract
        """
        lines = []

        # Generate nested enums
        for enum in contract.enums:
            lines.append(self._def.generate_enum(enum))

        # Generate nested structs
        for struct in contract.structs:
            lines.append(self._def.generate_struct(struct))

        # Generate interface for interfaces, class for contracts
        if contract.kind == 'interface':
            lines.append(self.generate_interface(contract))
        else:
            lines.append(self.generate_class(contract))

        return '\n'.join(lines)

    def generate_interface(self, contract: ContractDefinition) -> str:
        """Generate TypeScript interface.

        Args:
            contract: The interface definition AST node

        Returns:
            TypeScript interface code
        """
        lines = []
        lines.append(f'export interface {contract.name} {{')
        self.indent_level += 1

        # Add _contractAddress property - needed when checking address(interface) != address(0)
        lines.append(f'{self.indent()}_contractAddress: string;')

        for func in contract.functions:
            sig = self._func.generate_function_signature(func, for_interface=True)
            lines.append(f'{self.indent()}{sig};')

        self.indent_level -= 1
        lines.append('}\n')
        return '\n'.join(lines)

    def generate_class(self, contract: ContractDefinition) -> str:
        """Generate TypeScript class.

        Args:
            contract: The contract definition AST node

        Returns:
            TypeScript class code
        """
        lines = []

        # Setup contract context
        self._setup_contract_context(contract)

        # Generate class declaration with extends clause
        extends = self._compute_extends_clause(contract)
        abstract = 'abstract ' if contract.kind == 'abstract' else ''
        lines.append(f'export {abstract}class {contract.name}{extends} {{')
        self.indent_level += 1

        # State variables
        for var in contract.state_variables:
            lines.append(self.generate_state_variable(var))

        # Mutator methods for testing
        for var in contract.state_variables:
            mutators = self.generate_mutator_methods(var)
            if mutators:
                lines.append(mutators)

        # Constructor
        if contract.constructor:
            lines.append(self._func.generate_constructor(contract.constructor))

        # Group functions by name to handle overloads
        function_groups: Dict[str, List[FunctionDefinition]] = defaultdict(list)
        for func in contract.functions:
            function_groups[func.name].append(func)

        # Generate functions, merging overloads
        for func_name, funcs in function_groups.items():
            if len(funcs) == 1:
                lines.append(self._func.generate_function(funcs[0]))
            else:
                lines.append(self._func.generate_overloaded_function(funcs))

        # Handle secondary base class mixins
        self._add_mixin_code(contract, lines)

        self.indent_level -= 1
        lines.append('}\n')
        return '\n'.join(lines)

    # =========================================================================
    # CONTEXT SETUP
    # =========================================================================

    def _setup_contract_context(self, contract: ContractDefinition) -> None:
        """Setup the context for generating a contract."""
        # Track this contract as known
        self._ctx.known_contracts.add(contract.name)
        self._ctx.current_class_name = contract.name
        self._ctx.current_contract_kind = contract.kind

        # Track local structs (shouldn't get Structs. prefix)
        self._ctx.current_local_structs = {struct.name for struct in contract.structs}
        for struct_name in self._ctx.current_local_structs:
            if struct_name in self._ctx._qualified_name_cache:
                del self._ctx._qualified_name_cache[struct_name]

        # Track inherited structs
        self._ctx.current_inherited_structs = {}
        if self._registry:
            self._ctx.current_inherited_structs = self._registry.get_inherited_structs(contract.name)
            for struct_name in self._ctx.current_inherited_structs:
                if struct_name in self._ctx._qualified_name_cache:
                    del self._ctx._qualified_name_cache[struct_name]

        # Collect state variable and method names
        self._ctx.current_state_vars = {
            var.name for var in contract.state_variables
            if var.mutability != 'constant'
        }
        self._ctx.current_static_vars = {
            var.name for var in contract.state_variables
            if var.mutability == 'constant'
        }
        self._ctx.current_methods = {func.name for func in contract.functions}

        # Add runtime base class methods
        self._ctx.current_methods.update({
            '_yulStorageKey', '_storageRead', '_storageWrite', '_emitEvent',
        })

        self._ctx.current_local_vars = set()
        self._ctx.var_types = {var.name: var.type_name for var in contract.state_variables}

        # Build method return types
        method_return_types: Dict[str, str] = {}
        for func in contract.functions:
            if func.name and func.return_parameters and len(func.return_parameters) == 1:
                ret_type = func.return_parameters[0].type_name
                if ret_type and ret_type.name:
                    method_return_types[func.name] = ret_type.name
        self._ctx.current_method_return_types = method_return_types

    def _compute_extends_clause(self, contract: ContractDefinition) -> str:
        """Compute the extends clause for a contract class."""
        inherited_methods: Set[str] = set()
        self._ctx.current_base_classes = []

        if contract.base_contracts:
            # Filter to known contracts (skip interfaces)
            base_classes = [
                bc for bc in contract.base_contracts
                if bc not in self._ctx.known_interfaces
            ]
            if base_classes:
                primary_base = base_classes[0]
                extends = f' extends {primary_base}'
                self._ctx.current_base_classes = base_classes

                # Import all base contracts
                for base_class in base_classes:
                    self._ctx.base_contracts_needed.add(base_class)

                # Get all inherited methods and state vars
                if self._registry:
                    inherited = self._registry.get_all_inherited_methods(contract.name)
                    self._ctx.current_methods.update(inherited)
                    inherited_methods.update(inherited)
                    self._ctx.current_state_vars.update(
                        self._registry.get_all_inherited_vars(contract.name)
                    )
                else:
                    for base_class in base_classes:
                        if base_class in self._ctx.known_contract_methods:
                            self._ctx.current_methods.update(
                                self._ctx.known_contract_methods[base_class]
                            )
                            inherited_methods.update(
                                self._ctx.known_contract_methods[base_class]
                            )
                        if base_class in self._ctx.known_contract_vars:
                            self._ctx.current_state_vars.update(
                                self._ctx.known_contract_vars[base_class]
                            )

                # Check runtime replacement classes for inherited methods
                for base_class in base_classes:
                    if base_class in self._ctx.runtime_replacement_methods:
                        inherited_methods.update(
                            self._ctx.runtime_replacement_methods[base_class]
                        )
            else:
                extends = ' extends Contract'
                self._ctx.current_base_classes = ['Contract']
        else:
            extends = ' extends Contract'
            self._ctx.current_base_classes = ['Contract']

        # Set inherited methods on function generator
        self._func.set_inherited_methods(inherited_methods)

        return extends

    def _add_mixin_code(self, contract: ContractDefinition, lines: List[str]) -> None:
        """Add mixin code for secondary base classes."""
        non_interface_bases = [
            bc for bc in contract.base_contracts
            if bc not in self._ctx.known_interfaces
        ]
        actual_extends = non_interface_bases[0] if non_interface_bases else 'Contract'

        for base_class in contract.base_contracts:
            if (base_class in self._ctx.runtime_replacement_mixins and
                base_class != actual_extends):
                mixin_code = self._ctx.runtime_replacement_mixins[base_class]
                lines.append(mixin_code)

    # =========================================================================
    # STATE VARIABLES
    # =========================================================================

    def generate_state_variable(self, var: StateVariableDeclaration) -> str:
        """Generate TypeScript code for a state variable declaration."""
        ts_type = self._type_converter.solidity_type_to_ts(var.type_name)
        modifier = ''

        if var.mutability == 'constant':
            modifier = 'static readonly '
        elif var.mutability == 'immutable':
            modifier = 'readonly '
        elif var.visibility == 'private':
            modifier = 'private '
        elif var.visibility == 'internal':
            modifier = 'protected '

        if var.type_name.is_mapping:
            return self._generate_mapping_variable(var, modifier, ts_type)

        # Handle bytes32 constants specially
        if var.type_name.name == 'bytes32' and var.initial_value:
            if isinstance(var.initial_value, Literal) and var.initial_value.kind == 'hex':
                hex_val = var.initial_value.value
                if hex_val.startswith('0x'):
                    hex_val = hex_val[2:]
                hex_val = hex_val.zfill(64)
                return f'{self.indent()}{modifier}{var.name}: {ts_type} = "0x{hex_val}";'

        default_val = (
            self._expr.generate(var.initial_value)
            if var.initial_value
            else self._type_converter.default_value(ts_type)
        )
        return f'{self.indent()}{modifier}{var.name}: {ts_type} = {default_val};'

    def _generate_mapping_variable(
        self,
        var: StateVariableDeclaration,
        modifier: str,
        ts_type: str
    ) -> str:
        """Generate TypeScript code for a mapping state variable.

        For public mappings, generates a private backing field with underscore prefix
        and a public getter method to match interface signatures.
        """
        value_type = self._type_converter.solidity_type_to_ts(var.type_name.value_type)
        is_public_mapping = var.visibility == 'public' and var.name in self._ctx.known_public_mappings

        # Determine field name (underscore prefix for public mappings)
        field_name = f'_{var.name}' if is_public_mapping else var.name

        if var.type_name.value_type.is_mapping:
            inner_value = self._type_converter.solidity_type_to_ts(
                var.type_name.value_type.value_type
            )
            # Use private modifier for public mapping backing fields
            field_modifier = 'private ' if is_public_mapping else modifier
            field_decl = (
                f'{self.indent()}{field_modifier}{field_name}: '
                f'Record<string, Record<string, {inner_value}>> = {{}};'
            )
            if is_public_mapping:
                # Generate getter method for 2-level mappings
                key_type = self._type_converter.solidity_type_to_ts(var.type_name.key_type)
                inner_key_type = self._type_converter.solidity_type_to_ts(var.type_name.value_type.key_type)
                # Convert bigint keys to string for Record access
                key1_access = 'String(key1)' if key_type == 'bigint' else 'key1'
                key2_access = 'String(key2)' if inner_key_type == 'bigint' else 'key2'
                getter = (
                    f'{self.indent()}{var.name}(key1: {key_type}, key2: {inner_key_type}): {inner_value} {{\n'
                    f'{self.indent()}  return this.{field_name}[{key1_access}]?.[{key2_access}] ?? {self._type_converter.default_value(inner_value)};\n'
                    f'{self.indent()}}}'
                )
                return f'{field_decl}\n{getter}'
            return field_decl

        # Use private modifier for public mapping backing fields
        field_modifier = 'private ' if is_public_mapping else modifier
        field_decl = f'{self.indent()}{field_modifier}{field_name}: Record<string, {value_type}> = {{}};'

        if is_public_mapping:
            # Generate getter method
            key_type = self._type_converter.solidity_type_to_ts(var.type_name.key_type)
            # Convert bigint keys to string for Record access
            key_access = 'String(key)' if key_type == 'bigint' else 'key'
            getter = (
                f'{self.indent()}{var.name}(key: {key_type}): {value_type} {{\n'
                f'{self.indent()}  return this.{field_name}[{key_access}] ?? {self._type_converter.default_value(value_type)};\n'
                f'{self.indent()}}}'
            )
            return f'{field_decl}\n{getter}'

        return field_decl

    # =========================================================================
    # MUTATOR METHODS
    # =========================================================================

    def generate_mutator_methods(self, var: StateVariableDeclaration) -> str:
        """Generate __mutate* methods for testing state mutation."""
        if var.mutability in ('constant', 'immutable'):
            return ''

        lines = []
        ts_type = self._type_converter.solidity_type_to_ts(var.type_name)
        base_name = f'__mutate{var.name[0].upper()}{var.name[1:]}'
        body_indent = self._ctx.indent_str * (self.indent_level + 1)

        if var.type_name.is_mapping:
            lines.extend(self._generate_mapping_mutator(var, base_name, body_indent))
        elif var.type_name.is_array:
            lines.extend(self._generate_array_mutator(var, base_name, body_indent))
        else:
            lines.extend([
                f'{self.indent()}{base_name}(value: {ts_type}): void {{',
                f'{body_indent}this.{var.name} = value;',
                f'{self.indent()}}}',
                ''
            ])

        return '\n'.join(lines)

    def _generate_mapping_mutator(
        self,
        var: StateVariableDeclaration,
        base_name: str,
        body_indent: str
    ) -> List[str]:
        """Generate mutator for mapping types."""
        lines = []

        key_params = []
        # Use underscore prefix for public mappings (backing field)
        field_name = f'_{var.name}' if var.visibility == 'public' and var.name in self._ctx.known_public_mappings else var.name
        access_path = f'this.{field_name}'
        null_coalesce_lines = []

        current_type = var.type_name
        key_index = 1

        while current_type.is_mapping:
            key_ts_type = self._type_converter.solidity_type_to_ts(current_type.key_type)
            key_name = f'key{key_index}'
            key_params.append(f'{key_name}: {key_ts_type}')

            # Convert non-string keys to string for Record indexing
            key_access = key_name if key_ts_type == 'string' else f'String({key_name})'

            if current_type.value_type.is_mapping:
                null_coalesce_lines.append(
                    f'{body_indent}{access_path}[{key_access}] ??= {{}};'
                )

            access_path = f'{access_path}[{key_access}]'
            current_type = current_type.value_type
            key_index += 1

        value_ts_type = self._type_converter.solidity_type_to_ts(current_type)
        key_params.append(f'value: {value_ts_type}')

        params_str = ', '.join(key_params)
        lines.append(f'{self.indent()}{base_name}({params_str}): void {{')
        lines.extend(null_coalesce_lines)
        lines.append(f'{body_indent}{access_path} = value;')
        lines.append(f'{self.indent()}}}')
        lines.append('')

        return lines

    def _generate_array_mutator(
        self,
        var: StateVariableDeclaration,
        base_name: str,
        body_indent: str
    ) -> List[str]:
        """Generate mutator for array types."""
        lines = []

        element_type = self._type_converter.solidity_type_to_ts(var.type_name)
        if element_type.endswith('[]'):
            element_type = element_type[:-2]
        else:
            element_type = 'any'

        # __mutateXAt(index, value)
        lines.append(f'{self.indent()}{base_name}At(index: number, value: {element_type}): void {{')
        lines.append(f'{body_indent}this.{var.name}[index] = value;')
        lines.append(f'{self.indent()}}}')
        lines.append('')

        # __mutateXPush(value)
        lines.append(f'{self.indent()}{base_name}Push(value: {element_type}): void {{')
        lines.append(f'{body_indent}this.{var.name}.push(value);')
        lines.append(f'{self.indent()}}}')
        lines.append('')

        # __mutateXPop()
        lines.append(f'{self.indent()}{base_name}Pop(): void {{')
        lines.append(f'{body_indent}this.{var.name}.pop();')
        lines.append(f'{self.indent()}}}')
        lines.append('')

        return lines

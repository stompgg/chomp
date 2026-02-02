"""
Function generation for Solidity to TypeScript transpilation.

This module handles the generation of TypeScript code from Solidity function
definitions, including constructors, methods, and overloaded functions.
"""

from typing import List, Set, Dict, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from .expression import ExpressionGenerator
    from .statement import StatementGenerator
    from .type_converter import TypeConverter

from .base import BaseGenerator
from ..parser.ast_nodes import (
    FunctionDefinition,
    VariableDeclaration,
    Statement,
    ReturnStatement,
    IfStatement,
    Block,
    VariableDeclarationStatement,
)


class FunctionGenerator(BaseGenerator):
    """
    Generates TypeScript code from Solidity function definitions.

    This class handles:
    - Regular function methods
    - Constructors
    - Overloaded functions
    - Function signatures for interfaces
    - Return type generation
    """

    def __init__(
        self,
        ctx: 'CodeGenerationContext',
        expr_generator: 'ExpressionGenerator',
        stmt_generator: 'StatementGenerator',
        type_converter: 'TypeConverter',
    ):
        """
        Initialize the function generator.

        Args:
            ctx: The code generation context
            expr_generator: The expression generator
            stmt_generator: The statement generator
            type_converter: The type converter
        """
        super().__init__(ctx)
        self._expr = expr_generator
        self._stmt = stmt_generator
        self._type_converter = type_converter

        # Inherited methods from base classes (for override detection)
        self.inherited_methods: Set[str] = set()

    # =========================================================================
    # CONSTRUCTORS
    # =========================================================================

    def generate_constructor(self, func: FunctionDefinition) -> str:
        """Generate TypeScript code for a constructor."""
        lines = []

        # Track constructor parameters as local variables
        self._ctx.current_local_vars = set()
        for p in func.parameters:
            if p.name:
                self._ctx.current_local_vars.add(p.name)
                if p.type_name:
                    self._ctx.var_types[p.name] = p.type_name

        # Make constructor parameters optional for known base classes
        is_base_class = self._ctx.current_class_name in self._ctx.known_contract_methods
        optional_suffix = '?' if is_base_class else ''

        params = ', '.join([
            f'{p.name}{optional_suffix}: {self._type_converter.solidity_type_to_ts(p.type_name)}'
            for p in func.parameters
        ])
        lines.append(f'{self.indent()}constructor({params}) {{')
        self.indent_level += 1

        # Add super() call for derived classes - must be first statement
        if self._ctx.current_base_classes:
            if func.base_constructor_calls:
                for base_call in func.base_constructor_calls:
                    if base_call.base_name in self._ctx.current_base_classes:
                        if base_call.arguments:
                            self._ctx._in_base_constructor_args = True
                            args = ', '.join([
                                self._expr.generate(arg)
                                for arg in base_call.arguments
                            ])
                            self._ctx._in_base_constructor_args = False
                            lines.append(f'{self.indent()}super({args});')
                        else:
                            lines.append(f'{self.indent()}super();')
                        break
                else:
                    lines.append(f'{self.indent()}super();')
            else:
                lines.append(f'{self.indent()}super();')

        if func.body:
            if is_base_class and func.parameters:
                param_checks = [f'{p.name} !== undefined' for p in func.parameters if p.name]
                condition = ' && '.join(param_checks) if param_checks else 'true'
                lines.append(f'{self.indent()}if ({condition}) {{')
                self.indent_level += 1
                for stmt in func.body.statements:
                    lines.append(self._stmt.generate(stmt))
                self.indent_level -= 1
                lines.append(f'{self.indent()}}}')
            else:
                for stmt in func.body.statements:
                    lines.append(self._stmt.generate(stmt))

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')
        return '\n'.join(lines)

    # =========================================================================
    # REGULAR FUNCTIONS
    # =========================================================================

    def generate_function(self, func: FunctionDefinition) -> str:
        """Generate TypeScript code for a function implementation."""
        lines = []

        # Track local variables for this function
        self._ctx.current_local_vars = set()
        for i, p in enumerate(func.parameters):
            param_name = p.name if p.name else f'_arg{i}'
            self._ctx.current_local_vars.add(param_name)
            if p.type_name:
                self._ctx.var_types[param_name] = p.type_name

        for r in func.return_parameters:
            if r.name:
                self._ctx.current_local_vars.add(r.name)
                if r.type_name:
                    self._ctx.var_types[r.name] = r.type_name

        params = ', '.join([
            f'{self._generate_param_name(p, i)}: {self._type_converter.solidity_type_to_ts(p.type_name)}'
            for i, p in enumerate(func.parameters)
        ])
        return_type = self._generate_return_type(func.return_parameters)

        visibility = ''
        static_prefix = ''
        if self._ctx.current_contract_kind == 'library':
            static_prefix = 'static '

        if func.visibility == 'private':
            visibility = 'private '
        elif func.visibility == 'internal':
            visibility = 'protected ' if self._ctx.current_contract_kind != 'library' else ''

        # Check if should add override modifier
        should_override = (func.is_override and func.name in self.inherited_methods) or \
                         (func.name in self.inherited_methods and any(
                             base in self._ctx.runtime_replacement_methods and func.name in self._ctx.runtime_replacement_methods[base]
                             for base in self._ctx.current_base_classes
                         ))
        override_prefix = 'override ' if should_override else ''

        lines.append(f'{self.indent()}{visibility}{static_prefix}{override_prefix}{func.name}({params}): {return_type} {{')
        self.indent_level += 1

        # Declare named return parameters at start of function
        named_return_vars = []
        for r in func.return_parameters:
            if r.name:
                ts_type = self._type_converter.solidity_type_to_ts(r.type_name)
                default_val = self._type_converter.default_value(ts_type)
                lines.append(f'{self.indent()}let {r.name}: {ts_type} = {default_val};')
                named_return_vars.append(r.name)

        if func.body:
            for stmt in func.body.statements:
                lines.append(self._stmt.generate(stmt))

        # Add implicit return for named return parameters
        if named_return_vars and func.body:
            has_all_paths_return = self._all_paths_return(func.body.statements)
            if not has_all_paths_return:
                if len(named_return_vars) == 1:
                    lines.append(f'{self.indent()}return {named_return_vars[0]};')
                else:
                    lines.append(f'{self.indent()}return [{", ".join(named_return_vars)}];')

        # Handle virtual functions with no body
        if not func.body or (func.body and not func.body.statements):
            if named_return_vars:
                if len(named_return_vars) == 1:
                    lines.append(f'{self.indent()}return {named_return_vars[0]};')
                else:
                    lines.append(f'{self.indent()}return [{", ".join(named_return_vars)}];')
            elif return_type != 'void':
                lines.append(f'{self.indent()}throw new Error("Not implemented");')

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')

        self._ctx.current_local_vars = set()
        return '\n'.join(lines)

    # =========================================================================
    # OVERLOADED FUNCTIONS
    # =========================================================================

    def generate_overloaded_function(self, funcs: List[FunctionDefinition]) -> str:
        """Generate TypeScript code for overloaded functions.

        Combines overloaded Solidity functions into a single TypeScript function
        with optional parameters.
        """
        funcs_sorted = sorted(funcs, key=lambda f: len(f.parameters), reverse=True)
        main_func = funcs_sorted[0]
        shorter_funcs = funcs_sorted[1:]

        lines = []

        # Track local variables
        self._ctx.current_local_vars = set()
        for i, p in enumerate(main_func.parameters):
            param_name = p.name if p.name else f'_arg{i}'
            self._ctx.current_local_vars.add(param_name)
            if p.type_name:
                self._ctx.var_types[param_name] = p.type_name
        for r in main_func.return_parameters:
            if r.name:
                self._ctx.current_local_vars.add(r.name)
                if r.type_name:
                    self._ctx.var_types[r.name] = r.type_name

        min_param_count = min(len(f.parameters) for f in funcs)

        param_strs = []
        for i, p in enumerate(main_func.parameters):
            param_name = self._generate_param_name(p, i)
            param_type = self._type_converter.solidity_type_to_ts(p.type_name)
            if i >= min_param_count:
                param_strs.append(f'{param_name}?: {param_type}')
            else:
                param_strs.append(f'{param_name}: {param_type}')

        return_type = self._generate_return_type(main_func.return_parameters)

        visibility = ''
        if main_func.visibility == 'private':
            visibility = 'private '
        elif main_func.visibility == 'internal':
            visibility = 'protected '

        is_override = any(f.is_override for f in funcs) and main_func.name in self.inherited_methods
        override_prefix = 'override ' if is_override else ''

        lines.append(f'{self.indent()}{visibility}{override_prefix}{main_func.name}({", ".join(param_strs)}): {return_type} {{')
        self.indent_level += 1

        # Declare named return parameters
        named_return_vars = []
        for r in main_func.return_parameters:
            if r.name:
                ts_type = self._type_converter.solidity_type_to_ts(r.type_name)
                default_val = self._type_converter.default_value(ts_type)
                lines.append(f'{self.indent()}let {r.name}: {ts_type} = {default_val};')
                named_return_vars.append(r.name)

        if shorter_funcs and main_func.body:
            shorter = shorter_funcs[0]
            if len(shorter.parameters) < len(main_func.parameters):
                for i in range(len(shorter.parameters), len(main_func.parameters)):
                    extra_param = main_func.parameters[i]
                    extra_name = extra_param.name if extra_param.name else f'_arg{i}'

                    if shorter.body and shorter.body.statements:
                        for stmt in shorter.body.statements:
                            if isinstance(stmt, VariableDeclarationStatement):
                                for decl in stmt.declarations:
                                    if decl and decl.name == extra_name:
                                        init_expr = self._expr.generate(stmt.initial_value) if stmt.initial_value else 'undefined'
                                        lines.append(f'{self.indent()}if ({extra_name} === undefined) {{')
                                        lines.append(f'{self.indent()}  {extra_name} = {init_expr};')
                                        lines.append(f'{self.indent()}}}')
                                        break

            for stmt in main_func.body.statements:
                lines.append(self._stmt.generate(stmt))

        elif main_func.body:
            for stmt in main_func.body.statements:
                lines.append(self._stmt.generate(stmt))

        if named_return_vars and main_func.body:
            has_explicit_return = False
            if main_func.body.statements:
                last_stmt = main_func.body.statements[-1]
                has_explicit_return = isinstance(last_stmt, ReturnStatement)
            if not has_explicit_return:
                if len(named_return_vars) == 1:
                    lines.append(f'{self.indent()}return {named_return_vars[0]};')
                else:
                    lines.append(f'{self.indent()}return [{", ".join(named_return_vars)}];')

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')

        self._ctx.current_local_vars = set()
        return '\n'.join(lines)

    # =========================================================================
    # FUNCTION SIGNATURES
    # =========================================================================

    def generate_function_signature(self, func: FunctionDefinition) -> str:
        """Generate function signature for interface."""
        params = ', '.join([
            f'{self._generate_param_name(p, i)}: {self._type_converter.solidity_type_to_ts(p.type_name)}'
            for i, p in enumerate(func.parameters)
        ])
        return_type = self._generate_return_type(func.return_parameters)
        return f'{func.name}({params}): {return_type}'

    # =========================================================================
    # HELPERS
    # =========================================================================

    def _generate_param_name(self, param: VariableDeclaration, index: int) -> str:
        """Generate a parameter name, using _ for unnamed parameters."""
        if param.name:
            return param.name
        return f'_arg{index}'

    def _generate_return_type(self, params: List[VariableDeclaration]) -> str:
        """Generate return type from return parameters."""
        if not params:
            return 'void'
        if len(params) == 1:
            return self._type_converter.solidity_type_to_ts(params[0].type_name)
        types = [self._type_converter.solidity_type_to_ts(p.type_name) for p in params]
        return f'[{", ".join(types)}]'

    def _all_paths_return(self, statements: List[Statement]) -> bool:
        """Check if all code paths through statements end with a return."""
        if not statements:
            return False

        last_stmt = statements[-1]

        if isinstance(last_stmt, ReturnStatement):
            return True

        if isinstance(last_stmt, IfStatement):
            if last_stmt.false_body is None:
                return False

            if isinstance(last_stmt.true_body, Block):
                true_returns = self._all_paths_return(last_stmt.true_body.statements)
            elif isinstance(last_stmt.true_body, ReturnStatement):
                true_returns = True
            else:
                true_returns = False

            if isinstance(last_stmt.false_body, Block):
                false_returns = self._all_paths_return(last_stmt.false_body.statements)
            elif isinstance(last_stmt.false_body, ReturnStatement):
                false_returns = True
            elif isinstance(last_stmt.false_body, IfStatement):
                false_returns = self._all_paths_return([last_stmt.false_body])
            else:
                false_returns = False

            return true_returns and false_returns

        return False

    def set_inherited_methods(self, methods: Set[str]) -> None:
        """Set the inherited methods for override detection."""
        self.inherited_methods = methods

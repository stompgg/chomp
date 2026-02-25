"""
Statement generation for Solidity to TypeScript transpilation.

This module handles the generation of TypeScript code from Solidity statement
AST nodes, including control flow, variable declarations, and special statements.
"""

from typing import List, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from .expression import ExpressionGenerator
    from .type_converter import TypeConverter

from .base import BaseGenerator
from .yul import YulTranspiler
from ..parser.ast_nodes import (
    Statement,
    Block,
    ExpressionStatement,
    VariableDeclarationStatement,
    IfStatement,
    ForStatement,
    WhileStatement,
    DoWhileStatement,
    ReturnStatement,
    EmitStatement,
    RevertStatement,
    BreakStatement,
    ContinueStatement,
    DeleteStatement,
    AssemblyStatement,
    Expression,
    BinaryOperation,
    IndexAccess,
    MemberAccess,
    Identifier,
    FunctionCall,
    VariableDeclaration,
    TypeName,
)


class StatementGenerator(BaseGenerator):
    """
    Generates TypeScript code from Solidity statement AST nodes.

    This class handles all statement types including:
    - Blocks (groups of statements)
    - Variable declarations
    - Control flow (if, for, while, do-while)
    - Returns, breaks, continues
    - Emit (events) and revert
    - Delete statements
    - Assembly blocks (Yul)
    """

    def __init__(
        self,
        ctx: 'CodeGenerationContext',
        expr_generator: 'ExpressionGenerator',
        type_converter: 'TypeConverter',
    ):
        """
        Initialize the statement generator.

        Args:
            ctx: The code generation context
            expr_generator: The expression generator
            type_converter: The type converter
        """
        super().__init__(ctx)
        self._expr = expr_generator
        self._type_converter = type_converter
        self._yul_transpiler = YulTranspiler(known_constants=ctx.known_constants)

    # =========================================================================
    # MAIN DISPATCH
    # =========================================================================

    def generate(self, stmt: Statement) -> str:
        """Generate TypeScript code from a statement AST node.

        Args:
            stmt: The statement AST node

        Returns:
            The TypeScript code string
        """
        if isinstance(stmt, Block):
            return self.generate_block(stmt)
        elif isinstance(stmt, VariableDeclarationStatement):
            return self.generate_variable_declaration_statement(stmt)
        elif isinstance(stmt, IfStatement):
            return self.generate_if_statement(stmt)
        elif isinstance(stmt, ForStatement):
            return self.generate_for_statement(stmt)
        elif isinstance(stmt, WhileStatement):
            return self.generate_while_statement(stmt)
        elif isinstance(stmt, DoWhileStatement):
            return self.generate_do_while_statement(stmt)
        elif isinstance(stmt, ReturnStatement):
            return self.generate_return_statement(stmt)
        elif isinstance(stmt, EmitStatement):
            return self.generate_emit_statement(stmt)
        elif isinstance(stmt, RevertStatement):
            return self.generate_revert_statement(stmt)
        elif isinstance(stmt, BreakStatement):
            return f'{self.indent()}break;'
        elif isinstance(stmt, ContinueStatement):
            return f'{self.indent()}continue;'
        elif isinstance(stmt, DeleteStatement):
            return self.generate_delete_statement(stmt)
        elif isinstance(stmt, AssemblyStatement):
            return self.generate_assembly_statement(stmt)
        elif isinstance(stmt, ExpressionStatement):
            return self._generate_expression_statement(stmt)

        return f'{self.indent()}// Unknown statement'

    # =========================================================================
    # BLOCKS
    # =========================================================================

    def generate_block(self, block: Block) -> str:
        """Generate TypeScript code for a block of statements."""
        lines = []
        lines.append(f'{self.indent()}{{')
        self.indent_level += 1
        for stmt in block.statements:
            lines.append(self.generate(stmt))
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        return '\n'.join(lines)

    # =========================================================================
    # EXPRESSION STATEMENTS
    # =========================================================================

    def _generate_expression_statement(self, stmt: ExpressionStatement) -> str:
        """Generate expression statement with special handling for nested mapping assignments."""
        expr = stmt.expression

        # Check if this is an assignment to a mapping
        if isinstance(expr, BinaryOperation) and expr.operator in ('=', '+=', '-=', '*=', '/='):
            left = expr.left

            # Check for nested IndexAccess on left side (mapping[key1][key2] = value)
            if isinstance(left, IndexAccess) and isinstance(left.base, IndexAccess):
                # This is a nested mapping access like mapping[a][b] = value
                init_lines = self._generate_nested_mapping_init(left.base)
                main_expr = f'{self.indent()}{self._expr.generate(expr)};'
                if init_lines:
                    return init_lines + '\n' + main_expr
                return main_expr

            # Check for compound assignment on simple mapping (mapping[key] += value)
            if isinstance(left, IndexAccess) and expr.operator in ('+=', '-=', '*=', '/='):
                left_expr = self._expr.generate(left)
                init_line = f'{self.indent()}{left_expr} ??= 0n;'
                main_expr = f'{self.indent()}{self._expr.generate(expr)};'
                return init_line + '\n' + main_expr

        return f'{self.indent()}{self._expr.generate(expr)};'

    def _generate_nested_mapping_init(self, access: IndexAccess) -> str:
        """Generate initialization for nested mapping intermediate keys."""
        lines = []

        # Check if this is actually a mapping (not an array)
        base_var_name = self._get_base_var_name(access)
        if base_var_name and base_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[base_var_name]
            if type_info and not type_info.is_mapping:
                return ''

        base_expr = self._expr.generate(access)

        # Recursively handle deeper nesting
        if isinstance(access.base, IndexAccess):
            deeper_init = self._generate_nested_mapping_init(access.base)
            if deeper_init:
                lines.append(deeper_init)

        init_value = self._get_mapping_init_value(access)
        lines.append(f'{self.indent()}{base_expr} ??= {init_value};')

        return '\n'.join(lines)

    def _get_mapping_init_value(self, access: IndexAccess) -> str:
        """Determine the initialization value for a mapping access."""
        base_var_name = self._get_base_var_name(access.base)
        if not base_var_name or base_var_name not in self._ctx.var_types:
            return '{}'

        type_info = self._ctx.var_types[base_var_name]
        if not type_info or not type_info.is_mapping:
            return '{}'

        # Navigate through nested mappings to find the value type at this level
        depth = 0
        current = access
        while isinstance(current.base, IndexAccess):
            depth += 1
            current = current.base

        value_type = type_info.value_type
        for _ in range(depth):
            if value_type and value_type.is_mapping:
                value_type = value_type.value_type
            else:
                break

        if value_type:
            if value_type.is_array:
                return '[]'
            elif value_type.is_mapping:
                return '{}'

        return '{}'

    # =========================================================================
    # VARIABLE DECLARATIONS
    # =========================================================================

    def generate_variable_declaration_statement(self, stmt: VariableDeclarationStatement) -> str:
        """Generate TypeScript code for a variable declaration statement."""
        # Track declared variable names and types
        for decl in stmt.declarations:
            if decl and decl.name:
                self._ctx.current_local_vars.add(decl.name)
                if decl.type_name:
                    self._ctx.var_types[decl.name] = decl.type_name

        # Filter out None declarations for counting
        non_none_decls = [d for d in stmt.declarations if d is not None]

        # If there's only one actual declaration and no None entries, use simple let
        if len(stmt.declarations) == 1 and stmt.declarations[0] is not None:
            decl = stmt.declarations[0]
            ts_type = self._type_converter.solidity_type_to_ts(decl.type_name)
            if stmt.initial_value:
                # Check if this is a storage reference to a struct in a mapping
                storage_init = self._get_storage_init_statement(decl, stmt.initial_value, ts_type)
                if storage_init:
                    return storage_init

                init_expr = self._expr.generate(stmt.initial_value)
                init_expr = self._add_mapping_default(stmt.initial_value, ts_type, init_expr, decl.type_name)
                init = f' = {init_expr}'
            else:
                default_val = self._get_ts_default_value(ts_type, decl.type_name) or self._type_converter.default_value(ts_type)
                init = f' = {default_val}'
            return f'{self.indent()}let {decl.name}: {ts_type}{init};'
        else:
            # Tuple declaration
            names = ', '.join([d.name if d else '' for d in stmt.declarations])
            init = self._expr.generate(stmt.initial_value) if stmt.initial_value else ''

            # Check if this is an abi.decode with small integer types that need BigInt conversion
            small_int_conversions = self._get_small_int_conversions_from_decode(stmt)
            if small_int_conversions:
                # Use temp names for small int values, then convert to bigint
                temp_names = []
                for d in stmt.declarations:
                    if d and d.name in small_int_conversions:
                        temp_names.append(f'_{d.name}')
                    else:
                        temp_names.append(d.name if d else '')
                temp_names_str = ', '.join(temp_names)

                lines = [f'{self.indent()}const [{temp_names_str}] = {init};']
                for var_name in small_int_conversions:
                    lines.append(f'{self.indent()}const {var_name} = BigInt(_{var_name});')
                return '\n'.join(lines)

            return f'{self.indent()}const [{names}] = {init};'

    def _get_storage_init_statement(
        self,
        decl: VariableDeclaration,
        init_value: Expression,
        ts_type: str
    ) -> Optional[str]:
        """Generate storage initialization for struct references from mappings."""
        if decl.storage_location != 'storage':
            return None

        if not (ts_type.startswith('Structs.') or ts_type in self._ctx.known_structs):
            return None

        if not isinstance(init_value, IndexAccess):
            return None

        is_mapping_access = False
        mapping_var_name = None

        if isinstance(init_value.base, Identifier):
            var_name = init_value.base.name
            if var_name in self._ctx.var_types:
                type_info = self._ctx.var_types[var_name]
                is_mapping_access = type_info.is_mapping
                mapping_var_name = var_name

        if isinstance(init_value.base, MemberAccess):
            if isinstance(init_value.base.expression, Identifier) and init_value.base.expression.name == 'this':
                member_name = init_value.base.member
                if member_name in self._ctx.var_types:
                    type_info = self._ctx.var_types[member_name]
                    is_mapping_access = type_info.is_mapping
                    mapping_var_name = member_name

        if not is_mapping_access:
            return None

        mapping_expr = self._expr.generate(init_value.base)
        key_expr = self._expr.generate(init_value.index)

        needs_number_key = False
        if mapping_var_name and mapping_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[mapping_var_name]
            if type_info.is_mapping and type_info.key_type:
                key_type_name = type_info.key_type.name if type_info.key_type.name else ''
                needs_number_key = key_type_name.startswith('uint') or key_type_name.startswith('int')

        if needs_number_key and not key_expr.startswith('Number('):
            key_expr = f'Number({key_expr})'

        default_value = self._get_ts_default_value(ts_type, decl.type_name)
        if not default_value:
            struct_name = ts_type.replace('Structs.', '') if ts_type.startswith('Structs.') else ts_type
            if struct_name in self._ctx.current_local_structs:
                default_value = f'createDefault{struct_name}()'
            else:
                default_value = f'Structs.createDefault{struct_name}()'

        lines = []
        lines.append(f'{self.indent()}{mapping_expr}[{key_expr}] ??= {default_value};')
        lines.append(f'{self.indent()}let {decl.name}: {ts_type} = {mapping_expr}[{key_expr}];')
        return '\n'.join(lines)

    def _add_mapping_default(
        self,
        expr: Expression,
        ts_type: str,
        generated_expr: str,
        solidity_type: Optional[TypeName] = None
    ) -> str:
        """Add default value for mapping reads to simulate Solidity mapping semantics."""
        if not isinstance(expr, IndexAccess):
            return generated_expr

        is_mapping_read = False

        base_var_name = self._get_base_var_name(expr.base)
        if base_var_name and base_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[base_var_name]
            is_mapping_read = type_info.is_mapping

        if isinstance(expr.base, MemberAccess):
            if isinstance(expr.base.expression, Identifier) and expr.base.expression.name == 'this':
                member_name = expr.base.member
                if member_name in self._ctx.var_types:
                    type_info = self._ctx.var_types[member_name]
                    is_mapping_read = type_info.is_mapping

        # Check if the base identifier has a mapping type in var_types
        if isinstance(expr.base, Identifier):
            name = expr.base.name
            if name in self._ctx.var_types:
                type_info = self._ctx.var_types[name]
                if type_info.is_mapping:
                    is_mapping_read = True
            elif name in self._ctx.current_state_vars:
                # State vars that aren't in var_types but are accessed with index
                # are likely mappings (conservative: treat as mapping for default values)
                is_mapping_read = True

        if not is_mapping_read:
            return generated_expr

        default_value = self._get_ts_default_value(ts_type, solidity_type)
        if default_value:
            return f'({generated_expr} ?? {default_value})'
        return generated_expr

    def _get_ts_default_value(self, ts_type: str, solidity_type: Optional[TypeName] = None) -> Optional[str]:
        """Get the default value for a TypeScript type (matching Solidity semantics)."""
        if ts_type == 'bigint':
            return '0n'
        elif ts_type == 'boolean':
            return 'false'
        elif ts_type == 'string':
            if solidity_type and solidity_type.name:
                sol_type_name = solidity_type.name.lower()
                if 'bytes32' in sol_type_name or sol_type_name == 'bytes32':
                    return '"0x0000000000000000000000000000000000000000000000000000000000000000"'
                elif 'address' in sol_type_name or sol_type_name == 'address':
                    return '"0x0000000000000000000000000000000000000000"'
            return '""'
        elif ts_type == 'number':
            return '0'
        elif ts_type == 'AddressSet':
            return 'new AddressSet()'
        elif ts_type == 'Uint256Set':
            return 'new Uint256Set()'
        elif ts_type.startswith('Structs.'):
            struct_name = ts_type[8:]
            return f'Structs.createDefault{struct_name}()'
        elif ts_type in self._ctx.current_local_structs:
            return f'createDefault{ts_type}()'
        return None

    def _get_small_int_conversions_from_decode(self, stmt: VariableDeclarationStatement) -> List[str]:
        """Get list of variable names that need BigInt conversion from abi.decode.

        When abi.decode decodes small integer types (int8-int32, uint8-uint32),
        viem returns number instead of bigint. Since the transpiler assumes all
        integers are bigint, we need to convert these values.

        Returns list of variable names that need conversion.
        """
        if not stmt.initial_value:
            return []

        # Check if initial value is abi.decode call
        if not isinstance(stmt.initial_value, FunctionCall):
            return []

        func = stmt.initial_value.function
        if not isinstance(func, MemberAccess):
            return []

        if not isinstance(func.expression, Identifier) or func.expression.name != 'abi':
            return []

        if func.member != 'decode':
            return []

        # Get the types argument (second argument to abi.decode)
        if len(stmt.initial_value.arguments) < 2:
            return []

        types_arg = stmt.initial_value.arguments[1]

        # For multi-value decode, types_arg should be a TupleExpression
        from ..parser.ast_nodes import TupleExpression, TypeCast
        if not isinstance(types_arg, TupleExpression):
            return []

        small_int_types = {
            'int8', 'int16', 'int24', 'int32',
            'uint8', 'uint16', 'uint24', 'uint32',
        }

        # Map type indices to variable names that need conversion
        conversions = []
        for type_comp, decl in zip(types_arg.components, stmt.declarations):
            if decl is None:
                continue

            type_name = None
            if isinstance(type_comp, Identifier):
                # Check if it's an enum (enums should stay as number, not converted)
                if type_comp.name in self._ctx.known_enums:
                    continue
                type_name = type_comp.name
            elif isinstance(type_comp, TypeCast):
                type_name = type_comp.type_name.name

            if type_name and type_name in small_int_types:
                conversions.append(decl.name)

        return conversions

    # =========================================================================
    # CONTROL FLOW
    # =========================================================================

    def _generate_body_statements(self, body: Statement, lines: List[str]) -> None:
        """Generate statements from a body (Block or single statement)."""
        if isinstance(body, Block):
            for s in body.statements:
                lines.append(self.generate(s))
        else:
            lines.append(self.generate(body))

    def generate_if_statement(self, stmt: IfStatement) -> str:
        """Generate TypeScript code for an if statement."""
        lines = []
        cond = self._expr.generate(stmt.condition)
        lines.append(f'{self.indent()}if ({cond}) {{')
        self.indent_level += 1
        self._generate_body_statements(stmt.true_body, lines)
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')

        if stmt.false_body:
            if isinstance(stmt.false_body, IfStatement):
                lines[-1] = f'{self.indent()}}} else {self.generate_if_statement(stmt.false_body).strip()}'
            else:
                lines.append(f'{self.indent()}else {{')
                self.indent_level += 1
                self._generate_body_statements(stmt.false_body, lines)
                self.indent_level -= 1
                lines.append(f'{self.indent()}}}')

        return '\n'.join(lines)

    def generate_for_statement(self, stmt: ForStatement) -> str:
        """Generate TypeScript code for a for statement."""
        lines = []

        init = ''
        if stmt.init:
            if isinstance(stmt.init, VariableDeclarationStatement):
                decl = stmt.init.declarations[0]
                if decl.name:
                    self._ctx.current_local_vars.add(decl.name)
                    if decl.type_name:
                        self._ctx.var_types[decl.name] = decl.type_name
                ts_type = self._type_converter.solidity_type_to_ts(decl.type_name)
                if stmt.init.initial_value:
                    init_val = self._expr.generate(stmt.init.initial_value)
                else:
                    init_val = self._type_converter.default_value(ts_type)
                init = f'let {decl.name}: {ts_type} = {init_val}'
            else:
                init = self._expr.generate(stmt.init.expression)

        cond = self._expr.generate(stmt.condition) if stmt.condition else ''
        post = self._expr.generate(stmt.post) if stmt.post else ''

        lines.append(f'{self.indent()}for ({init}; {cond}; {post}) {{')
        self.indent_level += 1
        if stmt.body:
            self._generate_body_statements(stmt.body, lines)
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        return '\n'.join(lines)

    def generate_while_statement(self, stmt: WhileStatement) -> str:
        """Generate TypeScript code for a while statement."""
        lines = []
        cond = self._expr.generate(stmt.condition)
        lines.append(f'{self.indent()}while ({cond}) {{')
        self.indent_level += 1
        self._generate_body_statements(stmt.body, lines)
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        return '\n'.join(lines)

    def generate_do_while_statement(self, stmt: DoWhileStatement) -> str:
        """Generate TypeScript code for a do-while statement."""
        lines = []
        lines.append(f'{self.indent()}do {{')
        self.indent_level += 1
        self._generate_body_statements(stmt.body, lines)
        self.indent_level -= 1
        cond = self._expr.generate(stmt.condition)
        lines.append(f'{self.indent()}}} while ({cond});')
        return '\n'.join(lines)

    # =========================================================================
    # RETURN / BREAK / CONTINUE
    # =========================================================================

    def generate_return_statement(self, stmt: ReturnStatement) -> str:
        """Generate TypeScript code for a return statement."""
        if stmt.expression:
            return f'{self.indent()}return {self._expr.generate(stmt.expression)};'
        return f'{self.indent()}return;'

    # =========================================================================
    # DELETE
    # =========================================================================

    def generate_delete_statement(self, stmt: DeleteStatement) -> str:
        """Generate TypeScript code for a delete statement."""
        expr = self._expr.generate(stmt.expression)
        return f'{self.indent()}delete {expr};'

    # =========================================================================
    # EMIT / REVERT
    # =========================================================================

    def generate_emit_statement(self, stmt: EmitStatement) -> str:
        """Generate TypeScript code for an emit statement (event logging)."""
        if isinstance(stmt.event_call, FunctionCall):
            if isinstance(stmt.event_call.function, Identifier):
                event_name = stmt.event_call.function.name
                # Collect positional args, then named args (event emission doesn't need names)
                all_args = [self._expr.generate(a) for a in stmt.event_call.arguments]
                all_args.extend(self._expr.generate(v) for v in stmt.event_call.named_arguments.values())
                if all_args:
                    return f'{self.indent()}this._emitEvent("{event_name}", {", ".join(all_args)});'
                return f'{self.indent()}this._emitEvent("{event_name}");'
        expr = self._expr.generate(stmt.event_call)
        return f'{self.indent()}this._emitEvent({expr});'

    def generate_revert_statement(self, stmt: RevertStatement) -> str:
        """Generate TypeScript code for a revert statement."""
        if stmt.error_call:
            if isinstance(stmt.error_call, Identifier):
                return f'{self.indent()}throw new Error("{stmt.error_call.name}");'
            elif isinstance(stmt.error_call, FunctionCall):
                if isinstance(stmt.error_call.function, Identifier):
                    error_name = stmt.error_call.function.name
                    return f'{self.indent()}throw new Error("{error_name}");'
            return f'{self.indent()}throw new Error({self._expr.generate(stmt.error_call)});'
        return f'{self.indent()}throw new Error("Revert");'

    # =========================================================================
    # ASSEMBLY
    # =========================================================================

    def generate_assembly_statement(self, stmt: AssemblyStatement) -> str:
        """Generate TypeScript code for an assembly block (transpiled from Yul)."""
        yul_code = stmt.block.code
        ts_code = self._yul_transpiler.transpile(yul_code)
        lines = []
        lines.append(f'{self.indent()}// Assembly block (transpiled from Yul)')
        for line in ts_code.split('\n'):
            lines.append(f'{self.indent()}{line}')
        return '\n'.join(lines)

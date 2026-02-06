"""
Expression generation for Solidity to TypeScript transpilation.

This module handles the generation of TypeScript code from Solidity expression
AST nodes, including literals, identifiers, operators, function calls, and
member/index access.
"""

from typing import Optional, List, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from ..type_system import TypeRegistry

from .base import BaseGenerator
from .context import RESERVED_JS_METHODS
from .type_converter import TypeConverter
from ..parser.ast_nodes import (
    Expression,
    Literal,
    Identifier,
    BinaryOperation,
    UnaryOperation,
    TernaryOperation,
    FunctionCall,
    MemberAccess,
    IndexAccess,
    NewExpression,
    TupleExpression,
    ArrayLiteral,
    TypeCast,
)


class ExpressionGenerator(BaseGenerator):
    """
    Generates TypeScript code from Solidity expression AST nodes.

    This class handles all expression types including:
    - Literals (numbers, strings, booleans, hex)
    - Identifiers (variables, functions, special names)
    - Binary and unary operations
    - Function calls (regular, type casts, special functions)
    - Member access (properties, special patterns)
    - Index access (arrays, mappings)
    - New expressions (arrays, contracts)
    - Tuples and array literals
    - Type casts
    """

    def __init__(
        self,
        ctx: 'CodeGenerationContext',
        type_converter: TypeConverter,
        registry: Optional['TypeRegistry'] = None,
    ):
        """
        Initialize the expression generator.

        Args:
            ctx: The code generation context
            type_converter: The type converter for type-related operations
            registry: Optional type registry for lookups
        """
        super().__init__(ctx)
        self._type_converter = type_converter
        self._registry = registry
        self._abi_inferer: Optional['AbiTypeInferer'] = None

    def _get_abi_inferer(self) -> 'AbiTypeInferer':
        """Get or create an AbiTypeInferer with current context state."""
        from .abi import AbiTypeInferer
        # Rebuild on every call since context (var_types, method_return_types) changes per function
        self._abi_inferer = AbiTypeInferer(
            var_types=self._ctx.var_types,
            known_enums=self._ctx.known_enums,
            known_contracts=self._ctx.known_contracts,
            known_interfaces=self._ctx.known_interfaces,
            known_struct_fields=self._ctx.known_struct_fields,
            method_return_types=self._ctx.current_method_return_types,
        )
        return self._abi_inferer

    # =========================================================================
    # MAIN DISPATCH
    # =========================================================================

    def generate(self, expr: Expression) -> str:
        """Generate TypeScript expression from AST node.

        Args:
            expr: The expression AST node

        Returns:
            The TypeScript code string
        """
        if expr is None:
            return ''

        if isinstance(expr, Literal):
            return self.generate_literal(expr)
        elif isinstance(expr, Identifier):
            return self.generate_identifier(expr)
        elif isinstance(expr, BinaryOperation):
            return self.generate_binary_operation(expr)
        elif isinstance(expr, UnaryOperation):
            return self.generate_unary_operation(expr)
        elif isinstance(expr, TernaryOperation):
            return self.generate_ternary_operation(expr)
        elif isinstance(expr, FunctionCall):
            return self.generate_function_call(expr)
        elif isinstance(expr, MemberAccess):
            return self.generate_member_access(expr)
        elif isinstance(expr, IndexAccess):
            return self.generate_index_access(expr)
        elif isinstance(expr, NewExpression):
            return self.generate_new_expression(expr)
        elif isinstance(expr, TupleExpression):
            return self.generate_tuple_expression(expr)
        elif isinstance(expr, ArrayLiteral):
            return self.generate_array_literal(expr)
        elif isinstance(expr, TypeCast):
            return self.generate_type_cast(expr)

        return '/* unknown expression */'

    # =========================================================================
    # LITERALS
    # =========================================================================

    def generate_literal(self, lit: Literal) -> str:
        """Generate TypeScript code for a literal."""
        if lit.kind == 'number':
            # Use bigint literal syntax (Xn) which is more efficient than BigInt(X)
            # For large numbers (> 2^53), use BigInt("X") to avoid precision loss
            clean_value = lit.value.replace('_', '')
            if len(clean_value) > 15:
                return f'BigInt("{lit.value}")'
            return f'{lit.value}n'
        elif lit.kind == 'hex':
            # Hex literals: 0x... -> BigInt("0x...")
            return f'BigInt("{lit.value}")'
        elif lit.kind == 'string':
            return lit.value  # Already has quotes
        elif lit.kind == 'bool':
            return lit.value
        return lit.value

    def generate_array_literal(self, arr: ArrayLiteral) -> str:
        """Generate TypeScript code for an array literal."""
        elements = ', '.join([self.generate(e) for e in arr.elements])
        return f'[{elements}]'

    # =========================================================================
    # IDENTIFIERS
    # =========================================================================

    def generate_identifier(self, ident: Identifier) -> str:
        """Generate TypeScript code for an identifier."""
        name = ident.name

        # Handle special identifiers
        # In base constructor arguments, we can't use 'this' before super()
        # Use placeholder values instead
        if name == 'msg':
            if self._ctx._in_base_constructor_args:
                return '{ sender: ADDRESS_ZERO, value: 0n, data: "0x" as `0x${string}` }'
            return 'this._msg'
        elif name == 'block':
            if self._ctx._in_base_constructor_args:
                return '{ timestamp: 0n, number: 0n }'
            return 'this._block'
        elif name == 'tx':
            if self._ctx._in_base_constructor_args:
                return '{ origin: ADDRESS_ZERO }'
            return 'this._tx'
        elif name == 'this':
            return 'this'

        # Add ClassName. prefix for static constants (check before global constants)
        if name in self._ctx.current_static_vars:
            return f'{self._ctx.current_class_name}.{name}'

        # Add module prefixes for known types (but not for self-references)
        qualified = self.get_qualified_name(name)
        if qualified != name:
            return qualified

        # Add this. prefix for state variables and methods (but not local vars)
        if name not in self._ctx.current_local_vars:
            if name in self._ctx.current_state_vars or name in self._ctx.current_methods:
                # Use underscore prefix for public mappings (backing field)
                if name in self._ctx.known_public_mappings and name in self._ctx.current_state_vars:
                    return f'this._{name}'
                return f'this.{name}'

        return name

    # =========================================================================
    # OPERATORS
    # =========================================================================

    def _needs_parens(self, expr: Expression) -> bool:
        """Check if expression needs parentheses when used as operand."""
        # Simple expressions don't need parens
        if isinstance(expr, (Literal, Identifier)):
            return False
        if isinstance(expr, MemberAccess):
            return False
        if isinstance(expr, IndexAccess):
            return False
        if isinstance(expr, FunctionCall):
            return False
        return True

    def generate_binary_operation(self, op: BinaryOperation) -> str:
        """Generate TypeScript code for a binary operation."""
        left = self.generate(op.left)
        right = self.generate(op.right)
        operator = op.operator

        # For assignment operators, don't wrap tuple on left side (destructuring)
        is_assignment = operator in ('=', '+=', '-=', '*=', '/=', '%=', '|=', '&=', '^=')

        # Only add parens around complex sub-expressions
        if not (is_assignment and isinstance(op.left, TupleExpression)):
            if self._needs_parens(op.left):
                left = f'({left})'
        if self._needs_parens(op.right):
            right = f'({right})'

        return f'{left} {operator} {right}'

    def generate_unary_operation(self, op: UnaryOperation) -> str:
        """Generate TypeScript code for a unary operation."""
        operand = self.generate(op.operand)
        operator = op.operator

        if op.is_prefix:
            if self._needs_parens(op.operand):
                return f'{operator}({operand})'
            return f'{operator}{operand}'
        else:
            return f'({operand}){operator}'

    def generate_ternary_operation(self, op: TernaryOperation) -> str:
        """Generate TypeScript code for a ternary operation."""
        cond = self.generate(op.condition)
        true_expr = self.generate(op.true_expression)
        false_expr = self.generate(op.false_expression)
        return f'({cond} ? {true_expr} : {false_expr})'

    # =========================================================================
    # FUNCTION CALLS
    # =========================================================================

    def generate_function_call(self, call: FunctionCall) -> str:
        """Generate TypeScript code for a function call."""
        # Handle new expressions
        if isinstance(call.function, NewExpression):
            return self._generate_new_call(call)

        func = self.generate(call.function)

        # Handle abi.decode specially - need to swap args and format types
        if isinstance(call.function, MemberAccess):
            result = self._handle_abi_call(call)
            if result is not None:
                return result

        args = ', '.join([self.generate(a) for a in call.arguments])

        # Handle special function calls
        if isinstance(call.function, Identifier):
            name = call.function.name
            result = self._handle_special_function(call, name, args)
            if result is not None:
                return result

            # Handle type casts (uint256(x), etc.) - simplified for simulation
            result = self._handle_type_cast_call(call, name, args)
            if result is not None:
                return result

        # For bare function calls that start with _ (internal/protected methods),
        # add this. prefix if not already there.
        if isinstance(call.function, Identifier):
            name = call.function.name
            if name.startswith('_') and not func.startswith('this.'):
                return f'this.{func}({args})'

        # Handle public state variable getter calls
        if not args and isinstance(call.function, MemberAccess):
            member_name = call.function.member
            if member_name in self._ctx.known_public_state_vars:
                return func

        # Handle EnumerableSetLib method calls
        if isinstance(call.function, MemberAccess):
            member_name = call.function.member
            if member_name == 'length':
                return func

        # Handle library struct instantiation: Library.StructName({field: value, ...})
        # Check if this is a struct type being instantiated
        if isinstance(call.function, MemberAccess):
            struct_name = call.function.member
            if struct_name in self._ctx.known_structs:
                # Check for named arguments (struct initialization syntax)
                if call.named_arguments:
                    field_assignments = [
                        f'{name}: {self.generate(value)}'
                        for name, value in call.named_arguments.items()
                    ]
                    return '{ ' + ', '.join(field_assignments) + ' }'
                # No named args - use default creator
                return f'createDefault{struct_name}()'

        return f'{func}({args})'

    def _generate_new_call(self, call: FunctionCall) -> str:
        """Generate code for a 'new' expression call."""
        if call.function.type_name.is_array:
            # Array allocation: new Type[](size) -> new Array(size)
            if call.arguments:
                size_arg = call.arguments[0]
                size = self.generate(size_arg)
                # Convert BigInt to Number for array size
                if size.startswith('BigInt('):
                    inner = size[7:-1]
                    if inner.isdigit():
                        size = inner
                    else:
                        size = f'Number({size})'
                elif size.endswith('n') and size[:-1].isdigit():
                    size = size[:-1]
                elif isinstance(size_arg, Identifier):
                    size = f'Number({size})'
                return f'new Array({size})'
            return '[]'
        else:
            # Contract/class creation: new Contract(args)
            type_name = call.function.type_name.name
            if type_name == 'string':
                return '""'
            if type_name.startswith('bytes') and type_name != 'bytes32':
                return '""'
            args = ', '.join([self.generate(arg) for arg in call.arguments])
            return f'new {type_name}({args})'

    def _handle_abi_call(self, call: FunctionCall) -> Optional[str]:
        """Handle abi.encode/decode/encodePacked calls."""
        if not isinstance(call.function, MemberAccess):
            return None
        if not isinstance(call.function.expression, Identifier):
            return None
        if call.function.expression.name != 'abi':
            return None

        if call.function.member == 'decode':
            if len(call.arguments) >= 2:
                data_arg = self.generate(call.arguments[0])
                types_arg = call.arguments[1]
                type_params = self._convert_abi_types(types_arg)
                decode_expr = f'decodeAbiParameters({type_params}, {data_arg} as `0x${{string}}`)'

                # Check if decoding a single value - Solidity returns value directly,
                # but viem always returns a tuple, so we need to extract [0]
                is_single_type = False
                single_type = None

                # Single type parses as Identifier (e.g., (int32) -> Identifier('int32'))
                if isinstance(types_arg, Identifier):
                    is_single_type = True
                    single_type = types_arg
                # Or could be a TupleExpression with one component
                elif isinstance(types_arg, TupleExpression) and len(types_arg.components) == 1:
                    is_single_type = True
                    single_type = types_arg.components[0]

                if is_single_type and single_type:
                    type_name = self._get_abi_type_name(single_type)
                    # Small integers (int8-int32, uint8-uint32) return number from viem,
                    # but TypeScript code expects bigint
                    if type_name and self._is_small_integer_type(type_name):
                        return f'BigInt({decode_expr}[0])'
                    return f'{decode_expr}[0]'

                return decode_expr
        elif call.function.member == 'encode':
            if call.arguments:
                type_params = self._infer_abi_types_from_values(call.arguments)
                values = ', '.join([self._convert_abi_value(a) for a in call.arguments])
                return f'encodeAbiParameters({type_params}, [{values}])'
        elif call.function.member == 'encodePacked':
            if call.arguments:
                types = self._infer_packed_abi_types(call.arguments)
                values = ', '.join([self._convert_abi_value(a) for a in call.arguments])
                return f'encodePacked({types}, [{values}])'

        return None

    def _handle_special_function(self, call: FunctionCall, name: str, args: str) -> Optional[str]:
        """Handle special built-in functions."""
        if name == 'keccak256':
            # Handle keccak256("string") - need to convert string to hex for viem
            if len(call.arguments) == 1:
                arg = call.arguments[0]
                if isinstance(arg, Literal) and arg.kind == 'string':
                    # Plain string literal - use stringToHex
                    return f'keccak256(stringToHex({self.generate(arg)}))'
            return f'keccak256({args})'
        elif name == 'sha256':
            # Special case: sha256(abi.encode("string")) -> sha256String("string")
            if len(call.arguments) == 1:
                arg = call.arguments[0]
                if isinstance(arg, FunctionCall) and isinstance(arg.function, MemberAccess):
                    if (isinstance(arg.function.expression, Identifier) and
                        arg.function.expression.name == 'abi' and
                        arg.function.member == 'encode'):
                        if len(arg.arguments) == 1:
                            inner_arg = arg.arguments[0]
                            if isinstance(inner_arg, Literal) and inner_arg.kind == 'string':
                                return f'sha256String({self.generate(inner_arg)})'
            return f'sha256({args})'
        elif name == 'abi':
            return f'abi.{args}'
        elif name == 'require':
            if len(call.arguments) >= 2:
                cond = self.generate(call.arguments[0])
                msg = self.generate(call.arguments[1])
                return f'if (!({cond})) throw new Error({msg})'
            else:
                cond = self.generate(call.arguments[0])
                return f'if (!({cond})) throw new Error("Require failed")'
        elif name == 'assert':
            cond = self.generate(call.arguments[0])
            return f'if (!({cond})) throw new Error("Assert failed")'
        elif name == 'type':
            return f'/* type({args}) */'

        return None

    def _handle_type_cast_call(self, call: FunctionCall, name: str, args: str) -> Optional[str]:
        """Handle type cast function calls (uint256(x), address(x), etc.)."""
        if name.startswith('uint') or name.startswith('int'):
            # Skip redundant BigInt wrapping
            if args.startswith('BigInt(') or args.endswith('n'):
                return args
            if call.arguments and isinstance(call.arguments[0], Identifier):
                return args
            if args.isdigit():
                return f'{args}n'
            return f'BigInt({args})'
        elif name == 'address':
            if call.arguments:
                arg = call.arguments[0]
                if isinstance(arg, Literal) and arg.kind in ('number', 'hex'):
                    return self._to_padded_address(arg.value)
                if isinstance(arg, Identifier) and arg.name == 'this':
                    return 'this._contractAddress'
                if self._is_already_address_type(arg):
                    return self.generate(arg)
                if self._is_numeric_type_cast(arg):
                    inner = self.generate(arg)
                    return f'`0x${{({inner}).toString(16).padStart(40, "0")}}`'
                inner = self.generate(arg)
                if inner != 'this' and not inner.startswith('"') and not inner.startswith("'"):
                    return f'{inner}._contractAddress'
            return args
        elif name == 'bool':
            return args
        elif name == 'bytes32':
            if call.arguments:
                arg = call.arguments[0]
                if isinstance(arg, Literal) and arg.kind in ('number', 'hex'):
                    return self._to_padded_bytes32(arg.value)
            return args
        elif name.startswith('bytes'):
            return args
        elif name.startswith('I') and len(name) > 1 and name[1].isupper():
            # Interface cast
            return self._handle_interface_cast(call, args)
        elif name[0].isupper() and call.named_arguments:
            # Struct constructor with named args
            qualified = self.get_qualified_name(name)
            if self._registry and name in self._registry.struct_paths:
                self._ctx.external_structs_used[name] = self._registry.struct_paths[name]
            fields = ', '.join([
                f'{k}: {self.generate(v)}'
                for k, v in call.named_arguments.items()
            ])
            return f'{{ {fields} }} as {qualified}'
        elif name[0].isupper() and not args:
            # Struct with no args
            qualified = self.get_qualified_name(name)
            if self._registry and name in self._registry.struct_paths:
                self._ctx.external_structs_used[name] = self._registry.struct_paths[name]
            return f'{{}} as {qualified}'
        elif name in self._ctx.known_enums:
            qualified = self.get_qualified_name(name)
            return f'Number({args}) as {qualified}'

        return None

    def _handle_interface_cast(self, call: FunctionCall, args: str) -> str:
        """Handle interface type cast like IEffect(address(x))."""
        if call.arguments and len(call.arguments) == 1:
            arg = call.arguments[0]
            # Check for IEffect(address(x)) pattern
            if isinstance(arg, FunctionCall) and isinstance(arg.function, Identifier):
                if arg.function.name == 'address':
                    if arg.arguments and len(arg.arguments) == 1:
                        inner_arg = arg.arguments[0]
                        if isinstance(inner_arg, Identifier) and inner_arg.name == 'this':
                            return '(this as any)'
                        inner_expr = self.generate(inner_arg)
                        return f'({inner_expr} as any)'
            # Check for TypeCast address(x) pattern
            if isinstance(arg, TypeCast) and arg.type_name.name == 'address':
                inner_arg = arg.expression
                if isinstance(inner_arg, Identifier) and inner_arg.name == 'this':
                    return '(this as any)'
                inner_expr = self.generate(inner_arg)
                return f'({inner_expr} as any)'
        if args:
            return f'({args} as any)'
        return '{}'

    # =========================================================================
    # MEMBER ACCESS
    # =========================================================================

    def generate_member_access(self, access: MemberAccess) -> str:
        """Generate TypeScript code for member access."""
        expr = self.generate(access.expression)
        member = access.member

        # Handle special cases
        if isinstance(access.expression, Identifier):
            if access.expression.name == 'abi':
                if member == 'encode':
                    return 'encodeAbiParameters'
                elif member == 'encodePacked':
                    return 'encodePacked'
                elif member == 'decode':
                    return 'decodeAbiParameters'
            elif access.expression.name == 'type':
                return f'/* type().{member} */'
            elif access.expression.name in self._ctx.known_libraries or access.expression.name in self._ctx.runtime_replacement_classes:
                self._ctx.libraries_referenced.add(access.expression.name)
                # Rename reserved JS methods when accessing them on libraries
                if member in RESERVED_JS_METHODS:
                    member = RESERVED_JS_METHODS[member]

        # Handle type(TypeName).max/min
        if isinstance(access.expression, FunctionCall):
            if isinstance(access.expression.function, Identifier):
                if access.expression.function.name == 'type':
                    if access.expression.arguments:
                        type_arg = access.expression.arguments[0]
                        if isinstance(type_arg, Identifier):
                            type_name = type_arg.name
                            if member == 'max':
                                return self._type_converter.get_type_max(type_name)
                            elif member == 'min':
                                return self._type_converter.get_type_min(type_name)

        # Handle .slot for storage variables
        if member == 'slot':
            return f'/* {expr}.slot */'

        # Handle .length
        if member == 'length':
            base_var_name = self._get_base_var_name(access.expression)
            if base_var_name and base_var_name in self._ctx.var_types:
                type_info = self._ctx.var_types[base_var_name]
                type_name = type_info.name if type_info else ''
                enumerable_set_types = ('AddressSet', 'Uint256Set', 'Bytes32Set', 'Int256Set')
                if type_name in enumerable_set_types or type_name.startswith('EnumerableSetLib.'):
                    return f'{expr}.{member}'
            return f'BigInt({expr}.{member})'

        # Handle internal access to public mappings - use underscore prefix for backing field
        if (isinstance(access.expression, Identifier) and
            access.expression.name == 'this' and
            member in self._ctx.known_public_mappings and
            member in self._ctx.current_state_vars):
            return f'{expr}._{member}'

        return f'{expr}.{member}'

    # =========================================================================
    # INDEX ACCESS
    # =========================================================================

    def generate_index_access(self, access: IndexAccess) -> str:
        """Generate TypeScript code for index access (arrays and mappings)."""
        base = self.generate(access.base)
        index = self.generate(access.index)

        # Determine if this is likely an array access or mapping access
        is_likely_array = self._is_likely_array_access(access)

        # Check if the base is a mapping type
        base_var_name = self._get_base_var_name(access.base)
        is_mapping = False
        if base_var_name and base_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[base_var_name]
            is_mapping = type_info.is_mapping

        # Check if mapping has a numeric key type
        mapping_has_numeric_key = False
        if base_var_name and base_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[base_var_name]
            if type_info.is_mapping and type_info.key_type:
                key_type_name = type_info.key_type.name if type_info.key_type.name else ''
                mapping_has_numeric_key = key_type_name.startswith('uint') or key_type_name.startswith('int')

        # Check for struct field access using type registry
        if isinstance(access.base, MemberAccess):
            member_name = access.base.member
            # Try to resolve the struct type of the parent object
            parent_var = self._get_base_var_name(access.base.expression) if hasattr(access.base, 'expression') else None
            if parent_var and parent_var in self._ctx.var_types:
                parent_type = self._ctx.var_types[parent_var]
                struct_name = parent_type.name if parent_type else ''
                if struct_name and struct_name in self._ctx.known_struct_fields:
                    field_info = self._ctx.known_struct_fields[struct_name].get(member_name)
                    if field_info:
                        field_type = field_info[0] if isinstance(field_info, tuple) else field_info
                        field_is_array = field_info[1] if isinstance(field_info, tuple) else False
                        # Arrays and mappings with numeric keys need Number() conversion
                        if field_is_array:
                            is_likely_array = True
                        elif field_type and (field_type.startswith('mapping')):
                            is_mapping = True
                            mapping_has_numeric_key = True

        # Determine if we need Number conversion
        needs_number_conversion = is_likely_array or (is_mapping and mapping_has_numeric_key)

        # Apply index conversion
        index = self._convert_index(access, index, needs_number_conversion)

        return f'{base}[{index}]'

    def _convert_index(self, access: IndexAccess, index: str, needs_number: bool) -> str:
        """Convert index to appropriate type for array/object access."""
        if index.startswith('BigInt('):
            inner = index[7:-1]
            if inner.isdigit():
                return inner
            elif needs_number:
                return f'Number({index})'
        elif isinstance(access.index, Literal) and index.endswith('n'):
            return index[:-1]
        elif needs_number and isinstance(access.index, Identifier):
            return f'Number({index})'
        elif needs_number and isinstance(access.index, (BinaryOperation, UnaryOperation, IndexAccess, MemberAccess)):
            return f'Number({index})'
        elif isinstance(access.index, Identifier) and self._is_bigint_typed_identifier(access.index):
            if not index.startswith('Number('):
                return f'Number({index})'

        return index

    # =========================================================================
    # NEW EXPRESSIONS
    # =========================================================================

    def generate_new_expression(self, expr: NewExpression) -> str:
        """Generate TypeScript code for a new expression."""
        type_name = expr.type_name.name
        if expr.type_name.is_array:
            return 'new Array()'
        return f'new {type_name}()'

    # =========================================================================
    # TUPLES
    # =========================================================================

    def generate_tuple_expression(self, expr: TupleExpression) -> str:
        """Generate TypeScript code for a tuple expression."""
        components = []
        for comp in expr.components:
            if comp is None:
                components.append('')
            else:
                components.append(self.generate(comp))
        return f'[{", ".join(components)}]'

    # =========================================================================
    # TYPE CASTS
    # =========================================================================

    def generate_type_cast(self, cast: TypeCast) -> str:
        """Generate TypeScript code for a type cast."""
        return self._type_converter.generate_type_cast(cast, self.generate)

    # =========================================================================
    # ABI ENCODING HELPERS (delegated to AbiTypeInferer)
    # =========================================================================

    def _convert_abi_types(self, types_expr: Expression) -> str:
        """Convert Solidity type tuple to viem ABI parameter format."""
        return self._get_abi_inferer().convert_types_expr(types_expr)

    def _infer_abi_types_from_values(self, args: List[Expression]) -> str:
        """Infer ABI types from value expressions (for abi.encode)."""
        return self._get_abi_inferer().infer_abi_types(args)

    def _infer_packed_abi_types(self, args: List[Expression]) -> str:
        """Infer packed ABI types from value expressions (for abi.encodePacked)."""
        return self._get_abi_inferer().infer_packed_types(args)

    def _infer_expression_type(self, arg: Expression) -> tuple:
        """Infer the Solidity type from an expression.

        Returns:
            A tuple of (type_name: str, is_array: bool)
        """
        if isinstance(arg, Identifier):
            name = arg.name
            if name in self._ctx.var_types:
                type_info = self._ctx.var_types[name]
                if type_info.name:
                    is_array = getattr(type_info, 'is_array', False)
                    if type_info.name in self._ctx.known_enums:
                        return ('uint8', is_array)
                    return (type_info.name, is_array)
            if name in self._ctx.known_enums:
                return ('uint8', False)
            return ('uint256', False)

        if isinstance(arg, Literal):
            kind_to_type = {'string': 'string', 'bool': 'bool'}
            return (kind_to_type.get(arg.kind, 'uint256'), False)

        if isinstance(arg, MemberAccess):
            if arg.member == '_contractAddress':
                return ('address', False)
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return ('uint8', False)
                if arg.expression.name in ('this', 'msg', 'tx'):
                    if arg.member in ('sender', 'origin', '_contractAddress'):
                        return ('address', False)
                var_name = arg.expression.name
                if var_name in self._ctx.var_types:
                    type_info = self._ctx.var_types[var_name]
                    if type_info.name and type_info.name in self._ctx.known_struct_fields:
                        struct_fields = self._ctx.known_struct_fields[type_info.name]
                        if arg.member in struct_fields:
                            field_info = struct_fields[arg.member]
                            if isinstance(field_info, tuple):
                                return field_info
                            return (field_info, False)

        if isinstance(arg, FunctionCall):
            if isinstance(arg.function, Identifier):
                func_name = arg.function.name
                if func_name == 'address':
                    return ('address', False)
                if func_name.startswith('uint') or func_name.startswith('int'):
                    return (func_name, False)
                if func_name.startswith('bytes'):
                    return (func_name, False)
                if func_name in ('keccak256', 'blockhash', 'sha256'):
                    return ('bytes32', False)
                if func_name == 'name':
                    return ('string', False)
                # Check method return types from current contract
                if func_name in self._ctx.current_method_return_types:
                    return (self._ctx.current_method_return_types[func_name], False)
            elif isinstance(arg.function, MemberAccess):
                if arg.function.member == 'name':
                    return ('string', False)
                if isinstance(arg.function.expression, Identifier):
                    if arg.function.expression.name == 'this':
                        method_name = arg.function.member
                        if method_name in self._ctx.current_method_return_types:
                            return (self._ctx.current_method_return_types[method_name], False)

        if isinstance(arg, TypeCast):
            type_name = arg.type_name.name
            return (type_name, False)

        return ('uint256', False)

    def _infer_single_abi_type(self, arg: Expression) -> str:
        """Infer ABI type from a single value expression."""
        type_name, is_array = self._infer_expression_type(arg)
        return self._solidity_type_to_abi_type(type_name, is_array)

    def _infer_single_packed_type(self, arg: Expression) -> str:
        """Infer packed ABI type from a single value expression."""
        type_name, is_array = self._infer_expression_type(arg)
        return self._get_packed_type(type_name, is_array)

    def _resolve_abi_base_type(self, type_name: str) -> str:
        """Resolve a Solidity type to its base ABI type string.

        Maps enums to uint8, contracts/interfaces to address, preserves primitives.
        """
        if type_name in ('string', 'address', 'bool'):
            return type_name
        if type_name.startswith('uint') or type_name.startswith('int'):
            return type_name
        if type_name.startswith('bytes'):
            return type_name
        if type_name in self._ctx.known_enums:
            return 'uint8'
        if type_name in self._ctx.known_contracts or type_name in self._ctx.known_interfaces:
            return 'address'
        return 'uint256'

    def _solidity_type_to_abi_type(self, type_name: str, is_array: bool = False) -> str:
        """Convert a Solidity type name to ABI type format ({type: '...'})."""
        base_type = self._resolve_abi_base_type(type_name)
        array_suffix = '[]' if is_array else ''
        return f"{{type: '{base_type}{array_suffix}'}}"

    def _get_packed_type(self, type_name: str, is_array: bool = False) -> str:
        """Get packed type string for a Solidity type (plain string)."""
        base_type = self._resolve_abi_base_type(type_name)
        array_suffix = '[]' if is_array else ''
        return f'{base_type}{array_suffix}'

    def _convert_abi_value(self, arg: Expression) -> str:
        """Convert value for ABI encoding, ensuring proper types."""
        expr = self.generate(arg)
        var_type_name = None

        if isinstance(arg, Identifier):
            name = arg.name
            if name in self._ctx.var_types:
                type_info = self._ctx.var_types[name]
                if type_info.name:
                    var_type_name = type_info.name
                    if var_type_name in self._ctx.known_enums:
                        return f'Number({expr})'
                    if var_type_name in ('bytes32', 'address'):
                        if type_info.is_array:
                            return f'{expr} as `0x${{string}}`[]'
                        else:
                            return f'{expr} as `0x${{string}}`'
                    if var_type_name in ('int8', 'int16', 'int32', 'int64', 'int128',
                                          'uint8', 'uint16', 'uint32', 'uint64', 'uint128'):
                        return f'Number({expr})'

        if isinstance(arg, MemberAccess):
            if arg.member in ('sender', 'origin', '_contractAddress'):
                return f'{expr} as `0x${{string}}`'
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return f'Number({expr})'
                var_name = arg.expression.name
                if var_name in self._ctx.var_types:
                    type_info = self._ctx.var_types[var_name]
                    if type_info.name and type_info.name in self._ctx.known_struct_fields:
                        struct_fields = self._ctx.known_struct_fields[type_info.name]
                        if arg.member in struct_fields:
                            field_info = struct_fields[arg.member]
                            if isinstance(field_info, tuple):
                                field_type, is_array = field_info
                            else:
                                field_type, is_array = field_info, False
                            if field_type in ('address', 'bytes32'):
                                if is_array:
                                    return f'{expr} as `0x${{string}}`[]'
                                else:
                                    return f'{expr} as `0x${{string}}`'
                            if field_type in self._ctx.known_contracts or field_type in self._ctx.known_interfaces:
                                if is_array:
                                    return f'{expr}.map((c: any) => c._contractAddress as `0x${{string}}`)'
                                else:
                                    return f'{expr}._contractAddress as `0x${{string}}`'

        if isinstance(arg, FunctionCall):
            func_name = None
            if isinstance(arg.function, Identifier):
                func_name = arg.function.name
            elif isinstance(arg.function, MemberAccess):
                func_name = arg.function.member
            if func_name:
                if func_name == 'address':
                    return f'{expr} as `0x${{string}}`'
                if func_name in ('keccak256', 'sha256', 'blockhash', 'hashBattle', 'hashBattleOffer'):
                    return f'{expr} as `0x${{string}}`'

        if isinstance(arg, TypeCast):
            type_name = arg.type_name.name
            if type_name in ('address', 'bytes32'):
                return f'{expr} as `0x${{string}}`'

        return expr

    def _get_abi_type_name(self, type_expr: Expression) -> Optional[str]:
        """Extract the type name from an ABI type expression (e.g., int32 from a TypeCast)."""
        if isinstance(type_expr, TypeCast):
            return type_expr.type_name.name
        if isinstance(type_expr, Identifier):
            # Could be an enum or other named type
            if type_expr.name in self._ctx.known_enums:
                return 'uint8'
            return type_expr.name
        return None

    def _is_small_integer_type(self, type_name: str) -> bool:
        """Check if a type is a small integer that viem returns as number instead of bigint."""
        small_int_types = {
            'int8', 'int16', 'int24', 'int32',
            'uint8', 'uint16', 'uint24', 'uint32',
        }
        return type_name in small_int_types

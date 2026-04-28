"""Type reasoning for code generation.

``TypeConverter`` owns Solidity-to-TypeScript type conversion, default values,
type-cast emission, and the higher-level semantic decisions (expression type
resolution, mapping/index handling, ABI type mapping) that the generators rely
on. It is the single source of truth for type questions during emission.
"""

from typing import Optional, Tuple, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext
    from ..type_system import TypeRegistry

from .base import BaseGenerator
from ..parser.ast_nodes import (
    BinaryOperation,
    Expression,
    FunctionCall,
    Identifier,
    IndexAccess,
    Literal,
    MemberAccess,
    TypeCast,
    TypeName,
    UnaryOperation,
)


class TypeConverter(BaseGenerator):
    """Solidity-to-TypeScript type conversion and type-driven semantic decisions."""

    # Index expressions that can be safely wrapped in Number(...) / String(...).
    _WRAPPABLE_INDEX = (Identifier, BinaryOperation, UnaryOperation, IndexAccess, MemberAccess)

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

    # =========================================================================
    # CONSTANTS
    # =========================================================================

    BYTES32_ZERO = '"0x0000000000000000000000000000000000000000000000000000000000000000"'
    ADDRESS_ZERO = '"0x0000000000000000000000000000000000000000"'

    # =========================================================================
    # DEFAULT VALUE GENERATION
    # =========================================================================

    def default_value(self, ts_type: str, solidity_type_name: Optional[TypeName] = None) -> str:
        """Get the zero-initialized default value for a TypeScript type.

        This is the single source of truth for default values, matching Solidity's
        zero-initialization semantics. Used by state variables, struct fields,
        local variable declarations, and mapping access defaults.

        Args:
            ts_type: The TypeScript type string (e.g., 'bigint', 'string', 'Structs.Mon')
            solidity_type_name: Optional Solidity TypeName AST node for disambiguation
                (e.g., distinguishing bytes32 from string, fixed-size arrays)

        Returns:
            The default value expression as a TypeScript string
        """
        sol_name = ''
        if solidity_type_name and hasattr(solidity_type_name, 'name') and solidity_type_name.name:
            sol_name = solidity_type_name.name

        # Fixed-size arrays: Solidity zero-initializes all elements
        if (solidity_type_name and getattr(solidity_type_name, 'is_array', False)
                and getattr(solidity_type_name, 'array_size', None)):
            size_expr = solidity_type_name.array_size
            if isinstance(size_expr, Literal) and size_expr.kind == 'number':
                size = int(size_expr.value)
                element_ts_type = ts_type.rstrip('[]')
                # Build a TypeName for the element type (strip array info)
                element_sol_type = TypeName(name=sol_name, is_mapping=False) if sol_name else None
                element_default = self.default_value(element_ts_type, element_sol_type)
                return f'new Array({size}).fill({element_default})'

        # Primitives
        if ts_type == 'bigint':
            return '0n'
        elif ts_type == 'boolean':
            return 'false'
        elif ts_type == 'number':
            return '0'
        elif ts_type == 'string':
            # bytes types map to string in TS but default to zero hex, not ""
            if sol_name.startswith('bytes'):
                return self.BYTES32_ZERO
            elif sol_name == 'address':
                return self.ADDRESS_ZERO
            return '""'

        # Dynamic arrays
        if ts_type.endswith('[]'):
            return '[]'

        # Set types
        if ts_type == 'AddressSet':
            return 'new AddressSet()'
        elif ts_type == 'Uint256Set':
            return 'new Uint256Set()'

        # Record types (mapping simulation)
        if ts_type.startswith('Record<'):
            return self._record_default(ts_type, solidity_type_name)
        if ts_type.startswith('Map<'):
            return '{}'

        # Struct types
        if ts_type.startswith('Structs.'):
            struct_name = ts_type[8:]
            return f'Structs.createDefault{struct_name}()'
        if ts_type in self._ctx.known_structs:
            return f'createDefault{ts_type}()'

        # Enum types
        if ts_type.startswith('Enums.'):
            return '0'

        # Contract/interface types
        if ts_type in self._ctx.known_interfaces or ts_type in self._ctx.known_contracts:
            return f'{{ _contractAddress: {self.ADDRESS_ZERO} }} as any'

        return 'undefined as any'

    def _record_default(self, ts_type: str, solidity_type_name: Optional[TypeName] = None) -> str:
        """Initializer for a Record<string, V> (Solidity mapping).

        When the Solidity TypeName is available, returns a lazy Proxy whose
        ``get`` materializes the zero value of V for missing keys. This matches
        Solidity's "unwritten storage reads as zero" semantics and composes
        naturally for nested mappings: the inner default is computed via
        :py:meth:`default_value` again, so any depth works with no special case.

        Without a TypeName we fall back to parsing the TS type string, which
        only recognises the struct-value case (historic behaviour for call
        sites that predate TypeName threading).
        """
        if solidity_type_name and solidity_type_name.is_mapping:
            value_tn = solidity_type_name.value_type
            value_ts = self.solidity_type_to_ts(value_tn)
            inner_default = self.default_value(value_ts, value_tn)
            return self._lazy_record_proxy(ts_type, inner_default)

        # Fallback: parse "Record<K, V>" string for struct detection only.
        inner = ts_type[7:-1]
        parts = inner.split(', ', 1)
        if len(parts) == 2:
            value_ts = parts[1]
            if value_ts.startswith('Structs.') or value_ts in self._ctx.known_structs:
                struct_name = value_ts[8:] if value_ts.startswith('Structs.') else value_ts
                return self._lazy_record_proxy(ts_type, f'createDefault{struct_name}()')
        return '{}'

    @staticmethod
    def _lazy_record_proxy(ts_type: str, value_default: str) -> str:
        """Proxy that materializes ``value_default`` on first read of any string key."""
        return (
            f'new Proxy({{}} as {ts_type}, '
            f'{{ get: (t, k) => {{ '
            f'if (typeof k === "string" && !(k in t)) t[k] = {value_default}; '
            f'return t[k as any]; '
            f'}} }})'
        )

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

        # For numeric types (uint160, int128, etc.), mask to the correct bit width.
        # Solidity truncates on cast; BigInt does not, so we must mask explicitly.
        if type_name.startswith('uint') or type_name.startswith('int'):
            expr = generate_expression_fn(inner_expr)
            bigint_expr = self._ensure_bigint(expr)
            # Extract bit width (e.g., 'uint160' -> 160, 'int32' -> 32)
            width_str = type_name[4:] if type_name.startswith('uint') else type_name[3:]
            if width_str.isdigit():
                width = int(width_str)
                if width < 256:
                    if type_name.startswith('int'):
                        # Signed: mask then sign-extend (two's complement)
                        half = 1 << (width - 1)
                        full = 1 << width
                        return f'((v => v >= {half}n ? v - {full}n : v)({bigint_expr} & ((1n << {width}n) - 1n)))'
                    else:
                        return f'({bigint_expr} & ((1n << {width}n) - 1n))'
            return bigint_expr

        # Default: generate the inner expression
        return generate_expression_fn(inner_expr)

    @staticmethod
    def _ensure_bigint(expr: str) -> str:
        """Wrap expression in BigInt() only if it's not already a bigint expression.

        Avoids redundant BigInt(BigInt(x)) patterns in generated code.
        """
        # Already a BigInt() call
        if expr.startswith('BigInt('):
            return expr
        # Already a bigint literal (e.g., 0n, 123n)
        if expr.endswith('n') and (expr[:-1].isdigit() or expr.startswith('0x')):
            return expr
        # Already a bigint expression (mask, shift, or other bitwise op)
        if expr.startswith('(') and ('n)' in expr or '1n' in expr):
            return expr
        return f'BigInt({expr})'

    def _is_already_address_type(self, expr: Expression) -> bool:
        """Check if expression is already an address type."""
        if isinstance(expr, MemberAccess):
            if isinstance(expr.expression, Identifier):
                base_name = expr.expression.name
                member = expr.member
                if base_name == 'msg' and member == 'sender':
                    return True
                if base_name == 'tx' and member == 'origin':
                    return True
                if base_name in self._ctx.var_types:
                    type_info = self._ctx.var_types[base_name]
                    if type_info.name and type_info.name in self._ctx.known_struct_fields:
                        struct_fields = self._ctx.known_struct_fields[type_info.name]
                        if member in struct_fields:
                            field_info = struct_fields[member]
                            field_type = field_info[0] if isinstance(field_info, tuple) else field_info
                            if field_type == 'address':
                                return True

        if isinstance(expr, Identifier):
            if expr.name in self._ctx.var_types:
                type_info = self._ctx.var_types[expr.name]
                if type_info.name == 'address':
                    return True
        return False

    @staticmethod
    def _is_numeric_type_cast(expr: Expression) -> bool:
        """Check if expression is a numeric type cast."""
        if isinstance(expr, TypeCast):
            type_name = expr.type_name.name
            if type_name.startswith('uint') or type_name.startswith('int'):
                return True
        if isinstance(expr, FunctionCall):
            if isinstance(expr.function, Identifier):
                func_name = expr.function.name
                if func_name.startswith('uint') or func_name.startswith('int'):
                    return True
        return False

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

    # =========================================================================
    # EXPRESSION ANALYSIS
    # =========================================================================

    def base_var_name(self, expr: Expression) -> Optional[str]:
        """Extract the root variable name from an expression.

        For nested expressions like ``a.b.c`` or ``a[x][y]``, returns ``a``.
        For ``this.X`` state-variable access, returns ``X``.
        """
        if isinstance(expr, Identifier):
            return None if expr.name == 'this' else expr.name
        if isinstance(expr, MemberAccess):
            if self.is_this_access(expr):
                return expr.member
            return self.base_var_name(expr.expression)
        if isinstance(expr, IndexAccess):
            return self.base_var_name(expr.base)
        return None

    @staticmethod
    def is_this_access(expr: Expression) -> bool:
        """True when ``expr`` is ``this.<member>``."""
        return (
            isinstance(expr, MemberAccess)
            and isinstance(expr.expression, Identifier)
            and expr.expression.name == 'this'
        )

    def is_bigint_typed_identifier(self, expr: Expression) -> bool:
        """True for identifiers declared as Solidity uint/int types."""
        if isinstance(expr, Identifier):
            name = expr.name
            if name in self._ctx.var_types:
                type_name = self._ctx.var_types[name].name or ''
                return type_name.startswith('uint') or type_name.startswith('int')
        return False

    def resolve_access_type(self, expr: Expression) -> Optional[TypeName]:
        """Resolve the ``TypeName`` at a given expression point."""
        if isinstance(expr, Identifier):
            return None if expr.name == 'this' else self._ctx.var_types.get(expr.name)
        if isinstance(expr, MemberAccess):
            if self.is_this_access(expr):
                return self._ctx.var_types.get(expr.member)
            return self.resolve_struct_field_type(expr)
        if isinstance(expr, IndexAccess):
            container = self.resolve_access_type(expr.base)
            return self.step_into_container(container)
        return None

    def resolve_struct_field_type(self, expr: MemberAccess) -> Optional[TypeName]:
        """Type of a struct-field access, using ``known_struct_fields``."""
        parent_type = self.resolve_access_type(expr.expression)
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
        return self.field_info_to_type_name(field_type, field_is_array)

    @staticmethod
    def step_into_container(container: Optional[TypeName]) -> Optional[TypeName]:
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
    def field_info_to_type_name(field_type: str, field_is_array: bool) -> Optional[TypeName]:
        """Best-effort ``TypeName`` for a struct field registry entry."""
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

    def is_likely_array_access(self, access: IndexAccess) -> bool:
        """Determine if an index access is array-like rather than mapping-like."""
        base_var_name = self.base_var_name(access.base)

        if base_var_name and base_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[base_var_name]
            if type_info.is_array:
                return True
            if type_info.is_mapping:
                return False

        if isinstance(access.index, Identifier):
            index_name = access.index.name
            if index_name in self._ctx.var_types:
                index_type = self._ctx.var_types[index_name]
                if index_type.name and index_type.name.startswith(('uint', 'int')):
                    return True

        return False

    def is_mapping_read(self, expr: Expression) -> bool:
        """Return True if an index expression reads from a mapping container."""
        if not isinstance(expr, IndexAccess):
            return False

        base_var_name = self.base_var_name(expr.base)
        if base_var_name and base_var_name in self._ctx.var_types:
            type_info = self._ctx.var_types[base_var_name]
            if type_info.is_mapping:
                return True

        if isinstance(expr.base, MemberAccess):
            if isinstance(expr.base.expression, Identifier) and expr.base.expression.name == 'this':
                member_name = expr.base.member
                if member_name in self._ctx.var_types:
                    type_info = self._ctx.var_types[member_name]
                    if type_info.is_mapping:
                        return True

        if isinstance(expr.base, Identifier):
            name = expr.base.name
            if name in self._ctx.var_types:
                type_info = self._ctx.var_types[name]
                if type_info.is_mapping:
                    return True
            if name in self._ctx.current_state_vars:
                # Conservative fallback for state vars whose TypeName was not
                # threaded into var_types.
                return True

        return False

    # =========================================================================
    # DELETE / MAPPING DEFAULTS
    # =========================================================================

    def delete_default(self, expr: Expression) -> Optional[str]:
        """Return Solidity's zero/default value for a delete target if known."""
        type_info = self.resolve_access_type(expr)
        if not type_info:
            return None
        ts_type = self.solidity_type_to_ts(type_info)
        default_value = self.default_value(ts_type, type_info)
        if default_value == 'undefined as any':
            return None
        return default_value

    def mapping_init_value(self, access: IndexAccess) -> str:
        """Determine the initialization value for a mapping access."""
        base_var_name = self.base_var_name(access.base)
        if not base_var_name or base_var_name not in self._ctx.var_types:
            return '{}'

        type_info = self._ctx.var_types[base_var_name]
        if not type_info or not type_info.is_mapping:
            return '{}'

        # Navigate through nested mappings to find the value type at this level.
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
            if value_type.is_mapping:
                return '{}'

        return '{}'

    def add_mapping_default(
        self,
        expr: Expression,
        ts_type: str,
        generated_expr: str,
        solidity_type: Optional[TypeName] = None,
    ) -> str:
        """Add default value for mapping reads to simulate Solidity semantics."""
        if not self.is_mapping_read(expr):
            return generated_expr

        default_value = self.default_value(ts_type, solidity_type)
        if default_value and default_value != 'undefined as any':
            return f'({generated_expr} ?? {default_value})'
        return generated_expr

    @staticmethod
    def convert_bytes_string_literal(
        type_name: Optional[TypeName],
        initial_value: Expression,
        init_expr: str,
    ) -> str:
        """Convert string literals assigned to bytesN into right-padded hex."""
        if not (
            type_name
            and getattr(type_name, 'name', '')
            and type_name.name.startswith('bytes')
            and isinstance(initial_value, Literal)
            and initial_value.kind == 'string'
        ):
            return init_expr

        string_val = initial_value.value.strip('"\'')
        hex_bytes = string_val.encode('utf-8').hex()
        size_str = type_name.name[5:]
        byte_size = int(size_str) if size_str.isdigit() else 32
        hex_bytes = hex_bytes[:byte_size * 2].ljust(byte_size * 2, '0')
        return f'"0x{hex_bytes}"'

    # =========================================================================
    # INDEX CONVERSION
    # =========================================================================

    def index_access_kind(self, access: IndexAccess) -> Tuple[bool, bool]:
        """Return ``(is_array, is_numeric_keyed_mapping)`` for an index access."""
        container = self.resolve_access_type(access.base)
        is_array = bool(container and container.is_array) or self.is_likely_array_access(access)
        is_numeric_keyed_mapping = bool(
            container
            and container.is_mapping
            and container.key_type
            and (container.key_type.name or '').startswith(('uint', 'int'))
        )
        return is_array, is_numeric_keyed_mapping

    def convert_index(
        self,
        access: IndexAccess,
        index: str,
        needs_conversion: bool,
        mapping_access: bool,
    ) -> str:
        """Convert an index expression to match the container key type.

        Mappings transpile to ``Record<string, V>`` and preserve bigint
        precision via ``String(idx)``. Arrays use ``Number(idx)`` because TS
        array indices are numeric.
        """
        wrap = 'String' if mapping_access else 'Number'

        if index.startswith('BigInt('):
            inner = index[7:-1]
            if inner.isdigit():
                return inner

        if isinstance(access.index, Literal) and index.endswith('n'):
            return index[:-1]

        should_wrap = (
            (needs_conversion and isinstance(access.index, self._WRAPPABLE_INDEX))
            or (isinstance(access.index, Identifier) and self.is_bigint_typed_identifier(access.index))
        )
        if should_wrap and not index.startswith(f'{wrap}('):
            return f'{wrap}({index})'

        return index

    # =========================================================================
    # ABI TYPE MAPPING
    # =========================================================================

    def solidity_type_to_abi_param(self, type_name: str, is_array: bool = False) -> str:
        """Convert a Solidity type name to a viem ABI parameter object string."""
        return f"{{type: '{self.solidity_type_to_abi_type(type_name, is_array)}'}}"

    def solidity_type_to_abi_type(self, type_name: str, is_array: bool = False) -> str:
        """Convert a Solidity type name to an ABI type string."""
        array_suffix = '[]' if is_array else ''
        if type_name in ('address', 'string', 'bool'):
            return f'{type_name}{array_suffix}'
        if type_name.startswith(('uint', 'int', 'bytes')):
            return f'{type_name}{array_suffix}'
        if type_name in self._ctx.known_enums:
            return f'uint8{array_suffix}'
        if type_name in self._ctx.known_contracts or type_name in self._ctx.known_interfaces:
            return f'address{array_suffix}'
        return f'uint256{array_suffix}'

"""Typed Rust expression emission.

Unlike the TS generator (type-blind: everything is bigint), every emission
here is driven by inferred SolTypes:

- ``emit(expr, expected)`` returns Rust source producing a value of
  ``expected`` (implicitly widening the naturally-inferred type when legal).
- Untyped integer literals materialize directly in the expected type.
- Arithmetic picks checked vs wrapping intrinsics per the enclosing
  ``unchecked`` block and native-vs-wide representation (see rust_types.py
  for the verified semantic contract).

Value representation choices (Phase 0/1):
- Solidity memory reference types (structs, arrays) are ``&mut T`` at
  parameter positions; identifiers bound to such params emit ``(*name)`` so
  index/member/assignment forms all work uniformly as places.
- Interface-typed internal-fn parameters are ``&mut dyn Trait`` (callable);
  interface-typed values anywhere else are ``Address``. Method calls on a
  non-callable interface value emit a diverging ``unimplemented!`` (that is
  the external-dispatch surface, which lands with the Phase-3 dispatch
  enums) so the generated code compiles and fails loudly if reached.
"""

from typing import List, Optional, TYPE_CHECKING

from ..parser.ast_nodes import (
    ArrayLiteral,
    BinaryOperation,
    Expression,
    FunctionCall,
    Identifier,
    IndexAccess,
    Literal,
    MemberAccess,
    NewExpression,
    TernaryOperation,
    TupleExpression,
    TypeCast,
    TypeName,
    UnaryOperation,
)
from .soltypes import (
    ADDRESS, BOOL, BYTES, BYTES32, INTLIT, STRING, UINT256, UNKNOWN,
    SolType, TypeInferencer, common_type, parse_elementary, uint,
)
from .rust_types import RustTypeConverter, rust_ident

if TYPE_CHECKING:
    from .context import RustCodeGenerationContext
    from .symbols import RustSymbols


_CHECKED_WIDE = {'+': 'sol_add', '-': 'sol_sub', '*': 'sol_mul'}
_WRAPPING = {'+': 'wrapping_add', '-': 'wrapping_sub', '*': 'wrapping_mul'}


class RustExpressionGenerator:
    def __init__(self, ctx: 'RustCodeGenerationContext', symbols: 'RustSymbols',
                 types: RustTypeConverter, inferencer: TypeInferencer):
        self._ctx = ctx
        self._symbols = symbols
        self._types = types
        self._infer = inferencer

    # ------------------------------------------------------------------
    # Entry point
    # ------------------------------------------------------------------

    def emit(self, expr: Expression, expected: Optional[SolType] = None) -> str:
        code, actual = self.emit_typed(expr)
        if expected is None:
            return code
        return self._fit(code, actual, expected, expr)

    def emit_typed(self, expr: Expression):
        """Returns (code, SolType). Untyped literals stay INTLIT."""
        if isinstance(expr, Literal):
            return self._emit_literal(expr)
        if isinstance(expr, Identifier):
            return self._emit_identifier(expr)
        if isinstance(expr, BinaryOperation):
            return self._emit_binary(expr)
        if isinstance(expr, UnaryOperation):
            return self._emit_unary(expr)
        if isinstance(expr, TernaryOperation):
            return self._emit_ternary(expr)
        if isinstance(expr, FunctionCall):
            return self._emit_call(expr)
        if isinstance(expr, MemberAccess):
            return self._emit_member(expr)
        if isinstance(expr, IndexAccess):
            return self._emit_index(expr)
        if isinstance(expr, TypeCast):
            return self._emit_cast(expr.type_name, expr.expression)
        if isinstance(expr, TupleExpression):
            comps = expr.components
            if len(comps) == 1 and comps[0] is not None:
                code, t = self.emit_typed(comps[0])
                return f'({code})', t
            parts = []
            types = []
            for c in comps:
                if c is None:
                    parts.append('()')
                    types.append(UNKNOWN)
                else:
                    code, t = self.emit_typed(c)
                    parts.append(code)
                    types.append(t)
            return f'({", ".join(parts)})', SolType('tuple', members=tuple(types))
        if isinstance(expr, ArrayLiteral):
            elems = [self.emit(e) for e in expr.elements]
            t = self._infer.infer(expr)
            return f'[{", ".join(elems)}]', t
        if isinstance(expr, NewExpression):
            t = self._infer.from_type_name(expr.type_name)
            return self._types.default_value(t), t
        self._ctx.warn(f'unhandled expression node {type(expr).__name__}')
        return 'unimplemented!("unhandled expression")', UNKNOWN

    # ------------------------------------------------------------------
    # Fitting a value to an expected type
    # ------------------------------------------------------------------

    def _fit(self, code: str, actual: SolType, expected: SolType, expr: Expression) -> str:
        if expected.kind in ('unknown',):
            return code
        if actual.kind == 'intlit':
            # Re-materialize plain literals in the expected type; composed
            # literal arithmetic was already emitted against context.
            if isinstance(expr, Literal):
                return self._literal_in(expr, expected)
            return code
        if actual.is_integer and expected.is_integer:
            return self._types.coerce(code, actual, expected)
        if actual.kind == 'string' and expected.kind == 'string':
            return code
        return code

    def _literal_value(self, lit: Literal) -> int:
        return int(str(lit.value).replace('_', ''), 0)

    def _literal_in(self, lit: Literal, target: SolType) -> str:
        if lit.kind in ('number', 'hex'):
            v = self._literal_value(lit)
            if target.is_integer and target.kind != 'intlit':
                return self._types.int_literal(v, target)
            if target.kind == 'bytes_fixed' and target.bytes_n == 32:
                return _b256_literal(v)
            if target.kind == 'address':
                return _address_literal(v)
            if target.kind == 'enum':
                variants = self._symbols.enums.get(target.name, [])
                if 0 <= v < len(variants):
                    from .definition import enum_variant_ident
                    return f'{rust_ident(target.name)}::{enum_variant_ident(variants[v])}'
            return self._types.int_literal(v, UINT256)
        if lit.kind == 'string':
            return f'{lit.value}.to_string()'
        return lit.value

    # ------------------------------------------------------------------
    # Leaves
    # ------------------------------------------------------------------

    def _emit_literal(self, lit: Literal):
        if lit.kind in ('number', 'hex'):
            # Callers fit INTLIT into context; standalone emission defaults u256.
            return self._types.int_literal(self._literal_value(lit), UINT256), INTLIT
        if lit.kind == 'bool':
            return lit.value, BOOL
        if lit.kind == 'string':
            return f'{lit.value}.to_string()', STRING
        if lit.kind == 'hex_string':
            return f'rt::hex_bytes("{lit.value}")', BYTES
        return lit.value, UNKNOWN

    def _emit_identifier(self, ident: Identifier):
        name = ident.name
        t = self._infer.infer(ident)

        # Memory alias: `merged = existingParam` makes both names the same
        # object in Solidity; reads/writes of the param redirect to the
        # owned local from that point on (statement generator records it).
        if name in self._ctx.alias_map:
            return rust_ident(self._ctx.alias_map[name]), t
        if name in self._ctx.dyn_params:
            return rust_ident(name), t
        if name in self._ctx.ref_params:
            return f'(*{rust_ident(name)})', t
        if name in self._ctx.current_local_vars:
            return rust_ident(name), t
        const = self._symbols.lookup_constant(name, self._ctx.current_class_name or None)
        if const is not None:
            return self._constant_ref(const), const.sol_type
        if name in self._ctx.current_state_vars:
            return f'self.{rust_ident(name)}', t
        return rust_ident(name), t

    def _constant_ref(self, const) -> str:
        path = ''
        if const.container is None:
            # File-scope constant (Constants.sol): imported via generator
            self._ctx.used_constants.add(const.name)
        elif const.container != self._ctx.current_class_name:
            self._ctx.used_modules.add(const.container)
            path = f'{rust_ident(const.container)}::'
        name = f'{path}{rust_ident(const.name)}'
        if const.is_lazy:
            return f'(*{name})'
        return name

    # ------------------------------------------------------------------
    # Operators
    # ------------------------------------------------------------------

    def _emit_binary(self, op: BinaryOperation):
        operator = op.operator

        if operator in ('&&', '||'):
            l = self.emit(op.left, BOOL)
            r = self.emit(op.right, BOOL)
            return f'{self._paren(op.left, l)} {operator} {self._paren(op.right, r)}', BOOL

        if operator in ('==', '!=', '<', '<=', '>', '>='):
            lt = self._infer.infer(op.left)
            rt_ = self._infer.infer(op.right)
            common = common_type(lt, rt_)
            if common.kind == 'intlit':
                common = UINT256
            l = self.emit(op.left, common)
            r = self.emit(op.right, common)
            return f'{self._paren(op.left, l)} {operator} {self._paren(op.right, r)}', BOOL

        if operator in ('<<', '>>'):
            lt = self._infer.infer(op.left)
            if lt.kind == 'intlit':
                lt = UINT256  # literal shifts appear only in u256 packing exprs
            l = self.emit(op.left, lt)
            amt = self._shift_amount(op.right)
            method = 'sol_shl' if operator == '<<' else 'sol_shr'
            out = f'{self._paren(op.left, l)}.{method}({amt})'
            if operator == '<<':
                # Solidity truncates shl results to the DECLARED width; odd
                # widths live in a wider representation, so mask explicitly.
                out = self._mask_odd_width(out, lt)
            return out, lt

        if operator == '**':
            base_t = self._infer.infer(op.left)
            if base_t.kind == 'intlit':
                base_t = UINT256
            l = self.emit(op.left, base_t)
            lp = self._paren(op.left, l)
            if base_t.is_wide:
                exp = self.emit(op.right, UINT256)
                if self._ctx.unchecked:
                    return f'{lp}.pow({exp})', base_t  # ruint pow wraps (EVM semantics)
                return f'{lp}.checked_pow({exp}).expect("panic: exponentiation overflow")', base_t
            exp = self._to_u64(op.right)
            fn = 'rt::pow_wrapping' if self._ctx.unchecked else 'rt::pow_checked'
            return f'{fn}({l}, {exp})', base_t

        if operator in ('+', '-', '*', '/', '%'):
            lt = self._infer.infer(op.left)
            rt_ = self._infer.infer(op.right)
            common = common_type(lt, rt_)
            if common.kind == 'intlit':
                common = UINT256
            l = self.emit(op.left, common)
            r = self.emit(op.right, common)
            return self._arith(operator, l, r, common, op), common

        if operator in ('&', '|', '^'):
            lt = self._infer.infer(op.left)
            rt_ = self._infer.infer(op.right)
            common = common_type(lt, rt_)
            if common.kind == 'intlit':
                common = UINT256
            l = self.emit(op.left, common)
            r = self.emit(op.right, common)
            return f'{self._paren(op.left, l)} {operator} {self._paren(op.right, r)}', common

        if operator == '=' or operator.endswith('='):
            # Assignment as expression — handled by the statement generator;
            # reaching here means an unsupported embedded assignment.
            self._ctx.warn('assignment used in expression position')
            return 'unimplemented!("assignment in expression position")', UNKNOWN

        self._ctx.warn(f'unhandled binary operator {operator}')
        return f'unimplemented!("operator {operator}")', UNKNOWN

    def _arith(self, operator: str, l: str, r: str, t: SolType, op: BinaryOperation) -> str:
        lp = self._paren(op.left, l)
        rp = self._paren(op.right, r)
        if t.is_odd_width:
            self._ctx.warn(
                f'checked arithmetic on odd-width type {t}: bounds check happens at '
                f'the {t.mapped_bits}-bit representation, not {t.bits} bits'
            )
        if t.is_wide:
            if operator in ('+', '-', '*'):
                method = _WRAPPING[operator] if self._ctx.unchecked else _CHECKED_WIDE[operator]
                return f'{lp}.{method}({rp})'
            # '/' and '%': division by zero panics in both modes (Solidity
            # semantics). Checked '%' of MIN % -1 is 0 in Solidity (only
            # DIVISION overflows, Panic 0x11) — sol_rem implements that.
            if t.kind == 'int':
                method = {'/': 'sol_div', '%': 'sol_rem'}[operator]
                if self._ctx.unchecked:
                    method = {'/': 'wrapping_div', '%': 'wrapping_rem'}[operator]
                return f'{lp}.{method}({rp})'
            return f'{lp} {operator} {rp}'
        # native
        if self._ctx.unchecked:
            if operator in ('+', '-', '*'):
                return f'{lp}.{_WRAPPING[operator]}({rp})'
            method = {'/': 'wrapping_div', '%': 'wrapping_rem'}[operator]
            return f'{lp}.{method}({rp})'
        if operator == '%' and t.kind == 'int':
            # Checked iN::MIN % -1: Solidity yields 0; Rust's `%` panics
            # under overflow checks. rt::srem zero-checks then wraps.
            return f'rt::srem({lp}, {rp})'
        return f'{lp} {operator} {rp}'

    def _mask_odd_width(self, code: str, t: SolType) -> str:
        """Truncate a result back to a declared odd width (uint96/168/...)."""
        if not t.is_odd_width:
            return code
        if t.kind != 'uint':
            self._ctx.warn(f'odd-width signed result not re-masked for {t}')
            return code
        if t.is_wide:
            return f'rt::mask_bits({code}, {t.bits})'
        mask = (1 << t.bits) - 1
        mask_lit = self._types.int_literal(mask, SolType('uint', bits=t.mapped_bits))
        return f'(({code}) & {mask_lit})'

    def _shift_amount(self, expr: Expression) -> str:
        t = self._infer.infer(expr)
        if t.kind == 'intlit' and isinstance(expr, Literal):
            return f'{self._literal_value(expr)}u64'
        if t.is_wide:
            code = self.emit(expr, t)
            return f'rt::shift_amt({code})'
        code, actual = self.emit_typed(expr)
        return f'({self._paren(expr, code)} as u64)'

    def _to_u64(self, expr: Expression) -> str:
        t = self._infer.infer(expr)
        if t.kind == 'intlit' and isinstance(expr, Literal):
            return f'{self._literal_value(expr)}u64'
        if t.is_wide:
            code = self.emit(expr, t)
            return f'rt::shift_amt({code})'
        code, _ = self.emit_typed(expr)
        return f'({self._paren(expr, code)} as u64)'

    def _emit_unary(self, op: UnaryOperation):
        if op.operator == '!':
            code = self.emit(op.operand, BOOL)
            return f'!{self._paren(op.operand, code)}', BOOL
        if op.operator == '-':
            t = self._infer.infer(op.operand)
            if isinstance(op.operand, Literal) and t.kind == 'intlit':
                # Negative literal: keep untyped so context types it.
                return f'-{op.operand.value}', INTLIT
            code = self.emit(op.operand, t)
            if t.is_wide and t.kind == 'int':
                if self._ctx.unchecked:
                    return f'{self._paren(op.operand, code)}.wrapping_neg()', t
                return f'{self._paren(op.operand, code)}.checked_neg().expect("panic: negation overflow")', t
            if t.kind == 'int' and self._ctx.unchecked:
                # unchecked -iN::MIN wraps in Solidity; plain `-` would panic
                # under the workspace-wide overflow checks.
                return f'{self._paren(op.operand, code)}.wrapping_neg()', t
            return f'-{self._paren(op.operand, code)}', t
        if op.operator == '~':
            t = self._infer.infer(op.operand)
            code = self.emit(op.operand, t)
            # Bitwise NOT sets every representation bit; odd widths must be
            # truncated back to the declared width (Solidity semantics).
            out = self._mask_odd_width(f'!{self._paren(op.operand, code)}', t)
            return out, t
        if op.operator in ('++', '--'):
            # Only legal as a statement / for-loop post; the statement layer
            # rewrites those. Reaching here means value-position inc/dec.
            self._ctx.warn('++/-- used in value position (unsupported)')
            return 'unimplemented!("inc/dec in value position")', UNKNOWN
        self._ctx.warn(f'unhandled unary operator {op.operator}')
        return f'unimplemented!("unary {op.operator}")', UNKNOWN

    def _emit_ternary(self, op: TernaryOperation):
        t = common_type(
            self._infer.infer(op.true_expression),
            self._infer.infer(op.false_expression),
        )
        if t.kind == 'intlit':
            t = UINT256
        c = self.emit(op.condition, BOOL)
        a = self.emit(op.true_expression, t)
        b = self.emit(op.false_expression, t)
        return f'(if {c} {{ {a} }} else {{ {b} }})', t

    # ------------------------------------------------------------------
    # Member / index access
    # ------------------------------------------------------------------

    def _emit_member(self, access: MemberAccess):
        base = access.expression
        member = access.member

        if isinstance(base, Identifier):
            # Enum variant: Type.Fire
            if base.name in self._symbols.enums:
                from .definition import enum_variant_ident
                self._register_type_use(base.name)
                return f'{rust_ident(base.name)}::{enum_variant_ident(member)}', \
                    SolType('enum', name=base.name)
            # Library constant: Lib.CONST
            if base.name in self._symbols.libraries or base.name in self._symbols.contracts:
                const = self._symbols.lookup_constant(member, base.name)
                if const is not None and const.container == base.name:
                    if base.name != self._ctx.current_class_name:
                        self._ctx.used_modules.add(base.name)
                        name = f'{rust_ident(base.name)}::{rust_ident(const.name)}'
                    else:
                        name = rust_ident(const.name)
                    if const.is_lazy:
                        name = f'(*{name})'
                    return name, const.sol_type
            if base.name == 'msg' or base.name == 'block' or base.name == 'tx':
                self._ctx.warn(f'{base.name}.{member} not modeled yet (needs call context)')
                return f'unimplemented!("{base.name}.{member} requires call context")', \
                    self._infer.infer(access)

        # type(T).max / type(T).min -> compile-time literal
        if isinstance(base, FunctionCall) and isinstance(base.function, Identifier) \
                and base.function.name == 'type' and base.arguments:
            arg = base.arguments[0]
            if isinstance(arg, Identifier):
                t = parse_elementary(arg.name)
                if t is not None and t.is_integer:
                    if member == 'max':
                        v = (1 << t.bits) - 1 if t.kind == 'uint' else (1 << (t.bits - 1)) - 1
                        return self._types.int_literal(v, t), t
                    if member == 'min':
                        v = 0 if t.kind == 'uint' else -(1 << (t.bits - 1))
                        return self._types.int_literal(v, t), t

        if member == 'length':
            code, base_t = self.emit_typed(base)
            return f'U256::from({code}.len())', UINT256

        code, base_t = self.emit_typed(base)
        result_t = self._infer.infer(access)
        return f'{code}.{rust_ident(member)}', result_t

    def _emit_index(self, access: IndexAccess):
        base_code, base_t = self.emit_typed(access.base)
        result_t = self._infer.infer(access)
        if base_t.kind == 'mapping':
            key = self.emit(access.index, base_t.key or UNKNOWN)
            return f'{base_code}.get(&{key})', result_t
        idx = self._usize_index(access.index)
        return f'{base_code}[{idx}]', result_t

    def _usize_index(self, expr: Expression) -> str:
        t = self._infer.infer(expr)
        if t.kind == 'intlit' and isinstance(expr, Literal):
            return str(self._literal_value(expr))
        if t.is_wide:
            code = self.emit(expr, t)
            return f'rt::usize({code})'
        code, _ = self.emit_typed(expr)
        return f'({self._paren(expr, code)} as usize)'

    # ------------------------------------------------------------------
    # Casts
    # ------------------------------------------------------------------

    def _emit_cast(self, type_name: TypeName, inner: Expression):
        target = self._infer.from_type_name(type_name)

        # Literal folding: uint8(3), bytes32(0), address(0xdead)...
        if isinstance(inner, Literal) and inner.kind in ('number', 'hex'):
            return self._literal_in(inner, target), target
        if isinstance(inner, UnaryOperation) and inner.operator == '-' \
                and isinstance(inner.operand, Literal):
            v = -self._literal_value(inner.operand)
            if target.is_integer:
                return self._types.int_literal(v, target), target

        # Interface cast in a value context is just the address value.
        if target.kind in ('interface', 'contract'):
            code, actual = self.emit_typed(inner)
            return self._types.cast(code, actual, target), target

        code, actual = self.emit_typed(inner)
        if actual.kind == 'intlit':
            # e.g. uint256(1) — handled above for plain literals; composed
            # literal expressions land here already emitted as u256.
            actual = UINT256
        return self._types.cast(code, actual, target), target

    # ------------------------------------------------------------------
    # Calls
    # ------------------------------------------------------------------

    def _emit_call(self, call: FunctionCall):
        func = call.function

        if isinstance(func, NewExpression):
            t = self._infer.from_type_name(func.type_name)
            if t.kind == 'array' and t.size is None:
                elem_default = self._types.default_value(t.elem or UNKNOWN)
                if call.arguments:
                    n = self._usize_index(call.arguments[0])
                    return f'vec![{elem_default}; {n}]', t
                return 'Vec::new()', t
            self._ctx.warn(f'new {t} not supported')
            return 'unimplemented!("new expression")', t

        if isinstance(func, Identifier):
            name = func.name

            # Elementary type cast as call: uint32(x), address(x)...
            if parse_elementary(name) is not None:
                if len(call.arguments) == 1:
                    return self._emit_cast(TypeName(name=name), call.arguments[0])
            # Enum "cast": Type(x)
            if name in self._symbols.enums and call.arguments:
                return self._emit_cast(TypeName(name=name), call.arguments[0])
            # Struct construction
            if name in self._symbols.structs:
                return self._emit_struct_init(name, call)
            # Interface cast: IEffect(addr)
            if name in self._symbols.interfaces and len(call.arguments) == 1:
                return self._emit_cast(TypeName(name=name), call.arguments[0])

            if name == 'keccak256':
                return self._emit_hash('rt::keccak256', call), BYTES32
            if name == 'sha256':
                return self._emit_hash('rt::sha256', call), BYTES32

            # Same-container call
            sig = self._symbols.lookup_function(self._ctx.current_class_name, name)
            if sig is not None:
                args = self._emit_args(sig, call.arguments)
                return f'{rust_ident(name)}({args})' if self._ctx.current_contract_kind == 'library' \
                    else f'self.{rust_ident(name)}({args})', sig.return_type()

            self._ctx.warn(f'call to unknown function {name}')
            args = ', '.join(self.emit(a) for a in call.arguments)
            return f'{rust_ident(name)}({args})', UNKNOWN

        if isinstance(func, MemberAccess):
            base = func.expression
            member = func.member

            # abi.encode / abi.encodePacked
            if isinstance(base, Identifier) and base.name == 'abi':
                if member in ('encode', 'encodePacked'):
                    fn = 'rt::abi_encode' if member == 'encode' else 'rt::abi_encode_packed'
                    tokens = ', '.join(self._abi_token(a) for a in call.arguments)
                    return f'{fn}(&[{tokens}])', BYTES
                self._ctx.warn(f'abi.{member} not supported yet')
                return f'unimplemented!("abi.{member}")', UNKNOWN

            # Library static call: Lib.fn(...)
            if isinstance(base, Identifier) and base.name in self._symbols.libraries:
                sig = self._symbols.lookup_function(base.name, member)
                if sig is not None:
                    if base.name != self._ctx.current_class_name:
                        self._ctx.used_modules.add(base.name)
                        prefix = f'{rust_ident(base.name)}::'
                    else:
                        prefix = ''
                    args = self._emit_args(sig, call.arguments)
                    return f'{prefix}{rust_ident(member)}({args})', sig.return_type()

            # Interface method call through a value
            recv_t = self._infer.infer(base)
            if recv_t.kind in ('interface', 'contract'):
                sig = self._symbols.lookup_function(recv_t.name, member)
                ret = sig.return_type() if sig else UNKNOWN
                if isinstance(base, Identifier) and base.name in self._ctx.dyn_params:
                    args = self._emit_args(sig, call.arguments) if sig \
                        else ', '.join(self.emit(a) for a in call.arguments)
                    return f'{rust_ident(base.name)}.{rust_ident(member)}({args})', ret
                # Method call on an interface VALUE (an address): external
                # dispatch is a Phase-3 feature (address -> impl registry).
                self._ctx.info(
                    f'external dispatch stub emitted for {recv_t.name}.{member} '
                    f'(compiles; panics if reached before Phase 3)'
                )
                return (
                    f'unimplemented!("external contract dispatch (Phase 3): '
                    f'{recv_t.name}.{member}")',
                    ret,
                )

            # Fallback: plain method-style emission
            code, _ = self.emit_typed(base)
            args = ', '.join(self.emit(a) for a in call.arguments)
            return f'{code}.{rust_ident(member)}({args})', self._infer.infer(call)

        self._ctx.warn(f'unhandled call shape {type(func).__name__}')
        return 'unimplemented!("unhandled call")', UNKNOWN

    def _emit_struct_init(self, name: str, call: FunctionCall):
        t = SolType('struct', name=name)
        fields = self._symbols.structs.get(name, [])
        self._register_type_use(name)
        parts = []
        if call.named_arguments:
            by_name = dict(call.named_arguments)
            for fname, ftype in fields:
                if fname in by_name:
                    parts.append(f'{rust_ident(fname)}: {self.emit(by_name[fname], ftype)}')
                else:
                    parts.append(f'{rust_ident(fname)}: {self._types.default_value(ftype)}')
        else:
            for (fname, ftype), arg in zip(fields, call.arguments):
                parts.append(f'{rust_ident(fname)}: {self.emit(arg, ftype)}')
        return f'{rust_ident(name)} {{ {", ".join(parts)} }}', t

    def _emit_hash(self, fn: str, call: FunctionCall) -> str:
        if len(call.arguments) != 1:
            self._ctx.warn(f'{fn} with {len(call.arguments)} args')
            return f'unimplemented!("{fn} arity")'
        arg = call.arguments[0]
        t = self._infer.infer(arg)
        code = self.emit(arg, t)
        if t.kind == 'bytes':
            return f'{fn}(&{self._paren(arg, code)})'
        if t.kind == 'string':
            return f'{fn}({self._paren(arg, code)}.as_bytes())'
        if t.kind == 'bytes_fixed':
            return f'{fn}({self._paren(arg, code)}.as_slice())'
        self._ctx.warn(f'{fn} over unsupported type {t}')
        return f'unimplemented!("{fn} over {t}")'

    def _emit_args(self, sig, arguments: List[Expression]) -> str:
        parts = []
        for i, arg in enumerate(arguments):
            ptype = sig.param_types[i] if i < len(sig.param_types) else UNKNOWN
            parts.append(self.emit_arg(arg, ptype))
        return ', '.join(parts)

    def emit_arg(self, arg: Expression, ptype: SolType) -> str:
        """Emit a call argument honoring the callee's parameter passing mode."""
        if ptype.is_memory_ref:
            code = self.emit(arg, ptype)
            return f'&mut ({code})'
        if ptype.kind in ('interface', 'contract'):
            if isinstance(arg, Identifier) and arg.name in self._ctx.dyn_params:
                return f'&mut *{rust_ident(arg.name)}'
            # An interface value (Address) cannot become a callable handle
            # until the Phase-3 dispatch registry exists.
            self._ctx.info(
                f'dyn-interface argument from a non-parameter value; emitting '
                f'Phase-3 dispatch stub'
            )
            return f'unimplemented!("address -> dyn dispatch (Phase 3)")'
        return self.emit(arg, ptype)

    def _abi_token(self, arg: Expression) -> str:
        t = self._infer.infer(arg)
        if t.kind == 'intlit' or (t.kind == 'uint'):
            bits = 256 if t.kind == 'intlit' else t.bits
            code = self.emit(arg, uint(256))
            return f'rt::Token::Uint({code}, {bits})'
        if t.kind == 'int':
            code = self.emit(arg, SolType('int', bits=256))
            return f'rt::Token::Int({code}, {t.bits})'
        if t.kind == 'bool':
            return f'rt::Token::Bool({self.emit(arg, BOOL)})'
        if t.kind in ('address', 'interface', 'contract'):
            return f'rt::Token::Address({self.emit(arg, ADDRESS)})'
        if t.kind == 'bytes_fixed' and t.bytes_n == 32:
            return f'rt::Token::FixedBytes({self.emit(arg, BYTES32)})'
        if t.kind == 'string':
            return f'rt::Token::Str({self.emit(arg, STRING)})'
        if t.kind == 'bytes':
            return f'rt::Token::Bytes({self.emit(arg, BYTES)})'
        if t.kind == 'enum':
            code = self.emit(arg, t)
            return f'rt::Token::Uint(U256::from({code} as u8), 8)'
        self._ctx.warn(f'abi encoding of {t} not supported yet')
        return f'rt::Token::Bytes(unimplemented!("abi token for {t}"))'

    # ------------------------------------------------------------------
    # Misc
    # ------------------------------------------------------------------

    def _register_type_use(self, name: str) -> None:
        self._ctx.used_types.add(name)

    @staticmethod
    def _paren(expr: Expression, code: str) -> str:
        from .rust_types import is_wrapped
        if isinstance(expr, (Literal, Identifier, MemberAccess, IndexAccess, FunctionCall)):
            return code
        if is_wrapped(code):
            return code
        return f'({code})'


def _b256_literal(value: int) -> str:
    raw = value & ((1 << 256) - 1)
    b = raw.to_bytes(32, 'big')
    inner = ', '.join(f'0x{x:02x}' for x in b)
    if raw == 0:
        return 'B256::ZERO'
    return f'B256::new([{inner}])'


def _address_literal(value: int) -> str:
    raw = value & ((1 << 160) - 1)
    if raw == 0:
        return 'Address::ZERO'
    b = raw.to_bytes(20, 'big')
    inner = ', '.join(f'0x{x:02x}' for x in b)
    return f'Address::new([{inner}])'

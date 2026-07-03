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
        if actual.kind == 'string' and expected.kind in ('bytes', 'bytes_fixed') \
                and isinstance(expr, Literal):
            # Solidity string literals coerce to bytes/bytesN contexts
            # (`_runEffects(..., "")`); re-materialize in the byte type.
            return self._literal_in(expr, expected)
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
            if target.kind == 'bytes':
                # Solidity "" as bytes -> empty; other literals -> utf8 bytes
                inner = lit.value.strip('"')
                if not inner:
                    return 'Vec::new()'
                return f'{lit.value}.as_bytes().to_vec()'
            if target.kind == 'bytes_fixed':
                inner = lit.value.strip('"')
                raw = inner.encode('utf-8')[:target.bytes_n].ljust(target.bytes_n, b'\x00')
                if not any(raw):
                    return 'B256::ZERO' if target.bytes_n == 32 else f'[0u8; {target.bytes_n}]'
                b = ', '.join(f'0x{x:02x}' for x in raw)
                return f'B256::new([{b}])' if target.bytes_n == 32 else f'[{b}]'
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
        # Storage local bound to a direct mapping index: substitute the
        # re-derived place on every use (never hold a borrow).
        if name in self._ctx.storage_locals:
            return self._ctx.storage_locals[name]['place'], t
        if name in self._ctx.storage_ref_locals or name in self._ctx.ref_params:
            return f'(*{rust_ident(name)})', t
        if name in self._ctx.current_local_vars:
            return rust_ident(name), t
        const = self._symbols.lookup_constant(name, self._ctx.current_class_name or None)
        if const is not None:
            return self._constant_ref(const), const.sol_type
        if name == 'this':
            return 'world.env.current_contract', ADDRESS
        if name in self._ctx.current_state_vars:
            if self._ctx.in_constructor:
                return f'self_.{rust_ident(name)}', t
            return f'world.{rust_ident(self._ctx.current_class_name)}.{rust_ident(name)}', t
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
            if base.name in ('msg', 'block', 'tx'):
                env = {
                    ('msg', 'sender'): ('world.env.msg_sender', ADDRESS),
                    ('tx', 'origin'): ('world.env.tx_origin', ADDRESS),
                    ('block', 'timestamp'): ('world.env.block_timestamp', UINT256),
                    ('block', 'number'): ('world.env.block_number', UINT256),
                }.get((base.name, member))
                if env is not None:
                    return env
                self._ctx.warn(f'{base.name}.{member} not modeled')
                return f'unimplemented!("{base.name}.{member} not modeled")', \
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
        base_t = self._infer.infer(access.base)
        result_t = self._infer.infer(access)
        if base_t.kind == 'mapping':
            # Value read: clone (Solidity storage->memory copy). Place
            # contexts go through emit_place instead.
            base_code = self._emit_mapping_base(access.base)
            key = self.emit(access.index, base_t.key or UNKNOWN)
            return f'{base_code}.get(&({key}))', result_t
        base_code, _ = self.emit_typed(access.base)
        idx = self._usize_index(access.index)
        return f'{base_code}[{idx}]', result_t

    def _emit_mapping_base(self, expr: Expression) -> str:
        """Emit the mapping CONTAINER itself (no deref-clone semantics)."""
        code, _ = self.emit_typed(expr)
        return code

    # ------------------------------------------------------------------
    # Place emission (Phase 2): lvalue paths through world storage
    # ------------------------------------------------------------------

    def emit_place(self, expr: Expression, hoists: Optional[List[str]] = None):
        """Emit ``expr`` as a Rust PLACE (assignable lvalue path).

        Mapping indexing materializes via ``(*container.get_mut(&key))`` —
        matching Solidity's zero-initialized storage on first touch. When
        ``hoists`` is given, mapping keys are bound to temps (added to the
        list as `let` lines) so a registered storage-local substitution
        evaluates its key exactly once.
        Returns (code, SolType).
        """
        if isinstance(expr, Identifier):
            return self.emit_typed(expr)  # identifiers already emit as places
        if isinstance(expr, MemberAccess):
            base_code, _ = self.emit_place(expr.expression, hoists)
            t = self._infer.infer(expr)
            return f'{base_code}.{rust_ident(expr.member)}', t
        if isinstance(expr, IndexAccess):
            base_t = self._infer.infer(expr.base)
            t = self._infer.infer(expr)
            if base_t.kind == 'mapping':
                base_code, _ = self.emit_place(expr.base, hoists)
                key = self.emit(expr.index, base_t.key or UNKNOWN)
                if hoists is not None:
                    tmp = self._ctx.fresh_temp('k')
                    hoists.append(f'let {tmp} = {key};')
                    key = tmp
                return f'(*{base_code}.get_mut(&({key})))', t
            base_code, _ = self.emit_place(expr.base, hoists)
            idx = self._usize_index(expr.index)
            return f'{base_code}[{idx}]', t
        if isinstance(expr, TernaryOperation):
            # Conditional storage place: (if c { placeA } else { placeB })
            cond = self.emit(expr.condition, BOOL)
            if hoists is not None:
                tmp = self._ctx.fresh_temp('c')
                hoists.append(f'let {tmp} = {cond};')
                cond = tmp
            a, at = self.emit_place(expr.true_expression, hoists)
            b, _ = self.emit_place(expr.false_expression, hoists)
            # Emit as a reference-select then deref so both arms are places.
            return f'(*(if {cond} {{ &mut {a} }} else {{ &mut {b} }}))', at
        if isinstance(expr, TupleExpression) and len(expr.components) == 1:
            return self.emit_place(expr.components[0], hoists)
        # Fallback: value emission (diagnosed by callers if misused)
        return self.emit_typed(expr)

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

            # Same-container (or inherited/flattened) call — arity-aware
            # (Rust has no overloading; shorter overloads carry a suffix).
            ov = self._symbols.lookup_overload(
                self._ctx.current_class_name, name, len(call.arguments))
            sig = ov[0] if ov else self._symbols.lookup_function(
                self._ctx.current_class_name, name)
            suffix = ov[1] if ov else ''
            if sig is not None:
                return self._emit_direct_call(
                    rust_ident(name) + suffix, sig, call.arguments
                ), sig.return_type()

            if name in getattr(self._symbols, 'stub_calls', set()):
                self._ctx.info(f'stubbed call to {name} (configured stubCalls)')
                return f'unimplemented!("stubbed: {name} (on-chain-only path)")', UNKNOWN

            self._ctx.warn(f'call to unknown function {name}')
            args = ', '.join(self.emit(a) for a in call.arguments)
            return f'{rust_ident(name)}({args})', UNKNOWN

        if isinstance(func, MemberAccess):
            base = func.expression
            member = func.member

            # abi.encode / abi.encodePacked / abi.decode
            if isinstance(base, Identifier) and base.name == 'abi':
                if member in ('encode', 'encodePacked'):
                    fn = 'rt::abi_encode' if member == 'encode' else 'rt::abi_encode_packed'
                    tokens = ', '.join(self._abi_token(a) for a in call.arguments)
                    return f'{fn}(&[{tokens}])', BYTES
                if member == 'decode':
                    return self._emit_abi_decode(call)
                self._ctx.warn(f'abi.{member} not supported yet')
                return f'unimplemented!("abi.{member}")', UNKNOWN

            # Library static call: Lib.fn(...)
            if isinstance(base, Identifier) and base.name in self._symbols.libraries:
                ovl = self._symbols.lookup_overload(base.name, member, len(call.arguments))
                sig = ovl[0] if ovl else self._symbols.lookup_function(base.name, member)
                lib_suffix = ovl[1] if ovl else ''
                if sig is not None:
                    if not self._symbols_included(base.name):
                        self._ctx.info(f'stubbed call into non-transpiled {base.name}.{member}')
                        return (
                            f'unimplemented!("call into non-transpiled {base.name}.{member}")',
                            sig.return_type(),
                        )
                    if base.name != self._ctx.current_class_name:
                        self._ctx.used_modules.add(base.name)
                        prefix = f'{rust_ident(base.name)}::'
                    else:
                        prefix = ''
                    return self._emit_direct_call(
                        f'{prefix}{rust_ident(member)}{lib_suffix}', sig, call.arguments
                    ), sig.return_type()

            # Interface method call through a value (an Address expression)
            recv_t = self._infer.infer(base)
            if recv_t.kind in ('interface', 'contract'):
                return self._emit_interface_dispatch(recv_t.name, member, base, call)

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

        def field_value(arg: Expression, ftype: SolType) -> str:
            code = self.emit(arg, ftype)
            # Reusing one memory value across fields (or from a ref place)
            # must copy, not move (Solidity memory assignment copies into
            # the struct slotwise; TS aliases, but the gates watch that).
            if not self._types.is_copy(ftype) and isinstance(
                arg, (Identifier, MemberAccess, IndexAccess)
            ):
                return f'{code}.clone()'
            return code

        parts = []
        if call.named_arguments:
            by_name = dict(call.named_arguments)
            for fname, ftype in fields:
                if fname in by_name:
                    parts.append(f'{rust_ident(fname)}: {field_value(by_name[fname], ftype)}')
                else:
                    parts.append(f'{rust_ident(fname)}: {self._types.default_value(ftype)}')
        else:
            for (fname, ftype), arg in zip(fields, call.arguments):
                parts.append(f'{rust_ident(fname)}: {field_value(arg, ftype)}')
        return f'{rust_ident(name)} {{ {", ".join(parts)} }}', t

    def _value_of(self, arg: Expression, ptype: SolType) -> str:
        """Value emission for a hoisted call argument; clones when moving a
        non-Copy value out of a reference place (Solidity external calls
        copy — ABI encoding — so the clone is semantically exact) or out of
        an owned local the caller may still use (loop bodies re-pass the
        same `bytes` arg every iteration)."""
        code = self.emit(arg, ptype)
        if not self._types.is_copy(ptype) \
                and (self._is_storage_ref_expr(arg) or self._rooted_at_local(arg)):
            return f'{code}.clone()'
        return code

    def _rooted_at_local(self, e: Expression) -> bool:
        node = e
        while isinstance(node, (MemberAccess, IndexAccess)):
            node = node.expression if isinstance(node, MemberAccess) else node.base
        return isinstance(node, Identifier) and node.name in self._ctx.current_local_vars

    def _emit_abi_decode(self, call: FunctionCall):
        """`abi.decode(data, (T1, T2, ...))` over STATIC tuples: every element
        is one 32-byte head word. Dynamic/aggregate targets stay diagnosed
        stubs until a use case appears. Conversion reuses the explicit-cast
        machinery (enum range check = Panic 0x21, same as Solidity's decode
        validation)."""
        from ..parser.ast_nodes import TypeName as _TN
        if len(call.arguments) != 2:
            self._ctx.warn(f'abi.decode with {len(call.arguments)} args')
            return 'unimplemented!("abi.decode arity")', UNKNOWN
        types_arg = call.arguments[1]
        comps = list(types_arg.components) \
            if isinstance(types_arg, TupleExpression) else [types_arg]
        targets = []
        for c in comps:
            if isinstance(c, Identifier):
                targets.append(self._infer.from_type_name(_TN(name=c.name)))
            elif isinstance(c, TypeCast):
                targets.append(self._infer.from_type_name(c.type_name))
            else:
                self._ctx.warn('abi.decode: unsupported type expression')
                return 'unimplemented!("abi.decode type expr")', UNKNOWN
        for t in targets:
            if t.kind not in ('uint', 'int', 'bool', 'address', 'enum',
                              'bytes_fixed', 'interface', 'contract'):
                self._ctx.warn(f'abi.decode of {t.kind} not supported yet')
                return f'unimplemented!("abi.decode {t.kind}")', UNKNOWN
        data_code = self.emit(call.arguments[0], BYTES)
        d = self._ctx.fresh_temp('d')
        parts = []
        for i, t in enumerate(targets):
            word = f'rt::abi_word({d}, {i})'
            if t.kind == 'bool':
                parts.append(f'({word} != U256::ZERO)')
            elif t.kind == 'uint' and t.bits == 256:
                parts.append(word)
            else:
                if t.kind == 'enum':
                    self._register_type_use(t.name)
                parts.append(self._types.cast(word, UINT256, t))
        body = parts[0] if len(parts) == 1 else f'({", ".join(parts)})'
        ret_t = targets[0] if len(targets) == 1 else SolType('tuple', members=tuple(targets))
        return f'{{ let {d}: &[u8] = &{data_code}; {body} }}', ret_t

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

    def _symbols_included(self, container: str) -> bool:
        included = getattr(self._symbols, 'included_containers', None)
        return included is None or container in included

    def _emit_direct_call(self, fn_path: str, sig, arguments: List[Expression]) -> str:
        """Call a known function. If the callee takes `world`, hoist every
        argument to a temp inside a block expression so evaluation never
        overlaps the `&mut world` being passed; storage-ref arguments to
        world-taking callees are LOWERED to their mapping keys (the callee
        re-derives the place from world — see FuncSig.param_lowered)."""
        if not sig.needs_world:
            shared = self._shared_storage_base(arguments)
            if shared is not None:
                return self._emit_call_with_shared_base(fn_path, sig, arguments, shared)
            hoists: List[str] = []
            args = self._emit_args(sig, arguments, hoists)
            if hoists:
                # Storage-place args hoist their mapping keys first so key
                # computation (which may read world) finishes before the
                # get_mut borrow starts.
                return f'{{ {" ".join(hoists)} {fn_path}({args}) }}'
            return f'{fn_path}({args})'
        lines = []
        arg_names = []
        lowered = getattr(sig, 'param_lowered', None) or [None] * len(sig.param_types)
        for i, arg in enumerate(arguments):
            ptype = sig.param_types[i] if i < len(sig.param_types) else UNKNOWN
            low = lowered[i] if i < len(lowered) else None
            if low is not None:
                if low[0] == '!unsupported':
                    self._ctx.warn(
                        f'storage param of world-taking callee has no unique root '
                        f'mapping ({low[1]}); call site cannot lower it'
                    )
                    arg_names.append('unimplemented!("unlowerable storage param")')
                    continue
                if low[0] == '!selector':
                    place = self._selector_place_of(arg, lines)
                    tmp = self._ctx.fresh_temp('a')
                    lines.append(
                        f'let {tmp} = &crate::world::sel('
                        f'move |world: &mut World| &mut {place});'
                    )
                    arg_names.append(tmp)
                    continue
                key_code = self._storage_key_of(arg, low)
                tmp = self._ctx.fresh_temp('a')
                lines.append(f'let {tmp} = {key_code};')
                arg_names.append(tmp)
                continue
            tmp = self._ctx.fresh_temp('a')
            if ptype.is_memory_ref:
                code = self._value_of(arg, ptype)
                lines.append(f'let mut {tmp} = {code};')
                arg_names.append(f'&mut {tmp}')
            else:
                code = self._value_of(arg, ptype)
                lines.append(f'let {tmp} = {code};')
                arg_names.append(tmp)
        body = ' '.join(lines)
        args = ', '.join(['world'] + arg_names)
        return f'{{ {body} {fn_path}({args}) }}'

    def _shared_storage_base(self, arguments):
        """When 2+ args read through the SAME substituted storage local
        (e.g. `f(config.p0Effects, config.packedP0EffectsCount, ...)`), a
        naive emission would call get_mut twice in one expression (E0499).
        Returns the shared local name, or None."""
        counts = {}
        for arg in arguments:
            node = arg
            while isinstance(node, (MemberAccess, IndexAccess)):
                node = node.expression if isinstance(node, MemberAccess) else node.base
            if isinstance(node, Identifier) and node.name in self._ctx.storage_locals:
                counts[node.name] = counts.get(node.name, 0) + 1
        for name, n in counts.items():
            if n >= 2:
                return name
        return None

    def _emit_call_with_shared_base(self, fn_path: str, sig, arguments, base_name: str) -> str:
        """Bind the shared storage place ONCE, pass field paths through it."""
        base_place = self._ctx.storage_locals[base_name]['place']
        tmp = self._ctx.fresh_temp('cfg')
        saved = dict(self._ctx.storage_locals)
        self._ctx.storage_locals[base_name] = dict(
            saved[base_name], place=f'(*{tmp})'
        )
        try:
            args = self._emit_args(sig, arguments)
        finally:
            self._ctx.storage_locals = saved
        return f'{{ let {tmp} = &mut {base_place}; {fn_path}({args}) }}'

    def _selector_place_of(self, arg: Expression, hoists: List[str]) -> str:
        """Place text for a selector-lowered storage argument, valid inside a
        `move |world: &mut World|` closure: the closure param shadows `world`
        so the same substitution text re-derives the place per callee use;
        hoisted key temps are Copy values captured by the move."""
        if isinstance(arg, Identifier):
            info = self._ctx.storage_locals.get(arg.name)
            if info is not None:
                return info['place']
        place, _ = self.emit_place(arg, hoists)
        return place

    def _storage_key_of(self, arg: Expression, root) -> str:
        """The KEY expression for a storage argument being lowered.

        Cases: a registered storage local (its hoisted key temp); a direct
        `stateMapping[key]` index whose mapping matches the root; a forwarded
        key-lowered parameter of the current function.
        """
        if isinstance(arg, Identifier):
            info = self._ctx.storage_locals.get(arg.name)
            if info is not None and info.get('key') is not None:
                return info['key']
        if isinstance(arg, IndexAccess) and isinstance(arg.base, Identifier):
            if arg.base.name == root[1]:
                return self.emit(arg.index, root[2])
        self._ctx.warn('cannot derive storage key for lowered argument')
        return 'unimplemented!("storage key underivable at call site")'

    def _is_storage_ref_expr(self, expr: Expression) -> bool:
        """True when the argument denotes a storage place (substituted
        storage local, storage-ref param/local, or a path into one)."""
        if isinstance(expr, Identifier):
            return (expr.name in self._ctx.storage_locals
                    or expr.name in self._ctx.storage_ref_locals
                    or expr.name in self._ctx.ref_params)
        if isinstance(expr, MemberAccess):
            return self._is_storage_ref_expr(expr.expression)
        if isinstance(expr, IndexAccess):
            return self._is_storage_ref_expr(expr.base)
        if isinstance(expr, TernaryOperation):
            return (self._is_storage_ref_expr(expr.true_expression)
                    and self._is_storage_ref_expr(expr.false_expression))
        return False

    def _emit_interface_dispatch(self, iface: str, member: str, base: Expression,
                                 call: FunctionCall):
        """Method call through an interface-typed VALUE (an Address).

        - interfaceAliases: direct module call into the single transpiled
          impl, with a msg.sender frame push when the callee takes world.
        - externalInterfaces: routed to world.ext (harness mocks).
        - otherwise: loud stub (Phase-3 enum dispatch will replace it).
        """
        sig = self._symbols.lookup_function(iface, member)
        ret = sig.return_type() if sig else UNKNOWN

        alias = self._symbols.interface_aliases.get(iface)
        if alias is not None and self._symbols_included(alias):
            impl_sig = self._symbols.lookup_function(alias, member)
            if impl_sig is None:
                self._ctx.warn(f'alias {iface}->{alias} lacks method {member}')
                return f'unimplemented!("{alias}.{member} missing")', ret
            if alias != self._ctx.current_class_name:
                self._ctx.used_modules.add(alias)
                fn_path = f'{rust_ident(alias)}::{rust_ident(member)}'
            else:
                fn_path = rust_ident(member)
            if not impl_sig.needs_world:
                args = self._emit_args(impl_sig, call.arguments)
                return f'{fn_path}({args})', impl_sig.return_type()
            # world call with msg.sender frame: sender becomes the calling
            # contract, current becomes the callee address.
            target = self.emit(base, ADDRESS)
            lines = [
                f'let __target = {target};',
                'let __saved_sender = world.env.msg_sender;',
                'let __saved_contract = world.env.current_contract;',
                'world.env.msg_sender = world.env.current_contract;',
                'world.env.current_contract = __target;',
            ]
            arg_names = []
            for i, arg in enumerate(call.arguments):
                ptype = impl_sig.param_types[i] if i < len(impl_sig.param_types) else UNKNOWN
                tmp = self._ctx.fresh_temp('a')
                if ptype.is_memory_ref:
                    code = self._value_of(arg, ptype)
                    lines.insert(1, f'let mut {tmp} = {code};')
                    arg_names.append(f'&mut {tmp}')
                else:
                    code = self._value_of(arg, ptype)
                    lines.insert(1, f'let {tmp} = {code};')
                    arg_names.append(tmp)
            args = ', '.join(['world'] + arg_names)
            body = ' '.join(lines)
            return (
                f'{{ {body} let __r = {fn_path}({args}); '
                f'world.env.msg_sender = __saved_sender; '
                f'world.env.current_contract = __saved_contract; __r }}',
                impl_sig.return_type(),
            )

        if iface in self._symbols.external_interfaces:
            self._symbols.record_ext_call(iface, member)
            target = self.emit(base, ADDRESS)
            lines = [f'let __target = {target};']
            arg_names = []
            for i, arg in enumerate(call.arguments):
                ptype = sig.param_types[i] if sig and i < len(sig.param_types) else UNKNOWN
                tmp = self._ctx.fresh_temp('a')
                code = self._value_of(arg, ptype)
                lines.append(f'let {tmp} = {code};')
                arg_names.append(tmp)
            args = ', '.join(['__target'] + arg_names)
            body = ' '.join(lines)
            return (
                f'{{ {body} world.ext.{rust_ident(iface)}_{rust_ident(member)}({args}) }}',
                ret,
            )

        self._ctx.info(
            f'external dispatch stub emitted for {iface}.{member} '
            f'(compiles; panics if reached before Phase 3)'
        )
        return self._typed_stub(f'external contract dispatch (Phase 3): {iface}.{member}', ret), ret

    def _typed_stub(self, msg: str, ret: SolType) -> str:
        """Diverging stub carrying the callee's return type (plain
        `unimplemented!` gets unified as `()` in comparison/field contexts)."""
        if ret.kind == 'unknown':
            return f'rt::todo("{msg}")'
        if ret.kind == 'tuple' and any(m.kind == 'unknown' for m in ret.members):
            return f'rt::todo("{msg}")'
        return f'rt::todo::<{self._types.rust_type(ret)}>("{msg}")'

    def _emit_args(self, sig, arguments: List[Expression],
                   hoists: Optional[List[str]] = None) -> str:
        parts = []
        for i, arg in enumerate(arguments):
            ptype = sig.param_types[i] if i < len(sig.param_types) else UNKNOWN
            parts.append(self.emit_arg(arg, ptype, hoists))
        return ', '.join(parts)

    def emit_arg(self, arg: Expression, ptype: SolType,
                 hoists: Optional[List[str]] = None) -> str:
        """Emit a call argument honoring the callee's parameter passing mode.
        Interface-typed params are plain Address VALUES (Phase 2)."""
        if ptype.is_memory_ref or ptype.kind == 'mapping':
            if self._is_storage_ref_expr(arg):
                place, _ = self.emit_place(arg)
                return f'&mut {place}'
            if hoists is not None and self._is_state_place(arg):
                # `f(battleConfig[key], ...)` — pass the storage place, not a
                # clone; the mapping key hoists so its evaluation (possibly a
                # world call) never overlaps the get_mut borrow.
                place, _ = self.emit_place(arg, hoists)
                return f'&mut {place}'
            code = self.emit(arg, ptype)
            return f'&mut ({code})'
        return self.emit(arg, ptype)

    def _is_state_place(self, expr: Expression) -> bool:
        """True when ``expr`` is an index/member path rooted at a state var
        (a storage place living in world)."""
        node = expr
        while isinstance(node, (MemberAccess, IndexAccess)):
            node = node.expression if isinstance(node, MemberAccess) else node.base
        return isinstance(node, Identifier) \
            and node.name in self._ctx.current_state_vars \
            and node.name not in self._ctx.current_local_vars

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

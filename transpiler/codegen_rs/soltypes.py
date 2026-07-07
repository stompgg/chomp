"""Solidity type model + expression type inference for the Rust backend.

The TypeScript backend never needed expression types: every integer is a
``bigint`` and every container is a JS object, so emission is type-blind.
The Rust backend maps each Solidity integer width to the smallest native
Rust type (the whole point of the port), which makes emission type-DRIVEN:
every binary operation needs the Solidity "common type" of its operands so
the emitter can insert widening coercions, pick checked vs wrapping
intrinsics, and reproduce Solidity's cast semantics exactly.

``SolType`` is a small structural model of Solidity's type system and
``TypeInferencer`` computes the SolType of an expression from the same
context the TS generators use (``var_types`` + the cross-file
``RustSymbols`` table).

Fidelity notes (verified against Solidity 0.8 semantics):
- Explicit narrowing integer casts truncate (two's complement); same-width
  signed<->unsigned casts reinterpret bits. Rust ``as`` matches both.
- Arithmetic happens in the common type of the operands after implicit
  widening; 0.8 checked semantics revert on overflow.
- Shifts take the type of the LEFT operand; a shift amount >= bit width
  yields 0 (or -1 for negative signed right-shift) instead of trapping.
- ``**`` takes the type of the base.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple, TYPE_CHECKING

from ..parser.ast_nodes import (
    ArrayLiteral,
    BinaryOperation,
    Expression,
    FunctionCall,
    Identifier,
    IndexAccess,
    Literal,
    MemberAccess,
    TernaryOperation,
    TupleExpression,
    TypeCast,
    TypeName,
    UnaryOperation,
)

if TYPE_CHECKING:
    from .symbols import RustSymbols


# Widths for which Rust has a native integer type.
_NATIVE_WIDTHS = (8, 16, 32, 64, 128)

_COMPARISON_OPS = {'==', '!=', '<', '<=', '>', '>='}
_LOGICAL_OPS = {'&&', '||'}
_SHIFT_OPS = {'<<', '>>'}
_ARITH_OPS = {'+', '-', '*', '/', '%'}
_BITWISE_OPS = {'&', '|', '^'}


@dataclass(frozen=True)
class SolType:
    """Structural model of a Solidity type.

    kind is one of:
      'uint' / 'int'      - integer, ``bits`` set (8..256, any multiple of 8)
      'intlit'            - untyped integer literal (adopts context type)
      'bool' / 'address' / 'string' / 'bytes'
      'bytes_fixed'       - bytesN, ``bytes_n`` set
      'enum' / 'struct' / 'interface' / 'contract' / 'library'  - ``name`` set
      'array'             - ``elem`` set, ``size`` None for dynamic
      'mapping'           - ``key`` / ``value`` set
      'tuple'             - ``members`` set
      'unknown'
    """

    kind: str
    bits: int = 0
    bytes_n: int = 0
    name: str = ''
    elem: Optional['SolType'] = None
    size: Optional[int] = None
    key: Optional['SolType'] = None
    value: Optional['SolType'] = None
    members: Tuple['SolType', ...] = ()

    # ------------------------------------------------------------------
    # Classification helpers
    # ------------------------------------------------------------------

    @property
    def is_integer(self) -> bool:
        return self.kind in ('uint', 'int', 'intlit')

    @property
    def is_signed(self) -> bool:
        return self.kind == 'int'

    @property
    def mapped_bits(self) -> int:
        """Bit width of the Rust representation (native width or 256)."""
        for w in _NATIVE_WIDTHS:
            if self.bits <= w:
                return w
        return 256

    @property
    def is_native(self) -> bool:
        """True when the Rust representation is a native machine integer."""
        return self.is_integer and self.kind != 'intlit' and self.mapped_bits <= 128

    @property
    def is_wide(self) -> bool:
        """True when the Rust representation is U256/I256."""
        return self.is_integer and self.kind != 'intlit' and self.mapped_bits == 256

    @property
    def is_odd_width(self) -> bool:
        """Declared width has no exact Rust representation (e.g. uint96, uint168).

        Values are stored in the next-wider representation; explicit casts to
        the type must mask, and checked arithmetic bounds diverge (diagnosed).
        """
        return (
            self.is_integer
            and self.kind != 'intlit'
            and self.bits not in _NATIVE_WIDTHS
            and self.bits != 256
        )

    @property
    def is_memory_ref(self) -> bool:
        """Reference-typed in Solidity memory (passed by reference between
        internal functions): arrays and structs. These become ``&mut T``
        parameters in Rust."""
        return self.kind in ('array', 'struct')

    def __str__(self) -> str:  # pragma: no cover - debugging aid
        if self.kind in ('uint', 'int'):
            return f'{self.kind}{self.bits}'
        if self.kind == 'bytes_fixed':
            return f'bytes{self.bytes_n}'
        if self.kind == 'array':
            sz = '' if self.size is None else str(self.size)
            return f'{self.elem}[{sz}]'
        if self.kind in ('enum', 'struct', 'interface', 'contract', 'library'):
            return f'{self.kind} {self.name}'
        return self.kind


# Canonical singletons for common types
BOOL = SolType('bool')
ADDRESS = SolType('address')
STRING = SolType('string')
BYTES = SolType('bytes')
BYTES32 = SolType('bytes_fixed', bytes_n=32)
INTLIT = SolType('intlit')
UNKNOWN = SolType('unknown')
UINT256 = SolType('uint', bits=256)
UINT8 = SolType('uint', bits=8)


def uint(bits: int) -> SolType:
    return SolType('uint', bits=bits)


def int_(bits: int) -> SolType:
    return SolType('int', bits=bits)


def parse_elementary(name: str) -> Optional[SolType]:
    """Parse an elementary Solidity type name, or None if not elementary."""
    if name == 'bool':
        return BOOL
    if name == 'address' or name == 'payable':
        return ADDRESS
    if name == 'string':
        return STRING
    if name == 'bytes':
        return BYTES
    if name.startswith('bytes') and name[5:].isdigit():
        return SolType('bytes_fixed', bytes_n=int(name[5:]))
    if name.startswith('uint'):
        rest = name[4:]
        if rest == '':
            return UINT256
        if rest.isdigit():
            return uint(int(rest))
    if name.startswith('int'):
        rest = name[3:]
        if rest == '':
            return int_(256)
        if rest.isdigit():
            return int_(int(rest))
    return None


def common_type(a: SolType, b: SolType, diagnostics=None) -> SolType:
    """Solidity's common type for a binary operation's operands.

    Untyped literals adopt the other operand's type (Solidity checks the
    literal fits at compile time; we trust the source compiled with solc).
    """
    if a.kind == 'intlit' and b.kind == 'intlit':
        return INTLIT
    if a.kind == 'intlit':
        return b
    if b.kind == 'intlit':
        return a
    if a.kind == 'unknown':
        return b
    if b.kind == 'unknown':
        return a
    if a.kind == b.kind and a.kind in ('uint', 'int'):
        return SolType(a.kind, bits=max(a.bits, b.bits))
    if {a.kind, b.kind} == {'uint', 'int'}:
        # Implicit uintN -> intM is legal only when M > N; the common type is
        # the signed one (widened if needed). Source that compiles under solc
        # can only contain the legal case.
        u, s = (a, b) if a.kind == 'uint' else (b, a)
        bits = max(s.bits, u.bits * 2 if u.bits < 256 else 256)
        bits = min(bits, 256)
        return SolType('int', bits=max(s.bits, bits if u.bits >= s.bits else s.bits))
    # Same non-numeric kinds compare fine (address, bytes32, enum, bool...)
    return a


class TypeInferencer:
    """Compute the SolType of an expression.

    Reads local/param/state variable types from the shared codegen context's
    ``var_types`` (TypeName nodes, maintained by the function/statement
    generators exactly like the TS backend) and everything cross-file from
    ``RustSymbols``.
    """

    def __init__(self, symbols: 'RustSymbols', ctx):
        self._symbols = symbols
        self._ctx = ctx  # RustCodeGenerationContext

    # ------------------------------------------------------------------
    # TypeName -> SolType
    # ------------------------------------------------------------------

    def from_type_name(self, tn: Optional[TypeName]) -> SolType:
        if tn is None:
            return UNKNOWN
        if tn.is_mapping:
            return SolType(
                'mapping',
                key=self.from_type_name(tn.key_type),
                value=self.from_type_name(tn.value_type),
            )
        base = self._resolve_base_name(tn.name)
        if tn.is_array:
            size = self._resolve_array_size(tn)
            dims = getattr(tn, 'array_dimensions', 1) or 1
            arr = SolType('array', elem=base, size=size)
            for _ in range(dims - 1):
                arr = SolType('array', elem=arr, size=None)
            return arr
        return base

    def _resolve_base_name(self, name: str) -> SolType:
        elem = parse_elementary(name)
        if elem is not None:
            return elem
        # Library-qualified struct (Lib.Struct)
        if '.' in name:
            name = name.split('.')[-1]
        sym = self._symbols
        if name in sym.enums:
            return SolType('enum', name=name)
        if name in sym.structs:
            return SolType('struct', name=name)
        if name in sym.interfaces:
            return SolType('interface', name=name)
        if name in sym.libraries:
            return SolType('library', name=name)
        if name in sym.contracts:
            return SolType('contract', name=name)
        return SolType('unknown', name=name)

    def _resolve_array_size(self, tn: TypeName) -> Optional[int]:
        size_expr = getattr(tn, 'array_size', None)
        if size_expr is None:
            return None
        if isinstance(size_expr, Literal) and size_expr.kind == 'number':
            return int(str(size_expr.value), 0)
        if isinstance(size_expr, Identifier):
            const = self._symbols.lookup_constant(size_expr.name)
            if const is not None and const.value is not None:
                return int(const.value)
        return None

    # ------------------------------------------------------------------
    # Expression -> SolType
    # ------------------------------------------------------------------

    def infer(self, expr: Expression) -> SolType:
        if expr is None:
            return UNKNOWN
        if isinstance(expr, Literal):
            return self._infer_literal(expr)
        if isinstance(expr, Identifier):
            return self._infer_identifier(expr)
        if isinstance(expr, BinaryOperation):
            return self._infer_binary(expr)
        if isinstance(expr, UnaryOperation):
            op_type = self.infer(expr.operand)
            if expr.operator == '!':
                return BOOL
            return op_type
        if isinstance(expr, TernaryOperation):
            return common_type(
                self.infer(expr.true_expression), self.infer(expr.false_expression)
            )
        if isinstance(expr, TypeCast):
            return self.from_type_name(expr.type_name)
        if isinstance(expr, FunctionCall):
            return self._infer_call(expr)
        if isinstance(expr, MemberAccess):
            return self._infer_member(expr)
        if isinstance(expr, IndexAccess):
            container = self.infer(expr.base)
            if container.kind == 'array':
                return container.elem or UNKNOWN
            if container.kind == 'mapping':
                return container.value or UNKNOWN
            return UNKNOWN
        if isinstance(expr, TupleExpression):
            comps = [c for c in expr.components]
            if len(comps) == 1 and comps[0] is not None:
                return self.infer(comps[0])  # parenthesized expression
            return SolType(
                'tuple',
                members=tuple(self.infer(c) if c else UNKNOWN for c in comps),
            )
        if isinstance(expr, ArrayLiteral):
            elem = self.infer(expr.elements[0]) if expr.elements else UNKNOWN
            return SolType('array', elem=elem, size=len(expr.elements))
        return UNKNOWN

    def _infer_literal(self, lit: Literal) -> SolType:
        if lit.kind in ('number', 'hex'):
            return INTLIT
        if lit.kind == 'bool':
            return BOOL
        if lit.kind == 'string':
            return STRING
        if lit.kind == 'hex_string':
            return BYTES
        return UNKNOWN

    def _infer_identifier(self, ident: Identifier) -> SolType:
        name = ident.name
        tn = self._ctx.var_types.get(name)
        if tn is not None:
            return self.from_type_name(tn)
        const = self._symbols.lookup_constant(name, self._ctx.current_class_name or None)
        if const is not None:
            return const.sol_type
        # Bare type name used as value (rare; e.g. enum in abi args)
        return self._resolve_base_name(name)

    def _infer_binary(self, op: BinaryOperation) -> SolType:
        if op.operator in _COMPARISON_OPS or op.operator in _LOGICAL_OPS:
            return BOOL
        if op.operator in _SHIFT_OPS or op.operator == '**':
            base = self.infer(op.left)
            if base.kind == 'intlit':
                # e.g. (1 << KEY_OFFSET) in a uint256 context: Solidity gives
                # literal shifts type uint256 when the value requires it; the
                # emitter resolves intlit against the expected type, so keep
                # intlit here and let context decide.
                return INTLIT
            return base
        if op.operator == '=' or op.operator.endswith('='):
            # Assignment expression: type of the LHS
            if op.operator in ('=', '+=', '-=', '*=', '/=', '%=', '|=', '&=', '^=', '<<=', '>>='):
                return self.infer(op.left)
        return common_type(self.infer(op.left), self.infer(op.right))

    def _infer_call(self, call: FunctionCall) -> SolType:
        func = call.function
        # new T[](n)
        from ..parser.ast_nodes import NewExpression
        if isinstance(func, NewExpression):
            return self.from_type_name(func.type_name)

        if isinstance(func, Identifier):
            name = func.name
            elem = parse_elementary(name)
            if elem is not None:
                return elem  # cast-style call uint32(x)
            if name in self._symbols.enums:
                return SolType('enum', name=name)
            if name in self._symbols.structs:
                return SolType('struct', name=name)
            if name in self._symbols.interfaces:
                return SolType('interface', name=name)
            if name in self._symbols.contracts:
                return SolType('contract', name=name)
            if name == 'keccak256' or name == 'sha256' or name == 'blockhash':
                return BYTES32
            if name == 'type':
                return UNKNOWN
            # Same-container function call
            sig = self._symbols.lookup_function(self._ctx.current_class_name, name)
            if sig is None:
                sig = self._symbols.lookup_function(None, name)
            if sig is not None:
                return sig.return_type()
            return UNKNOWN

        if isinstance(func, MemberAccess):
            base = func.expression
            member = func.member
            if isinstance(base, Identifier):
                if base.name == 'abi':
                    return BYTES  # encode/encodePacked; decode handled by caller
                if base.name == 'type':
                    return UNKNOWN
                # Library / contract static call: Lib.fn(...)
                sig = self._symbols.lookup_function(base.name, member)
                if sig is not None:
                    return sig.return_type()
            # Interface method call through a value: engine.getTeamSize(...)
            recv = self.infer(base)
            if recv.kind in ('interface', 'contract'):
                sig = self._symbols.lookup_function(recv.name, member)
                if sig is not None:
                    return sig.return_type()
            if recv.kind == 'library':
                sig = self._symbols.lookup_function(recv.name, member)
                if sig is not None:
                    return sig.return_type()
        return UNKNOWN

    def _infer_member(self, access: MemberAccess) -> SolType:
        base = access.expression
        member = access.member

        if isinstance(base, Identifier):
            # Enum variant reference: Type.Fire
            if base.name in self._symbols.enums:
                return SolType('enum', name=base.name)
            if base.name == 'msg':
                if member == 'sender':
                    return ADDRESS
                if member == 'value':
                    return UINT256
                return UNKNOWN
            if base.name == 'block':
                return UINT256
            if base.name == 'tx':
                return ADDRESS if member == 'origin' else UNKNOWN
            # Library constant: Lib.CONST
            if base.name in self._symbols.libraries or base.name in self._symbols.contracts:
                const = self._symbols.lookup_constant(member, base.name)
                if const is not None:
                    return const.sol_type

        # type(T).max / type(T).min
        if isinstance(base, FunctionCall) and isinstance(base.function, Identifier) \
                and base.function.name == 'type' and base.arguments:
            arg = base.arguments[0]
            if isinstance(arg, Identifier):
                t = parse_elementary(arg.name)
                if t is not None and member in ('max', 'min'):
                    return t

        if member == 'length':
            return UINT256

        parent = self.infer(base)
        if parent.kind == 'struct':
            fields = self._symbols.structs.get(parent.name)
            if fields:
                for fname, ftype in fields:
                    if fname == member:
                        return ftype
        return UNKNOWN

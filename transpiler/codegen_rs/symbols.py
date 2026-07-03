"""Cross-file symbol table for the Rust backend.

Built in a pre-pass over every parsed source unit before any emission. The
TS backend gets by with the looser ``TypeRegistry`` (names + string types)
because everything is bigint; Rust emission needs full ``SolType`` fidelity
for function signatures (parameter passing mode, widening at call sites),
struct fields (fixed-array sizes), and constants (const-evaluated values so
fixed array sizes and const initializers can be materialized).
"""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from ..parser.ast_nodes import (
    BinaryOperation,
    ContractDefinition,
    Expression,
    FunctionCall,
    FunctionDefinition,
    Identifier,
    Literal,
    MemberAccess,
    SourceUnit,
    TernaryOperation,
    TupleExpression,
    TypeCast,
    UnaryOperation,
)
from .soltypes import SolType, parse_elementary, UNKNOWN


@dataclass
class FuncSig:
    name: str
    container: Optional[str]           # contract/library/interface name, None for free fns
    container_kind: str                # 'contract' | 'library' | 'interface' | ''
    param_names: List[str]
    param_types: List[SolType]
    return_types: List[SolType]
    mutability: str                    # '', 'view', 'pure', 'payable'

    @property
    def is_view(self) -> bool:
        return self.mutability in ('view', 'pure')

    def return_type(self) -> SolType:
        if not self.return_types:
            return SolType('tuple', members=())
        if len(self.return_types) == 1:
            return self.return_types[0]
        return SolType('tuple', members=tuple(self.return_types))


@dataclass
class ConstSig:
    name: str
    sol_type: SolType
    value: Optional[int]               # const-evaluated numeric value, if any
    initial_value: Optional[Expression]
    container: Optional[str] = None    # library/contract that declares it, None = file scope
    is_lazy: bool = False              # emitted as LazyLock (non-const-evaluable initializer)


class RustSymbols:
    """Symbol table spanning every file handed to the Rust backend."""

    def __init__(self):
        self.enums: Dict[str, List[str]] = {}
        self.structs: Dict[str, List[Tuple[str, SolType]]] = {}
        # struct name -> ordered raw TypeName list (for emission-time detail)
        self.struct_type_names: Dict[str, list] = {}
        # Keyed by (container, name): the same constant name can exist at file
        # scope AND inside contracts with different types (live example:
        # Constants.sol's uint256 SWITCH_PRIORITY vs FairCPU's uint32 one) —
        # a bare-name table silently clobbers and mistypes emissions.
        self.constants: Dict[Tuple[Optional[str], str], ConstSig] = {}
        self.interfaces: set = set()
        self.libraries: set = set()
        self.contracts: set = set()
        # (container or None, fn name) -> FuncSig ; overloads keep the longest
        self.functions: Dict[Tuple[Optional[str], str], FuncSig] = {}
        # type/contract name -> rust module path segments, e.g. ('types', 'TypeCalcLib')
        self.module_of: Dict[str, Tuple[str, ...]] = {}
        # state variables per contract: name -> SolType
        self.state_vars: Dict[str, Dict[str, SolType]] = {}

    # ------------------------------------------------------------------
    # Construction
    # ------------------------------------------------------------------

    @classmethod
    def build(cls, asts: Dict[str, SourceUnit]) -> 'RustSymbols':
        """``asts`` maps source-relative paths (no extension) to SourceUnits."""
        sym = cls()
        # Pass 1: names only, so SolType resolution in pass 2 sees everything.
        for rel_path, ast in asts.items():
            module = cls._module_path(rel_path)
            for enum in ast.enums:
                sym.enums[enum.name] = list(enum.members)
                sym.module_of[enum.name] = module
            for struct in ast.structs:
                sym.structs.setdefault(struct.name, [])
                sym.module_of[struct.name] = module
            for contract in ast.contracts:
                sym.module_of[contract.name] = module
                if contract.kind == 'interface':
                    sym.interfaces.add(contract.name)
                elif contract.kind == 'library':
                    sym.libraries.add(contract.name)
                else:
                    sym.contracts.add(contract.name)
                for enum in contract.enums:
                    sym.enums[enum.name] = list(enum.members)
                    sym.module_of[enum.name] = module
                for struct in contract.structs:
                    sym.structs.setdefault(struct.name, [])
                    sym.module_of[struct.name] = module

        resolver = _TypeResolver(sym)

        # Pass 2: full signatures now that all names resolve.
        for rel_path, ast in asts.items():
            module = cls._module_path(rel_path)
            for struct in ast.structs:
                sym._record_struct(struct, resolver)
            for const in ast.constants:
                sym._record_constant(const, resolver, container=None)
                sym.module_of.setdefault(const.name, module)
            for contract in ast.contracts:
                for struct in contract.structs:
                    sym._record_struct(struct, resolver)
                state_types: Dict[str, SolType] = {}
                for var in contract.state_variables:
                    st = resolver.resolve(var.type_name)
                    state_types[var.name] = st
                    if var.mutability == 'constant':
                        sym._record_constant(var, resolver, container=contract.name)
                sym.state_vars[contract.name] = state_types
                for func in contract.functions:
                    if not func.name:
                        continue
                    sig = FuncSig(
                        name=func.name,
                        container=contract.name,
                        container_kind=contract.kind,
                        param_names=[
                            p.name if p.name else f'_arg{i}'
                            for i, p in enumerate(func.parameters)
                        ],
                        param_types=[resolver.resolve(p.type_name) for p in func.parameters],
                        return_types=[resolver.resolve(r.type_name) for r in func.return_parameters],
                        mutability=func.mutability,
                    )
                    key = (contract.name, func.name)
                    existing = sym.functions.get(key)
                    if existing is None or len(sig.param_types) > len(existing.param_types):
                        sym.functions[key] = sig

        # Pass 3: const-eval (constants may reference each other in any order).
        evaluator = ConstEvaluator(sym)
        for _ in range(4):  # small fixed-point for cross-references
            progressed = False
            for const in sym.constants.values():
                if const.value is None and const.initial_value is not None and not const.is_lazy:
                    val = evaluator.eval(const.initial_value, const.sol_type)
                    if val is not None:
                        const.value = val
                        progressed = True
            if not progressed:
                break
        # Decide const vs LazyLock now, so references and definitions agree:
        # lazy iff the initializer is neither const-evaluated numeric nor a
        # literal-like cast (address(0xdead), bytes32(0), ...).
        for const in sym.constants.values():
            if const.value is None and const.initial_value is not None:
                const.is_lazy = not _initializer_is_literal_like(const.initial_value)
        return sym

    @staticmethod
    def _module_path(rel_path: str) -> Tuple[str, ...]:
        parts = rel_path.replace('\\', '/').split('/')
        segs = []
        for i, p in enumerate(parts):
            if i < len(parts) - 1:
                segs.append(_sanitize_module(p))
            else:
                segs.append(p)  # file stem keeps its exact (PascalCase) name
        return tuple(segs)

    def _record_struct(self, struct, resolver) -> None:
        fields = []
        tns = []
        for member in struct.members:
            fields.append((member.name, resolver.resolve(member.type_name)))
            tns.append((member.name, member.type_name))
        self.structs[struct.name] = fields
        self.struct_type_names[struct.name] = tns

    def _record_constant(self, var, resolver, container) -> None:
        self.constants[(container, var.name)] = ConstSig(
            name=var.name,
            sol_type=resolver.resolve(var.type_name),
            value=None,
            initial_value=var.initial_value,
            container=container,
        )

    def lookup_constant(self, name: str, container: Optional[str] = None) -> Optional['ConstSig']:
        """Scoped constant resolution: the current container's own constant
        shadows a file-scope one of the same name (Solidity scoping); a
        file-scope constant is preferred over some other contract's."""
        if container is not None:
            sig = self.constants.get((container, name))
            if sig is not None:
                return sig
        sig = self.constants.get((None, name))
        if sig is not None:
            return sig
        matches = [s for (cont, n), s in sorted(
            self.constants.items(), key=lambda kv: (kv[0][0] or '', kv[0][1])
        ) if n == name]
        if len(matches) == 1:
            return matches[0]
        return None

    # ------------------------------------------------------------------
    # Queries
    # ------------------------------------------------------------------

    def lookup_function(self, container: Optional[str], name: str) -> Optional[FuncSig]:
        sig = self.functions.get((container, name))
        if sig is not None:
            return sig
        # Fall back to any container exposing the name (interface aliases etc.)
        for (cont, fname), s in self.functions.items():
            if fname == name and cont == container:
                return s
        return None

    def rust_module(self, type_name: str) -> Optional[str]:
        segs = self.module_of.get(type_name)
        if segs is None:
            return None
        return '::'.join(segs)


def _sanitize_module(name: str) -> str:
    """Directory name -> valid Rust module identifier (game-layer -> game_layer)."""
    out = name.replace('-', '_').replace('.', '_')
    if out and out[0].isdigit():
        out = '_' + out
    return out


def _initializer_is_literal_like(expr: Expression) -> bool:
    """True for initializers the Rust backend can emit in a `const` context:
    plain literals and (nested) casts of literals — e.g. ``address(0x57B)``,
    ``bytes32(0)``. Runtime computations (hashing, abi encoding) are not."""
    if isinstance(expr, Literal):
        return expr.kind in ('number', 'hex', 'bool')
    if isinstance(expr, UnaryOperation) and expr.operator == '-':
        return _initializer_is_literal_like(expr.operand)
    if isinstance(expr, TypeCast):
        return _initializer_is_literal_like(expr.expression)
    if isinstance(expr, FunctionCall) and isinstance(expr.function, Identifier) \
            and len(expr.arguments) == 1:
        if parse_elementary(expr.function.name) is not None or expr.function.name == 'payable':
            return _initializer_is_literal_like(expr.arguments[0])
    if isinstance(expr, TupleExpression) and len(expr.components) == 1:
        return _initializer_is_literal_like(expr.components[0])
    return False


class _TypeResolver:
    """TypeName -> SolType without a codegen context (symbols only)."""

    def __init__(self, symbols: RustSymbols):
        self._symbols = symbols

    def resolve(self, tn) -> SolType:
        if tn is None:
            return UNKNOWN
        if tn.is_mapping:
            return SolType(
                'mapping',
                key=self.resolve(tn.key_type),
                value=self.resolve(tn.value_type),
            )
        base = self._resolve_name(tn.name)
        if tn.is_array:
            size = None
            size_expr = getattr(tn, 'array_size', None)
            if isinstance(size_expr, Literal) and size_expr.kind == 'number':
                size = int(str(size_expr.value), 0)
            elif isinstance(size_expr, Identifier):
                const = self._symbols.lookup_constant(size_expr.name)
                if const is not None and const.value is not None:
                    size = int(const.value)
                else:
                    # May not be evaluated yet during pass 2; try direct literal.
                    init = const.initial_value if const else None
                    if isinstance(init, Literal) and init.kind == 'number':
                        size = int(str(init.value), 0)
            dims = getattr(tn, 'array_dimensions', 1) or 1
            arr = SolType('array', elem=base, size=size)
            for _ in range(dims - 1):
                arr = SolType('array', elem=arr, size=None)
            return arr
        return base

    def _resolve_name(self, name: str) -> SolType:
        elem = parse_elementary(name)
        if elem is not None:
            return elem
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


class ConstEvaluator:
    """Evaluate constant initializer expressions to Python ints.

    Handles the shapes that appear in this codebase's ``Constants.sol`` and
    library constants: literals (incl. hex + ``_`` separators), unary minus,
    the full binary operator set, ``type(T).max/min``, integer casts
    (masking / sign behavior matching Solidity), references to other
    constants, and parenthesized tuples. Time units are already desugared by
    the parser into ``lit * seconds`` multiplications.

    Returns None for anything non-numeric (e.g. ``sha256(abi.encode(...))``,
    address literals) — those become LazyLock statics or special-cased
    emissions instead.
    """

    def __init__(self, symbols: RustSymbols):
        self._symbols = symbols

    def eval(self, expr: Expression, target: Optional[SolType] = None) -> Optional[int]:
        v = self._eval(expr)
        if v is None:
            return None
        if target is not None and target.is_integer and target.kind != 'intlit':
            # Solidity constant initializers must fit the declared type.
            return v
        return v

    def _eval(self, expr: Expression) -> Optional[int]:
        if isinstance(expr, Literal):
            if expr.kind in ('number', 'hex'):
                try:
                    return int(str(expr.value).replace('_', ''), 0)
                except ValueError:
                    return None
            if expr.kind == 'bool':
                return 1 if expr.value == 'true' else 0
            return None
        if isinstance(expr, Identifier):
            const = self._symbols.lookup_constant(expr.name)
            if const is not None:
                return const.value
            return None
        if isinstance(expr, UnaryOperation):
            v = self._eval(expr.operand)
            if v is None:
                return None
            if expr.operator == '-':
                return -v
            if expr.operator == '~':
                return (~v) & ((1 << 256) - 1)
            return None
        if isinstance(expr, TupleExpression) and len(expr.components) == 1:
            return self._eval(expr.components[0])
        if isinstance(expr, BinaryOperation):
            l = self._eval(expr.left)
            r = self._eval(expr.right)
            if l is None or r is None:
                return None
            op = expr.operator
            if op == '+':
                return l + r
            if op == '-':
                return l - r
            if op == '*':
                return l * r
            if op == '/':
                if r == 0:
                    return None
                q = abs(l) // abs(r)
                return q if (l >= 0) == (r >= 0) else -q
            if op == '%':
                if r == 0:
                    return None
                m = abs(l) % abs(r)
                return m if l >= 0 else -m
            if op == '**':
                return l ** r
            if op == '<<':
                return l << r
            if op == '>>':
                return l >> r
            if op == '&':
                return l & r
            if op == '|':
                return l | r
            if op == '^':
                return l ^ r
            return None
        if isinstance(expr, TypeCast):
            return self._eval_cast(expr.type_name.name, expr.expression)
        if isinstance(expr, FunctionCall):
            func = expr.function
            # type(T).max/min arrives as MemberAccess over FunctionCall
            if isinstance(func, Identifier):
                t = parse_elementary(func.name)
                if t is not None and len(expr.arguments) == 1:
                    return self._eval_cast(func.name, expr.arguments[0])
            return None
        if isinstance(expr, MemberAccess):
            base = expr.expression
            if isinstance(base, FunctionCall) and isinstance(base.function, Identifier) \
                    and base.function.name == 'type' and base.arguments:
                arg = base.arguments[0]
                if isinstance(arg, Identifier):
                    t = parse_elementary(arg.name)
                    if t is not None and t.is_integer:
                        if expr.member == 'max':
                            if t.kind == 'uint':
                                return (1 << t.bits) - 1
                            return (1 << (t.bits - 1)) - 1
                        if expr.member == 'min':
                            if t.kind == 'uint':
                                return 0
                            return -(1 << (t.bits - 1))
            # Library-qualified constant: Lib.CONST
            if isinstance(base, Identifier):
                const = self._symbols.lookup_constant(expr.member, base.name)
                if const is not None:
                    return const.value
            return None
        if isinstance(expr, TernaryOperation):
            c = self._eval(expr.condition)
            if c is None:
                return None
            return self._eval(expr.true_expression if c else expr.false_expression)
        return None

    def _eval_cast(self, type_name: str, inner: Expression) -> Optional[int]:
        v = self._eval(inner)
        if v is None:
            return None
        t = parse_elementary(type_name)
        if t is None or not t.is_integer:
            return None
        mask = (1 << t.bits) - 1
        v &= mask
        if t.kind == 'int' and v >= (1 << (t.bits - 1)):
            v -= 1 << t.bits
        return v

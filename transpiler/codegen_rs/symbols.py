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

# Sentinel import kept light; FuncSig.param_lowered entries are
# (contract_name, state_var_name, key SolType) tuples or None.

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
    # Phase 2: does this function (transitively) need `world: &mut World`?
    # True when it touches contract state, msg/block env, or makes a
    # world-routed call (aliased interface / external interface / a callee
    # that itself needs world). Computed as a call-graph fixed point.
    needs_world: bool = False
    # Per-parameter storage lowering: None = normal passing; otherwise
    # (contract, mapping_state_var, key SolType) — the parameter was a
    # `T storage` ref into that root mapping and is passed as its KEY
    # (a world-taking callee cannot also borrow world through an argument).
    param_lowered: List = field(default_factory=list)

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
        # function bodies for the needs_world scan: (container, name) -> FunctionDefinition
        self.function_defs: Dict[Tuple[Optional[str], str], 'FunctionDefinition'] = {}
        # Phase-2 world configuration (set by the driver before compute_needs_world)
        self.stateful_contracts: set = set()        # contracts with world-resident state
        self.interface_aliases: Dict[str, str] = {} # IEngine -> Engine (transpiled impl)
        self.external_interfaces: set = set()       # routed to world.ext (harness mocks)
        self.stub_calls: set = set()                # bare fn names emitted as stubs
        self.included_containers: Optional[set] = None  # containers whose files are emitted
        self.ext_calls: Dict[Tuple[str, str], Optional['FuncSig']] = {}
        self.flatten_bases: Dict[str, list] = {}
        self.contract_defs: Dict[str, object] = {}  # name -> ContractDefinition
        # (container, name) -> [(FuncSig, FunctionDefinition)] per overload
        self.overloads: Dict[Tuple[Optional[str], str], list] = {}

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
                sym.contract_defs[contract.name] = contract
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

        # Pass 2: constants FIRST (all scopes), then const-eval, and only
        # then structs/signatures — fixed-array sizes named by constants
        # (uint256[MOVE_LANES_PER_MON]) must resolve regardless of file
        # order or constant-to-constant indirection, or the field silently
        # degrades to Vec<T>.
        for rel_path, ast in asts.items():
            module = cls._module_path(rel_path)
            for const in ast.constants:
                sym._record_constant(const, resolver, container=None)
                sym.module_of.setdefault(const.name, module)
            for contract in ast.contracts:
                for var in contract.state_variables:
                    if var.mutability == 'constant':
                        sym._record_constant(var, resolver, container=contract.name)

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

        # Pass 3: structs, state vars, and function signatures — every
        # constant-sized array now sees its evaluated size.
        for rel_path, ast in asts.items():
            for struct in ast.structs:
                sym._record_struct(struct, resolver)
            for contract in ast.contracts:
                for struct in contract.structs:
                    sym._record_struct(struct, resolver)
                state_types: Dict[str, SolType] = {}
                for var in contract.state_variables:
                    state_types[var.name] = resolver.resolve(var.type_name)
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
                    sym.overloads.setdefault(key, []).append((sig, func))
                    existing = sym.functions.get(key)
                    if existing is None or len(sig.param_types) > len(existing.param_types):
                        sym.functions[key] = sig
                        sym.function_defs[key] = func
        return sym

    def lookup_overload(self, container: Optional[str], name: str, nargs: int):
        """Exact-arity overload resolution: returns (FuncSig, name_suffix)
        where the suffix is '' for the longest (canonical) overload and
        '__{arity}' for shorter siblings (Rust has no overloading)."""
        key = (container, name)
        cands = self.overloads.get(key)
        if cands is None:
            for base in self.flatten_bases.get(container, []):
                cands = self.overloads.get((base, name))
                if cands is not None:
                    break
        if not cands:
            return None
        longest = max(len(s.param_types) for s, _ in cands)
        for s, _ in cands:
            if len(s.param_types) == nargs:
                suffix = '' if len(s.param_types) == longest else f'__{nargs}'
                return (s, suffix)
        return None

    # ------------------------------------------------------------------
    # Phase 2: needs_world call-graph fixed point
    # ------------------------------------------------------------------

    def configure_world(self, stateful_contracts, interface_aliases, external_interfaces,
                        stub_calls=(), flatten=None, included_containers=None,
                        stub_functions=()) -> None:
        self.stub_functions = set(stub_functions)
        self.stateful_contracts = set(stateful_contracts)
        self.interface_aliases = dict(interface_aliases)
        self.external_interfaces = set(external_interfaces)
        self.stub_calls = set(stub_calls)
        self.flatten_bases = dict(flatten or {})
        self.included_containers = set(included_containers) if included_containers else None
        # Flattened bases live inside the child's state struct: their state
        # vars and functions behave as the child's for the world analysis.
        for child, bases in self.flatten_bases.items():
            if child in self.stateful_contracts:
                for base in bases:
                    self.stateful_contracts.add(base)
                    # Merge base state vars into the child's set so world
                    # paths resolve to world.<child>.<var>.
                    merged = dict(self.state_vars.get(child, {}))
                    for k, v in self.state_vars.get(base, {}).items():
                        merged.setdefault(k, v)
                    self.state_vars[child] = merged
                    if self.included_containers is not None:
                        self.included_containers.add(base)

    def world_field_of(self, container: str) -> str:
        """World field owning this container's state (child for flattened bases)."""
        for child, bases in getattr(self, 'flatten_bases', {}).items():
            if container in bases:
                return child
        return container

    def compute_needs_world(self) -> None:
        """Seed + propagate `needs_world` over the call graph.

        Seeds: touching a state variable of the enclosing stateful contract,
        msg./block./tx. access, or a method call through an interface-typed
        expression (alias or external dispatch always routes via world).
        Propagation: any caller of a needy function is needy.
        """
        from ..parser.ast_nodes import (
            Block as _Block, Expression as _Expr, Statement as _Stmt,
        )
        import dataclasses

        def walk(node, visit):
            if node is None:
                return
            if isinstance(node, (list, tuple)):
                for item in node:
                    walk(item, visit)
                return
            if not dataclasses.is_dataclass(node):
                return
            visit(node)
            for f in dataclasses.fields(node):
                walk(getattr(node, f.name), visit)

        # Build per-function seed + call edges. EVERY overload body is
        # scanned (they share one FuncSig; the union decides).
        edges: Dict[Tuple[Optional[str], str], set] = {}
        scan_items = []
        for key, cands in self.overloads.items():
            for _sig, fd in cands:
                scan_items.append((key, fd))
        for key, func in scan_items:
            container, _ = key
            state_names = set(self.state_vars.get(container, {}).keys()) \
                if container in self.stateful_contracts else set()
            local_names = {p.name for p in func.parameters if p.name}
            seed = [False]
            callees: set = set()
            iface_param_names = {}
            for p in func.parameters:
                if p.type_name is not None and p.type_name.name in (
                    set(self.interface_aliases) | self.external_interfaces | self.interfaces
                ):
                    iface_param_names[p.name] = p.type_name.name

            def visit(node, _seed=seed, _callees=callees, _state=state_names,
                      _locals=local_names, _container=container,
                      _iface_params=iface_param_names):
                cls = type(node).__name__
                if cls == 'Identifier':
                    if node.name in _state:
                        _seed[0] = True
                    elif node.name == 'this':
                        _seed[0] = True  # address(this) -> world.env.current_contract
                elif cls == 'MemberAccess':
                    base = node.expression
                    if type(base).__name__ == 'Identifier' and base.name in ('msg', 'block', 'tx'):
                        _seed[0] = True
                elif cls == 'FunctionCall':
                    fn = node.function
                    fcls = type(fn).__name__
                    if fcls == 'Identifier':
                        _callees.add((_container, fn.name))
                        _callees.add((None, fn.name))
                        # constructor-style interface cast has no call edge
                    elif fcls == 'MemberAccess':
                        base = fn.expression
                        bcls = type(base).__name__
                        if bcls == 'Identifier' and (
                            base.name in self.libraries or base.name in self.contracts
                        ):
                            _callees.add((base.name, fn.member))
                        else:
                            # Possible interface-value method call: engine.getX(...),
                            # config.teamRegistry.getTeams(...). Aliased dispatch
                            # only propagates neediness through the callee edge
                            # (a pure impl keeps its callers pure); external
                            # dispatch always needs world (it lives on world.ext).
                            for iface in self.external_interfaces:
                                if (iface, fn.member) in self.functions:
                                    _seed[0] = True
                                    break
                            for iface, alias in self.interface_aliases.items():
                                if (iface, fn.member) in self.functions:
                                    _callees.add((alias, fn.member))
                                    break

            walk(func.body, visit)
            # No blanket seed for stateful contracts: precision keeps pure
            # bit-helpers worldless — fewer borrow conflicts at call sites
            # and no world threading through hot math.
            sig = self.functions.get(key)
            if sig is not None:
                sig.needs_world = sig.needs_world or seed[0]
            edges.setdefault(key, set()).update(callees)

        # Fixed point
        changed = True
        while changed:
            changed = False
            for key, callees in edges.items():
                sig = self.functions.get(key)
                if sig is None or sig.needs_world:
                    continue
                for callee_key in callees:
                    callee = self.functions.get(callee_key)
                    if callee is None:
                        callee = self.lookup_function(callee_key[0], callee_key[1])
                    if callee is not None and callee.needs_world:
                        sig.needs_world = True
                        changed = True
                        break

        self._compute_param_lowering()

    def _compute_param_lowering(self) -> None:
        """`T storage` params of world-taking functions become KEY params.

        A world-taking callee cannot also borrow world through an argument
        (double &mut). Structs reachable from exactly one root mapping of a
        stateful contract (BattleConfig <- battleConfig, BattleData <-
        battleData) are re-derived inside the callee from the passed key.
        """
        # struct name -> (contract, state var, key type) for unique roots
        roots: Dict[str, Tuple[str, str, SolType]] = {}
        ambiguous: set = set()
        for contract in self.stateful_contracts:
            for var_name, st in self.state_vars.get(contract, {}).items():
                if st.kind == 'mapping' and st.value is not None \
                        and st.value.kind == 'struct':
                    sname = st.value.name
                    if sname in roots or sname in ambiguous:
                        ambiguous.add(sname)
                        roots.pop(sname, None)
                    else:
                        roots[sname] = (contract, var_name, st.key or UNKNOWN)

        # Every overload sig shares the canonical needs_world, then gets its
        # own lowering (arities differ).
        for key, cands in self.overloads.items():
            canonical = self.functions.get(key)
            for sig, func in cands:
                if canonical is not None:
                    sig.needs_world = canonical.needs_world
                lowered = []
                for p, pt in zip(func.parameters, sig.param_types):
                    entry = None
                    if sig.needs_world and getattr(p, 'storage_location', '') == 'storage':
                        if pt.kind == 'struct' and pt.name in roots:
                            entry = roots[pt.name]
                        elif pt.kind == 'mapping':
                            # No single key addresses a nested mapping; lower
                            # to a SELECTOR closure that re-derives the place
                            # from world per use (funnel: world::sel).
                            entry = ('!selector', pt, None)
                        else:
                            entry = ('!unsupported', pt.name if pt.name else pt.kind, UNKNOWN)
                    lowered.append(entry)
                while len(lowered) < len(sig.param_types):
                    lowered.append(None)
                sig.param_lowered = lowered

    # Ext-call accumulation (ExternalCalls trait generation)
    def record_ext_call(self, iface: str, method: str) -> None:
        self.ext_calls[(iface, method)] = self.lookup_function(iface, method)

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
        # Flattened inheritance: a child's bare call may resolve to a base
        # (Engine -> MappingAllocator).
        for base in getattr(self, 'flatten_bases', {}).get(container, []):
            sig = self.functions.get((base, name))
            if sig is not None:
                return sig
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

    Solidity evaluates constant expressions over UNTYPED literals in
    arbitrary-precision rational arithmetic (``10 / 4 * 2`` is exactly 5),
    while any subexpression involving a TYPED value (a declared constant,
    a cast, ``type(T).max``) uses that type's truncating integer semantics.
    Internally values are (Fraction, typed) pairs to reproduce both.

    Returns None for anything non-numeric (e.g. ``sha256(abi.encode(...))``,
    address literals) — those become LazyLock statics or special-cased
    emissions instead — and for a non-integral FINAL value (which could not
    have type-checked in the Solidity source anyway).
    """

    _MAX_POW_EXP = 100_000

    def __init__(self, symbols: RustSymbols):
        self._symbols = symbols

    def eval(self, expr: Expression, target: Optional[SolType] = None) -> Optional[int]:
        from fractions import Fraction
        r = self._eval(expr)
        if r is None:
            return None
        frac, _typed = r
        if frac.denominator != 1:
            return None
        return int(frac)

    def _eval(self, expr: Expression):
        from fractions import Fraction

        def lit(v: int, typed: bool):
            return (Fraction(v), typed)

        if isinstance(expr, Literal):
            if expr.kind in ('number', 'hex'):
                try:
                    return lit(int(str(expr.value).replace('_', ''), 0), False)
                except ValueError:
                    return None
            if expr.kind == 'bool':
                return lit(1 if expr.value == 'true' else 0, False)
            return None
        if isinstance(expr, Identifier):
            const = self._symbols.lookup_constant(expr.name)
            if const is not None and const.value is not None:
                return lit(const.value, True)
            return None
        if isinstance(expr, UnaryOperation):
            r = self._eval(expr.operand)
            if r is None:
                return None
            v, typed = r
            if expr.operator == '-':
                return (-v, typed)
            if expr.operator == '~':
                if v.denominator != 1:
                    return None
                return lit((~int(v)) & ((1 << 256) - 1), typed)
            return None
        if isinstance(expr, TupleExpression) and len(expr.components) == 1:
            return self._eval(expr.components[0])
        if isinstance(expr, BinaryOperation):
            lr = self._eval(expr.left)
            rr = self._eval(expr.right)
            if lr is None or rr is None:
                return None
            l, lt = lr
            r, rt = rr
            typed = lt or rt
            op = expr.operator
            if op == '+':
                return (l + r, typed)
            if op == '-':
                return (l - r, typed)
            if op == '*':
                return (l * r, typed)
            if op == '/':
                if r == 0:
                    return None
                if not typed:
                    return (l / r, False)  # exact rational division
                # Typed division truncates toward zero (Solidity int semantics)
                if l.denominator != 1 or r.denominator != 1:
                    return None
                li, ri = int(l), int(r)
                q = abs(li) // abs(ri)
                return lit(q if (li >= 0) == (ri >= 0) else -q, True)
            if op == '%':
                if r == 0 or l.denominator != 1 or r.denominator != 1:
                    return None
                li, ri = int(l), int(r)
                m = abs(li) % abs(ri)
                return lit(m if li >= 0 else -m, typed)
            if op == '**':
                if r.denominator != 1:
                    return None
                exp = int(r)
                if abs(exp) > self._MAX_POW_EXP:
                    return None
                if l not in (0, 1, -1) and abs(exp) > 4096:
                    return None  # guard pathological blowups
                if exp < 0:
                    if typed or l == 0:
                        return None  # negative exponents are rational-only
                    return (Fraction(1) / (l ** -exp), False)
                return (l ** exp, typed)
            if op in ('<<', '>>', '&', '|', '^'):
                if l.denominator != 1 or r.denominator != 1:
                    return None
                li, ri = int(l), int(r)
                if op == '<<':
                    if ri > self._MAX_POW_EXP or ri < 0:
                        return None
                    return lit(li << ri, typed)
                if op == '>>':
                    if ri < 0:
                        return None
                    return lit(li >> ri, typed)
                if op == '&':
                    return lit(li & ri, typed)
                if op == '|':
                    return lit(li | ri, typed)
                return lit(li ^ ri, typed)
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
                                return lit((1 << t.bits) - 1, True)
                            return lit((1 << (t.bits - 1)) - 1, True)
                        if expr.member == 'min':
                            if t.kind == 'uint':
                                return lit(0, True)
                            return lit(-(1 << (t.bits - 1)), True)
            # Library-qualified constant: Lib.CONST
            if isinstance(base, Identifier):
                const = self._symbols.lookup_constant(expr.member, base.name)
                if const is not None and const.value is not None:
                    from fractions import Fraction as _F
                    return (_F(const.value), True)
            return None
        if isinstance(expr, TernaryOperation):
            c = self._eval(expr.condition)
            if c is None:
                return None
            branch = expr.true_expression if c[0] != 0 else expr.false_expression
            return self._eval(branch)
        return None

    def _eval_cast(self, type_name: str, inner: Expression):
        from fractions import Fraction
        r = self._eval(inner)
        if r is None:
            return None
        v, _typed = r
        if v.denominator != 1:
            return None  # fractional -> integer conversion is a Solidity error
        t = parse_elementary(type_name)
        if t is None or not t.is_integer:
            return None
        vi = int(v) & ((1 << t.bits) - 1)
        if t.kind == 'int' and vi >= (1 << (t.bits - 1)):
            vi -= 1 << t.bits
        return (Fraction(vi), True)

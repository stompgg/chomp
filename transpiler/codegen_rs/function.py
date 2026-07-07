"""Rust function emission (library fns, contract methods, trait signatures)."""

from typing import List, Optional, Set, TYPE_CHECKING

from ..parser.ast_nodes import (
    Block,
    FunctionDefinition,
    IfStatement,
    ReturnStatement,
    Statement,
    VariableDeclaration,
)
from .soltypes import SolType, UNKNOWN
from .rust_types import rust_ident

if TYPE_CHECKING:
    from .context import RustCodeGenerationContext
    from .expression import RustExpressionGenerator
    from .statement import RustStatementGenerator
    from .rust_types import RustTypeConverter
    from .soltypes import TypeInferencer
    from .symbols import RustSymbols


class RustFunctionGenerator:
    def __init__(self, ctx: 'RustCodeGenerationContext', symbols: 'RustSymbols',
                 expr: 'RustExpressionGenerator', stmt: 'RustStatementGenerator',
                 types: 'RustTypeConverter', inferencer: 'TypeInferencer'):
        self._ctx = ctx
        self._symbols = symbols
        self._expr = expr
        self._stmt = stmt
        self._types = types
        self._infer = inferencer

    # ------------------------------------------------------------------
    # Signatures
    # ------------------------------------------------------------------

    def param_decl(self, p: VariableDeclaration, index: int, allow_mut: bool = True,
                   lowered=None) -> str:
        name = rust_ident(p.name if p.name else f'_arg{index}')
        t = self._infer.from_type_name(p.type_name)
        if lowered is not None and lowered[0] == '!selector':
            # Nested-mapping storage param of a world-taking fn: passed as a
            # selector closure re-deriving the place from world per use.
            inner = self._types.rust_type(lowered[1])
            return (f'{name}_sel: &dyn for<\'w> Fn(&\'w mut World) '
                    f'-> &\'w mut {inner}')
        if lowered is not None and lowered[0] != '!unsupported':
            # Storage param of a world-taking fn: passed as its mapping KEY;
            # the body re-derives the place from world per use.
            key_t = self._types.rust_type(lowered[2])
            return f'__key_{name}: {key_t}'
        if t.is_memory_ref or t.kind == 'mapping':
            return f'{name}: &mut {self._types.rust_type(t)}'
        # Solidity freely reassigns value parameters; bind them `mut`.
        # (Trait method DECLARATIONS cannot carry patterns like `mut x`.)
        prefix = 'mut ' if allow_mut else ''
        return f'{prefix}{name}: {self._types.rust_type(t)}'

    def return_decl(self, params: List[VariableDeclaration]) -> str:
        if not params:
            return ''
        types = []
        for r in params:
            t = self._types.rust_type(self._infer.from_type_name(r.type_name))
            if getattr(r, 'storage_location', '') == 'storage':
                t = f'&mut {t}'
            types.append(t)
        if len(types) == 1:
            return f' -> {types[0]}'
        return f' -> ({", ".join(types)})'

    def _register_params(self, func: FunctionDefinition, sig=None) -> None:
        self._ctx.reset_for_function()
        lowered = (getattr(sig, 'param_lowered', None) or []) if sig else []
        for i, p in enumerate(func.parameters):
            name = p.name if p.name else f'_arg{i}'
            self._ctx.current_local_vars.add(name)
            if p.type_name is not None:
                self._ctx.var_types[name] = p.type_name
            t = self._infer.from_type_name(p.type_name)
            low = lowered[i] if i < len(lowered) else None
            if low is not None and low[0] == '!selector':
                self._ctx.storage_locals[name] = {
                    'place': f'(*{rust_ident(name)}_sel(&mut *world))',
                    'key': None,
                    'root': low,
                }
            elif low is not None and low[0] != '!unsupported':
                contract_field, var, _key_t = low
                field = self._symbols.world_field_of(contract_field)
                self._ctx.storage_locals[name] = {
                    'place': f'(*world.{rust_ident(field)}.{rust_ident(var)}'
                             f'.get_mut(&__key_{rust_ident(name)}))',
                    'key': f'__key_{rust_ident(name)}',
                    'root': low,
                }
            elif t.is_memory_ref or t.kind == 'mapping':
                self._ctx.ref_params.add(name)
        for r in func.return_parameters:
            if r.name:
                self._ctx.current_local_vars.add(r.name)
                if r.type_name is not None:
                    self._ctx.var_types[r.name] = r.type_name

    # ------------------------------------------------------------------
    # Trait method signature (interfaces)
    # ------------------------------------------------------------------

    def trait_method_signature(self, func: FunctionDefinition) -> str:
        recv = '&self' if func.mutability in ('view', 'pure') else '&mut self'
        params = ', '.join(
            [recv] + [self.param_decl(p, i, allow_mut=False) for i, p in enumerate(func.parameters)]
        )
        ret = self.return_decl(func.return_parameters)
        return f'fn {rust_ident(func.name)}({params}){ret};'

    # ------------------------------------------------------------------
    # Function bodies
    # ------------------------------------------------------------------

    def _generate_stub(self, func: FunctionDefinition, sig, name_suffix: str = '') -> str:
        """Configured stubFunctions: signature-faithful, body panics.
        Used for on-chain-only flows (dual-signed buffer) whose bodies pull
        in non-transpiled machinery (EIP712/ECDSA)."""
        self._register_params(func, sig)
        needs_world = bool(sig and sig.needs_world)
        lowered = (getattr(sig, 'param_lowered', None) or []) if sig else []
        params = []
        for i, p in enumerate(func.parameters):
            low = lowered[i] if i < len(lowered) else None
            params.append(self.param_decl(p, i, lowered=low))
        if needs_world:
            params = ['world: &mut World'] + params
            self._ctx.uses_world_type = True
        ret = self.return_decl(func.return_parameters)
        return (
            f'{self._ctx.indent()}pub fn {rust_ident(func.name)}{name_suffix}({", ".join(params)}){ret} {{\n'
            f'{self._ctx.indent()}    unimplemented!("stubFunction: {func.name} (on-chain-only flow)")\n'
            f'{self._ctx.indent()}}}\n'
        )

    def generate_function(self, func: FunctionDefinition, receiver: Optional[str],
                          name_suffix: str = '', defining_container: str = None) -> str:
        """receiver: retained for API compat; contracts now emit module-level
        fns (the World model), so it is always None. name_suffix
        disambiguates shorter overloads (`__{arity}`)."""
        container = defining_container or self._ctx.current_class_name
        ov = self._symbols.lookup_overload(container, func.name, len(func.parameters)) \
            if hasattr(self._symbols, 'lookup_overload') else None
        sig = ov[0] if ov else self._symbols.lookup_function(container, func.name)
        if func.name in getattr(self._symbols, 'stub_functions', set()):
            return self._generate_stub(func, sig, name_suffix)
        self._register_params(func, sig)
        self._ctx.current_defining_container = container
        needs_world = bool(sig and sig.needs_world)
        self._ctx.current_fn_needs_world = needs_world

        lowered = (getattr(sig, 'param_lowered', None) or []) if sig else []
        params = []
        for i, p in enumerate(func.parameters):
            low = lowered[i] if i < len(lowered) else None
            params.append(self.param_decl(p, i, lowered=low))
        if needs_world:
            params = ['world: &mut World'] + params
            self._ctx.uses_world_type = True
        ret = self.return_decl(func.return_parameters)

        # Storage returns borrow from a reference input; with multiple
        # reference params Rust cannot elide, so tag everything 'a.
        returns_storage = any(
            getattr(r, 'storage_location', '') == 'storage'
            for r in func.return_parameters
        )
        self._ctx.current_fn_returns_storage = returns_storage
        generics = ''
        if returns_storage:
            ref_count = sum(1 for p in params if p.startswith(('world', '&')) or ': &mut' in p)
            if ref_count != 1:
                generics = "<'a>"
                params = [p.replace(': &mut', ": &'a mut", 1) for p in params]
                params = [
                    "world: &'a mut World" if p == 'world: &mut World' else p
                    for p in params
                ]
                ret = ret.replace('-> &mut', "-> &'a mut")

        lines = []
        lines.append(
            f'{self._ctx.indent()}pub fn {rust_ident(func.name)}{name_suffix}{generics}'
            f'({", ".join(params)}){ret} {{'
        )
        self._ctx.indent_level += 1

        named_returns = [r.name for r in func.return_parameters if r.name]
        return_types = [self._infer.from_type_name(r.type_name) for r in func.return_parameters]
        if named_returns and len(named_returns) != len(func.return_parameters):
            self._ctx.warn(f'{func.name}: mixed named/unnamed returns not supported')
            named_returns = []
        self._stmt.named_returns = named_returns
        self._stmt.return_types = return_types

        for r in func.return_parameters:
            if r.name:
                t = self._infer.from_type_name(r.type_name)
                lines.append(
                    f'{self._ctx.indent()}let mut {rust_ident(r.name)}: '
                    f'{self._types.rust_type(t)} = {self._types.default_value(t)};'
                )

        if func.body is not None:
            for s in func.body.statements:
                lines.append(self._stmt.generate(s))

        has_body = func.body is not None and bool(func.body.statements)
        if named_returns:
            if not has_body or not _all_paths_return(func.body.statements):
                names = [rust_ident(n) for n in named_returns]
                value = names[0] if len(names) == 1 else f'({", ".join(names)})'
                lines.append(f'{self._ctx.indent()}return {value};')
        elif func.return_parameters:
            if not has_body:
                lines.append(f'{self._ctx.indent()}unimplemented!("virtual function with no body");')
            elif not _all_paths_return(func.body.statements):
                # Solidity implicitly returns zero-values when control falls
                # off the end of a function with unnamed returns.
                defaults = [self._types.default_value(t) for t in return_types]
                value = defaults[0] if len(defaults) == 1 else f'({", ".join(defaults)})'
                lines.append(f'{self._ctx.indent()}return {value};')

        self._ctx.indent_level -= 1
        lines.append(f'{self._ctx.indent()}}}')
        lines.append('')
        self._stmt.named_returns = []
        self._stmt.return_types = []
        return '\n'.join(lines)


def _unused(*_a):
    pass


def _all_paths_return(statements: List[Statement]) -> bool:
    """Mirror of the TS backend's control-flow check (function.py)."""
    if not statements:
        return False
    last = statements[-1]
    if isinstance(last, ReturnStatement):
        return True
    if isinstance(last, IfStatement):
        if last.false_body is None:
            return False
        if isinstance(last.true_body, Block):
            true_returns = _all_paths_return(last.true_body.statements)
        else:
            true_returns = isinstance(last.true_body, ReturnStatement)
        if isinstance(last.false_body, Block):
            false_returns = _all_paths_return(last.false_body.statements)
        elif isinstance(last.false_body, IfStatement):
            false_returns = _all_paths_return([last.false_body])
        else:
            false_returns = isinstance(last.false_body, ReturnStatement)
        return true_returns and false_returns
    return False

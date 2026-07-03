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
                 types: 'RustTypeConverter', inferencer: 'TypeInferencer',
                 dyn_interfaces: Set[str]):
        self._ctx = ctx
        self._symbols = symbols
        self._expr = expr
        self._stmt = stmt
        self._types = types
        self._infer = inferencer
        self._dyn_interfaces = dyn_interfaces

    # ------------------------------------------------------------------
    # Signatures
    # ------------------------------------------------------------------

    def param_decl(self, p: VariableDeclaration, index: int) -> str:
        name = rust_ident(p.name if p.name else f'_arg{index}')
        t = self._infer.from_type_name(p.type_name)
        if t.is_memory_ref:
            return f'{name}: &mut {self._types.rust_type(t)}'
        if t.kind in ('interface', 'contract') and t.name in self._dyn_interfaces:
            self._ctx.used_traits.add(t.name)
            return f'{name}: &mut dyn {rust_ident(t.name)}'
        return f'{name}: {self._types.rust_type(t)}'

    def return_decl(self, params: List[VariableDeclaration]) -> str:
        if not params:
            return ''
        types = [self._types.rust_type(self._infer.from_type_name(r.type_name)) for r in params]
        if len(types) == 1:
            return f' -> {types[0]}'
        return f' -> ({", ".join(types)})'

    def _register_params(self, func: FunctionDefinition) -> None:
        self._ctx.reset_for_function()
        for i, p in enumerate(func.parameters):
            name = p.name if p.name else f'_arg{i}'
            self._ctx.current_local_vars.add(name)
            if p.type_name is not None:
                self._ctx.var_types[name] = p.type_name
            t = self._infer.from_type_name(p.type_name)
            if t.is_memory_ref:
                self._ctx.ref_params.add(name)
            elif t.kind in ('interface', 'contract') and t.name in self._dyn_interfaces:
                self._ctx.dyn_params.add(name)
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
            [recv] + [self.param_decl(p, i) for i, p in enumerate(func.parameters)]
        )
        ret = self.return_decl(func.return_parameters)
        return f'fn {rust_ident(func.name)}({params}){ret};'

    # ------------------------------------------------------------------
    # Function bodies
    # ------------------------------------------------------------------

    def generate_function(self, func: FunctionDefinition, receiver: Optional[str]) -> str:
        """receiver: None for library/module-level fns, '&self'/'&mut self'
        for contract methods."""
        self._register_params(func)

        params = [self.param_decl(p, i) for i, p in enumerate(func.parameters)]
        if receiver is not None:
            params = [receiver] + params
        ret = self.return_decl(func.return_parameters)

        lines = []
        lines.append(f'{self._ctx.indent()}pub fn {rust_ident(func.name)}({", ".join(params)}){ret} {{')
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

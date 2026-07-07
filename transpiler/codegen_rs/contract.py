"""Rust emission for Solidity contract-level constructs.

Mapping:
- ``library``   -> module-level ``pub const``s + ``pub fn``s (the emitted
                   file IS the module, so ``Lib.fn(...)`` call sites become
                   ``Lib::fn(...)`` after a ``use crate::path::Lib;``).
- ``interface`` -> ``pub trait`` (view/pure methods take ``&self``, the rest
                   ``&mut self``). Only interfaces in the emitted set become
                   traits; interface-typed VALUES elsewhere are Addresses.
- ``contract``  -> ``pub struct`` (state vars as fields) + inherent ``impl``
                   + one ``impl Trait for Struct`` per implemented interface
                   that has an emitted trait. Stateful contracts and
                   contract inheritance are Phase 2 (diagnosed, not silently
                   mis-emitted).
"""

from typing import List, Set, TYPE_CHECKING

from ..parser.ast_nodes import ContractDefinition, FunctionDefinition
from .rust_types import rust_ident

if TYPE_CHECKING:
    from .context import RustCodeGenerationContext
    from .definition import RustDefinitionGenerator
    from .function import RustFunctionGenerator
    from .rust_types import RustTypeConverter
    from .soltypes import TypeInferencer
    from .symbols import RustSymbols


class RustContractGenerator:
    def __init__(self, ctx: 'RustCodeGenerationContext', symbols: 'RustSymbols',
                 types: 'RustTypeConverter', func: 'RustFunctionGenerator',
                 defs: 'RustDefinitionGenerator', inferencer: 'TypeInferencer'):
        self._ctx = ctx
        self._symbols = symbols
        self._types = types
        self._func = func
        self._defs = defs
        self._infer = inferencer

    def generate_contract(self, contract: ContractDefinition) -> str:
        pieces = []
        for enum in contract.enums:
            pieces.append(self._defs.generate_enum(enum))
        for struct in contract.structs:
            pieces.append(self._defs.generate_struct(struct))

        self._ctx.current_class_name = contract.name
        self._ctx.current_contract_kind = contract.kind

        if contract.kind == 'interface':
            pieces.append(self._generate_trait(contract))
        elif contract.kind == 'library':
            pieces.append(self._generate_library(contract))
        elif contract.kind == 'abstract' \
                or contract.name in getattr(self._symbols, 'base_contract_names', set()):
            # Emitted only flattened into inheriting contracts; a standalone
            # module would need World state this codebase never deploys.
            if contract.structs or contract.enums:
                self._ctx.warn(
                    f'base contract {contract.name} declares structs/enums that '
                    f'are skipped with its standalone emission'
                )
            pieces.append(f'// {contract.name}: emitted flattened into inheriting contracts')
        else:
            pieces.append(self._generate_struct_contract(contract))

        self._ctx.current_class_name = ''
        self._ctx.current_contract_kind = ''
        return '\n'.join(pieces)

    # ------------------------------------------------------------------

    def _generate_trait(self, contract: ContractDefinition) -> str:
        lines = [f'pub trait {rust_ident(contract.name)} {{']
        self._ctx.indent_level += 1
        for func in contract.functions:
            if not func.name:
                continue
            self._func._register_params(func)
            lines.append(f'{self._ctx.indent()}{self._func.trait_method_signature(func)}')
        self._ctx.indent_level -= 1
        lines.append('}')
        lines.append('')
        return '\n'.join(lines)

    # ------------------------------------------------------------------

    def _generate_library(self, contract: ContractDefinition) -> str:
        lines = []
        for var in contract.state_variables:
            if var.mutability == 'constant':
                lines.append(self._defs.generate_constant(var))
            else:
                self._ctx.warn(
                    f'library {contract.name} has non-constant state var {var.name}'
                )
        for func in contract.functions:
            if not func.name:
                continue
            lines.append(self._func.generate_function(func, receiver=None))
        return '\n'.join(lines)

    # ------------------------------------------------------------------

    def _generate_struct_contract(self, contract: ContractDefinition) -> str:
        """World-model emission: every contract becomes a MODULE of free
        functions; a stateful one also gets a `<Name>State` struct living in
        World. Flattened bases (Engine <- MappingAllocator) contribute their
        state vars and functions to the child's module."""
        lines = []
        name = contract.name
        stateful = name in self._symbols.stateful_contracts

        flatten_defs = []
        for base in self._symbols.flatten_bases.get(name, []):
            base_def = self._symbols.contract_defs.get(base)
            if base_def is not None:
                flatten_defs.append(base_def)
            else:
                self._ctx.warn(f'flatten base {base} of {name} not found')
        all_defs = [contract] + flatten_defs

        # Constants from every flattened part
        for cdef in all_defs:
            for var in cdef.state_variables:
                if var.mutability == 'constant':
                    lines.append(self._defs.generate_constant(var))

        # Merged mutable state
        state_fields = []
        for cdef in all_defs:
            for var in cdef.state_variables:
                if var.mutability != 'constant':
                    state_fields.append(var)

        self._ctx.current_state_vars = set()
        for var in state_fields:
            self._ctx.current_state_vars.add(var.name)
            self._ctx.var_types[var.name] = var.type_name
        self._ctx.contract_var_types = dict(self._ctx.var_types)
        self._ctx.current_contract_stateful = stateful

        if stateful:
            lines.append('#[derive(Debug)]')
            lines.append(f'pub struct {rust_ident(name)}State {{')
            for var in state_fields:
                t = self._infer.from_type_name(var.type_name)
                lines.append(f'    pub {rust_ident(var.name)}: {self._types.rust_type(t)},')
            lines.append('}')
            lines.append('')
            lines.append(f'impl Default for {rust_ident(name)}State {{')
            lines.append('    fn default() -> Self {')
            lines.append('        Self {')
            for var in state_fields:
                t = self._infer.from_type_name(var.type_name)
                lines.append(f'            {rust_ident(var.name)}: {self._types.default_value(t)},')
            lines.append('        }')
            lines.append('    }')
            lines.append('}')
            lines.append('')
            if contract.constructor is not None:
                lines.append(self._generate_constructor(contract, name))
        elif state_fields:
            self._ctx.warn(
                f'contract {name} has state vars but is not configured stateful; '
                f'state accesses will not compile'
            )

        # Emit every overload: the longest keeps the Solidity name, shorter
        # siblings get an `__{arity}` suffix (call sites resolve by arity).
        #
        # Two passes. Pass 1 assigns emitted names: the FIRST definition in
        # MRO order (leaf, then bases) wins the plain name; shadowed base
        # definitions with bodies get `__in_{Base}` so `super.f()` can call
        # them (Solidity super is static: next definition after the caller's
        # defining contract in the MRO). Pass 2 emits, with the super-target
        # map already complete so bodies can resolve their super calls.
        per_key: dict = {}
        for cdef in all_defs:
            for func in cdef.functions:
                if not func.name:
                    continue
                per_key.setdefault((func.name, len(func.parameters)), []).append((cdef, func))

        plan = []  # (cdef, func, name_suffix)
        for (fname, arity), entries in per_key.items():
            emitted_names = []
            for i, (cdef, func) in enumerate(entries):
                ov = self._symbols.lookup_overload(cdef.name, fname, arity)
                ov_suffix = ov[1] if ov else ''
                if i == 0:
                    suffix = ov_suffix
                else:
                    if func.body is None:
                        emitted_names.append(None)
                        continue
                    suffix = f'__in_{rust_ident(cdef.name)}{ov_suffix}'
                emitted_name = f'{rust_ident(fname)}{suffix}'
                emitted_names.append(emitted_name)
                self._symbols.emitted_fn_names[(name, cdef.name, fname, arity)] = emitted_name
                plan.append((cdef, func, suffix))
            # super in entries[i] targets the next EMITTED definition below it
            for i, (cdef, _func) in enumerate(entries):
                for j in range(i + 1, len(entries)):
                    if emitted_names[j] is not None:
                        self._symbols.super_targets[(name, cdef.name, fname, arity)] = (
                            emitted_names[j], entries[j][0].name
                        )
                        break

        for cdef, func, suffix in plan:
            lines.append(self._func.generate_function(
                func, receiver=None, name_suffix=suffix,
                defining_container=cdef.name,
            ))

        return '\n'.join(lines)

    def _generate_constructor(self, contract: ContractDefinition, name: str) -> str:
        """Constructor -> `pub fn construct(args) -> <Name>State` (pure state
        init; the harness wires it into World). Base constructors chain:
        each base-constructor invocation binds the base's ctor params as
        locals from the child-supplied args, recurses into deeper bases,
        then runs the base body — Solidity's base-first execution order —
        before the child's own body."""
        func = contract.constructor
        self._func._register_params(func, None)
        self._ctx.in_constructor = True
        params = [self._func.param_decl(p, i) for i, p in enumerate(func.parameters)]
        if self._symbols.constructor_needs_world(name):
            params = ['world: &mut World'] + params
            self._ctx.uses_world_type = True
            self._ctx.current_fn_needs_world = True
        lines = [
            f'{self._ctx.indent()}pub fn construct({", ".join(params)}) -> {rust_ident(name)}State {{',
        ]
        self._ctx.indent_level += 1
        lines.append(f'{self._ctx.indent()}let mut self_ = {rust_ident(name)}State::default();')
        self._emit_base_ctor_chain(contract, lines)
        if func.body is not None:
            for s in func.body.statements:
                lines.append(self._stmt_gen().generate(s))
        lines.append(f'{self._ctx.indent()}self_')
        self._ctx.indent_level -= 1
        lines.append(f'{self._ctx.indent()}}}')
        lines.append('')
        self._ctx.in_constructor = False
        return '\n'.join(lines)

    def _emit_base_ctor_chain(self, cdef: ContractDefinition, lines: list) -> None:
        ctor = cdef.constructor
        if ctor is None:
            return
        for bcc in getattr(ctor, 'base_constructor_calls', []):
            bdef = self._symbols.contract_defs.get(bcc.base_name)
            if bdef is None or bdef.constructor is None:
                continue
            bctor = bdef.constructor
            lines.append(f'{self._ctx.indent()}// base constructor: {bcc.base_name}')
            for p, arg in zip(bctor.parameters, bcc.arguments):
                t = self._infer.from_type_name(p.type_name)
                code = self._func._expr.emit(arg, t)
                lines.append(
                    f'{self._ctx.indent()}let mut {rust_ident(p.name)}: '
                    f'{self._types.rust_type(t)} = {code};'
                )
                # Owned local (NOT a ref param): reads emit plain paths.
                self._ctx.current_local_vars.add(p.name)
                if p.type_name is not None:
                    self._ctx.var_types[p.name] = p.type_name
            self._emit_base_ctor_chain(bdef, lines)
            if bctor.body is not None:
                for s in bctor.body.statements:
                    lines.append(self._stmt_gen().generate(s))

    def _stmt_gen(self):
        return self._func._stmt


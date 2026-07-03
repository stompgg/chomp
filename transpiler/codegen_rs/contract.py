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
                 defs: 'RustDefinitionGenerator', inferencer: 'TypeInferencer',
                 dyn_interfaces: Set[str]):
        self._ctx = ctx
        self._symbols = symbols
        self._types = types
        self._func = func
        self._defs = defs
        self._infer = inferencer
        self._dyn_interfaces = dyn_interfaces

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
        lines = []
        name = rust_ident(contract.name)

        state_fields = [
            v for v in contract.state_variables if v.mutability != 'constant'
        ]
        for var in contract.state_variables:
            if var.mutability == 'constant':
                lines.append(self._defs.generate_constant(var))

        non_interface_bases = [
            b for b in contract.base_contracts if b not in self._symbols.interfaces
        ]
        if non_interface_bases:
            self._ctx.warn(
                f'contract {contract.name} inherits {non_interface_bases}: contract '
                f'inheritance flattening is Phase 2; emitting this contract standalone'
            )

        lines.append('#[derive(Debug, Default)]')
        lines.append(f'pub struct {name} {{')
        self._ctx.current_state_vars = set()
        for var in state_fields:
            t = self._infer.from_type_name(var.type_name)
            lines.append(f'    pub {rust_ident(var.name)}: {self._types.rust_type(t)},')
            self._ctx.current_state_vars.add(var.name)
            self._ctx.var_types[var.name] = var.type_name
        # Snapshot the contract-level view: reset_for_function restores from
        # this so one method's locals never leak into the next one's types.
        self._ctx.contract_var_types = dict(self._ctx.var_types)
        lines.append('}')
        lines.append('')

        if state_fields or contract.constructor:
            self._ctx.warn(
                f'contract {contract.name} has state/constructor: full contract '
                f'emission (storage model, constructor args) is Phase 2'
            )

        # Split methods into per-interface trait impls and the inherent impl.
        trait_bases = [
            b for b in contract.base_contracts
            if b in self._symbols.interfaces and b in self._dyn_interfaces
        ]
        claimed = {}
        for base in trait_bases:
            for (cont, fname), sig in self._symbols.functions.items():
                if cont == base:
                    claimed.setdefault(fname, base)

        inherent: List[FunctionDefinition] = []
        per_trait = {b: [] for b in trait_bases}
        for func in contract.functions:
            if not func.name:
                continue
            base = claimed.get(func.name)
            if base is not None:
                per_trait[base].append(func)
            else:
                inherent.append(func)

        for base in trait_bases:
            self._ctx.used_traits.add(base)
            lines.append(f'impl {rust_ident(base)} for {name} {{')
            self._ctx.indent_level += 1
            for func in per_trait[base]:
                body = self._func.generate_function(
                    func,
                    receiver='&self' if func.mutability in ('view', 'pure') else '&mut self',
                )
                # Trait impl methods must not carry `pub`.
                body = body.replace(f'{self._ctx.indent()}pub fn ', f'{self._ctx.indent()}fn ', 1)
                lines.append(body)
            self._ctx.indent_level -= 1
            lines.append('}')
            lines.append('')

        if inherent:
            lines.append(f'impl {name} {{')
            self._ctx.indent_level += 1
            for func in inherent:
                lines.append(self._func.generate_function(
                    func,
                    receiver='&self' if func.mutability in ('view', 'pure') else '&mut self',
                ))
            self._ctx.indent_level -= 1
            lines.append('}')
            lines.append('')

        return '\n'.join(lines)

"""Rust emission for Solidity type definitions: enums, structs, constants.

- Enums: ``#[repr(u8)]`` with explicit discriminants matching Solidity's
  sequential numbering, a checked ``from_u8`` (out-of-range panics — the
  Solidity enum-conversion Panic(0x21)), and Default = first variant (the
  Solidity zero value).
- Structs: plain data structs; ``Default`` is implemented by hand with
  Solidity zero-initialization semantics (derive would need T: Default for
  fixed arrays and picks wrong enum defaults).
- Constants: const-evaluable initializers become ``pub const``; anything
  runtime-computed (``sha256(abi.encode("..."))``) becomes a ``LazyLock``
  static so the derivation stays in code (single source of truth) rather
  than being frozen into the generator.
"""

from typing import List, Optional, TYPE_CHECKING

from ..parser.ast_nodes import EnumDefinition, StateVariableDeclaration, StructDefinition
from .rust_types import rust_ident
from .soltypes import SolType

if TYPE_CHECKING:
    from .context import RustCodeGenerationContext
    from .expression import RustExpressionGenerator
    from .rust_types import RustTypeConverter
    from .symbols import RustSymbols
    from .soltypes import TypeInferencer


def enum_variant_ident(name: str) -> str:
    """Enum variant names: `Self` cannot be an identifier at all in Rust
    (not even raw), so it maps to `Self_`. Everything else via rust_ident."""
    return rust_ident(name)


def enum_from_u8_fn() -> str:
    return 'from_u8'


class RustDefinitionGenerator:
    def __init__(self, ctx: 'RustCodeGenerationContext', symbols: 'RustSymbols',
                 types: 'RustTypeConverter', expr: 'RustExpressionGenerator',
                 inferencer: 'TypeInferencer'):
        self._ctx = ctx
        self._symbols = symbols
        self._types = types
        self._expr = expr
        self._infer = inferencer

    # ------------------------------------------------------------------
    # Enums
    # ------------------------------------------------------------------

    def generate_enum(self, enum: EnumDefinition) -> str:
        name = rust_ident(enum.name)
        lines = []
        lines.append('#[repr(u8)]')
        lines.append('#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]')
        lines.append(f'pub enum {name} {{')
        for i, member in enumerate(enum.members):
            lines.append(f'    {enum_variant_ident(member)} = {i},')
        lines.append('}')
        lines.append('')
        lines.append(f'impl {name} {{')
        lines.append(f'    pub fn {enum_from_u8_fn()}(v: u8) -> Self {{')
        lines.append('        match v {')
        for i, member in enumerate(enum.members):
            lines.append(f'            {i} => Self::{enum_variant_ident(member)},')
        lines.append(f'            _ => panic!("panic: enum {enum.name} conversion out of range (0x21)"),')
        lines.append('        }')
        lines.append('    }')
        lines.append('}')
        lines.append('')
        lines.append(f'impl Default for {name} {{')
        first = enum_variant_ident(enum.members[0]) if enum.members else 'unreachable'
        lines.append(f'    fn default() -> Self {{ Self::{first} }}')
        lines.append('}')
        lines.append('')
        return '\n'.join(lines)

    # ------------------------------------------------------------------
    # Structs
    # ------------------------------------------------------------------

    def generate_struct(self, struct: StructDefinition) -> str:
        name = rust_ident(struct.name)
        fields = self._symbols.structs.get(struct.name, [])
        all_copy = all(self._types.is_copy(t) for _, t in fields)
        has_mapping = any(t.kind == 'mapping' for _, t in fields)

        derives = ['Clone', 'Debug']
        if all_copy:
            derives.insert(1, 'Copy')
        if not has_mapping:
            derives.append('PartialEq')

        lines = []
        lines.append(f'#[derive({", ".join(derives)})]')
        lines.append(f'pub struct {name} {{')
        for fname, ftype in fields:
            lines.append(f'    pub {rust_ident(fname)}: {self._types.rust_type(ftype)},')
        lines.append('}')
        lines.append('')
        lines.append(f'impl Default for {name} {{')
        lines.append('    fn default() -> Self {')
        lines.append('        Self {')
        for fname, ftype in fields:
            lines.append(f'            {rust_ident(fname)}: {self._types.default_value(ftype)},')
        lines.append('        }')
        lines.append('    }')
        lines.append('}')
        lines.append('')
        return '\n'.join(lines)

    # ------------------------------------------------------------------
    # Constants
    # ------------------------------------------------------------------

    def generate_constant(self, const: StateVariableDeclaration) -> str:
        sig = self._symbols.lookup_constant(const.name, self._ctx.current_class_name or None)
        t = sig.sol_type if sig else self._infer.from_type_name(const.type_name)
        rust_t = self._types.rust_type(t)
        name = rust_ident(const.name)

        # Const-evaluated numeric value
        if sig is not None and sig.value is not None and t.is_integer:
            return f'pub const {name}: {rust_t} = {self._types.int_literal(sig.value, t)};\n'

        if sig is not None and sig.value is not None and t.kind == 'bytes_fixed':
            from .expression import _b256_literal
            return f'pub const {name}: {rust_t} = {_b256_literal(sig.value)};\n'

        if const.initial_value is None:
            return f'pub const {name}: {rust_t} = {self._types.default_value(t)};\n'

        fitted = self._expr.emit(const.initial_value, t)

        # symbols.build decided const-vs-lazy up front (references must agree
        # with the definition form: lazy statics are read through a deref).
        if sig is not None and sig.is_lazy:
            return (
                f'pub static {name}: std::sync::LazyLock<{rust_t}> = '
                f'std::sync::LazyLock::new(|| {fitted});\n'
            )
        return f'pub const {name}: {rust_t} = {fitted};\n'

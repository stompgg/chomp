"""Solidity storage slot packing for structs.

Both backends model storage by field identity — a Rust struct field, a TS object
property — never by slot. Inline assembly that reads or writes a whole slot
(`sload(x.slot)`) therefore has to be reconciled against every field that slot
packs, and against the bits no field claims: hand-packed Solidity treats that
padding as free real estate, so those bits carry state the declared members
cannot represent.

This computes the packing so the Yul lowerings in both backends can turn a slot
word into field assignments and back.
"""

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Set, Tuple

from ..parser.ast_nodes import StructDefinition, TypeName, VariableDeclaration

WORD_BYTES = 32
WORD_BITS = 256

#: Generated member holding a slot's undeclared bits. Double-underscored so it
#: cannot collide with a Solidity member name.
SLOT0_FREE_FIELD = '__slot0_free'


@dataclass(frozen=True)
class SlotField:
    """One declared member's placement inside its slot."""

    name: str
    bit_offset: int
    bit_width: int

    @property
    def mask(self) -> int:
        return ((1 << self.bit_width) - 1) << self.bit_offset


@dataclass(frozen=True)
class SlotLayout:
    """One 32-byte slot: the members packed into it, plus the leftover bits."""

    index: int
    fields: Tuple[SlotField, ...]

    @property
    def claimed_mask(self) -> int:
        m = 0
        for f in self.fields:
            m |= f.mask
        return m

    @property
    def free_mask(self) -> int:
        return ((1 << WORD_BITS) - 1) & ~self.claimed_mask

    @property
    def has_free_bits(self) -> bool:
        return self.free_mask != 0


def _int_bytes(name: str, prefix: str) -> Optional[int]:
    """`uint96` -> 12. Bare `uint`/`int` is 256-bit."""
    suffix = name[len(prefix):]
    if not suffix:
        return 32
    if not suffix.isdigit():
        return None
    bits = int(suffix)
    if bits % 8 or not 8 <= bits <= 256:
        return None
    return bits // 8


def value_byte_size(
    type_name: TypeName,
    *,
    enum_names: Set[str],
    struct_names: Set[str],
) -> Optional[int]:
    """Packed byte size of a value type; None when the type takes whole slots."""
    if type_name is None:
        return None
    if type_name.is_mapping or type_name.is_array:
        return None

    name = (type_name.name or '').strip()
    if name in ('address', 'address payable'):
        return 20
    if name == 'bool':
        return 1
    if name.startswith('uint'):
        return _int_bytes(name, 'uint')
    if name.startswith('int'):
        return _int_bytes(name, 'int')
    if name in ('bytes', 'string'):
        return None
    if name.startswith('bytes'):
        n = name[5:]
        return int(n) if n.isdigit() and 1 <= int(n) <= 32 else None
    if name in enum_names:
        return 1
    if name in struct_names:
        return None
    # Remaining user-defined names are contracts/interfaces, i.e. addresses.
    return 20


def _whole_slot_span(
    type_name: TypeName,
    *,
    enum_names: Set[str],
    struct_names: Set[str],
    structs: Dict[str, StructDefinition],
) -> Optional[int]:
    """Slots occupied by a member that can't share a slot; None if unknown."""
    if type_name.is_mapping:
        return 1
    if type_name.is_array:
        # Only a single-dimension fixed array of a sized value type is exact.
        if type_name.array_dimensions > 1 or type_name.array_size is None:
            return 1  # dynamic arrays occupy exactly one slot (the length)
        return None
    name = (type_name.name or '').strip()
    if name in ('bytes', 'string'):
        return 1
    if name in struct_names:
        nested = structs.get(name)
        if nested is None:
            return None
        layouts = struct_slots(
            nested, enum_names=enum_names, struct_names=struct_names, structs=structs
        )
        return len(layouts) if layouts else None
    return None


def struct_slots(
    struct: StructDefinition,
    *,
    enum_names: Set[str],
    struct_names: Set[str],
    structs: Optional[Dict[str, StructDefinition]] = None,
) -> List[SlotLayout]:
    """Slot layout for `struct`, in declaration order.

    Members pack left-to-right into the current slot and spill to the next when
    they no longer fit — Solidity's rule. Computation stops at the first member
    whose slot span can't be determined, so callers get exact layouts or none at
    all for a given slot, never a guess.
    """
    structs = structs or {}
    layouts: List[SlotLayout] = []
    pending: List[SlotField] = []
    slot = 0
    used = 0  # bytes consumed in the current slot

    def flush() -> None:
        nonlocal pending
        if pending:
            layouts.append(SlotLayout(index=slot, fields=tuple(pending)))
            pending = []

    members: Sequence[VariableDeclaration] = struct.members or []
    for member in members:
        size = value_byte_size(
            member.type_name, enum_names=enum_names, struct_names=struct_names
        )
        if size is None:
            flush()
            if used:
                slot += 1
                used = 0
            span = _whole_slot_span(
                member.type_name,
                enum_names=enum_names,
                struct_names=struct_names,
                structs=structs,
            )
            if span is None:
                return layouts  # unknown span: everything after it is unknowable
            slot += span
            continue

        if used + size > WORD_BYTES:
            flush()
            slot += 1
            used = 0
        pending.append(
            SlotField(name=member.name, bit_offset=used * 8, bit_width=size * 8)
        )
        used += size

    flush()
    return layouts


def _declared_type_of(ident: str, func) -> Optional[TypeName]:
    """The declared TypeName of `ident` within `func`, or None."""
    import dataclasses

    for p in list(func.parameters or []) + list(func.return_parameters or []):
        if p.name == ident:
            return p.type_name

    found: List[TypeName] = []

    def walk(node):
        if node is None or found:
            return
        if isinstance(node, (list, tuple)):
            for item in node:
                walk(item)
            return
        if isinstance(node, dict):
            for item in node.values():
                walk(item)
            return
        if not dataclasses.is_dataclass(node):
            return
        if type(node).__name__ == 'VariableDeclaration' and node.name == ident:
            found.append(node.type_name)
            return
        for f in dataclasses.fields(node):
            walk(getattr(node, f.name))

    walk(func.body)
    return found[0] if found else None


def discover_slot_layouts(
    asts,
    *,
    enum_names: Set[str],
    struct_names: Set[str],
    struct_defs: Dict[str, StructDefinition],
) -> Dict[str, SlotLayout]:
    """Slot-0 layouts for every struct whose raw slot is reached by Yul.

    `asts` is any iterable of parsed SourceUnits. A struct is included only
    when its layout is exactly computable, so callers get a precise packing or
    nothing — never an approximation.
    """
    import dataclasses
    import re

    slot_idents = re.compile(r'(\w+)\s*\.\s*slot\b')
    touched: Set[str] = set()

    def walk(node, fn_scope):
        if node is None:
            return
        if isinstance(node, (list, tuple)):
            for item in node:
                walk(item, fn_scope)
            return
        if isinstance(node, dict):
            for item in node.values():
                walk(item, fn_scope)
            return
        if not dataclasses.is_dataclass(node):
            return
        cls = type(node).__name__
        if cls == 'FunctionDefinition':
            fn_scope = node
        elif cls == 'AssemblyStatement' and fn_scope is not None:
            code = getattr(getattr(node, 'block', None), 'code', '') or ''
            for ident in slot_idents.findall(code):
                tn = _declared_type_of(ident, fn_scope)
                if tn is not None and tn.name in struct_names:
                    touched.add(tn.name)
        for f in dataclasses.fields(node):
            walk(getattr(node, f.name), fn_scope)

    for ast in asts:
        walk(ast, None)

    layouts: Dict[str, SlotLayout] = {}
    for name in touched:
        struct = struct_defs.get(name)
        if struct is None:
            continue
        layout = slot_zero(
            struct,
            enum_names=enum_names,
            struct_names=struct_names,
            structs=struct_defs,
        )
        if layout is not None:
            layouts[name] = layout
    return layouts


def slot_zero(
    struct: StructDefinition,
    *,
    enum_names: Set[str],
    struct_names: Set[str],
    structs: Optional[Dict[str, StructDefinition]] = None,
) -> Optional[SlotLayout]:
    """The base slot a `<place>.slot` expression addresses, or None if unknown."""
    layouts = struct_slots(
        struct, enum_names=enum_names, struct_names=struct_names, structs=structs
    )
    for layout in layouts:
        if layout.index == 0:
            return layout
    return None

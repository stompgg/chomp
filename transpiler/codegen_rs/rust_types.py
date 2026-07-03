"""SolType -> Rust mapping: type strings, defaults, literals, casts, coercions.

The semantic contract (each rule verified empirically against alloy-primitives
1.x / ruint 1.19 before being relied on):

- uintN/intN with N <= 128 map to the smallest native Rust integer. Native
  operators panic on overflow because the emitted workspace sets
  ``overflow-checks = true`` in every profile — matching Solidity 0.8 checked
  arithmetic. Wrapping intrinsics are emitted inside ``unchecked`` blocks.
- uint256/int256 map to alloy U256/I256. ruint's operators WRAP silently in
  release builds regardless of overflow-checks, so checked arithmetic on wide
  types must be *explicit* (``rt::SolOps`` checked helpers) and unchecked
  arithmetic must also be explicit (``wrapping_*``) so debug builds don't
  spuriously panic inside ``unchecked`` blocks.
- Rust ``as`` between native integers reproduces Solidity explicit-cast
  semantics exactly: narrowing truncates (two's complement), same-width
  signed<->unsigned reinterprets, widening zero/sign-extends.
- U256 shifts already have EVM semantics (>= 256 yields 0); native shifts
  panic on shift-amount >= width, so they go through rt::shl/shr helpers.
- Odd declared widths (uint40/96/104/168...) are stored in the next-wider
  representation; explicit casts to them mask to the declared width.
"""

from typing import Optional

from .soltypes import SolType, UNKNOWN

# Rust keywords that CAN be raw identifiers (r#name)
_RAW_OK_KEYWORDS = {
    'as', 'break', 'const', 'continue', 'else', 'enum', 'false', 'fn', 'for',
    'if', 'impl', 'in', 'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub',
    'ref', 'return', 'static', 'struct', 'trait', 'true', 'type', 'unsafe',
    'use', 'where', 'while', 'async', 'await', 'dyn', 'abstract', 'become',
    'box', 'do', 'final', 'macro', 'override', 'priv', 'typeof', 'unsized',
    'virtual', 'yield', 'try',
}
# Keywords that cannot even be raw identifiers -> suffix with `_`
_NO_RAW_KEYWORDS = {'self', 'Self', 'super', 'crate', 'extern', '_'}


def rust_ident(name: str) -> str:
    """Make a Solidity identifier valid in Rust, preserving the original
    spelling wherever legal (fidelity beats lint style; the emitted crate
    carries #![allow(non_snake_case, ...)])."""
    if name in _NO_RAW_KEYWORDS:
        return name + '_'
    if name in _RAW_OK_KEYWORDS:
        return 'r#' + name
    return name


_NATIVE = {8: ('u8', 'i8'), 16: ('u16', 'i16'), 32: ('u32', 'i32'),
           64: ('u64', 'i64'), 128: ('u128', 'i128')}


class RustTypeConverter:
    """SolType -> Rust emission helpers (records type usage for `use` lines)."""

    def __init__(self, symbols, ctx=None):
        self._symbols = symbols
        self._ctx = ctx

    def _record_use(self, name: str) -> None:
        if self._ctx is not None:
            self._ctx.used_types.add(name)

    # ------------------------------------------------------------------
    # Type strings
    # ------------------------------------------------------------------

    def rust_type(self, t: SolType) -> str:
        if t.kind == 'uint':
            if t.mapped_bits == 256:
                return 'U256'
            return _NATIVE[t.mapped_bits][0]
        if t.kind == 'int':
            if t.mapped_bits == 256:
                return 'I256'
            return _NATIVE[t.mapped_bits][1]
        if t.kind == 'intlit':
            return 'U256'  # only reachable for untyped consts; default to widest
        if t.kind == 'bool':
            return 'bool'
        if t.kind == 'address':
            return 'Address'
        if t.kind == 'string':
            return 'String'
        if t.kind == 'bytes':
            return 'Vec<u8>'
        if t.kind == 'bytes_fixed':
            return 'B256' if t.bytes_n == 32 else f'[u8; {t.bytes_n}]'
        if t.kind == 'enum':
            self._record_use(t.name)
            return rust_ident(t.name)
        if t.kind == 'struct':
            self._record_use(t.name)
            return rust_ident(t.name)
        if t.kind in ('interface', 'contract', 'library'):
            # Interface/contract-typed VALUES are their on-chain identity: an
            # address. Callable interface handles exist only at internal-fn
            # parameter positions (see function generator: &mut dyn Trait).
            return 'Address'
        if t.kind == 'array':
            elem = self.rust_type(t.elem or UNKNOWN)
            if t.size is not None:
                return f'[{elem}; {t.size}]'
            return f'Vec<{elem}>'
        if t.kind == 'mapping':
            k = self.rust_type(t.key or UNKNOWN)
            v = self.rust_type(t.value or UNKNOWN)
            return f'rt::Mapping<{k}, {v}>'
        if t.kind == 'tuple':
            inner = ', '.join(self.rust_type(m) for m in t.members)
            return f'({inner})'
        return '() /* unknown type */'

    def is_copy(self, t: SolType) -> bool:
        """Whether the Rust representation is Copy (value semantics for free)."""
        if t.kind in ('uint', 'int', 'intlit', 'bool', 'address', 'enum', 'bytes_fixed'):
            return True
        if t.kind in ('interface', 'contract', 'library'):
            return True  # Address
        if t.kind == 'array':
            return t.size is not None and self.is_copy(t.elem or UNKNOWN)
        if t.kind == 'struct':
            fields = self._symbols.structs.get(t.name, [])
            return all(self.is_copy(ft) for _, ft in fields)
        return False

    # ------------------------------------------------------------------
    # Defaults (Solidity zero-initialization)
    # ------------------------------------------------------------------

    def default_value(self, t: SolType) -> str:
        if t.kind == 'uint':
            return 'U256::ZERO' if t.mapped_bits == 256 else f'0{_NATIVE[t.mapped_bits][0]}'
        if t.kind == 'int':
            return 'I256::ZERO' if t.mapped_bits == 256 else f'0{_NATIVE[t.mapped_bits][1]}'
        if t.kind == 'intlit':
            return 'U256::ZERO'
        if t.kind == 'bool':
            return 'false'
        if t.kind == 'address':
            return 'Address::ZERO'
        if t.kind == 'string':
            return 'String::new()'
        if t.kind == 'bytes':
            return 'Vec::new()'
        if t.kind == 'bytes_fixed':
            return 'B256::ZERO' if t.bytes_n == 32 else f'[0u8; {t.bytes_n}]'
        if t.kind == 'enum':
            self._record_use(t.name)
            variants = self._symbols.enums.get(t.name)
            first = variants[0] if variants else 'default'
            from .definition import enum_variant_ident
            return f'{rust_ident(t.name)}::{enum_variant_ident(first)}'
        if t.kind == 'struct':
            self._record_use(t.name)
            return f'{rust_ident(t.name)}::default()'
        if t.kind in ('interface', 'contract', 'library'):
            return 'Address::ZERO'
        if t.kind == 'array':
            if t.size is not None:
                elem_default = self.default_value(t.elem or UNKNOWN)
                return f'[{elem_default}; {t.size}]'
            return 'Vec::new()'
        if t.kind == 'mapping':
            return 'rt::Mapping::new()'
        if t.kind == 'tuple':
            inner = ', '.join(self.default_value(m) for m in t.members)
            return f'({inner})'
        return 'Default::default()'

    # ------------------------------------------------------------------
    # Integer literal emission
    # ------------------------------------------------------------------

    def int_literal(self, value: int, target: Optional[SolType]) -> str:
        """Emit a Python-int literal as Rust source with the target's type."""
        if target is None or not target.is_integer or target.kind == 'intlit':
            # No context: pick the smallest sensible default (matches Solidity
            # literal-only expressions being evaluated at compile time).
            target = SolType('int' if value < 0 else 'uint', bits=256)
        if target.kind == 'uint':
            if target.mapped_bits == 256:
                return self.u256_literal(value)
            suffix = _NATIVE[target.mapped_bits][0]
            return f'{self._fmt_int(value)}{suffix}'
        # signed
        if target.mapped_bits == 256:
            return self.i256_literal(value)
        suffix = _NATIVE[target.mapped_bits][1]
        if value < 0:
            # `-128i8` won't parse (128i8 is out of range before the unary
            # minus applies) so MIN values use the named constant.
            if value == -(1 << (target.mapped_bits - 1)):
                return f'{suffix}::MIN'
            return f'(-{self._fmt_int(-value)}{suffix})'
        return f'{self._fmt_int(value)}{suffix}'

    @staticmethod
    def _fmt_int(value: int) -> str:
        assert value >= 0
        if value >= 1 << 32:
            return hex(value)
        return str(value)

    @staticmethod
    def u256_limbs(value: int) -> str:
        assert 0 <= value < (1 << 256)
        limbs = [(value >> (64 * i)) & ((1 << 64) - 1) for i in range(4)]
        return ', '.join(f'0x{l:x}u64' if l else '0u64' for l in limbs)

    def u256_literal(self, value: int) -> str:
        value &= (1 << 256) - 1
        if value == 0:
            return 'U256::ZERO'
        if value < (1 << 64):
            return f'U256::from_limbs([{value}u64, 0, 0, 0])'
        return f'U256::from_limbs([{self.u256_limbs(value)}])'

    def i256_literal(self, value: int) -> str:
        if value == 0:
            return 'I256::ZERO'
        raw = value & ((1 << 256) - 1)  # two's complement
        return f'I256::from_raw({self.u256_literal(raw)})'

    # ------------------------------------------------------------------
    # Coercion (implicit widening) and explicit casts
    # ------------------------------------------------------------------

    def coerce(self, code: str, frm: SolType, to: SolType) -> str:
        """Implicitly widen ``code`` from ``frm`` to ``to`` (numeric only).

        Only ever widens — Solidity has no implicit narrowing. Identity
        coercions (same Rust representation) return the code unchanged.
        """
        if frm.kind == 'intlit' or to.kind in ('intlit', 'unknown') or frm.kind == 'unknown':
            return code
        if not (frm.is_integer and to.is_integer):
            return code
        if frm.kind == to.kind and frm.mapped_bits == to.mapped_bits:
            return code
        return self.cast(code, frm, to)

    def cast(self, code: str, frm: SolType, to: SolType) -> str:
        """Explicit Solidity conversion between integer/address/bytes types."""
        code_p = f'({code})' if _needs_parens_for_cast(code) else code

        # --- integer -> integer ---
        if frm.is_integer and to.is_integer:
            return self._int_cast(code, code_p, frm, to)

        # --- address <-> uint160/uint256 ---
        if frm.kind == 'address' and to.is_integer:
            u = f'rt::address_to_u256({code})'
            return self._int_cast(u, f'({u})', SolType('uint', bits=256), to) if to.mapped_bits != 256 or to.kind != 'uint' or to.bits != 256 else u
        if frm.is_integer and to.kind == 'address':
            wide = self._int_cast(code, code_p, frm, SolType('uint', bits=256))
            return f'rt::address_from_u256({wide})'

        # --- bytes32 <-> uint256 ---
        if frm.kind == 'bytes_fixed' and frm.bytes_n == 32 and to.is_integer:
            u = f'rt::b256_to_u256({code})'
            if to.kind == 'uint' and to.bits == 256:
                return u
            return self._int_cast(u, f'({u})', SolType('uint', bits=256), to)
        if frm.is_integer and to.kind == 'bytes_fixed' and to.bytes_n == 32:
            wide = self._int_cast(code, code_p, frm, SolType('uint', bits=256))
            return f'rt::u256_to_b256({wide})'

        # --- enum <-> integer ---
        if frm.kind == 'enum' and to.is_integer:
            u8code = f'({code} as u8)'
            return self._int_cast(u8code, u8code, SolType('uint', bits=8), to)
        if frm.is_integer and to.kind == 'enum':
            # Solidity checks the FULL source value on enum conversion
            # (Panic 0x21): uint256(256) -> enum must revert, not wrap to
            # variant 0. `to::<u8>()` / try_from panic on overflow, then
            # from_u8 range-checks against the variant count.
            from .definition import enum_from_u8_fn
            if frm.mapped_bits == 256:
                src = f'({code_p}.into_raw())' if frm.kind == 'int' else code_p
                narrowed = f'{src}.to::<u8>()'
            elif frm.mapped_bits == 8 and frm.kind == 'uint':
                narrowed = code
            else:
                narrowed = (
                    f'u8::try_from({code}).expect('
                    f'"panic: enum conversion out of range (0x21)")'
                )
            return f'{rust_ident(to.name)}::{enum_from_u8_fn()}({narrowed})'

        # --- interface/contract cast of an address (value context) ---
        if to.kind in ('interface', 'contract') and frm.kind in ('address', 'interface', 'contract'):
            return code
        if frm.kind in ('interface', 'contract') and to.kind == 'address':
            return code

        # payable(x) etc.
        if frm.kind == to.kind:
            return code
        return code  # last resort: representations are compatible or a diagnostic fired upstream

    def _int_cast(self, code: str, code_p: str, frm: SolType, to: SolType) -> str:
        frm_wide, to_wide = frm.mapped_bits == 256, to.mapped_bits == 256

        if not frm_wide and not to_wide:
            out = f'{code_p} as {self.rust_type(to)}'
            if to.is_odd_width:
                out = self._truncate_native_odd(out, to)
            return out

        if not frm_wide and to_wide:
            # native -> U256/I256 (Solidity explicit conversion = mod 2^256
            # two's complement for signed sources)
            if to.kind == 'uint':
                if frm.kind == 'uint':
                    out = f'U256::from({code})'
                else:
                    out = f'rt::u256_from_i128({code_p} as i128)'
            else:
                if frm.kind == 'uint':
                    out = f'I256::from_raw(U256::from({code}))'
                else:
                    out = f'rt::i256_from_i128({code_p} as i128)'
            if to.is_odd_width:
                out = self._truncate_wide_odd(out, to)
            return out

        if frm_wide and not to_wide:
            # U256/I256 -> native: truncate low bits (wrapping_to), then
            # reinterpret sign via `as` (exactly Solidity's behavior).
            src = code_p
            if frm.kind == 'int':
                src = f'({code_p}.into_raw())'
            un = _NATIVE[to.mapped_bits][0]
            truncated = f'{src}.wrapping_to::<{un}>()'
            if to.kind == 'int':
                truncated = f'({truncated} as {_NATIVE[to.mapped_bits][1]})'
            if to.is_odd_width:
                truncated = self._truncate_native_odd(truncated, to)
            return truncated

        # wide -> wide
        if frm.kind == 'int' and to.kind == 'uint':
            out = f'{code_p}.into_raw()'
        elif frm.kind == 'uint' and to.kind == 'int':
            out = f'I256::from_raw({code})'
        else:
            out = code
        if to.is_odd_width:
            out = self._truncate_wide_odd(out, to)
        return out

    def _truncate_native_odd(self, code: str, to: SolType) -> str:
        """Truncate a native-representation value to an odd declared width.

        Unsigned: AND-mask. Signed: Solidity intM(x) truncates to M bits AND
        sign-extends into the wider representation — the shl/asr pair does
        both (a plain mask would zero-extend: int24(-1) must stay -1, not
        become 0xFFFFFF)."""
        if to.kind == 'uint':
            mask = (1 << to.bits) - 1
            return f'(({code}) & {self._fmt_int(mask)}{_NATIVE[to.mapped_bits][0]})'
        d = to.mapped_bits - to.bits
        return f'((({code}) << {d}) >> {d})'

    @staticmethod
    def _truncate_wide_odd(code: str, to: SolType) -> str:
        if to.kind == 'uint':
            return f'rt::mask_bits({code}, {to.bits})'
        return f'rt::mask_bits_signed({code}, {to.bits})'


def is_wrapped(code: str) -> bool:
    """True when the string is one balanced (...) group — `(a) & (b)` is NOT."""
    if not (code.startswith('(') and code.endswith(')')):
        return False
    depth = 0
    for i, ch in enumerate(code):
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return i == len(code) - 1
    return False


def _needs_parens_for_cast(code: str) -> bool:
    if code.isidentifier():
        return False
    if is_wrapped(code):
        return False
    # Over-parenthesizing is harmless (the crate allows unused_parens);
    # under-parenthesizing silently rebinds casts/method calls. Be safe.
    return True

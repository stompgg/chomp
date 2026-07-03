#!/usr/bin/env python3
"""Regenerate differential-rs/src/mock_engine.rs from the emitted IEngine trait.

Run after `python3 -m transpiler src/ --target rust` whenever IEngine.sol's
surface changes:

    python3 transpiler/scripts/gen_mock_engine.py
"""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main() -> None:
    src = (ROOT / 'transpiler/rs-output/engine/src/IEngine.rs').read_text()
    m = re.search(r'pub trait IEngine \{(.*?)\n\}', src, re.S)
    if m is None:
        raise SystemExit('IEngine trait not found — run the rust transpile first')
    sigs = [line.strip() for line in m.group(1).split('\n') if line.strip().startswith('fn ')]

    out = [
        '//! PanicEngine: an IEngine implementation whose every method panics.',
        '//! Pure-lib differential tests need a `&mut dyn IEngine` to satisfy',
        '//! signatures on paths that never touch the engine (e.g. MoveSlotLib',
        '//! inline decoding). Any actual call is a test bug and fails loudly.',
        '//!',
        '//! Generated from the emitted IEngine trait (scripts/gen_mock_engine.py',
        '//! regenerates it if the trait surface changes).',
        '',
        'use chomp_engine::IEngine::IEngine;',
        'use chomp_engine::Enums::*;',
        'use chomp_engine::Structs::*;',
        'use chomp_rt::{Address, B256, I256, U256};',
        '',
        'pub struct PanicEngine;',
        '',
        'impl IEngine for PanicEngine {',
    ]
    for sig in sigs:
        sig_no_semi = sig.rstrip(';')
        name = re.match(r'fn (r#\w+|\w+)', sig_no_semi).group(1)
        out.append(f'    {sig_no_semi} {{')
        out.append(f'        unimplemented!("PanicEngine.{name} called from a pure-lib test")')
        out.append('    }')
    out.append('}')
    out.append('')

    dest = ROOT / 'transpiler/differential-rs/src/mock_engine.rs'
    dest.write_text('\n'.join(out))
    print(f'wrote {dest} with {len(sigs)} methods')


if __name__ == '__main__':
    main()

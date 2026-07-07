"""Rust backend for the extruder transpiler (sol2rs).

Mirrors the structure of ``codegen/`` (the TypeScript backend) with one
emitter per concern, plus the two pieces TS never needed: a cross-file
``RustSymbols`` table and a ``SolType`` expression-type inferencer that
drive the native-integer mapping.
"""

from .generator import RustCodeGenerator
from .symbols import RustSymbols

__all__ = ['RustCodeGenerator', 'RustSymbols']

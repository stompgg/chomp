"""
Solidity to TypeScript Transpiler

This package provides a transpiler that converts Solidity smart contracts
to TypeScript for local simulation and testing.

Module Structure:
- lexer/: Tokenization (TokenType, Token, Lexer)
- parser/: AST nodes and parsing (Parser, all AST node types)
- types/: Type registry and mappings (TypeRegistry, type conversion utilities)
- codegen/: Code generation helpers (YulTranspiler, AbiTypeInferer, CodeGenerationContext)
- sol2ts.py: Main transpiler (backward compatible monolithic version)

Usage:
    # Using the new modular structure:
    from transpiler.lexer import Lexer
    from transpiler.parser import Parser
    from transpiler.types import TypeRegistry

    # Or using the legacy monolithic structure:
    from transpiler.sol2ts import SolidityToTypeScriptTranspiler

    # Both approaches work and produce identical output.
"""

# Re-export main classes for convenience
from .sol2ts import (
    SolidityToTypeScriptTranspiler,
    TypeScriptCodeGenerator,
    TypeRegistry,
    Lexer,
    Parser,
)

__all__ = [
    'SolidityToTypeScriptTranspiler',
    'TypeScriptCodeGenerator',
    'TypeRegistry',
    'Lexer',
    'Parser',
]

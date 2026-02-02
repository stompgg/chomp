"""
Solidity to TypeScript Transpiler

This package provides a transpiler that converts Solidity smart contracts
to TypeScript for local simulation and testing.

Module Structure:
- lexer/: Tokenization (TokenType, Token, Lexer)
- parser/: AST nodes and parsing (Parser, all AST node types)
- types/: Type registry and mappings (TypeRegistry, type conversion utilities)
- codegen/: Code generation (TypeScriptCodeGenerator + specialized generators)
- sol2ts.py: Main transpiler entry point

Usage:
    from transpiler import SolidityToTypeScriptTranspiler

    # Or import individual components:
    from transpiler.lexer import Lexer
    from transpiler.parser import Parser
    from transpiler.type_system import TypeRegistry
    from transpiler.codegen import TypeScriptCodeGenerator
"""

# Re-export main classes for convenience
from .sol2ts import SolidityToTypeScriptTranspiler
from .lexer import Lexer
from .parser import Parser
from .type_system import TypeRegistry
from .codegen import TypeScriptCodeGenerator

__all__ = [
    'SolidityToTypeScriptTranspiler',
    'TypeScriptCodeGenerator',
    'TypeRegistry',
    'Lexer',
    'Parser',
]

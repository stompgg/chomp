"""
Code generation module for the Solidity to TypeScript transpiler.

This module provides TypeScript code generation from Solidity AST nodes.
"""

from .yul import YulTranspiler
from .abi import AbiTypeInferer
from .context import CodeGenerationContext
from .base import BaseGenerator
from .type_converter import TypeConverter
from .expression import ExpressionGenerator
from .statement import StatementGenerator
from .function import FunctionGenerator
from .definition import DefinitionGenerator
from .imports import ImportGenerator
from .contract import ContractGenerator
from .generator import TypeScriptCodeGenerator
from .metadata import MetadataExtractor, FactoryGenerator, ContractMetadata
from .diagnostics import TranspilerDiagnostics, Diagnostic, DiagnosticSeverity

__all__ = [
    'YulTranspiler',
    'AbiTypeInferer',
    'CodeGenerationContext',
    'BaseGenerator',
    'TypeConverter',
    'ExpressionGenerator',
    'StatementGenerator',
    'FunctionGenerator',
    'DefinitionGenerator',
    'ImportGenerator',
    'ContractGenerator',
    'TypeScriptCodeGenerator',
    'MetadataExtractor',
    'FactoryGenerator',
    'ContractMetadata',
    'TranspilerDiagnostics',
    'Diagnostic',
    'DiagnosticSeverity',
]

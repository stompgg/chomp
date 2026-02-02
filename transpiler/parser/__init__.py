"""
Parser module for the Solidity to TypeScript transpiler.

This module provides AST node definitions and the parser implementation.
"""

from .ast_nodes import (
    # Base
    ASTNode,
    # Top-level
    SourceUnit,
    PragmaDirective,
    ImportDirective,
    ContractDefinition,
    UsingDirective,
    # Definitions
    StructDefinition,
    EnumDefinition,
    EventDefinition,
    ErrorDefinition,
    ModifierDefinition,
    FunctionDefinition,
    BaseConstructorCall,
    # Type and variable
    TypeName,
    VariableDeclaration,
    StateVariableDeclaration,
    # Expressions
    Expression,
    Literal,
    Identifier,
    BinaryOperation,
    UnaryOperation,
    TernaryOperation,
    FunctionCall,
    MemberAccess,
    IndexAccess,
    NewExpression,
    TupleExpression,
    ArrayLiteral,
    TypeCast,
    AssemblyBlock,
    # Statements
    Statement,
    Block,
    ExpressionStatement,
    VariableDeclarationStatement,
    IfStatement,
    ForStatement,
    WhileStatement,
    DoWhileStatement,
    ReturnStatement,
    EmitStatement,
    RevertStatement,
    BreakStatement,
    ContinueStatement,
    DeleteStatement,
    AssemblyStatement,
)
from .parser import Parser

__all__ = [
    # Base
    'ASTNode',
    # Top-level
    'SourceUnit',
    'PragmaDirective',
    'ImportDirective',
    'ContractDefinition',
    'UsingDirective',
    # Definitions
    'StructDefinition',
    'EnumDefinition',
    'EventDefinition',
    'ErrorDefinition',
    'ModifierDefinition',
    'FunctionDefinition',
    'BaseConstructorCall',
    # Type and variable
    'TypeName',
    'VariableDeclaration',
    'StateVariableDeclaration',
    # Expressions
    'Expression',
    'Literal',
    'Identifier',
    'BinaryOperation',
    'UnaryOperation',
    'TernaryOperation',
    'FunctionCall',
    'MemberAccess',
    'IndexAccess',
    'NewExpression',
    'TupleExpression',
    'ArrayLiteral',
    'TypeCast',
    'AssemblyBlock',
    # Statements
    'Statement',
    'Block',
    'ExpressionStatement',
    'VariableDeclarationStatement',
    'IfStatement',
    'ForStatement',
    'WhileStatement',
    'DoWhileStatement',
    'ReturnStatement',
    'EmitStatement',
    'RevertStatement',
    'BreakStatement',
    'ContinueStatement',
    'DeleteStatement',
    'AssemblyStatement',
    # Parser
    'Parser',
]

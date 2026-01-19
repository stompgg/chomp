#!/usr/bin/env python3
"""
Solidity to TypeScript Transpiler

This transpiler converts Solidity contracts to TypeScript for local simulation.
It's specifically designed for the Chomp game engine but can be extended for general use.

Key features:
- BigInt for 256-bit integer operations
- Storage simulation via objects/maps
- Bit manipulation helpers
- Yul/inline assembly support
- Interface and contract inheritance
"""

import re
import os
import sys
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Any, Tuple, Set
from enum import Enum, auto
from pathlib import Path


# =============================================================================
# LEXER / TOKENIZER
# =============================================================================

class TokenType(Enum):
    # Keywords
    CONTRACT = auto()
    INTERFACE = auto()
    LIBRARY = auto()
    ABSTRACT = auto()
    STRUCT = auto()
    ENUM = auto()
    FUNCTION = auto()
    MODIFIER = auto()
    EVENT = auto()
    ERROR = auto()
    MAPPING = auto()
    STORAGE = auto()
    MEMORY = auto()
    CALLDATA = auto()
    PUBLIC = auto()
    PRIVATE = auto()
    INTERNAL = auto()
    EXTERNAL = auto()
    VIEW = auto()
    PURE = auto()
    PAYABLE = auto()
    VIRTUAL = auto()
    OVERRIDE = auto()
    IMMUTABLE = auto()
    CONSTANT = auto()
    TRANSIENT = auto()
    INDEXED = auto()
    RETURNS = auto()
    RETURN = auto()
    IF = auto()
    ELSE = auto()
    FOR = auto()
    WHILE = auto()
    DO = auto()
    BREAK = auto()
    CONTINUE = auto()
    NEW = auto()
    DELETE = auto()
    EMIT = auto()
    REVERT = auto()
    REQUIRE = auto()
    ASSERT = auto()
    ASSEMBLY = auto()
    PRAGMA = auto()
    IMPORT = auto()
    IS = auto()
    USING = auto()
    TYPE = auto()
    CONSTRUCTOR = auto()
    RECEIVE = auto()
    FALLBACK = auto()
    TRUE = auto()
    FALSE = auto()

    # Types
    UINT = auto()
    INT = auto()
    BOOL = auto()
    ADDRESS = auto()
    BYTES = auto()
    STRING = auto()
    BYTES32 = auto()

    # Operators
    PLUS = auto()
    MINUS = auto()
    STAR = auto()
    SLASH = auto()
    PERCENT = auto()
    STAR_STAR = auto()
    AMPERSAND = auto()
    PIPE = auto()
    CARET = auto()
    TILDE = auto()
    LT = auto()
    GT = auto()
    LT_EQ = auto()
    GT_EQ = auto()
    EQ_EQ = auto()
    BANG_EQ = auto()
    AMPERSAND_AMPERSAND = auto()
    PIPE_PIPE = auto()
    BANG = auto()
    LT_LT = auto()
    GT_GT = auto()
    EQ = auto()
    PLUS_EQ = auto()
    MINUS_EQ = auto()
    STAR_EQ = auto()
    SLASH_EQ = auto()
    PERCENT_EQ = auto()
    AMPERSAND_EQ = auto()
    PIPE_EQ = auto()
    CARET_EQ = auto()
    LT_LT_EQ = auto()
    GT_GT_EQ = auto()
    PLUS_PLUS = auto()
    MINUS_MINUS = auto()
    QUESTION = auto()
    COLON = auto()
    ARROW = auto()

    # Delimiters
    LPAREN = auto()
    RPAREN = auto()
    LBRACE = auto()
    RBRACE = auto()
    LBRACKET = auto()
    RBRACKET = auto()
    SEMICOLON = auto()
    COMMA = auto()
    DOT = auto()

    # Literals
    NUMBER = auto()
    HEX_NUMBER = auto()
    STRING_LITERAL = auto()
    IDENTIFIER = auto()

    # Special
    COMMENT = auto()
    NEWLINE = auto()
    EOF = auto()


@dataclass
class Token:
    type: TokenType
    value: str
    line: int
    column: int


KEYWORDS = {
    'contract': TokenType.CONTRACT,
    'interface': TokenType.INTERFACE,
    'library': TokenType.LIBRARY,
    'abstract': TokenType.ABSTRACT,
    'struct': TokenType.STRUCT,
    'enum': TokenType.ENUM,
    'function': TokenType.FUNCTION,
    'modifier': TokenType.MODIFIER,
    'event': TokenType.EVENT,
    'error': TokenType.ERROR,
    'mapping': TokenType.MAPPING,
    'storage': TokenType.STORAGE,
    'memory': TokenType.MEMORY,
    'calldata': TokenType.CALLDATA,
    'public': TokenType.PUBLIC,
    'private': TokenType.PRIVATE,
    'internal': TokenType.INTERNAL,
    'external': TokenType.EXTERNAL,
    'view': TokenType.VIEW,
    'pure': TokenType.PURE,
    'payable': TokenType.PAYABLE,
    'virtual': TokenType.VIRTUAL,
    'override': TokenType.OVERRIDE,
    'immutable': TokenType.IMMUTABLE,
    'constant': TokenType.CONSTANT,
    'transient': TokenType.TRANSIENT,
    'indexed': TokenType.INDEXED,
    'returns': TokenType.RETURNS,
    'return': TokenType.RETURN,
    'if': TokenType.IF,
    'else': TokenType.ELSE,
    'for': TokenType.FOR,
    'while': TokenType.WHILE,
    'do': TokenType.DO,
    'break': TokenType.BREAK,
    'continue': TokenType.CONTINUE,
    'new': TokenType.NEW,
    'delete': TokenType.DELETE,
    'emit': TokenType.EMIT,
    'revert': TokenType.REVERT,
    'require': TokenType.REQUIRE,
    'assert': TokenType.ASSERT,
    'assembly': TokenType.ASSEMBLY,
    'pragma': TokenType.PRAGMA,
    'import': TokenType.IMPORT,
    'is': TokenType.IS,
    'using': TokenType.USING,
    'type': TokenType.TYPE,
    'constructor': TokenType.CONSTRUCTOR,
    'receive': TokenType.RECEIVE,
    'fallback': TokenType.FALLBACK,
    'true': TokenType.TRUE,
    'false': TokenType.FALSE,
    'bool': TokenType.BOOL,
    'address': TokenType.ADDRESS,
    'string': TokenType.STRING,
}


class Lexer:
    def __init__(self, source: str):
        self.source = source
        self.pos = 0
        self.line = 1
        self.column = 1
        self.tokens: List[Token] = []

    def peek(self, offset: int = 0) -> str:
        pos = self.pos + offset
        if pos >= len(self.source):
            return ''
        return self.source[pos]

    def advance(self) -> str:
        ch = self.peek()
        self.pos += 1
        if ch == '\n':
            self.line += 1
            self.column = 1
        else:
            self.column += 1
        return ch

    def skip_whitespace(self):
        ch = self.peek()
        while ch and ch in ' \t\r\n':
            self.advance()
            ch = self.peek()

    def skip_comment(self):
        if self.peek() == '/' and self.peek(1) == '/':
            while self.peek() and self.peek() != '\n':
                self.advance()
        elif self.peek() == '/' and self.peek(1) == '*':
            self.advance()  # skip /
            self.advance()  # skip *
            while self.peek():
                if self.peek() == '*' and self.peek(1) == '/':
                    self.advance()  # skip *
                    self.advance()  # skip /
                    break
                self.advance()

    def read_string(self) -> str:
        quote = self.advance()
        result = quote
        while self.peek() and self.peek() != quote:
            if self.peek() == '\\':
                result += self.advance()
            result += self.advance()
        if self.peek() == quote:
            result += self.advance()
        return result

    def read_number(self) -> Tuple[str, TokenType]:
        result = ''
        token_type = TokenType.NUMBER

        if self.peek() == '0' and self.peek(1) in 'xX':
            result += self.advance()  # 0
            result += self.advance()  # x
            token_type = TokenType.HEX_NUMBER
            while self.peek() in '0123456789abcdefABCDEF_':
                if self.peek() != '_':
                    result += self.advance()
                else:
                    self.advance()  # skip underscore
        else:
            while self.peek() in '0123456789_':
                if self.peek() != '_':
                    result += self.advance()
                else:
                    self.advance()  # skip underscore
            # Handle decimal
            if self.peek() == '.' and self.peek(1) in '0123456789':
                result += self.advance()  # .
                while self.peek() in '0123456789_':
                    if self.peek() != '_':
                        result += self.advance()
                    else:
                        self.advance()
            # Handle exponent
            if self.peek() in 'eE':
                result += self.advance()
                if self.peek() in '+-':
                    result += self.advance()
                while self.peek() in '0123456789':
                    result += self.advance()

        return result, token_type

    def read_identifier(self) -> str:
        result = ''
        while self.peek() and (self.peek().isalnum() or self.peek() == '_'):
            result += self.advance()
        return result

    def add_token(self, token_type: TokenType, value: str):
        self.tokens.append(Token(token_type, value, self.line, self.column))

    def tokenize(self) -> List[Token]:
        while self.pos < len(self.source):
            self.skip_whitespace()

            if self.pos >= len(self.source):
                break

            # Skip comments
            if self.peek() == '/' and self.peek(1) in '/*':
                self.skip_comment()
                continue

            start_line = self.line
            start_col = self.column
            ch = self.peek()

            # String literals
            if ch in '"\'':
                value = self.read_string()
                self.tokens.append(Token(TokenType.STRING_LITERAL, value, start_line, start_col))
                continue

            # Numbers
            if ch.isdigit():
                value, token_type = self.read_number()
                self.tokens.append(Token(token_type, value, start_line, start_col))
                continue

            # Identifiers and keywords
            if ch.isalpha() or ch == '_':
                value = self.read_identifier()
                token_type = KEYWORDS.get(value, TokenType.IDENTIFIER)
                # Check for type keywords like uint256, int32, bytes32
                if token_type == TokenType.IDENTIFIER:
                    if value.startswith('uint') or value.startswith('int'):
                        token_type = TokenType.UINT if value.startswith('uint') else TokenType.INT
                    elif value.startswith('bytes') and value != 'bytes':
                        token_type = TokenType.BYTES32
                self.tokens.append(Token(token_type, value, start_line, start_col))
                continue

            # Multi-character operators
            two_char = self.peek() + self.peek(1)
            three_char = two_char + self.peek(2) if len(self.source) > self.pos + 2 else ''

            # Three-character operators
            if three_char in ('>>=', '<<='):
                self.advance()
                self.advance()
                self.advance()
                token_type = TokenType.GT_GT_EQ if three_char == '>>=' else TokenType.LT_LT_EQ
                self.tokens.append(Token(token_type, three_char, start_line, start_col))
                continue

            # Two-character operators
            two_char_ops = {
                '++': TokenType.PLUS_PLUS,
                '--': TokenType.MINUS_MINUS,
                '**': TokenType.STAR_STAR,
                '&&': TokenType.AMPERSAND_AMPERSAND,
                '||': TokenType.PIPE_PIPE,
                '==': TokenType.EQ_EQ,
                '!=': TokenType.BANG_EQ,
                '<=': TokenType.LT_EQ,
                '>=': TokenType.GT_EQ,
                '<<': TokenType.LT_LT,
                '>>': TokenType.GT_GT,
                '+=': TokenType.PLUS_EQ,
                '-=': TokenType.MINUS_EQ,
                '*=': TokenType.STAR_EQ,
                '/=': TokenType.SLASH_EQ,
                '%=': TokenType.PERCENT_EQ,
                '&=': TokenType.AMPERSAND_EQ,
                '|=': TokenType.PIPE_EQ,
                '^=': TokenType.CARET_EQ,
                '=>': TokenType.ARROW,
            }
            if two_char in two_char_ops:
                self.advance()
                self.advance()
                self.tokens.append(Token(two_char_ops[two_char], two_char, start_line, start_col))
                continue

            # Single-character operators and delimiters
            single_char_ops = {
                '+': TokenType.PLUS,
                '-': TokenType.MINUS,
                '*': TokenType.STAR,
                '/': TokenType.SLASH,
                '%': TokenType.PERCENT,
                '&': TokenType.AMPERSAND,
                '|': TokenType.PIPE,
                '^': TokenType.CARET,
                '~': TokenType.TILDE,
                '<': TokenType.LT,
                '>': TokenType.GT,
                '!': TokenType.BANG,
                '=': TokenType.EQ,
                '?': TokenType.QUESTION,
                ':': TokenType.COLON,
                '(': TokenType.LPAREN,
                ')': TokenType.RPAREN,
                '{': TokenType.LBRACE,
                '}': TokenType.RBRACE,
                '[': TokenType.LBRACKET,
                ']': TokenType.RBRACKET,
                ';': TokenType.SEMICOLON,
                ',': TokenType.COMMA,
                '.': TokenType.DOT,
            }
            if ch in single_char_ops:
                self.advance()
                self.tokens.append(Token(single_char_ops[ch], ch, start_line, start_col))
                continue

            # Unknown character - skip
            self.advance()

        self.tokens.append(Token(TokenType.EOF, '', self.line, self.column))
        return self.tokens


# =============================================================================
# AST NODES
# =============================================================================

@dataclass
class ASTNode:
    pass


@dataclass
class SourceUnit(ASTNode):
    pragmas: List['PragmaDirective'] = field(default_factory=list)
    imports: List['ImportDirective'] = field(default_factory=list)
    contracts: List['ContractDefinition'] = field(default_factory=list)
    enums: List['EnumDefinition'] = field(default_factory=list)
    structs: List['StructDefinition'] = field(default_factory=list)
    constants: List['StateVariableDeclaration'] = field(default_factory=list)


@dataclass
class PragmaDirective(ASTNode):
    name: str
    value: str


@dataclass
class ImportDirective(ASTNode):
    path: str
    symbols: List[Tuple[str, Optional[str]]] = field(default_factory=list)  # (name, alias)


@dataclass
class ContractDefinition(ASTNode):
    name: str
    kind: str  # 'contract', 'interface', 'library', 'abstract'
    base_contracts: List[str] = field(default_factory=list)
    state_variables: List['StateVariableDeclaration'] = field(default_factory=list)
    functions: List['FunctionDefinition'] = field(default_factory=list)
    modifiers: List['ModifierDefinition'] = field(default_factory=list)
    events: List['EventDefinition'] = field(default_factory=list)
    errors: List['ErrorDefinition'] = field(default_factory=list)
    structs: List['StructDefinition'] = field(default_factory=list)
    enums: List['EnumDefinition'] = field(default_factory=list)
    constructor: Optional['FunctionDefinition'] = None
    using_directives: List['UsingDirective'] = field(default_factory=list)


@dataclass
class UsingDirective(ASTNode):
    library: str
    type_name: Optional[str] = None


@dataclass
class StructDefinition(ASTNode):
    name: str
    members: List['VariableDeclaration'] = field(default_factory=list)


@dataclass
class EnumDefinition(ASTNode):
    name: str
    members: List[str] = field(default_factory=list)


@dataclass
class EventDefinition(ASTNode):
    name: str
    parameters: List['VariableDeclaration'] = field(default_factory=list)


@dataclass
class ErrorDefinition(ASTNode):
    name: str
    parameters: List['VariableDeclaration'] = field(default_factory=list)


@dataclass
class ModifierDefinition(ASTNode):
    name: str
    parameters: List['VariableDeclaration'] = field(default_factory=list)
    body: Optional['Block'] = None


@dataclass
class TypeName(ASTNode):
    name: str
    is_array: bool = False
    array_size: Optional['Expression'] = None
    array_dimensions: int = 0  # For multi-dimensional arrays (e.g., 2 for int[][])
    key_type: Optional['TypeName'] = None  # For mappings
    value_type: Optional['TypeName'] = None  # For mappings
    is_mapping: bool = False


@dataclass
class VariableDeclaration(ASTNode):
    name: str
    type_name: TypeName
    visibility: str = 'internal'
    mutability: str = ''  # '', 'constant', 'immutable', 'transient'
    storage_location: str = ''  # '', 'storage', 'memory', 'calldata'
    is_indexed: bool = False
    initial_value: Optional['Expression'] = None


@dataclass
class StateVariableDeclaration(VariableDeclaration):
    pass


@dataclass
class FunctionDefinition(ASTNode):
    name: str
    parameters: List[VariableDeclaration] = field(default_factory=list)
    return_parameters: List[VariableDeclaration] = field(default_factory=list)
    visibility: str = 'public'
    mutability: str = ''  # '', 'view', 'pure', 'payable'
    modifiers: List[str] = field(default_factory=list)
    is_virtual: bool = False
    is_override: bool = False
    body: Optional['Block'] = None
    is_constructor: bool = False
    is_receive: bool = False
    is_fallback: bool = False


# =============================================================================
# EXPRESSION NODES
# =============================================================================

@dataclass
class Expression(ASTNode):
    pass


@dataclass
class Literal(Expression):
    value: str
    kind: str  # 'number', 'string', 'bool', 'hex'


@dataclass
class Identifier(Expression):
    name: str


@dataclass
class BinaryOperation(Expression):
    left: Expression
    operator: str
    right: Expression


@dataclass
class UnaryOperation(Expression):
    operator: str
    operand: Expression
    is_prefix: bool = True


@dataclass
class TernaryOperation(Expression):
    condition: Expression
    true_expression: Expression
    false_expression: Expression


@dataclass
class FunctionCall(Expression):
    function: Expression
    arguments: List[Expression] = field(default_factory=list)
    named_arguments: Dict[str, Expression] = field(default_factory=dict)


@dataclass
class MemberAccess(Expression):
    expression: Expression
    member: str


@dataclass
class IndexAccess(Expression):
    base: Expression
    index: Expression


@dataclass
class NewExpression(Expression):
    type_name: TypeName


@dataclass
class TupleExpression(Expression):
    components: List[Optional[Expression]] = field(default_factory=list)


@dataclass
class TypeCast(Expression):
    type_name: TypeName
    expression: Expression


@dataclass
class AssemblyBlock(Expression):
    code: str
    flags: List[str] = field(default_factory=list)


# =============================================================================
# STATEMENT NODES
# =============================================================================

@dataclass
class Statement(ASTNode):
    pass


@dataclass
class Block(Statement):
    statements: List[Statement] = field(default_factory=list)


@dataclass
class ExpressionStatement(Statement):
    expression: Expression


@dataclass
class VariableDeclarationStatement(Statement):
    declarations: List[VariableDeclaration]
    initial_value: Optional[Expression] = None


@dataclass
class IfStatement(Statement):
    condition: Expression
    true_body: Statement
    false_body: Optional[Statement] = None


@dataclass
class ForStatement(Statement):
    init: Optional[Statement] = None
    condition: Optional[Expression] = None
    post: Optional[Expression] = None
    body: Optional[Statement] = None


@dataclass
class WhileStatement(Statement):
    condition: Expression
    body: Statement


@dataclass
class DoWhileStatement(Statement):
    body: Statement
    condition: Expression


@dataclass
class ReturnStatement(Statement):
    expression: Optional[Expression] = None


@dataclass
class EmitStatement(Statement):
    event_call: FunctionCall


@dataclass
class RevertStatement(Statement):
    error_call: Optional[FunctionCall] = None


@dataclass
class BreakStatement(Statement):
    pass


@dataclass
class ContinueStatement(Statement):
    pass


@dataclass
class AssemblyStatement(Statement):
    block: AssemblyBlock


# =============================================================================
# PARSER
# =============================================================================

class Parser:
    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0

    def peek(self, offset: int = 0) -> Token:
        pos = self.pos + offset
        if pos >= len(self.tokens):
            return self.tokens[-1]  # Return EOF
        return self.tokens[pos]

    def current(self) -> Token:
        return self.peek()

    def advance(self) -> Token:
        token = self.current()
        self.pos += 1
        return token

    def match(self, *types: TokenType) -> bool:
        return self.current().type in types

    def expect(self, token_type: TokenType, message: str = '') -> Token:
        if self.current().type != token_type:
            raise SyntaxError(
                f"Expected {token_type.name} but got {self.current().type.name} "
                f"at line {self.current().line}, column {self.current().column}: {message}"
            )
        return self.advance()

    def parse(self) -> SourceUnit:
        unit = SourceUnit()

        while not self.match(TokenType.EOF):
            if self.match(TokenType.PRAGMA):
                unit.pragmas.append(self.parse_pragma())
            elif self.match(TokenType.IMPORT):
                unit.imports.append(self.parse_import())
            elif self.match(TokenType.CONTRACT, TokenType.INTERFACE, TokenType.LIBRARY, TokenType.ABSTRACT):
                unit.contracts.append(self.parse_contract())
            elif self.match(TokenType.STRUCT):
                unit.structs.append(self.parse_struct())
            elif self.match(TokenType.ENUM):
                unit.enums.append(self.parse_enum())
            elif self.match(TokenType.IDENTIFIER, TokenType.UINT, TokenType.INT, TokenType.BOOL,
                           TokenType.ADDRESS, TokenType.BYTES, TokenType.STRING, TokenType.BYTES32):
                # Top-level constant
                var = self.parse_state_variable()
                unit.constants.append(var)
            else:
                self.advance()  # Skip unknown tokens

        return unit

    def parse_pragma(self) -> PragmaDirective:
        self.expect(TokenType.PRAGMA)
        name = self.advance().value
        # Collect the rest until semicolon
        value = ''
        while not self.match(TokenType.SEMICOLON, TokenType.EOF):
            value += self.advance().value + ' '
        self.expect(TokenType.SEMICOLON)
        return PragmaDirective(name, value.strip())

    def parse_import(self) -> ImportDirective:
        self.expect(TokenType.IMPORT)
        symbols = []

        if self.match(TokenType.LBRACE):
            # Named imports: import {A, B as C} from "..."
            self.advance()
            while not self.match(TokenType.RBRACE):
                name = self.advance().value
                alias = None
                if self.current().value == 'as':
                    self.advance()
                    alias = self.advance().value
                symbols.append((name, alias))
                if self.match(TokenType.COMMA):
                    self.advance()
            self.expect(TokenType.RBRACE)
            # Expect 'from'
            if self.current().value == 'from':
                self.advance()

        path = self.advance().value.strip('"\'')
        self.expect(TokenType.SEMICOLON)
        return ImportDirective(path, symbols)

    def parse_contract(self) -> ContractDefinition:
        kind = 'contract'
        if self.match(TokenType.ABSTRACT):
            kind = 'abstract'
            self.advance()

        if self.match(TokenType.CONTRACT):
            if kind != 'abstract':
                kind = 'contract'
        elif self.match(TokenType.INTERFACE):
            kind = 'interface'
        elif self.match(TokenType.LIBRARY):
            kind = 'library'
        self.advance()

        name = self.expect(TokenType.IDENTIFIER).value
        base_contracts = []

        if self.match(TokenType.IS):
            self.advance()
            while True:
                base_name = self.advance().value
                # Handle generics like MappingAllocator
                if self.match(TokenType.LPAREN):
                    self.advance()
                    depth = 1
                    while depth > 0:
                        if self.match(TokenType.LPAREN):
                            depth += 1
                        elif self.match(TokenType.RPAREN):
                            depth -= 1
                        self.advance()
                base_contracts.append(base_name)
                if self.match(TokenType.COMMA):
                    self.advance()
                else:
                    break

        self.expect(TokenType.LBRACE)
        contract = ContractDefinition(name=name, kind=kind, base_contracts=base_contracts)

        while not self.match(TokenType.RBRACE, TokenType.EOF):
            if self.match(TokenType.FUNCTION):
                contract.functions.append(self.parse_function())
            elif self.match(TokenType.CONSTRUCTOR):
                contract.constructor = self.parse_constructor()
            elif self.match(TokenType.MODIFIER):
                contract.modifiers.append(self.parse_modifier())
            elif self.match(TokenType.EVENT):
                contract.events.append(self.parse_event())
            elif self.match(TokenType.ERROR):
                contract.errors.append(self.parse_error())
            elif self.match(TokenType.STRUCT):
                contract.structs.append(self.parse_struct())
            elif self.match(TokenType.ENUM):
                contract.enums.append(self.parse_enum())
            elif self.match(TokenType.USING):
                contract.using_directives.append(self.parse_using())
            elif self.match(TokenType.RECEIVE):
                # Skip receive function for now
                self.skip_function()
            elif self.match(TokenType.FALLBACK):
                # Skip fallback function for now
                self.skip_function()
            else:
                # State variable
                try:
                    var = self.parse_state_variable()
                    contract.state_variables.append(var)
                except Exception:
                    self.advance()  # Skip on error

        self.expect(TokenType.RBRACE)
        return contract

    def parse_using(self) -> UsingDirective:
        self.expect(TokenType.USING)
        library = self.advance().value
        type_name = None
        if self.current().value == 'for':
            self.advance()
            type_name = self.advance().value
            if type_name == '*':
                type_name = '*'
        self.expect(TokenType.SEMICOLON)
        return UsingDirective(library, type_name)

    def parse_struct(self) -> StructDefinition:
        self.expect(TokenType.STRUCT)
        name = self.expect(TokenType.IDENTIFIER).value
        self.expect(TokenType.LBRACE)

        members = []
        while not self.match(TokenType.RBRACE, TokenType.EOF):
            type_name = self.parse_type_name()
            member_name = self.expect(TokenType.IDENTIFIER).value
            self.expect(TokenType.SEMICOLON)
            members.append(VariableDeclaration(name=member_name, type_name=type_name))

        self.expect(TokenType.RBRACE)
        return StructDefinition(name=name, members=members)

    def parse_enum(self) -> EnumDefinition:
        self.expect(TokenType.ENUM)
        name = self.expect(TokenType.IDENTIFIER).value
        self.expect(TokenType.LBRACE)

        members = []
        while not self.match(TokenType.RBRACE, TokenType.EOF):
            members.append(self.advance().value)
            if self.match(TokenType.COMMA):
                self.advance()

        self.expect(TokenType.RBRACE)
        return EnumDefinition(name=name, members=members)

    def parse_event(self) -> EventDefinition:
        self.expect(TokenType.EVENT)
        name = self.expect(TokenType.IDENTIFIER).value
        self.expect(TokenType.LPAREN)

        parameters = []
        while not self.match(TokenType.RPAREN, TokenType.EOF):
            param = self.parse_parameter()
            parameters.append(param)
            if self.match(TokenType.COMMA):
                self.advance()

        self.expect(TokenType.RPAREN)
        self.expect(TokenType.SEMICOLON)
        return EventDefinition(name=name, parameters=parameters)

    def parse_error(self) -> ErrorDefinition:
        self.expect(TokenType.ERROR)
        name = self.expect(TokenType.IDENTIFIER).value
        self.expect(TokenType.LPAREN)

        parameters = []
        while not self.match(TokenType.RPAREN, TokenType.EOF):
            param = self.parse_parameter()
            parameters.append(param)
            if self.match(TokenType.COMMA):
                self.advance()

        self.expect(TokenType.RPAREN)
        self.expect(TokenType.SEMICOLON)
        return ErrorDefinition(name=name, parameters=parameters)

    def parse_modifier(self) -> ModifierDefinition:
        self.expect(TokenType.MODIFIER)
        name = self.expect(TokenType.IDENTIFIER).value

        parameters = []
        if self.match(TokenType.LPAREN):
            self.advance()
            while not self.match(TokenType.RPAREN, TokenType.EOF):
                param = self.parse_parameter()
                parameters.append(param)
                if self.match(TokenType.COMMA):
                    self.advance()
            self.expect(TokenType.RPAREN)

        body = None
        if self.match(TokenType.LBRACE):
            body = self.parse_block()

        return ModifierDefinition(name=name, parameters=parameters, body=body)

    def parse_function(self) -> FunctionDefinition:
        self.expect(TokenType.FUNCTION)

        name = ''
        if self.match(TokenType.IDENTIFIER):
            name = self.advance().value

        self.expect(TokenType.LPAREN)
        parameters = []
        while not self.match(TokenType.RPAREN, TokenType.EOF):
            param = self.parse_parameter()
            parameters.append(param)
            if self.match(TokenType.COMMA):
                self.advance()
        self.expect(TokenType.RPAREN)

        visibility = 'public'
        mutability = ''
        modifiers = []
        is_virtual = False
        is_override = False
        return_parameters = []

        # Parse function attributes
        while True:
            if self.match(TokenType.PUBLIC):
                visibility = 'public'
                self.advance()
            elif self.match(TokenType.PRIVATE):
                visibility = 'private'
                self.advance()
            elif self.match(TokenType.INTERNAL):
                visibility = 'internal'
                self.advance()
            elif self.match(TokenType.EXTERNAL):
                visibility = 'external'
                self.advance()
            elif self.match(TokenType.VIEW):
                mutability = 'view'
                self.advance()
            elif self.match(TokenType.PURE):
                mutability = 'pure'
                self.advance()
            elif self.match(TokenType.PAYABLE):
                mutability = 'payable'
                self.advance()
            elif self.match(TokenType.VIRTUAL):
                is_virtual = True
                self.advance()
            elif self.match(TokenType.OVERRIDE):
                is_override = True
                self.advance()
                # Handle override(A, B)
                if self.match(TokenType.LPAREN):
                    self.advance()
                    while not self.match(TokenType.RPAREN):
                        self.advance()
                    self.expect(TokenType.RPAREN)
            elif self.match(TokenType.RETURNS):
                self.advance()
                self.expect(TokenType.LPAREN)
                while not self.match(TokenType.RPAREN, TokenType.EOF):
                    ret_param = self.parse_parameter()
                    return_parameters.append(ret_param)
                    if self.match(TokenType.COMMA):
                        self.advance()
                self.expect(TokenType.RPAREN)
            elif self.match(TokenType.IDENTIFIER):
                # Modifier call
                modifiers.append(self.advance().value)
                if self.match(TokenType.LPAREN):
                    self.advance()
                    depth = 1
                    while depth > 0:
                        if self.match(TokenType.LPAREN):
                            depth += 1
                        elif self.match(TokenType.RPAREN):
                            depth -= 1
                        self.advance()
            else:
                break

        body = None
        if self.match(TokenType.LBRACE):
            body = self.parse_block()
        elif self.match(TokenType.SEMICOLON):
            self.advance()

        return FunctionDefinition(
            name=name,
            parameters=parameters,
            return_parameters=return_parameters,
            visibility=visibility,
            mutability=mutability,
            modifiers=modifiers,
            is_virtual=is_virtual,
            is_override=is_override,
            body=body,
        )

    def parse_constructor(self) -> FunctionDefinition:
        self.expect(TokenType.CONSTRUCTOR)
        self.expect(TokenType.LPAREN)

        parameters = []
        while not self.match(TokenType.RPAREN, TokenType.EOF):
            param = self.parse_parameter()
            parameters.append(param)
            if self.match(TokenType.COMMA):
                self.advance()
        self.expect(TokenType.RPAREN)

        # Skip modifiers and visibility
        while not self.match(TokenType.LBRACE, TokenType.EOF):
            self.advance()

        body = self.parse_block()

        return FunctionDefinition(
            name='constructor',
            parameters=parameters,
            body=body,
            is_constructor=True,
        )

    def skip_function(self):
        # Skip until we find the function body or semicolon
        self.advance()  # Skip receive/fallback
        if self.match(TokenType.LPAREN):
            self.advance()
            depth = 1
            while depth > 0 and not self.match(TokenType.EOF):
                if self.match(TokenType.LPAREN):
                    depth += 1
                elif self.match(TokenType.RPAREN):
                    depth -= 1
                self.advance()

        while not self.match(TokenType.LBRACE, TokenType.SEMICOLON, TokenType.EOF):
            self.advance()

        if self.match(TokenType.LBRACE):
            self.parse_block()
        elif self.match(TokenType.SEMICOLON):
            self.advance()

    def parse_parameter(self) -> VariableDeclaration:
        type_name = self.parse_type_name()

        storage_location = ''
        is_indexed = False

        while True:
            if self.match(TokenType.STORAGE):
                storage_location = 'storage'
                self.advance()
            elif self.match(TokenType.MEMORY):
                storage_location = 'memory'
                self.advance()
            elif self.match(TokenType.CALLDATA):
                storage_location = 'calldata'
                self.advance()
            elif self.match(TokenType.INDEXED):
                is_indexed = True
                self.advance()
            else:
                break

        name = ''
        if self.match(TokenType.IDENTIFIER):
            name = self.advance().value

        return VariableDeclaration(
            name=name,
            type_name=type_name,
            storage_location=storage_location,
            is_indexed=is_indexed,
        )

    def parse_state_variable(self) -> StateVariableDeclaration:
        type_name = self.parse_type_name()

        visibility = 'internal'
        mutability = ''
        storage_location = ''

        while True:
            if self.match(TokenType.PUBLIC):
                visibility = 'public'
                self.advance()
            elif self.match(TokenType.PRIVATE):
                visibility = 'private'
                self.advance()
            elif self.match(TokenType.INTERNAL):
                visibility = 'internal'
                self.advance()
            elif self.match(TokenType.CONSTANT):
                mutability = 'constant'
                self.advance()
            elif self.match(TokenType.IMMUTABLE):
                mutability = 'immutable'
                self.advance()
            elif self.match(TokenType.TRANSIENT):
                mutability = 'transient'
                self.advance()
            elif self.match(TokenType.OVERRIDE):
                self.advance()
            else:
                break

        name = self.expect(TokenType.IDENTIFIER).value

        initial_value = None
        if self.match(TokenType.EQ):
            self.advance()
            initial_value = self.parse_expression()

        self.expect(TokenType.SEMICOLON)

        return StateVariableDeclaration(
            name=name,
            type_name=type_name,
            visibility=visibility,
            mutability=mutability,
            storage_location=storage_location,
            initial_value=initial_value,
        )

    def parse_type_name(self) -> TypeName:
        # Handle mapping type
        if self.match(TokenType.MAPPING):
            return self.parse_mapping_type()

        # Basic type
        type_token = self.advance()
        base_type = type_token.value

        # Check for function type
        if base_type == 'function':
            # Skip function type definition for now
            while not self.match(TokenType.RPAREN, TokenType.COMMA, TokenType.IDENTIFIER):
                self.advance()
            return TypeName(name='function')

        # Check for array brackets (can be multiple for multi-dimensional arrays)
        is_array = False
        array_dimensions = 0
        array_size = None
        while self.match(TokenType.LBRACKET):
            self.advance()
            is_array = True
            array_dimensions += 1
            if not self.match(TokenType.RBRACKET):
                array_size = self.parse_expression()
            self.expect(TokenType.RBRACKET)

        type_name = TypeName(name=base_type, is_array=is_array, array_size=array_size)
        # For multi-dimensional arrays, we store the dimension count
        type_name.array_dimensions = array_dimensions if is_array else 0
        return type_name

    def parse_mapping_type(self) -> TypeName:
        self.expect(TokenType.MAPPING)
        self.expect(TokenType.LPAREN)

        key_type = self.parse_type_name()

        # Skip optional key name
        if self.match(TokenType.IDENTIFIER):
            self.advance()

        self.expect(TokenType.ARROW)

        value_type = self.parse_type_name()

        # Skip optional value name
        if self.match(TokenType.IDENTIFIER):
            self.advance()

        self.expect(TokenType.RPAREN)

        return TypeName(
            name='mapping',
            is_mapping=True,
            key_type=key_type,
            value_type=value_type,
        )

    def parse_block(self) -> Block:
        self.expect(TokenType.LBRACE)
        statements = []

        while not self.match(TokenType.RBRACE, TokenType.EOF):
            stmt = self.parse_statement()
            if stmt:
                statements.append(stmt)

        self.expect(TokenType.RBRACE)
        return Block(statements=statements)

    def parse_statement(self) -> Optional[Statement]:
        if self.match(TokenType.LBRACE):
            return self.parse_block()
        elif self.match(TokenType.IF):
            return self.parse_if_statement()
        elif self.match(TokenType.FOR):
            return self.parse_for_statement()
        elif self.match(TokenType.WHILE):
            return self.parse_while_statement()
        elif self.match(TokenType.DO):
            return self.parse_do_while_statement()
        elif self.match(TokenType.RETURN):
            return self.parse_return_statement()
        elif self.match(TokenType.EMIT):
            return self.parse_emit_statement()
        elif self.match(TokenType.REVERT):
            return self.parse_revert_statement()
        elif self.match(TokenType.BREAK):
            self.advance()
            self.expect(TokenType.SEMICOLON)
            return BreakStatement()
        elif self.match(TokenType.CONTINUE):
            self.advance()
            self.expect(TokenType.SEMICOLON)
            return ContinueStatement()
        elif self.match(TokenType.ASSEMBLY):
            return self.parse_assembly_statement()
        elif self.is_variable_declaration():
            return self.parse_variable_declaration_statement()
        else:
            return self.parse_expression_statement()

    def is_variable_declaration(self) -> bool:
        """Check if current position starts a variable declaration."""
        # Save position
        saved_pos = self.pos

        try:
            # Check for tuple declaration: (type name, type name) = ...
            if self.match(TokenType.LPAREN):
                self.advance()  # skip (
                # Check if first item is a type followed by an identifier
                if self.match(TokenType.IDENTIFIER, TokenType.UINT, TokenType.INT,
                             TokenType.BOOL, TokenType.ADDRESS, TokenType.BYTES,
                             TokenType.STRING, TokenType.BYTES32):
                    self.advance()  # type name
                    # Skip array brackets
                    while self.match(TokenType.LBRACKET):
                        while not self.match(TokenType.RBRACKET, TokenType.EOF):
                            self.advance()
                        if self.match(TokenType.RBRACKET):
                            self.advance()
                    # Skip storage location
                    while self.match(TokenType.STORAGE, TokenType.MEMORY, TokenType.CALLDATA):
                        self.advance()
                    # Check for identifier (variable name)
                    if self.match(TokenType.IDENTIFIER):
                        return True
                return False

            # Try to parse type
            if self.match(TokenType.MAPPING):
                return True
            if not self.match(TokenType.IDENTIFIER, TokenType.UINT, TokenType.INT,
                             TokenType.BOOL, TokenType.ADDRESS, TokenType.BYTES,
                             TokenType.STRING, TokenType.BYTES32):
                return False

            self.advance()  # type name

            # Skip array brackets
            while self.match(TokenType.LBRACKET):
                self.advance()
                depth = 1
                while depth > 0 and not self.match(TokenType.EOF):
                    if self.match(TokenType.LBRACKET):
                        depth += 1
                    elif self.match(TokenType.RBRACKET):
                        depth -= 1
                    self.advance()

            # Skip storage location
            while self.match(TokenType.STORAGE, TokenType.MEMORY, TokenType.CALLDATA):
                self.advance()

            # Check for identifier (variable name)
            return self.match(TokenType.IDENTIFIER)

        finally:
            self.pos = saved_pos

    def parse_variable_declaration_statement(self) -> VariableDeclarationStatement:
        # Check for tuple declaration: (uint a, uint b) = ...
        if self.match(TokenType.LPAREN):
            return self.parse_tuple_declaration()

        type_name = self.parse_type_name()

        storage_location = ''
        while self.match(TokenType.STORAGE, TokenType.MEMORY, TokenType.CALLDATA):
            storage_location = self.advance().value

        name = self.expect(TokenType.IDENTIFIER).value
        declaration = VariableDeclaration(
            name=name,
            type_name=type_name,
            storage_location=storage_location,
        )

        initial_value = None
        if self.match(TokenType.EQ):
            self.advance()
            initial_value = self.parse_expression()

        self.expect(TokenType.SEMICOLON)
        return VariableDeclarationStatement(declarations=[declaration], initial_value=initial_value)

    def parse_tuple_declaration(self) -> VariableDeclarationStatement:
        self.expect(TokenType.LPAREN)
        declarations = []

        while not self.match(TokenType.RPAREN, TokenType.EOF):
            if self.match(TokenType.COMMA):
                declarations.append(None)
                self.advance()
                continue

            type_name = self.parse_type_name()

            storage_location = ''
            while self.match(TokenType.STORAGE, TokenType.MEMORY, TokenType.CALLDATA):
                storage_location = self.advance().value

            name = self.expect(TokenType.IDENTIFIER).value
            declarations.append(VariableDeclaration(
                name=name,
                type_name=type_name,
                storage_location=storage_location,
            ))

            if self.match(TokenType.COMMA):
                self.advance()

        self.expect(TokenType.RPAREN)
        self.expect(TokenType.EQ)
        initial_value = self.parse_expression()
        self.expect(TokenType.SEMICOLON)

        return VariableDeclarationStatement(
            declarations=[d for d in declarations if d is not None],
            initial_value=initial_value,
        )

    def parse_if_statement(self) -> IfStatement:
        self.expect(TokenType.IF)
        self.expect(TokenType.LPAREN)
        condition = self.parse_expression()
        self.expect(TokenType.RPAREN)

        true_body = self.parse_statement()

        false_body = None
        if self.match(TokenType.ELSE):
            self.advance()
            false_body = self.parse_statement()

        return IfStatement(condition=condition, true_body=true_body, false_body=false_body)

    def parse_for_statement(self) -> ForStatement:
        self.expect(TokenType.FOR)
        self.expect(TokenType.LPAREN)

        init = None
        if not self.match(TokenType.SEMICOLON):
            if self.is_variable_declaration():
                init = self.parse_variable_declaration_statement()
            else:
                init = self.parse_expression_statement()
        else:
            self.advance()

        condition = None
        if not self.match(TokenType.SEMICOLON):
            condition = self.parse_expression()
        self.expect(TokenType.SEMICOLON)

        post = None
        if not self.match(TokenType.RPAREN):
            post = self.parse_expression()
        self.expect(TokenType.RPAREN)

        body = self.parse_statement()

        return ForStatement(init=init, condition=condition, post=post, body=body)

    def parse_while_statement(self) -> WhileStatement:
        self.expect(TokenType.WHILE)
        self.expect(TokenType.LPAREN)
        condition = self.parse_expression()
        self.expect(TokenType.RPAREN)
        body = self.parse_statement()
        return WhileStatement(condition=condition, body=body)

    def parse_do_while_statement(self) -> DoWhileStatement:
        self.expect(TokenType.DO)
        body = self.parse_statement()
        self.expect(TokenType.WHILE)
        self.expect(TokenType.LPAREN)
        condition = self.parse_expression()
        self.expect(TokenType.RPAREN)
        self.expect(TokenType.SEMICOLON)
        return DoWhileStatement(body=body, condition=condition)

    def parse_return_statement(self) -> ReturnStatement:
        self.expect(TokenType.RETURN)
        expr = None
        if not self.match(TokenType.SEMICOLON):
            expr = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return ReturnStatement(expression=expr)

    def parse_emit_statement(self) -> EmitStatement:
        self.expect(TokenType.EMIT)
        event_call = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return EmitStatement(event_call=event_call)

    def parse_revert_statement(self) -> RevertStatement:
        self.expect(TokenType.REVERT)
        error_call = None
        if not self.match(TokenType.SEMICOLON):
            error_call = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return RevertStatement(error_call=error_call)

    def parse_assembly_statement(self) -> AssemblyStatement:
        self.expect(TokenType.ASSEMBLY)

        flags = []
        # Check for flags like ("memory-safe")
        if self.match(TokenType.LPAREN):
            self.advance()
            while not self.match(TokenType.RPAREN, TokenType.EOF):
                flags.append(self.advance().value)
            self.expect(TokenType.RPAREN)

        # Parse the assembly block
        self.expect(TokenType.LBRACE)
        code = ''
        depth = 1
        while depth > 0 and not self.match(TokenType.EOF):
            if self.current().type == TokenType.LBRACE:
                depth += 1
                code += ' { '
            elif self.current().type == TokenType.RBRACE:
                depth -= 1
                if depth > 0:
                    code += ' } '
            else:
                code += ' ' + self.current().value
            self.advance()

        return AssemblyStatement(block=AssemblyBlock(code=code.strip(), flags=flags))

    def parse_expression_statement(self) -> ExpressionStatement:
        expr = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return ExpressionStatement(expression=expr)

    def parse_expression(self) -> Expression:
        return self.parse_assignment()

    def parse_assignment(self) -> Expression:
        left = self.parse_ternary()

        if self.match(TokenType.EQ, TokenType.PLUS_EQ, TokenType.MINUS_EQ,
                     TokenType.STAR_EQ, TokenType.SLASH_EQ, TokenType.PERCENT_EQ,
                     TokenType.AMPERSAND_EQ, TokenType.PIPE_EQ, TokenType.CARET_EQ,
                     TokenType.LT_LT_EQ, TokenType.GT_GT_EQ):
            op = self.advance().value
            right = self.parse_assignment()
            return BinaryOperation(left=left, operator=op, right=right)

        return left

    def parse_ternary(self) -> Expression:
        condition = self.parse_or()

        if self.match(TokenType.QUESTION):
            self.advance()
            true_expr = self.parse_expression()
            self.expect(TokenType.COLON)
            false_expr = self.parse_ternary()
            return TernaryOperation(
                condition=condition,
                true_expression=true_expr,
                false_expression=false_expr,
            )

        return condition

    def parse_or(self) -> Expression:
        left = self.parse_and()
        while self.match(TokenType.PIPE_PIPE):
            op = self.advance().value
            right = self.parse_and()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_and(self) -> Expression:
        left = self.parse_bitwise_or()
        while self.match(TokenType.AMPERSAND_AMPERSAND):
            op = self.advance().value
            right = self.parse_bitwise_or()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_bitwise_or(self) -> Expression:
        left = self.parse_bitwise_xor()
        while self.match(TokenType.PIPE):
            op = self.advance().value
            right = self.parse_bitwise_xor()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_bitwise_xor(self) -> Expression:
        left = self.parse_bitwise_and()
        while self.match(TokenType.CARET):
            op = self.advance().value
            right = self.parse_bitwise_and()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_bitwise_and(self) -> Expression:
        left = self.parse_equality()
        while self.match(TokenType.AMPERSAND):
            op = self.advance().value
            right = self.parse_equality()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_equality(self) -> Expression:
        left = self.parse_comparison()
        while self.match(TokenType.EQ_EQ, TokenType.BANG_EQ):
            op = self.advance().value
            right = self.parse_comparison()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_comparison(self) -> Expression:
        left = self.parse_shift()
        while self.match(TokenType.LT, TokenType.GT, TokenType.LT_EQ, TokenType.GT_EQ):
            op = self.advance().value
            right = self.parse_shift()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_shift(self) -> Expression:
        left = self.parse_additive()
        while self.match(TokenType.LT_LT, TokenType.GT_GT):
            op = self.advance().value
            right = self.parse_additive()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_additive(self) -> Expression:
        left = self.parse_multiplicative()
        while self.match(TokenType.PLUS, TokenType.MINUS):
            op = self.advance().value
            right = self.parse_multiplicative()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_multiplicative(self) -> Expression:
        left = self.parse_exponentiation()
        while self.match(TokenType.STAR, TokenType.SLASH, TokenType.PERCENT):
            op = self.advance().value
            right = self.parse_exponentiation()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_exponentiation(self) -> Expression:
        left = self.parse_unary()
        if self.match(TokenType.STAR_STAR):
            op = self.advance().value
            right = self.parse_exponentiation()  # Right associative
            return BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_unary(self) -> Expression:
        if self.match(TokenType.BANG, TokenType.TILDE, TokenType.MINUS,
                     TokenType.PLUS_PLUS, TokenType.MINUS_MINUS):
            op = self.advance().value
            operand = self.parse_unary()
            return UnaryOperation(operator=op, operand=operand, is_prefix=True)

        return self.parse_postfix()

    def parse_postfix(self) -> Expression:
        expr = self.parse_primary()

        while True:
            if self.match(TokenType.DOT):
                self.advance()
                member = self.advance().value
                expr = MemberAccess(expression=expr, member=member)
            elif self.match(TokenType.LBRACKET):
                self.advance()
                index = self.parse_expression()
                self.expect(TokenType.RBRACKET)
                expr = IndexAccess(base=expr, index=index)
            elif self.match(TokenType.LPAREN):
                self.advance()
                args, named_args = self.parse_arguments()
                self.expect(TokenType.RPAREN)
                expr = FunctionCall(function=expr, arguments=args, named_arguments=named_args)
            elif self.match(TokenType.PLUS_PLUS, TokenType.MINUS_MINUS):
                op = self.advance().value
                expr = UnaryOperation(operator=op, operand=expr, is_prefix=False)
            else:
                break

        return expr

    def parse_arguments(self) -> Tuple[List[Expression], Dict[str, Expression]]:
        args = []
        named_args = {}

        # Check for named arguments: { name: value, ... }
        if self.match(TokenType.LBRACE):
            self.advance()
            while not self.match(TokenType.RBRACE, TokenType.EOF):
                name = self.expect(TokenType.IDENTIFIER).value
                self.expect(TokenType.COLON)
                value = self.parse_expression()
                named_args[name] = value
                if self.match(TokenType.COMMA):
                    self.advance()
            self.expect(TokenType.RBRACE)
            return args, named_args

        while not self.match(TokenType.RPAREN, TokenType.EOF):
            args.append(self.parse_expression())
            if self.match(TokenType.COMMA):
                self.advance()

        return args, named_args

    def parse_primary(self) -> Expression:
        # Literals with optional time/denomination suffix
        if self.match(TokenType.NUMBER, TokenType.HEX_NUMBER):
            token = self.advance()
            value = token.value
            kind = 'number' if token.type == TokenType.NUMBER else 'hex'

            # Check for time units or ether denominations
            time_units = {
                'seconds': 1, 'minutes': 60, 'hours': 3600,
                'days': 86400, 'weeks': 604800,
                'wei': 1, 'gwei': 10**9, 'ether': 10**18
            }
            if self.match(TokenType.IDENTIFIER) and self.current().value in time_units:
                unit = self.advance().value
                multiplier = time_units[unit]
                # Create a multiplication expression
                return BinaryOperation(
                    left=Literal(value=value, kind=kind),
                    operator='*',
                    right=Literal(value=str(multiplier), kind='number')
                )

            return Literal(value=value, kind=kind)
        if self.match(TokenType.STRING_LITERAL):
            return Literal(value=self.advance().value, kind='string')
        if self.match(TokenType.TRUE):
            self.advance()
            return Literal(value='true', kind='bool')
        if self.match(TokenType.FALSE):
            self.advance()
            return Literal(value='false', kind='bool')

        # Tuple/Parenthesized expression
        if self.match(TokenType.LPAREN):
            self.advance()
            if self.match(TokenType.RPAREN):
                self.advance()
                return TupleExpression(components=[])

            first = self.parse_expression()

            if self.match(TokenType.COMMA):
                components = [first]
                while self.match(TokenType.COMMA):
                    self.advance()
                    if self.match(TokenType.RPAREN):
                        components.append(None)
                    else:
                        components.append(self.parse_expression())
                self.expect(TokenType.RPAREN)
                return TupleExpression(components=components)

            self.expect(TokenType.RPAREN)
            return first

        # Type cast or new expression
        if self.match(TokenType.NEW):
            self.advance()
            type_name = self.parse_type_name()
            return NewExpression(type_name=type_name)

        # Type cast: type(expr)
        if self.match(TokenType.UINT, TokenType.INT, TokenType.BOOL, TokenType.ADDRESS,
                     TokenType.BYTES, TokenType.STRING, TokenType.BYTES32):
            type_token = self.advance()
            if self.match(TokenType.LPAREN):
                self.advance()
                expr = self.parse_expression()
                self.expect(TokenType.RPAREN)
                return TypeCast(type_name=TypeName(name=type_token.value), expression=expr)
            return Identifier(name=type_token.value)

        # Type keyword
        if self.match(TokenType.TYPE):
            self.advance()
            self.expect(TokenType.LPAREN)
            type_name = self.parse_type_name()
            self.expect(TokenType.RPAREN)
            return FunctionCall(
                function=Identifier(name='type'),
                arguments=[Identifier(name=type_name.name)],
            )

        # Identifier (including possible type cast)
        if self.match(TokenType.IDENTIFIER):
            name = self.advance().value
            # Check for type cast
            if self.match(TokenType.LPAREN):
                # Could be function call or type cast
                # We'll treat it as function call and handle casts in codegen
                pass
            return Identifier(name=name)

        # If nothing matches, return empty identifier
        return Identifier(name='')


# =============================================================================
# CODE GENERATOR
# =============================================================================

class TypeScriptCodeGenerator:
    """Generates TypeScript code from the AST."""

    def __init__(self):
        self.indent_level = 0
        self.indent_str = '  '
        self.imports: Set[str] = set()
        self.type_info: Dict[str, str] = {}  # Maps Solidity types to TypeScript types

    def indent(self) -> str:
        return self.indent_str * self.indent_level

    def generate(self, ast: SourceUnit) -> str:
        """Generate TypeScript code from the AST."""
        output = []

        # Add header
        output.append('// Auto-generated by sol2ts transpiler')
        output.append('// Do not edit manually\n')

        # Generate imports (will be filled in during generation)
        import_placeholder_index = len(output)
        output.append('')  # Placeholder for imports

        # Generate enums first (top-level and from contracts)
        for enum in ast.enums:
            output.append(self.generate_enum(enum))

        # Generate top-level constants
        for const in ast.constants:
            output.append(self.generate_constant(const))

        # Generate structs (top-level)
        for struct in ast.structs:
            output.append(self.generate_struct(struct))

        # Generate contracts/interfaces
        for contract in ast.contracts:
            output.append(self.generate_contract(contract))

        # Insert imports at placeholder
        import_lines = self.generate_imports()
        output[import_placeholder_index] = import_lines

        return '\n'.join(output)

    def generate_imports(self) -> str:
        """Generate import statements."""
        lines = []
        lines.append("import { keccak256, encodePacked, encodeAbiParameters, parseAbiParameters } from 'viem';")
        lines.append('')
        return '\n'.join(lines)

    def generate_enum(self, enum: EnumDefinition) -> str:
        """Generate TypeScript enum."""
        lines = []
        lines.append(f'export enum {enum.name} {{')
        for i, member in enumerate(enum.members):
            lines.append(f'  {member} = {i},')
        lines.append('}\n')
        return '\n'.join(lines)

    def generate_constant(self, const: StateVariableDeclaration) -> str:
        """Generate TypeScript constant."""
        ts_type = self.solidity_type_to_ts(const.type_name)
        value = self.generate_expression(const.initial_value) if const.initial_value else self.default_value(ts_type)
        return f'export const {const.name}: {ts_type} = {value};\n'

    def generate_struct(self, struct: StructDefinition) -> str:
        """Generate TypeScript interface for struct."""
        lines = []
        lines.append(f'export interface {struct.name} {{')
        for member in struct.members:
            ts_type = self.solidity_type_to_ts(member.type_name)
            lines.append(f'  {member.name}: {ts_type};')
        lines.append('}\n')
        return '\n'.join(lines)

    def generate_contract(self, contract: ContractDefinition) -> str:
        """Generate TypeScript class for contract."""
        lines = []

        # Generate nested enums
        for enum in contract.enums:
            lines.append(self.generate_enum(enum))

        # Generate nested structs
        for struct in contract.structs:
            lines.append(self.generate_struct(struct))

        # Generate interface for interfaces
        if contract.kind == 'interface':
            lines.append(self.generate_interface(contract))
        else:
            lines.append(self.generate_class(contract))

        return '\n'.join(lines)

    def generate_interface(self, contract: ContractDefinition) -> str:
        """Generate TypeScript interface."""
        lines = []
        lines.append(f'export interface {contract.name} {{')
        self.indent_level += 1

        for func in contract.functions:
            sig = self.generate_function_signature(func)
            lines.append(f'{self.indent()}{sig};')

        self.indent_level -= 1
        lines.append('}\n')
        return '\n'.join(lines)

    def generate_class(self, contract: ContractDefinition) -> str:
        """Generate TypeScript class."""
        lines = []

        # Class declaration
        extends = ''
        if contract.base_contracts:
            extends = f' extends {contract.base_contracts[0]}'
        implements = ''
        if len(contract.base_contracts) > 1:
            implements = f' implements {", ".join(contract.base_contracts[1:])}'

        abstract = 'abstract ' if contract.kind == 'abstract' else ''
        lines.append(f'export {abstract}class {contract.name}{extends}{implements} {{')
        self.indent_level += 1

        # Storage simulation
        lines.append(f'{self.indent()}// Storage')
        lines.append(f'{self.indent()}protected _storage: Map<string, any> = new Map();')
        lines.append(f'{self.indent()}protected _transient: Map<string, any> = new Map();')
        lines.append('')

        # State variables
        for var in contract.state_variables:
            lines.append(self.generate_state_variable(var))

        # Constructor
        if contract.constructor:
            lines.append(self.generate_constructor(contract.constructor))

        # Functions
        for func in contract.functions:
            lines.append(self.generate_function(func))

        self.indent_level -= 1
        lines.append('}\n')
        return '\n'.join(lines)

    def generate_state_variable(self, var: StateVariableDeclaration) -> str:
        """Generate state variable declaration."""
        ts_type = self.solidity_type_to_ts(var.type_name)
        modifier = ''

        if var.mutability == 'constant':
            modifier = 'static readonly '
        elif var.mutability == 'immutable':
            modifier = 'readonly '
        elif var.visibility == 'private':
            modifier = 'private '
        elif var.visibility == 'internal':
            modifier = 'protected '

        if var.type_name.is_mapping:
            # Use Map for mappings
            key_type = self.solidity_type_to_ts(var.type_name.key_type)
            value_type = self.solidity_type_to_ts(var.type_name.value_type)
            return f'{self.indent()}{modifier}{var.name}: Map<{key_type}, {value_type}> = new Map();'

        default_val = self.generate_expression(var.initial_value) if var.initial_value else self.default_value(ts_type)
        return f'{self.indent()}{modifier}{var.name}: {ts_type} = {default_val};'

    def generate_constructor(self, func: FunctionDefinition) -> str:
        """Generate constructor."""
        lines = []
        params = ', '.join([
            f'{p.name}: {self.solidity_type_to_ts(p.type_name)}'
            for p in func.parameters
        ])
        lines.append(f'{self.indent()}constructor({params}) {{')
        self.indent_level += 1

        if func.body:
            for stmt in func.body.statements:
                lines.append(self.generate_statement(stmt))

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')
        return '\n'.join(lines)

    def generate_param_name(self, param: VariableDeclaration, index: int) -> str:
        """Generate a parameter name, using _ for unnamed parameters."""
        if param.name:
            return param.name
        return f'_arg{index}'

    def generate_function_signature(self, func: FunctionDefinition) -> str:
        """Generate function signature for interface."""
        params = ', '.join([
            f'{self.generate_param_name(p, i)}: {self.solidity_type_to_ts(p.type_name)}'
            for i, p in enumerate(func.parameters)
        ])
        return_type = self.generate_return_type(func.return_parameters)
        return f'{func.name}({params}): {return_type}'

    def generate_function(self, func: FunctionDefinition) -> str:
        """Generate function implementation."""
        lines = []

        params = ', '.join([
            f'{self.generate_param_name(p, i)}: {self.solidity_type_to_ts(p.type_name)}'
            for i, p in enumerate(func.parameters)
        ])
        return_type = self.generate_return_type(func.return_parameters)

        visibility = ''
        if func.visibility == 'private':
            visibility = 'private '
        elif func.visibility == 'internal':
            visibility = 'protected '

        lines.append(f'{self.indent()}{visibility}{func.name}({params}): {return_type} {{')
        self.indent_level += 1

        if func.body:
            for stmt in func.body.statements:
                lines.append(self.generate_statement(stmt))

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')
        return '\n'.join(lines)

    def generate_return_type(self, params: List[VariableDeclaration]) -> str:
        """Generate return type from return parameters."""
        if not params:
            return 'void'
        if len(params) == 1:
            return self.solidity_type_to_ts(params[0].type_name)
        types = [self.solidity_type_to_ts(p.type_name) for p in params]
        return f'[{", ".join(types)}]'

    def generate_statement(self, stmt: Statement) -> str:
        """Generate TypeScript statement."""
        if isinstance(stmt, Block):
            return self.generate_block(stmt)
        elif isinstance(stmt, VariableDeclarationStatement):
            return self.generate_variable_declaration_statement(stmt)
        elif isinstance(stmt, IfStatement):
            return self.generate_if_statement(stmt)
        elif isinstance(stmt, ForStatement):
            return self.generate_for_statement(stmt)
        elif isinstance(stmt, WhileStatement):
            return self.generate_while_statement(stmt)
        elif isinstance(stmt, DoWhileStatement):
            return self.generate_do_while_statement(stmt)
        elif isinstance(stmt, ReturnStatement):
            return self.generate_return_statement(stmt)
        elif isinstance(stmt, EmitStatement):
            return self.generate_emit_statement(stmt)
        elif isinstance(stmt, RevertStatement):
            return self.generate_revert_statement(stmt)
        elif isinstance(stmt, BreakStatement):
            return f'{self.indent()}break;'
        elif isinstance(stmt, ContinueStatement):
            return f'{self.indent()}continue;'
        elif isinstance(stmt, AssemblyStatement):
            return self.generate_assembly_statement(stmt)
        elif isinstance(stmt, ExpressionStatement):
            return f'{self.indent()}{self.generate_expression(stmt.expression)};'
        return f'{self.indent()}// Unknown statement'

    def generate_block(self, block: Block) -> str:
        """Generate block of statements."""
        lines = []
        lines.append(f'{self.indent()}{{')
        self.indent_level += 1
        for stmt in block.statements:
            lines.append(self.generate_statement(stmt))
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        return '\n'.join(lines)

    def generate_variable_declaration_statement(self, stmt: VariableDeclarationStatement) -> str:
        """Generate variable declaration statement."""
        if len(stmt.declarations) == 1:
            decl = stmt.declarations[0]
            ts_type = self.solidity_type_to_ts(decl.type_name)
            init = ''
            if stmt.initial_value:
                init = f' = {self.generate_expression(stmt.initial_value)}'
            return f'{self.indent()}let {decl.name}: {ts_type}{init};'
        else:
            # Tuple declaration
            names = ', '.join([d.name if d else '_' for d in stmt.declarations])
            init = self.generate_expression(stmt.initial_value) if stmt.initial_value else ''
            return f'{self.indent()}const [{names}] = {init};'

    def generate_if_statement(self, stmt: IfStatement) -> str:
        """Generate if statement."""
        lines = []
        cond = self.generate_expression(stmt.condition)
        lines.append(f'{self.indent()}if ({cond}) {{')
        self.indent_level += 1
        if isinstance(stmt.true_body, Block):
            for s in stmt.true_body.statements:
                lines.append(self.generate_statement(s))
        else:
            lines.append(self.generate_statement(stmt.true_body))
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')

        if stmt.false_body:
            if isinstance(stmt.false_body, IfStatement):
                lines[-1] = f'{self.indent()}}} else {self.generate_if_statement(stmt.false_body).strip()}'
            else:
                lines.append(f'{self.indent()}else {{')
                self.indent_level += 1
                if isinstance(stmt.false_body, Block):
                    for s in stmt.false_body.statements:
                        lines.append(self.generate_statement(s))
                else:
                    lines.append(self.generate_statement(stmt.false_body))
                self.indent_level -= 1
                lines.append(f'{self.indent()}}}')

        return '\n'.join(lines)

    def generate_for_statement(self, stmt: ForStatement) -> str:
        """Generate for statement."""
        lines = []

        init = ''
        if stmt.init:
            if isinstance(stmt.init, VariableDeclarationStatement):
                decl = stmt.init.declarations[0]
                ts_type = self.solidity_type_to_ts(decl.type_name)
                if stmt.init.initial_value:
                    init_val = self.generate_expression(stmt.init.initial_value)
                else:
                    init_val = self.default_value(ts_type)
                init = f'let {decl.name}: {ts_type} = {init_val}'
            else:
                init = self.generate_expression(stmt.init.expression)

        cond = self.generate_expression(stmt.condition) if stmt.condition else ''
        post = self.generate_expression(stmt.post) if stmt.post else ''

        lines.append(f'{self.indent()}for ({init}; {cond}; {post}) {{')
        self.indent_level += 1
        if stmt.body:
            if isinstance(stmt.body, Block):
                for s in stmt.body.statements:
                    lines.append(self.generate_statement(s))
            else:
                lines.append(self.generate_statement(stmt.body))
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        return '\n'.join(lines)

    def generate_while_statement(self, stmt: WhileStatement) -> str:
        """Generate while statement."""
        lines = []
        cond = self.generate_expression(stmt.condition)
        lines.append(f'{self.indent()}while ({cond}) {{')
        self.indent_level += 1
        if isinstance(stmt.body, Block):
            for s in stmt.body.statements:
                lines.append(self.generate_statement(s))
        else:
            lines.append(self.generate_statement(stmt.body))
        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        return '\n'.join(lines)

    def generate_do_while_statement(self, stmt: DoWhileStatement) -> str:
        """Generate do-while statement."""
        lines = []
        lines.append(f'{self.indent()}do {{')
        self.indent_level += 1
        if isinstance(stmt.body, Block):
            for s in stmt.body.statements:
                lines.append(self.generate_statement(s))
        else:
            lines.append(self.generate_statement(stmt.body))
        self.indent_level -= 1
        cond = self.generate_expression(stmt.condition)
        lines.append(f'{self.indent()}}} while ({cond});')
        return '\n'.join(lines)

    def generate_return_statement(self, stmt: ReturnStatement) -> str:
        """Generate return statement."""
        if stmt.expression:
            return f'{self.indent()}return {self.generate_expression(stmt.expression)};'
        return f'{self.indent()}return;'

    def generate_emit_statement(self, stmt: EmitStatement) -> str:
        """Generate emit statement (as event logging)."""
        expr = self.generate_expression(stmt.event_call)
        return f'{self.indent()}this._emitEvent({expr});'

    def generate_revert_statement(self, stmt: RevertStatement) -> str:
        """Generate revert statement (as throw)."""
        if stmt.error_call:
            return f'{self.indent()}throw new Error({self.generate_expression(stmt.error_call)});'
        return f'{self.indent()}throw new Error("Revert");'

    def generate_assembly_statement(self, stmt: AssemblyStatement) -> str:
        """Generate assembly block (transpile Yul to TypeScript)."""
        yul_code = stmt.block.code
        ts_code = self.transpile_yul(yul_code)
        lines = []
        lines.append(f'{self.indent()}// Assembly block (transpiled from Yul)')
        for line in ts_code.split('\n'):
            lines.append(f'{self.indent()}{line}')
        return '\n'.join(lines)

    def transpile_yul(self, yul_code: str) -> str:
        """Transpile Yul assembly to TypeScript.

        Handles the specific patterns used in Engine.sol:
        - Storage slot access: varName.slot
        - sload/sstore for storage read/write
        - mstore for array length manipulation
        """
        lines = []

        # Normalize whitespace and remove extra spaces around operators/punctuation
        code = ' '.join(yul_code.split())
        # The tokenizer adds spaces around punctuation, normalize these patterns:
        code = re.sub(r':\s*=', ':=', code)           # ": =" -> ":="
        code = re.sub(r'\s*\.\s*', '.', code)         # " . " -> "." (member access)
        code = re.sub(r'(\w)\s+\(', r'\1(', code)     # "sload (" -> "sload(" (function calls)
        code = re.sub(r'\(\s+', '(', code)            # "( " -> "("
        code = re.sub(r'\s+\)', ')', code)            # " )" -> ")"
        code = re.sub(r'\s+,', ',', code)             # " ," -> ","
        code = re.sub(r',\s+', ', ', code)            # ", " normalize to single space
        code = re.sub(r'\{\s+', '{ ', code)           # "{ " normalize to single space
        code = re.sub(r'\s+\}', ' }', code)           # " }" normalize to single space

        # Pattern 1: MonState clearing pattern
        # let slot := monState.slot if sload(slot) { sstore(slot, PACKED_CLEARED_MON_STATE) }
        clear_pattern = re.search(
            r'let\s+(\w+)\s*:=\s*(\w+)\.slot\s+if\s+sload\((\w+)\)\s*\{\s*sstore\((\w+),\s*(\w+)\)\s*\}',
            code
        )
        if clear_pattern:
            slot_var = clear_pattern.group(1)
            state_var = clear_pattern.group(2)
            constant = clear_pattern.group(5)
            lines.append(f'// Clear {state_var} storage if it has data')
            lines.append(f'if (this._hasStorageData({state_var})) {{')
            lines.append(f'  this._clearMonState({state_var}, {constant});')
            lines.append(f'}}')
            return '\n'.join(lines)

        # Pattern 2: mstore for array length - mstore(array, length)
        mstore_pattern = re.search(r'mstore\((\w+),\s*(\w+)\)', code)
        if mstore_pattern:
            array_name = mstore_pattern.group(1)
            length_var = mstore_pattern.group(2)
            lines.append(f'// Set array length')
            lines.append(f'{array_name}.length = Number({length_var});')
            return '\n'.join(lines)

        # Pattern 3: Simple sload
        sload_pattern = re.search(r'sload\((\w+)\)', code)
        if sload_pattern and 'sstore' not in code:
            slot = sload_pattern.group(1)
            lines.append(f'this._storage.get({slot})')
            return '\n'.join(lines)

        # Pattern 4: Simple sstore
        sstore_pattern = re.search(r'sstore\((\w+),\s*(.+?)\)', code)
        if sstore_pattern and 'if' not in code:
            slot = sstore_pattern.group(1)
            value = sstore_pattern.group(2)
            lines.append(f'this._storage.set({slot}, {value});')
            return '\n'.join(lines)

        # Fallback: parse line by line for simpler cases
        statements = self.parse_yul_statements(yul_code)
        for stmt in statements:
            ts_stmt = self.transpile_yul_statement(stmt)
            if ts_stmt:
                lines.append(ts_stmt)

        return '\n'.join(lines) if lines else '// Assembly: no-op'

    def parse_yul_statements(self, code: str) -> List[str]:
        """Parse Yul code into individual statements."""
        # Simple parsing: split by newlines and braces
        statements = []
        current = ''
        depth = 0

        for char in code:
            if char == '{':
                depth += 1
                current += char
            elif char == '}':
                depth -= 1
                current += char
                if depth == 0:
                    statements.append(current.strip())
                    current = ''
            elif char == '\n' and depth == 0:
                if current.strip():
                    statements.append(current.strip())
                current = ''
            else:
                current += char

        if current.strip():
            statements.append(current.strip())

        return statements

    def transpile_yul_statement(self, stmt: str) -> str:
        """Transpile a single Yul statement to TypeScript."""
        stmt = stmt.strip()
        if not stmt:
            return ''

        # Variable assignment: let x := expr
        let_match = re.match(r'let\s+(\w+)\s*:=\s*(.+)', stmt)
        if let_match:
            var_name = let_match.group(1)
            expr = self.transpile_yul_expression(let_match.group(2))
            return f'let {var_name} = {expr};'

        # Assignment: x := expr
        assign_match = re.match(r'(\w+)\s*:=\s*(.+)', stmt)
        if assign_match:
            var_name = assign_match.group(1)
            expr = self.transpile_yul_expression(assign_match.group(2))
            return f'{var_name} = {expr};'

        # If statement
        if_match = re.match(r'if\s+(.+?)\s*\{(.+)\}', stmt, re.DOTALL)
        if if_match:
            cond = self.transpile_yul_expression(if_match.group(1))
            body = self.transpile_yul(if_match.group(2))
            return f'if ({cond}) {{\n{body}\n}}'

        # Function call (like sstore, sload, etc.)
        call_match = re.match(r'(\w+)\s*\((.+)\)', stmt)
        if call_match:
            func_name = call_match.group(1)
            args = [self.transpile_yul_expression(a.strip()) for a in call_match.group(2).split(',')]
            return self.transpile_yul_function(func_name, args)

        return f'// Unhandled Yul: {stmt}'

    def transpile_yul_expression(self, expr: str) -> str:
        """Transpile a Yul expression to TypeScript."""
        expr = expr.strip()

        # Handle function calls
        call_match = re.match(r'(\w+)\s*\((.+)\)', expr)
        if call_match:
            func_name = call_match.group(1)
            args_str = call_match.group(2)
            # Parse arguments carefully (handling nested calls)
            args = self.parse_yul_args(args_str)
            ts_args = [self.transpile_yul_expression(a) for a in args]
            return self.transpile_yul_function_expr(func_name, ts_args)

        # Handle identifiers and literals
        if expr.startswith('0x'):
            return f'BigInt("{expr}")'
        if expr.isdigit():
            return f'BigInt({expr})'
        return expr

    def parse_yul_args(self, args_str: str) -> List[str]:
        """Parse Yul function arguments, handling nested calls."""
        args = []
        current = ''
        depth = 0

        for char in args_str:
            if char == '(':
                depth += 1
                current += char
            elif char == ')':
                depth -= 1
                current += char
            elif char == ',' and depth == 0:
                args.append(current.strip())
                current = ''
            else:
                current += char

        if current.strip():
            args.append(current.strip())

        return args

    def transpile_yul_function(self, func_name: str, args: List[str]) -> str:
        """Transpile a Yul function call to TypeScript."""
        if func_name == 'sstore':
            return f'this._storage.set(String({args[0]}), {args[1]});'
        elif func_name == 'sload':
            return f'this._storage.get(String({args[0]})) ?? 0n'
        elif func_name == 'mstore':
            return f'// mstore({args[0]}, {args[1]})'
        elif func_name == 'mload':
            return f'// mload({args[0]})'
        elif func_name == 'revert':
            return f'throw new Error("Revert");'
        else:
            return f'// Yul function: {func_name}({", ".join(args)})'

    def transpile_yul_function_expr(self, func_name: str, args: List[str]) -> str:
        """Transpile a Yul function call expression to TypeScript."""
        if func_name == 'sload':
            return f'(this._storage.get(String({args[0]})) ?? 0n)'
        elif func_name == 'add':
            return f'(({args[0]}) + ({args[1]}))'
        elif func_name == 'sub':
            return f'(({args[0]}) - ({args[1]}))'
        elif func_name == 'mul':
            return f'(({args[0]}) * ({args[1]}))'
        elif func_name == 'div':
            return f'(({args[0]}) / ({args[1]}))'
        elif func_name == 'mod':
            return f'(({args[0]}) % ({args[1]}))'
        elif func_name == 'and':
            return f'(({args[0]}) & ({args[1]}))'
        elif func_name == 'or':
            return f'(({args[0]}) | ({args[1]}))'
        elif func_name == 'xor':
            return f'(({args[0]}) ^ ({args[1]}))'
        elif func_name == 'not':
            return f'(~({args[0]}))'
        elif func_name == 'shl':
            return f'(({args[1]}) << ({args[0]}))'
        elif func_name == 'shr':
            return f'(({args[1]}) >> ({args[0]}))'
        elif func_name == 'lt':
            return f'(({args[0]}) < ({args[1]}) ? 1n : 0n)'
        elif func_name == 'gt':
            return f'(({args[0]}) > ({args[1]}) ? 1n : 0n)'
        elif func_name == 'eq':
            return f'(({args[0]}) === ({args[1]}) ? 1n : 0n)'
        elif func_name == 'iszero':
            return f'(({args[0]}) === 0n ? 1n : 0n)'
        else:
            return f'/* {func_name}({", ".join(args)}) */'

    def generate_expression(self, expr: Expression) -> str:
        """Generate TypeScript expression."""
        if expr is None:
            return ''

        if isinstance(expr, Literal):
            return self.generate_literal(expr)
        elif isinstance(expr, Identifier):
            return self.generate_identifier(expr)
        elif isinstance(expr, BinaryOperation):
            return self.generate_binary_operation(expr)
        elif isinstance(expr, UnaryOperation):
            return self.generate_unary_operation(expr)
        elif isinstance(expr, TernaryOperation):
            return self.generate_ternary_operation(expr)
        elif isinstance(expr, FunctionCall):
            return self.generate_function_call(expr)
        elif isinstance(expr, MemberAccess):
            return self.generate_member_access(expr)
        elif isinstance(expr, IndexAccess):
            return self.generate_index_access(expr)
        elif isinstance(expr, NewExpression):
            return self.generate_new_expression(expr)
        elif isinstance(expr, TupleExpression):
            return self.generate_tuple_expression(expr)
        elif isinstance(expr, TypeCast):
            return self.generate_type_cast(expr)

        return '/* unknown expression */'

    def generate_literal(self, lit: Literal) -> str:
        """Generate literal."""
        if lit.kind == 'number':
            return f'BigInt({lit.value})'
        elif lit.kind == 'hex':
            return f'BigInt("{lit.value}")'
        elif lit.kind == 'string':
            return lit.value  # Already has quotes
        elif lit.kind == 'bool':
            return lit.value
        return lit.value

    def generate_identifier(self, ident: Identifier) -> str:
        """Generate identifier."""
        # Handle special identifiers
        if ident.name == 'msg':
            return 'this._msg'
        elif ident.name == 'block':
            return 'this._block'
        elif ident.name == 'tx':
            return 'this._tx'
        elif ident.name == 'this':
            return 'this'
        return ident.name

    def _needs_parens(self, expr: Expression) -> bool:
        """Check if expression needs parentheses when used as operand."""
        # Simple expressions don't need parens
        if isinstance(expr, (Literal, Identifier)):
            return False
        if isinstance(expr, MemberAccess):
            return False
        if isinstance(expr, IndexAccess):
            return False
        if isinstance(expr, FunctionCall):
            return False
        return True

    def generate_binary_operation(self, op: BinaryOperation) -> str:
        """Generate binary operation with minimal parentheses."""
        left = self.generate_expression(op.left)
        right = self.generate_expression(op.right)
        operator = op.operator

        # Only add parens around complex sub-expressions
        if self._needs_parens(op.left):
            left = f'({left})'
        if self._needs_parens(op.right):
            right = f'({right})'

        return f'{left} {operator} {right}'

    def generate_unary_operation(self, op: UnaryOperation) -> str:
        """Generate unary operation."""
        operand = self.generate_expression(op.operand)
        operator = op.operator

        if op.is_prefix:
            if self._needs_parens(op.operand):
                return f'{operator}({operand})'
            return f'{operator}{operand}'
        else:
            return f'({operand}){operator}'

    def generate_ternary_operation(self, op: TernaryOperation) -> str:
        """Generate ternary operation."""
        cond = self.generate_expression(op.condition)
        true_expr = self.generate_expression(op.true_expression)
        false_expr = self.generate_expression(op.false_expression)
        return f'({cond} ? {true_expr} : {false_expr})'

    def generate_function_call(self, call: FunctionCall) -> str:
        """Generate function call."""
        func = self.generate_expression(call.function)
        args = ', '.join([self.generate_expression(a) for a in call.arguments])

        # Handle special function calls
        if isinstance(call.function, Identifier):
            name = call.function.name
            if name == 'keccak256':
                return f'keccak256({args})'
            elif name == 'sha256':
                return f'sha256({args})'
            elif name == 'abi':
                return f'abi.{args}'
            elif name == 'require':
                if len(call.arguments) >= 2:
                    cond = self.generate_expression(call.arguments[0])
                    msg = self.generate_expression(call.arguments[1])
                    return f'if (!({cond})) throw new Error({msg})'
                else:
                    cond = self.generate_expression(call.arguments[0])
                    return f'if (!({cond})) throw new Error("Require failed")'
            elif name == 'assert':
                cond = self.generate_expression(call.arguments[0])
                return f'if (!({cond})) throw new Error("Assert failed")'
            elif name == 'type':
                return f'/* type({args}) */'

        # Handle type casts (uint256(x), etc.) - simplified for simulation
        if isinstance(call.function, Identifier):
            name = call.function.name
            if name.startswith('uint') or name.startswith('int'):
                # Skip redundant BigInt wrapping
                if args.startswith('BigInt(') or args.endswith('n'):
                    return args
                # For simple identifiers that are likely already bigint, pass through
                if call.arguments and isinstance(call.arguments[0], Identifier):
                    return args
                return f'BigInt({args})'
            elif name == 'address':
                return args  # Pass through - addresses are strings
            elif name == 'bool':
                return args  # Pass through - JS truthy works
            elif name.startswith('bytes'):
                return args  # Pass through

        return f'{func}({args})'

    def generate_member_access(self, access: MemberAccess) -> str:
        """Generate member access."""
        expr = self.generate_expression(access.expression)
        member = access.member

        # Handle special cases
        if isinstance(access.expression, Identifier):
            if access.expression.name == 'abi':
                if member == 'encode':
                    return 'encodeAbiParameters'
                elif member == 'encodePacked':
                    return 'encodePacked'
                elif member == 'decode':
                    return 'decodeAbiParameters'
            elif access.expression.name == 'type':
                return f'/* type().{member} */'

        # Handle .slot for storage variables
        if member == 'slot':
            return f'/* {expr}.slot */'

        return f'{expr}.{member}'

    def generate_index_access(self, access: IndexAccess) -> str:
        """Generate index access."""
        base = self.generate_expression(access.base)
        index = self.generate_expression(access.index)

        # Check if this is a mapping access
        return f'{base}.get({index})'

    def generate_new_expression(self, expr: NewExpression) -> str:
        """Generate new expression."""
        type_name = expr.type_name.name
        if expr.type_name.is_array:
            return f'new Array()'
        return f'new {type_name}()'

    def generate_tuple_expression(self, expr: TupleExpression) -> str:
        """Generate tuple expression."""
        components = [self.generate_expression(c) if c else '_' for c in expr.components]
        return f'[{", ".join(components)}]'

    def generate_type_cast(self, cast: TypeCast) -> str:
        """Generate type cast - simplified for simulation (no strict bit masking)."""
        type_name = cast.type_name.name
        expr = self.generate_expression(cast.expression)

        # For integers, just ensure it's a BigInt - skip bit masking for simplicity
        if type_name.startswith('uint') or type_name.startswith('int'):
            # If already looks like a BigInt or number, just use it
            if expr.startswith('BigInt(') or expr.isdigit() or expr.endswith('n'):
                return expr
            return f'BigInt({expr})'
        elif type_name == 'address':
            # Addresses are strings
            if expr.startswith('"') or expr.startswith("'"):
                return expr
            return expr  # Already a string in most cases
        elif type_name == 'bool':
            return expr  # JS truthy/falsy works fine
        elif type_name.startswith('bytes'):
            return expr  # Pass through

        # For custom types (structs, enums), just pass through
        return expr

    def solidity_type_to_ts(self, type_name: TypeName) -> str:
        """Convert Solidity type to TypeScript type."""
        if type_name.is_mapping:
            key = self.solidity_type_to_ts(type_name.key_type)
            value = self.solidity_type_to_ts(type_name.value_type)
            return f'Map<{key}, {value}>'

        name = type_name.name
        ts_type = 'any'

        if name.startswith('uint') or name.startswith('int'):
            ts_type = 'bigint'
        elif name == 'bool':
            ts_type = 'boolean'
        elif name == 'address':
            ts_type = 'string'
        elif name == 'string':
            ts_type = 'string'
        elif name.startswith('bytes'):
            ts_type = 'string'  # hex string
        else:
            ts_type = name  # Custom type (struct, enum, interface)

        if type_name.is_array:
            # Handle multi-dimensional arrays
            dimensions = getattr(type_name, 'array_dimensions', 1) or 1
            ts_type = ts_type + '[]' * dimensions

        return ts_type

    def default_value(self, ts_type: str) -> str:
        """Get default value for TypeScript type."""
        if ts_type == 'bigint':
            return '0n'
        elif ts_type == 'boolean':
            return 'false'
        elif ts_type == 'string':
            return '""'
        elif ts_type == 'number':
            return '0'
        elif ts_type.endswith('[]'):
            return '[]'
        elif ts_type.startswith('Map<'):
            return 'new Map()'
        return 'undefined as any'


# =============================================================================
# MAIN TRANSPILER CLASS
# =============================================================================

class SolidityToTypeScriptTranspiler:
    """Main transpiler class that orchestrates the conversion process."""

    def __init__(self, source_dir: str = '.', output_dir: str = './ts-output'):
        self.source_dir = Path(source_dir)
        self.output_dir = Path(output_dir)
        self.parsed_files: Dict[str, SourceUnit] = {}
        self.type_registry: Dict[str, Any] = {}  # Global type registry

    def transpile_file(self, filepath: str) -> str:
        """Transpile a single Solidity file to TypeScript."""
        with open(filepath, 'r') as f:
            source = f.read()

        # Tokenize
        lexer = Lexer(source)
        tokens = lexer.tokenize()

        # Parse
        parser = Parser(tokens)
        ast = parser.parse()

        # Store parsed AST
        self.parsed_files[filepath] = ast

        # Generate TypeScript
        generator = TypeScriptCodeGenerator()
        ts_code = generator.generate(ast)

        return ts_code

    def transpile_directory(self, pattern: str = '**/*.sol') -> Dict[str, str]:
        """Transpile all Solidity files matching the pattern."""
        results = {}

        for sol_file in self.source_dir.glob(pattern):
            try:
                ts_code = self.transpile_file(str(sol_file))
                # Calculate output path
                rel_path = sol_file.relative_to(self.source_dir)
                ts_path = self.output_dir / rel_path.with_suffix('.ts')
                results[str(ts_path)] = ts_code
            except Exception as e:
                print(f"Error transpiling {sol_file}: {e}")

        return results

    def write_output(self, results: Dict[str, str]):
        """Write transpiled TypeScript files to disk."""
        for filepath, content in results.items():
            path = Path(filepath)
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, 'w') as f:
                f.write(content)
            print(f"Written: {filepath}")


# =============================================================================
# CLI INTERFACE
# =============================================================================

def main():
    import argparse

    parser = argparse.ArgumentParser(description='Solidity to TypeScript Transpiler')
    parser.add_argument('input', help='Input Solidity file or directory')
    parser.add_argument('-o', '--output', default='./ts-output', help='Output directory')
    parser.add_argument('--stdout', action='store_true', help='Print to stdout instead of file')

    args = parser.parse_args()

    input_path = Path(args.input)

    if input_path.is_file():
        transpiler = SolidityToTypeScriptTranspiler()
        ts_code = transpiler.transpile_file(str(input_path))

        if args.stdout:
            print(ts_code)
        else:
            output_path = Path(args.output) / input_path.with_suffix('.ts').name
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, 'w') as f:
                f.write(ts_code)
            print(f"Written: {output_path}")

    elif input_path.is_dir():
        transpiler = SolidityToTypeScriptTranspiler(str(input_path), args.output)
        results = transpiler.transpile_directory()
        transpiler.write_output(results)

    else:
        print(f"Error: {args.input} is not a valid file or directory")
        sys.exit(1)


if __name__ == '__main__':
    main()

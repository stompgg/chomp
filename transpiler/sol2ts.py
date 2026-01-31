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

python transpiler/sol2ts.py src/
"""

import re
import sys
import json
import shutil
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
    UNCHECKED = auto()
    TRY = auto()
    CATCH = auto()
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
    'unchecked': TokenType.UNCHECKED,
    'try': TokenType.TRY,
    'catch': TokenType.CATCH,
    'true': TokenType.TRUE,
    'false': TokenType.FALSE,
    'bool': TokenType.BOOL,
    'address': TokenType.ADDRESS,
    'string': TokenType.STRING,
}

# Two-character operators (moved from inside tokenize() for performance)
TWO_CHAR_OPS = {
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

# Single-character operators and delimiters (moved from inside tokenize() for performance)
SINGLE_CHAR_OPS = {
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

# Precompiled regex patterns for Yul transpilation (moved from _transpile_yul_block for performance)
YUL_NORMALIZE_PATTERNS = [
    (re.compile(r':\s*='), ':='),           # ": =" -> ":="
    (re.compile(r'\s*\.\s*'), '.'),         # " . " -> "."
    (re.compile(r'(\w)\s+\('), r'\1('),     # "func (" -> "func("
    (re.compile(r'\(\s+'), '('),            # "( " -> "("
    (re.compile(r'\s+\)'), ')'),            # " )" -> ")"
    (re.compile(r'\s+,'), ','),             # " ," -> ","
    (re.compile(r',\s+'), ', '),            # normalize comma spacing
]
YUL_LET_PATTERN = re.compile(r'let\s+(\w+)\s*:=\s*([^{}\n]+?)(?=\s+(?:let|if|for|switch|sstore|mstore|revert|log\d)\b|\s*}|\s*$)')
YUL_SLOT_PATTERN = re.compile(r'(\w+)\.slot')
YUL_IF_PATTERN = re.compile(r'if\s+([^{]+)\s*\{([^}]*)\}')
YUL_IF_STRIP_PATTERN = re.compile(r'if\s+[^{]+\{[^}]*\}')
YUL_CALL_PATTERN = re.compile(r'\b(sstore|mstore|revert|log[0-4])\s*\(([^)]+)\)')


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

            # Two-character operators (using module-level constant)
            if two_char in TWO_CHAR_OPS:
                self.advance()
                self.advance()
                self.tokens.append(Token(TWO_CHAR_OPS[two_char], two_char, start_line, start_col))
                continue

            # Single-character operators and delimiters (using module-level constant)
            if ch in SINGLE_CHAR_OPS:
                self.advance()
                self.tokens.append(Token(SINGLE_CHAR_OPS[ch], ch, start_line, start_col))
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
class BaseConstructorCall(ASTNode):
    """Represents a base constructor call in a constructor definition."""
    base_name: str
    arguments: List['Expression'] = field(default_factory=list)


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
    base_constructor_calls: List[BaseConstructorCall] = field(default_factory=list)


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
class ArrayLiteral(Expression):
    """Array literal like [1, 2, 3]"""
    elements: List[Expression] = field(default_factory=list)


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
class DeleteStatement(Statement):
    expression: Expression


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
        # Library can also be qualified
        while self.match(TokenType.DOT):
            self.advance()  # skip dot
            library += '.' + self.advance().value
        type_name = None
        if self.current().value == 'for':
            self.advance()
            type_name = self.advance().value
            if type_name == '*':
                type_name = '*'
            else:
                # Handle qualified names like EnumerableSetLib.Uint256Set
                while self.match(TokenType.DOT):
                    self.advance()  # skip dot
                    type_name += '.' + self.advance().value
        # Skip optional 'global' keyword
        if self.current().value == 'global':
            self.advance()
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

        # Parse modifiers, visibility, and base constructor calls
        base_constructor_calls = []
        while not self.match(TokenType.LBRACE, TokenType.EOF):
            # Skip visibility and state mutability keywords
            if self.match(TokenType.PUBLIC, TokenType.PRIVATE, TokenType.INTERNAL,
                          TokenType.EXTERNAL, TokenType.PAYABLE):
                self.advance()
            # Check for base constructor call: Identifier(args)
            elif self.match(TokenType.IDENTIFIER):
                base_name = self.advance().value
                if self.match(TokenType.LPAREN):
                    # This is a base constructor call
                    args = self.parse_base_constructor_args()
                    base_constructor_calls.append(
                        BaseConstructorCall(base_name=base_name, arguments=args)
                    )
                # else it's just a modifier name, skip it
            else:
                self.advance()

        body = self.parse_block()

        return FunctionDefinition(
            name='constructor',
            parameters=parameters,
            body=body,
            is_constructor=True,
            base_constructor_calls=base_constructor_calls,
        )

    def parse_base_constructor_args(self) -> List[Expression]:
        """Parse base constructor arguments, handling nested braces for struct literals."""
        self.expect(TokenType.LPAREN)
        args = []

        while not self.match(TokenType.RPAREN, TokenType.EOF):
            arg = self.parse_expression()
            args.append(arg)
            if self.match(TokenType.COMMA):
                self.advance()

        self.expect(TokenType.RPAREN)
        return args

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

        # Check for qualified names (Library.StructName, Contract.EnumName, etc.)
        while self.match(TokenType.DOT):
            self.advance()  # skip dot
            member = self.expect(TokenType.IDENTIFIER).value
            base_type = f'{base_type}.{member}'

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
        elif self.match(TokenType.UNCHECKED):
            # unchecked { ... } - parse as a regular block (no overflow checks in TypeScript BigInt anyway)
            self.advance()  # skip 'unchecked'
            return self.parse_block()
        elif self.match(TokenType.TRY):
            return self.parse_try_statement()
        elif self.match(TokenType.ASSEMBLY):
            return self.parse_assembly_statement()
        elif self.match(TokenType.DELETE):
            return self.parse_delete_statement()
        elif self.is_variable_declaration():
            return self.parse_variable_declaration_statement()
        else:
            return self.parse_expression_statement()

    def is_variable_declaration(self) -> bool:
        """Check if current position starts a variable declaration."""
        # Save position
        saved_pos = self.pos

        try:
            # Check for tuple declaration: (type name, type name) = ... or (, , type name, ...) = ...
            if self.match(TokenType.LPAREN):
                self.advance()  # skip (
                # Skip leading commas (skipped elements)
                while self.match(TokenType.COMMA):
                    self.advance()
                # If we hit RPAREN, it's empty tuple - not a declaration
                if self.match(TokenType.RPAREN):
                    return False
                # Check if first non-skipped item is a type followed by storage location and identifier
                if self.match(TokenType.IDENTIFIER, TokenType.UINT, TokenType.INT,
                             TokenType.BOOL, TokenType.ADDRESS, TokenType.BYTES,
                             TokenType.STRING, TokenType.BYTES32):
                    self.advance()  # type name
                    # Skip qualified names (Library.StructName)
                    while self.match(TokenType.DOT):
                        self.advance()
                        if self.match(TokenType.IDENTIFIER):
                            self.advance()
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

            # Skip qualified names (Library.StructName, Contract.EnumName, etc.)
            while self.match(TokenType.DOT):
                self.advance()  # skip dot
                if self.match(TokenType.IDENTIFIER):
                    self.advance()  # skip member name

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
                # If next token is ), this is a trailing comma - add None for skipped element
                if self.match(TokenType.RPAREN):
                    declarations.append(None)

        self.expect(TokenType.RPAREN)
        self.expect(TokenType.EQ)
        initial_value = self.parse_expression()
        self.expect(TokenType.SEMICOLON)

        # Keep the declarations list as-is (including None for skipped elements)
        # to preserve tuple structure for destructuring
        return VariableDeclarationStatement(
            declarations=declarations,
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

    def parse_try_statement(self) -> Block:
        """Parse try/catch statement - skip the entire construct and return empty block."""
        self.expect(TokenType.TRY)

        # Skip until we find the opening brace of the try block
        while not self.match(TokenType.LBRACE, TokenType.EOF):
            self.advance()

        # Skip the try block
        if self.match(TokenType.LBRACE):
            depth = 1
            self.advance()
            while depth > 0 and not self.match(TokenType.EOF):
                if self.match(TokenType.LBRACE):
                    depth += 1
                elif self.match(TokenType.RBRACE):
                    depth -= 1
                self.advance()

        # Skip catch clauses
        while self.match(TokenType.CATCH):
            self.advance()  # skip 'catch'
            # Skip catch parameters like Error(string memory reason)
            while not self.match(TokenType.LBRACE, TokenType.EOF):
                self.advance()
            # Skip catch block
            if self.match(TokenType.LBRACE):
                depth = 1
                self.advance()
                while depth > 0 and not self.match(TokenType.EOF):
                    if self.match(TokenType.LBRACE):
                        depth += 1
                    elif self.match(TokenType.RBRACE):
                        depth -= 1
                    self.advance()

        # Return empty block
        return Block(statements=[])

    def parse_delete_statement(self) -> DeleteStatement:
        self.expect(TokenType.DELETE)
        expression = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return DeleteStatement(expression=expression)

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

        # Array literal: [expr, expr, ...]
        if self.match(TokenType.LBRACKET):
            self.advance()  # skip [
            elements = []
            while not self.match(TokenType.RBRACKET, TokenType.EOF):
                elements.append(self.parse_expression())
                if self.match(TokenType.COMMA):
                    self.advance()
            self.expect(TokenType.RBRACKET)
            return ArrayLiteral(elements=elements)

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
# TYPE REGISTRY
# =============================================================================

class TypeRegistry:
    """Registry of discovered types from Solidity source files.

    Performs a first pass over Solidity files to discover:
    - Structs
    - Enums
    - Constants
    - Interfaces
    - Contracts (with their methods and state variables)
    - Libraries
    """

    def __init__(self):
        self.structs: Set[str] = set()
        self.enums: Set[str] = set()
        self.constants: Set[str] = set()
        self.interfaces: Set[str] = set()
        self.contracts: Set[str] = set()
        self.libraries: Set[str] = set()
        self.contract_methods: Dict[str, Set[str]] = {}
        self.contract_vars: Dict[str, Set[str]] = {}
        self.known_public_state_vars: Set[str] = set()  # Public state vars that generate getters
        # Method return types: contract_name -> {method_name -> return_type}
        self.method_return_types: Dict[str, Dict[str, str]] = {}
        # Contract paths: contract_name -> relative path (without extension)
        self.contract_paths: Dict[str, str] = {}
        # Contract-local structs: contract_name -> set of struct names defined in that contract
        self.contract_structs: Dict[str, Set[str]] = {}
        # Contract base classes: contract_name -> list of base contract names
        self.contract_bases: Dict[str, List[str]] = {}
        # Struct paths: struct_name -> relative path (without extension) for top-level structs
        self.struct_paths: Dict[str, str] = {}
        # Struct field types: struct_name -> {field_name -> field_type_name}
        self.struct_fields: Dict[str, Dict[str, str]] = {}

    def discover_from_source(self, source: str, rel_path: Optional[str] = None) -> None:
        """Discover types from a single Solidity source string."""
        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        self.discover_from_ast(ast, rel_path)

    def discover_from_file(self, filepath: str, rel_path: Optional[str] = None) -> None:
        """Discover types from a Solidity file."""
        with open(filepath, 'r') as f:
            source = f.read()
        self.discover_from_source(source, rel_path)

    def discover_from_directory(self, directory: str, pattern: str = '**/*.sol') -> None:
        """Discover types from all Solidity files in a directory."""
        from pathlib import Path
        base_dir = Path(directory)
        for sol_file in base_dir.glob(pattern):
            try:
                # Calculate relative path from the directory root (without extension)
                rel_path = sol_file.relative_to(base_dir).with_suffix('')
                self.discover_from_file(str(sol_file), str(rel_path))
            except Exception as e:
                print(f"Warning: Could not parse {sol_file} for type discovery: {e}")

    def discover_from_ast(self, ast: SourceUnit, rel_path: Optional[str] = None) -> None:
        """Extract type information from a parsed AST."""
        # Top-level structs
        for struct in ast.structs:
            self.structs.add(struct.name)
            # Track where the struct is defined (for non-Structs files)
            if rel_path and rel_path != 'Structs':
                self.struct_paths[struct.name] = rel_path
            # Track struct field types for ABI type inference (type_name, is_array)
            self.struct_fields[struct.name] = {}
            for member in struct.members:
                if member.type_name:
                    is_array = getattr(member.type_name, 'is_array', False)
                    self.struct_fields[struct.name][member.name] = (member.type_name.name, is_array)

        # Top-level enums
        for enum in ast.enums:
            self.enums.add(enum.name)

        # Top-level constants
        for const in ast.constants:
            if const.mutability == 'constant':
                self.constants.add(const.name)

        # Contracts, interfaces, libraries
        for contract in ast.contracts:
            name = contract.name
            kind = contract.kind

            if kind == 'interface':
                self.interfaces.add(name)
            elif kind == 'library':
                self.libraries.add(name)
                self.contracts.add(name)
            else:
                self.contracts.add(name)

            # Track contract path if provided
            if rel_path:
                self.contract_paths[name] = rel_path

            # Track base contracts for inheritance resolution
            self.contract_bases[name] = contract.base_contracts or []

            # Collect structs defined inside contracts
            contract_local_structs: Set[str] = set()
            for struct in contract.structs:
                self.structs.add(struct.name)
                contract_local_structs.add(struct.name)
            self.contract_structs[name] = contract_local_structs

            # Collect enums defined inside contracts
            for enum in contract.enums:
                self.enums.add(enum.name)

            # Collect methods and their return types
            methods = set()
            return_types: Dict[str, str] = {}
            for func in contract.functions:
                if func.name:
                    methods.add(func.name)
                    # Store the return type for single-return functions
                    if func.return_parameters and len(func.return_parameters) == 1:
                        ret_type = func.return_parameters[0].type_name
                        if ret_type and ret_type.name:
                            return_types[func.name] = ret_type.name
            if contract.constructor:
                methods.add('constructor')
            if methods:
                self.contract_methods[name] = methods
            if return_types:
                self.method_return_types[name] = return_types

            # Collect state variables
            state_vars = set()
            for var in contract.state_variables:
                state_vars.add(var.name)
                if var.mutability == 'constant':
                    self.constants.add(var.name)
                # Track public state variables that generate getter functions
                if var.visibility == 'public' and var.mutability not in ('constant', 'immutable'):
                    self.known_public_state_vars.add(var.name)
            if state_vars:
                self.contract_vars[name] = state_vars

    def merge(self, other: 'TypeRegistry') -> None:
        """Merge another registry into this one."""
        self.structs.update(other.structs)
        self.enums.update(other.enums)
        self.constants.update(other.constants)
        self.interfaces.update(other.interfaces)
        self.contracts.update(other.contracts)
        self.libraries.update(other.libraries)
        for name, methods in other.contract_methods.items():
            if name in self.contract_methods:
                self.contract_methods[name].update(methods)
            else:
                self.contract_methods[name] = methods.copy()
        for name, vars in other.contract_vars.items():
            if name in self.contract_vars:
                self.contract_vars[name].update(vars)
            else:
                self.contract_vars[name] = vars.copy()
        self.known_public_state_vars.update(other.known_public_state_vars)
        for name, ret_types in other.method_return_types.items():
            if name in self.method_return_types:
                self.method_return_types[name].update(ret_types)
            else:
                self.method_return_types[name] = ret_types.copy()
        # Merge contract paths (don't overwrite existing entries)
        for name, path in other.contract_paths.items():
            if name not in self.contract_paths:
                self.contract_paths[name] = path
        # Merge contract-local structs
        for name, structs in other.contract_structs.items():
            if name in self.contract_structs:
                self.contract_structs[name].update(structs)
            else:
                self.contract_structs[name] = structs.copy()
        # Merge contract bases
        for name, bases in other.contract_bases.items():
            if name not in self.contract_bases:
                self.contract_bases[name] = bases.copy()
        # Merge struct field types
        for struct_name, fields in other.struct_fields.items():
            if struct_name in self.struct_fields:
                self.struct_fields[struct_name].update(fields)
            else:
                self.struct_fields[struct_name] = fields.copy()

    def get_inherited_structs(self, contract_name: str) -> Dict[str, str]:
        """Get structs inherited from base contracts.

        Returns a dict mapping struct_name -> defining_contract_name.
        """
        inherited: Dict[str, str] = {}
        bases = self.contract_bases.get(contract_name, [])
        for base in bases:
            # Add structs from this base
            if base in self.contract_structs:
                for struct_name in self.contract_structs[base]:
                    if struct_name not in inherited:
                        inherited[struct_name] = base
            # Recursively get structs from ancestors
            ancestor_structs = self.get_inherited_structs(base)
            for struct_name, defining_contract in ancestor_structs.items():
                if struct_name not in inherited:
                    inherited[struct_name] = defining_contract
        return inherited

    def get_all_inherited_vars(self, contract_name: str) -> Set[str]:
        """Get all state variables inherited from base contracts (transitively)."""
        inherited: Set[str] = set()
        bases = self.contract_bases.get(contract_name, [])
        for base in bases:
            # Add vars from this base
            if base in self.contract_vars:
                inherited.update(self.contract_vars[base])
            # Recursively get vars from ancestors
            inherited.update(self.get_all_inherited_vars(base))
        return inherited

    def get_all_inherited_methods(self, contract_name: str, exclude_interfaces: bool = True) -> Set[str]:
        """Get all methods inherited from base contracts (transitively).

        Args:
            contract_name: The contract to get inherited methods for
            exclude_interfaces: If True, skip interfaces (starting with 'I' and uppercase)
                              This is important for TypeScript 'override' modifier which
                              only applies to class inheritance, not interface implementation.
        """
        inherited: Set[str] = set()
        bases = self.contract_bases.get(contract_name, [])
        for base in bases:
            # Skip interfaces if requested (for TypeScript override detection)
            if exclude_interfaces:
                is_interface = (base.startswith('I') and len(base) > 1 and base[1].isupper()) or base in self.interfaces
                if is_interface:
                    continue
            # Add methods from this base
            if base in self.contract_methods:
                inherited.update(self.contract_methods[base])
            # Recursively get methods from ancestors
            inherited.update(self.get_all_inherited_methods(base, exclude_interfaces))
        return inherited

    def build_qualified_name_cache(self, current_file_type: str = '') -> Dict[str, str]:
        """Build a cached lookup dictionary for qualified names.

        This optimization avoids repeated set lookups in get_qualified_name().
        Returns a dict mapping name -> qualified name (with prefix if needed).
        """
        cache: Dict[str, str] = {}

        # Add structs with Structs. prefix (unless current file is Structs)
        # Skip structs defined in other files (they'll be imported directly)
        if current_file_type != 'Structs':
            for name in self.structs:
                # Only add Structs. prefix for structs in the main Structs file
                if name not in self.struct_paths:
                    cache[name] = f'Structs.{name}'
                # Structs in other files are accessed without prefix (imported directly)

        # Add enums with Enums. prefix (unless current file is Enums)
        if current_file_type != 'Enums':
            for name in self.enums:
                cache[name] = f'Enums.{name}'

        # Add constants with Constants. prefix (unless current file is Constants)
        if current_file_type != 'Constants':
            for name in self.constants:
                cache[name] = f'Constants.{name}'

        return cache


# =============================================================================
# CODE GENERATOR
# =============================================================================

class TypeScriptCodeGenerator:
    """Generates TypeScript code from the AST."""

    def __init__(self, registry: Optional[TypeRegistry] = None, file_depth: int = 0, current_file_path: str = '', runtime_replacement_classes: Optional[Set[str]] = None, runtime_replacement_mixins: Optional[Dict[str, str]] = None):
        self.indent_level = 0
        self.indent_str = '  '
        self.file_depth = file_depth  # Depth of output file for relative imports
        self.current_file_path = current_file_path  # Relative path of current file (without extension)
        # Track current contract context for this. prefix handling
        self.current_state_vars: Set[str] = set()
        self.current_static_vars: Set[str] = set()  # Static/constant state variables
        self.current_class_name: str = ''  # Current class name for static access
        self.current_base_classes: List[str] = []  # Current base classes for super() calls
        self.current_contract_kind: str = ''  # 'contract', 'library', 'abstract', 'interface'
        self.current_methods: Set[str] = set()
        self.current_local_vars: Set[str] = set()  # Local variables in current scope
        # Type registry: maps variable names to their TypeName for array/mapping detection
        self.var_types: Dict[str, 'TypeName'] = {}

        # Store the registry reference for later use
        self._registry = registry

        # Use provided registry or create empty one
        if registry:
            self.known_structs = registry.structs
            self.known_enums = registry.enums
            self.known_constants = registry.constants
            self.known_interfaces = registry.interfaces
            self.known_contracts = registry.contracts
            self.known_libraries = registry.libraries
            self.known_contract_methods = registry.contract_methods
            self.known_contract_vars = registry.contract_vars
            self.known_public_state_vars = registry.known_public_state_vars
            self.known_method_return_types = registry.method_return_types
            self.known_contract_paths = registry.contract_paths
            self.known_struct_fields = registry.struct_fields
        else:
            # Empty sets - types will be discovered as files are parsed
            self.known_structs: Set[str] = set()
            self.known_enums: Set[str] = set()
            self.known_constants: Set[str] = set()
            self.known_interfaces: Set[str] = set()
            self.known_contracts: Set[str] = set()
            self.known_libraries: Set[str] = set()
            self.known_contract_methods: Dict[str, Set[str]] = {}
            self.known_contract_vars: Dict[str, Set[str]] = {}
            self.known_public_state_vars: Set[str] = set()
            self.known_method_return_types: Dict[str, Dict[str, str]] = {}
            self.known_contract_paths: Dict[str, str] = {}
            self.known_struct_fields: Dict[str, Dict[str, str]] = {}

        # Base contracts needed for current file (for import generation)
        self.base_contracts_needed: Set[str] = set()
        # Library contracts referenced (for import generation)
        self.libraries_referenced: Set[str] = set()
        # Contracts referenced as types (for import generation)
        self.contracts_referenced: Set[str] = set()
        # EnumerableSetLib set types used (for runtime import)
        self.set_types_used: Set[str] = set()
        # External structs used (from files other than Structs.ts)
        self.external_structs_used: Dict[str, str] = {}  # struct_name -> relative_path
        # Current file type (to avoid self-referencing prefixes)
        self.current_file_type = ''

        # OPTIMIZATION: Cached qualified name lookup (built lazily per file)
        self._qualified_name_cache: Dict[str, str] = {}

        # Local structs defined in the current contract (should not get Structs. prefix)
        self.current_local_structs: Set[str] = set()
        # Inherited structs from base contracts: struct_name -> defining_contract_name
        self.current_inherited_structs: Dict[str, str] = {}
        # Flag to track when generating base constructor arguments (can't use 'this' before super())
        self._in_base_constructor_args: bool = False

        # Runtime replacement classes (should import from runtime instead of separate files)
        self.runtime_replacement_classes: Set[str] = runtime_replacement_classes or set()
        # Runtime replacement mixins (class name -> mixin code for secondary inheritance)
        self.runtime_replacement_mixins: Dict[str, str] = runtime_replacement_mixins or {}

    def indent(self) -> str:
        return self.indent_str * self.indent_level

    def get_qualified_name(self, name: str) -> str:
        """Get the qualified name for a type, adding appropriate prefix if needed.

        Handles Structs., Enums., Constants. prefixes based on the current file context.
        Uses cached lookup for performance optimization.
        """
        # OPTIMIZATION: Use cached lookup instead of repeated set membership checks
        return self._qualified_name_cache.get(name, name)

    def _to_padded_address(self, val: str) -> str:
        """Convert a numeric or hex value to a 40-char padded hex address string."""
        if val.startswith('0x') or val.startswith('0X'):
            hex_val = val[2:].lower()
        else:
            hex_val = hex(int(val))[2:]
        return f'"0x{hex_val.zfill(40)}"'

    def _to_padded_bytes32(self, val: str) -> str:
        """Convert a numeric or hex value to a 64-char padded hex bytes32 string."""
        if val == '0':
            return '"0x' + '0' * 64 + '"'
        elif val.startswith('0x') or val.startswith('0X'):
            hex_val = val[2:].lower()
            return f'"0x{hex_val.zfill(64)}"'
        else:
            hex_val = hex(int(val))[2:]
            return f'"0x{hex_val.zfill(64)}"'

    def generate(self, ast: SourceUnit) -> str:
        """Generate TypeScript code from the AST."""
        output = []

        # Reset base contracts needed for this file
        self.base_contracts_needed = set()
        self.libraries_referenced = set()
        self.contracts_referenced = set()
        self.set_types_used = set()
        self.external_structs_used = {}

        # Determine file type before generating (affects identifier prefixes)
        contract_name = ast.contracts[0].name if ast.contracts else ''
        if ast.enums and not ast.contracts:
            self.current_file_type = 'Enums'
        elif ast.structs and not ast.contracts:
            self.current_file_type = 'Structs'
        elif ast.constants and not ast.contracts and not ast.structs:
            self.current_file_type = 'Constants'
        else:
            self.current_file_type = contract_name

        # OPTIMIZATION: Build qualified name cache for this file
        if self._registry:
            self._qualified_name_cache = self._registry.build_qualified_name_cache(self.current_file_type)
        else:
            # Build cache manually from current sets
            self._qualified_name_cache = {}
            if self.current_file_type != 'Structs':
                for name in self.known_structs:
                    self._qualified_name_cache[name] = f'Structs.{name}'
            if self.current_file_type != 'Enums':
                for name in self.known_enums:
                    self._qualified_name_cache[name] = f'Enums.{name}'
            if self.current_file_type != 'Constants':
                for name in self.known_constants:
                    self._qualified_name_cache[name] = f'Constants.{name}'

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
        import_lines = self.generate_imports(self.current_file_type)
        output[import_placeholder_index] = import_lines

        return '\n'.join(output)

    def _get_relative_import_path(self, target_contract: str) -> str:
        """Compute the relative import path from current file to target contract."""
        # Get the target contract's path from the registry
        target_path = self.known_contract_paths.get(target_contract)

        if not target_path or not self.current_file_path:
            # Fallback to simple prefix + name if paths not available
            prefix = '../' * self.file_depth if self.file_depth > 0 else './'
            return f'{prefix}{target_contract}'

        # Compute relative path from current file's directory to target
        from pathlib import PurePosixPath
        current_dir = PurePosixPath(self.current_file_path).parent
        target = PurePosixPath(target_path)

        # Calculate relative path
        try:
            # Find common prefix and compute relative path
            current_parts = current_dir.parts if str(current_dir) != '.' else ()
            target_parts = target.parts

            # Find common prefix length
            common_len = 0
            for i, (c, t) in enumerate(zip(current_parts, target_parts)):
                if c == t:
                    common_len = i + 1
                else:
                    break

            # Go up from current dir, then down to target
            ups = len(current_parts) - common_len
            downs = target_parts[common_len:]

            if ups == 0 and not downs:
                # Same directory
                return f'./{target.name}'
            elif ups == 0:
                return './' + '/'.join(downs)
            else:
                return '../' * ups + '/'.join(downs)
        except Exception:
            # Fallback
            prefix = '../' * self.file_depth if self.file_depth > 0 else './'
            return f'{prefix}{target_contract}'

    def generate_imports(self, contract_name: str = '') -> str:
        """Generate import statements."""
        # Compute relative import prefix based on file depth (for root-level files)
        prefix = '../' * self.file_depth if self.file_depth > 0 else './'

        lines = []
        lines.append("import { keccak256, encodePacked, encodeAbiParameters, decodeAbiParameters, parseAbiParameters } from 'viem';")
        # Build runtime import with optional set types
        runtime_imports = ['Contract', 'Storage', 'ADDRESS_ZERO', 'sha256', 'sha256String', 'addressToUint', 'blockhash']
        if self.set_types_used:
            runtime_imports.extend(sorted(self.set_types_used))
        # Add runtime replacement classes that are needed as base contracts
        for base_contract in sorted(self.base_contracts_needed):
            if base_contract in self.runtime_replacement_classes:
                runtime_imports.append(base_contract)
        lines.append(f"import {{ {', '.join(runtime_imports)} }} from '{prefix}runtime';")

        # Import base contracts needed for inheritance (skip runtime replacements)
        for base_contract in sorted(self.base_contracts_needed):
            if base_contract in self.runtime_replacement_classes:
                continue  # Already imported from runtime
            import_path = self._get_relative_import_path(base_contract)
            lines.append(f"import {{ {base_contract} }} from '{import_path}';")

        # Import library contracts that are referenced (skip runtime replacements - already imported)
        for library in sorted(self.libraries_referenced):
            if library in self.runtime_replacement_classes:
                # Add to runtime imports if not already there
                if library not in runtime_imports:
                    # Need to update the runtime import line
                    for i, line in enumerate(lines):
                        if "from '" in line and "runtime'" in line:
                            # Parse existing imports and add the library
                            import_match = line.split('{')[1].split('}')[0]
                            existing = [x.strip() for x in import_match.split(',')]
                            if library not in existing:
                                existing.append(library)
                                lines[i] = f"import {{ {', '.join(existing)} }} from '{prefix}runtime';"
                            break
                continue
            import_path = self._get_relative_import_path(library)
            lines.append(f"import {{ {library} }} from '{import_path}';")

        # Import contracts that are used as types (e.g., in constructor params or state vars)
        for contract in sorted(self.contracts_referenced):
            # Skip if already imported as base contract or if it's the current contract
            if contract not in self.base_contracts_needed and contract != contract_name:
                import_path = self._get_relative_import_path(contract)
                lines.append(f"import {{ {contract} }} from '{import_path}';")

        # Import inherited structs from their defining contracts
        # Group by defining contract to generate compact imports
        if self.current_inherited_structs:
            structs_by_contract: Dict[str, List[str]] = {}
            for struct_name, defining_contract in self.current_inherited_structs.items():
                if defining_contract not in structs_by_contract:
                    structs_by_contract[defining_contract] = []
                structs_by_contract[defining_contract].append(struct_name)
            for defining_contract, struct_names in sorted(structs_by_contract.items()):
                # Skip if this is the current contract or already imported as base
                if defining_contract != contract_name:
                    import_path = self._get_relative_import_path(defining_contract)
                    # Check if the base contract is already imported (we can extend the import)
                    if defining_contract in self.base_contracts_needed:
                        # Find and extend the existing import line
                        for i, line in enumerate(lines):
                            if f"from '{import_path}'" in line and f"import {{ {defining_contract} }}" in line:
                                # Extend with struct imports
                                structs_str = ', '.join(sorted(struct_names))
                                lines[i] = f"import {{ {defining_contract}, {structs_str} }} from '{import_path}';"
                                break
                    else:
                        # Create new import for structs only
                        structs_str = ', '.join(sorted(struct_names))
                        lines.append(f"import {{ {structs_str} }} from '{import_path}';")

        # Import external structs (from files other than Structs.ts)
        if self.external_structs_used:
            # Group by source file
            structs_by_file: Dict[str, List[str]] = {}
            for struct_name, rel_path in self.external_structs_used.items():
                if rel_path not in structs_by_file:
                    structs_by_file[rel_path] = []
                structs_by_file[rel_path].append(struct_name)
            for rel_path, struct_names in sorted(structs_by_file.items()):
                # Skip if this is the current file
                if rel_path != self.current_file_path:
                    import_path = f"{prefix}{rel_path}"
                    structs_str = ', '.join(sorted(struct_names))
                    lines.append(f"import {{ {structs_str} }} from '{import_path}';")

        # Import types based on current file type:
        # - Enums.ts: no imports needed from other modules
        # - Structs.ts: needs Enums (for Type, etc.) but not itself
        # - Constants.ts: may need Enums and Structs
        # - Other files: import all three
        if contract_name == 'Enums':
            pass  # Enums doesn't need to import anything
        elif contract_name == 'Structs':
            lines.append(f"import * as Enums from '{prefix}Enums';")
        elif contract_name == 'Constants':
            lines.append(f"import * as Structs from '{prefix}Structs';")
            lines.append(f"import * as Enums from '{prefix}Enums';")
        elif contract_name:
            lines.append(f"import * as Structs from '{prefix}Structs';")
            lines.append(f"import * as Enums from '{prefix}Enums';")
            lines.append(f"import * as Constants from '{prefix}Constants';")

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
        """Generate TypeScript interface for struct and a factory function for default initialization."""
        lines = []
        lines.append(f'export interface {struct.name} {{')
        for member in struct.members:
            ts_type = self.solidity_type_to_ts(member.type_name)
            lines.append(f'  {member.name}: {ts_type};')
        lines.append('}\n')

        # Generate factory function for creating default-initialized struct
        # This is needed because in Solidity, reading from a mapping returns a zero-initialized struct
        lines.append(f'export function createDefault{struct.name}(): {struct.name} {{')
        lines.append('  return {')
        for member in struct.members:
            ts_type = self.solidity_type_to_ts(member.type_name)
            default_val = self._get_struct_field_default(ts_type, member.type_name)
            lines.append(f'    {member.name}: {default_val},')
        lines.append('  };')
        lines.append('}\n')
        return '\n'.join(lines)

    def _get_struct_field_default(self, ts_type: str, solidity_type: Optional['TypeName'] = None) -> str:
        """Get the default value for a struct field based on its TypeScript type."""
        if ts_type == 'bigint':
            return '0n'
        elif ts_type == 'boolean':
            return 'false'
        elif ts_type == 'string':
            # Check if this is a bytes32 or address type
            if solidity_type and solidity_type.name:
                sol_type_name = solidity_type.name.lower()
                if 'bytes32' in sol_type_name or sol_type_name == 'bytes32':
                    return '"0x0000000000000000000000000000000000000000000000000000000000000000"'
                elif 'address' in sol_type_name or sol_type_name == 'address':
                    return '"0x0000000000000000000000000000000000000000"'
            return '""'
        elif ts_type == 'number':
            return '0'
        elif ts_type.endswith('[]'):
            return '[]'
        elif ts_type.startswith('Record<'):
            return '{}'
        elif ts_type.startswith('Structs.'):
            # Nested struct with Structs. prefix - call its factory function
            struct_name = ts_type[8:]  # Remove 'Structs.' prefix
            return f'createDefault{struct_name}()'
        elif ts_type.startswith('Enums.'):
            # Enum - default to 0
            return '0'
        elif ts_type == 'any':
            return 'undefined as any'
        elif ts_type in self.known_structs:
            # Unqualified struct name (used when inside Structs file)
            return f'createDefault{ts_type}()'
        else:
            # Unknown type
            return 'undefined as any'

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

        # Track this contract as known for future inheritance
        self.known_contracts.add(contract.name)
        self.current_class_name = contract.name
        self.current_contract_kind = contract.kind

        # Track local structs defined in this contract (shouldn't get Structs. prefix)
        self.current_local_structs = {struct.name for struct in contract.structs}
        # Remove local structs from qualified name cache so they don't get Structs. prefix
        for struct_name in self.current_local_structs:
            if struct_name in self._qualified_name_cache:
                del self._qualified_name_cache[struct_name]

        # Track inherited structs from base contracts
        self.current_inherited_structs = {}
        if self._registry:
            self.current_inherited_structs = self._registry.get_inherited_structs(contract.name)
            # Remove inherited structs from qualified name cache so they don't get Structs. prefix
            # These will be imported from their defining contract
            for struct_name in self.current_inherited_structs:
                if struct_name in self._qualified_name_cache:
                    del self._qualified_name_cache[struct_name]

        # Collect state variable and method names for this. prefix handling
        self.current_state_vars = {var.name for var in contract.state_variables
                                   if var.mutability != 'constant'}
        self.current_static_vars = {var.name for var in contract.state_variables
                                    if var.mutability == 'constant'}
        self.current_methods = {func.name for func in contract.functions}
        # Track inherited methods separately for override detection
        # (TypeScript override only applies to methods from base classes, not interfaces)
        self.inherited_methods: Set[str] = set()
        # Add runtime base class methods that need this. prefix
        self.current_methods.update({
            '_yulStorageKey', '_storageRead', '_storageWrite', '_emitEvent',
        })
        self.current_local_vars = set()
        # Populate type registry with state variable types
        self.var_types = {var.name: var.type_name for var in contract.state_variables}
        # Build current method return types from functions in this contract
        self.current_method_return_types: Dict[str, str] = {}
        for func in contract.functions:
            if func.name and func.return_parameters and len(func.return_parameters) == 1:
                ret_type = func.return_parameters[0].type_name
                if ret_type and ret_type.name:
                    self.current_method_return_types[func.name] = ret_type.name

        # Determine the extends clause based on base_contracts
        # TypeScript only supports single inheritance, but we need to handle Solidity's
        # multiple inheritance by importing ALL base contracts and merging their methods.
        extends = ''
        self.current_base_classes = []  # Reset for this contract
        if contract.base_contracts:
            # Filter to known contracts (skip interfaces which are handled differently)
            base_classes = [bc for bc in contract.base_contracts
                           if bc not in self.known_interfaces]
            if base_classes:
                # Use the first non-interface base contract for TypeScript extends
                primary_base = base_classes[0]
                extends = f' extends {primary_base}'
                self.current_base_classes = base_classes

                # Import ALL base contracts (for multiple inheritance support)
                for base_class in base_classes:
                    self.base_contracts_needed.add(base_class)

                # Use transitive inheritance to get ALL inherited methods and state vars
                # This ensures grandparent classes are also included
                if self._registry:
                    inherited = self._registry.get_all_inherited_methods(contract.name)
                    self.current_methods.update(inherited)
                    self.inherited_methods.update(inherited)
                    self.current_state_vars.update(self._registry.get_all_inherited_vars(contract.name))
                else:
                    # Fallback to direct base class lookup if no registry
                    for base_class in base_classes:
                        if base_class in self.known_contract_methods:
                            self.current_methods.update(self.known_contract_methods[base_class])
                            self.inherited_methods.update(self.known_contract_methods[base_class])
                        if base_class in self.known_contract_vars:
                            self.current_state_vars.update(self.known_contract_vars[base_class])

                # Add method return types from ALL base classes for ABI encoding inference
                for base_class in base_classes:
                    if base_class in self.known_method_return_types:
                        for method, ret_type in self.known_method_return_types[base_class].items():
                            if method not in self.current_method_return_types:
                                self.current_method_return_types[method] = ret_type
            else:
                extends = ' extends Contract'
                self.current_base_classes = ['Contract']  # Ensure super() is called
        else:
            extends = ' extends Contract'
            self.current_base_classes = ['Contract']  # Ensure super() is called

        abstract = 'abstract ' if contract.kind == 'abstract' else ''
        lines.append(f'export {abstract}class {contract.name}{extends} {{')
        self.indent_level += 1

        # State variables
        for var in contract.state_variables:
            lines.append(self.generate_state_variable(var))

        # Constructor
        if contract.constructor:
            lines.append(self.generate_constructor(contract.constructor))

        # Group functions by name to handle overloads
        from collections import defaultdict
        function_groups: Dict[str, List[FunctionDefinition]] = defaultdict(list)
        for func in contract.functions:
            function_groups[func.name].append(func)

        # Generate functions, merging overloads
        for func_name, funcs in function_groups.items():
            if len(funcs) == 1:
                lines.append(self.generate_function(funcs[0]))
            else:
                # Multiple functions with same name - merge into one with optional params
                lines.append(self.generate_overloaded_function(funcs))

        # Handle multiple inheritance with runtime replacement classes
        # If a runtime replacement class is in base classes but not the primary extends, add its mixin
        non_interface_bases = [bc for bc in contract.base_contracts if bc not in self.known_interfaces]
        actual_extends = non_interface_bases[0] if non_interface_bases else 'Contract'
        for base_class in contract.base_contracts:
            if base_class in self.runtime_replacement_mixins and base_class != actual_extends:
                # This is a secondary base class with a mixin defined - add the mixin code
                mixin_code = self.runtime_replacement_mixins[base_class]
                lines.append(mixin_code)

        self.indent_level -= 1
        lines.append('}\n')
        return '\n'.join(lines)

    def generate_state_variable(self, var: StateVariableDeclaration) -> str:
        """Generate state variable declaration."""
        ts_type = self.solidity_type_to_ts(var.type_name)
        modifier = ''
        property_modifier = ''

        if var.mutability == 'constant':
            modifier = 'static readonly '
        elif var.mutability == 'immutable':
            modifier = 'readonly '
        elif var.visibility == 'private':
            modifier = 'private '
            property_modifier = 'private '
        elif var.visibility == 'internal':
            modifier = 'protected '
            property_modifier = 'protected '
        # public variables stay with no modifier (public is default in TypeScript)

        if var.type_name.is_mapping:
            # Use Record (plain object) for mappings - allows [] access
            value_type = self.solidity_type_to_ts(var.type_name.value_type)
            # Nested mappings become nested Records
            if var.type_name.value_type.is_mapping:
                inner_value = self.solidity_type_to_ts(var.type_name.value_type.value_type)
                return f'{self.indent()}{modifier}{var.name}: Record<string, Record<string, {inner_value}>> = {{}};'
            return f'{self.indent()}{modifier}{var.name}: Record<string, {value_type}> = {{}};'

        # Handle bytes32 constants specially - they should be hex strings, not BigInt
        if var.type_name.name == 'bytes32' and var.initial_value:
            if isinstance(var.initial_value, Literal) and var.initial_value.kind == 'hex':
                hex_val = var.initial_value.value
                # Ensure 64-character hex string (32 bytes)
                if hex_val.startswith('0x'):
                    hex_val = hex_val[2:]
                hex_val = hex_val.zfill(64)
                return f'{self.indent()}{modifier}{var.name}: {ts_type} = "0x{hex_val}";'

        default_val = self.generate_expression(var.initial_value) if var.initial_value else self.default_value(ts_type)
        return f'{self.indent()}{modifier}{var.name}: {ts_type} = {default_val};'

    def generate_constructor(self, func: FunctionDefinition) -> str:
        """Generate constructor."""
        lines = []

        # Track constructor parameters as local variables (to avoid this. prefix)
        self.current_local_vars = set()
        for p in func.parameters:
            if p.name:
                self.current_local_vars.add(p.name)
                if p.type_name:
                    self.var_types[p.name] = p.type_name

        # Make constructor parameters optional for known base classes
        # This allows derived classes to call super() without arguments
        is_base_class = self.current_class_name in self.known_contract_methods
        optional_suffix = '?' if is_base_class else ''

        params = ', '.join([
            f'{p.name}{optional_suffix}: {self.solidity_type_to_ts(p.type_name)}'
            for p in func.parameters
        ])
        lines.append(f'{self.indent()}constructor({params}) {{')
        self.indent_level += 1

        # Add super() call for derived classes - must be first statement
        if self.current_base_classes:
            # Check if there are base constructor calls with arguments
            if func.base_constructor_calls:
                # Find the base constructor call that matches one of our base classes
                for base_call in func.base_constructor_calls:
                    if base_call.base_name in self.current_base_classes:
                        if base_call.arguments:
                            # Set flag to avoid 'this' references in base constructor args
                            self._in_base_constructor_args = True
                            args = ', '.join([
                                self.generate_expression(arg)
                                for arg in base_call.arguments
                            ])
                            self._in_base_constructor_args = False
                            lines.append(f'{self.indent()}super({args});')
                        else:
                            lines.append(f'{self.indent()}super();')
                        break
                else:
                    # No matching base constructor call found
                    lines.append(f'{self.indent()}super();')
            else:
                lines.append(f'{self.indent()}super();')

        if func.body:
            # For base classes with optional params, wrap body in conditional
            if is_base_class and func.parameters:
                # Get first param name for the condition
                first_param = func.parameters[0].name
                lines.append(f'{self.indent()}if ({first_param} !== undefined) {{')
                self.indent_level += 1
                for stmt in func.body.statements:
                    lines.append(self.generate_statement(stmt))
                self.indent_level -= 1
                lines.append(f'{self.indent()}}}')
            else:
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

        # Track local variables for this function (start with parameters)
        self.current_local_vars = set()
        for i, p in enumerate(func.parameters):
            param_name = p.name if p.name else f'_arg{i}'
            self.current_local_vars.add(param_name)
            # Also track parameter types
            if p.type_name:
                self.var_types[param_name] = p.type_name
        # Also add return parameter names as local vars
        for r in func.return_parameters:
            if r.name:
                self.current_local_vars.add(r.name)
                if r.type_name:
                    self.var_types[r.name] = r.type_name

        params = ', '.join([
            f'{self.generate_param_name(p, i)}: {self.solidity_type_to_ts(p.type_name)}'
            for i, p in enumerate(func.parameters)
        ])
        return_type = self.generate_return_type(func.return_parameters)

        visibility = ''
        static_prefix = ''
        # Library functions should be static
        if self.current_contract_kind == 'library':
            static_prefix = 'static '

        if func.visibility == 'private':
            visibility = 'private '
        elif func.visibility == 'internal':
            visibility = 'protected ' if self.current_contract_kind != 'library' else ''

        # Add override modifier only if:
        # 1. The Solidity function has override keyword AND
        # 2. The method actually exists in an inherited base class (not just interfaces)
        # This is because TypeScript's 'override' only applies to class inheritance,
        # not interface implementation
        should_override = func.is_override and func.name in self.inherited_methods
        override_prefix = 'override ' if should_override else ''

        lines.append(f'{self.indent()}{visibility}{static_prefix}{override_prefix}{func.name}({params}): {return_type} {{')
        self.indent_level += 1

        # Declare named return parameters at start of function
        named_return_vars = []
        for r in func.return_parameters:
            if r.name:
                ts_type = self.solidity_type_to_ts(r.type_name)
                default_val = self.default_value(ts_type)
                lines.append(f'{self.indent()}let {r.name}: {ts_type} = {default_val};')
                named_return_vars.append(r.name)

        if func.body:
            for stmt in func.body.statements:
                lines.append(self.generate_statement(stmt))

        # Add implicit return for named return parameters
        if named_return_vars and func.body:
            # Check if all code paths have explicit returns
            has_all_paths_return = self._all_paths_return(func.body.statements)
            if not has_all_paths_return:
                if len(named_return_vars) == 1:
                    lines.append(f'{self.indent()}return {named_return_vars[0]};')
                else:
                    lines.append(f'{self.indent()}return [{", ".join(named_return_vars)}];')

        # Handle virtual functions with no body
        if not func.body or (func.body and not func.body.statements):
            if named_return_vars:
                # Return the default-initialized named return values
                if len(named_return_vars) == 1:
                    lines.append(f'{self.indent()}return {named_return_vars[0]};')
                else:
                    lines.append(f'{self.indent()}return [{", ".join(named_return_vars)}];')
            elif return_type != 'void':
                # No named return vars but non-void return type - add throw
                lines.append(f'{self.indent()}throw new Error("Not implemented");')

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')

        # Clear local vars after function
        self.current_local_vars = set()
        return '\n'.join(lines)

    def _all_paths_return(self, statements: List[Statement]) -> bool:
        """Check if all code paths through a list of statements end with a return.

        This handles simple cases like:
        - Last statement is a return
        - Last statement is if/else where both branches return
        """
        if not statements:
            return False

        last_stmt = statements[-1]

        # Direct return statement
        if isinstance(last_stmt, ReturnStatement):
            return True

        # If/else where both branches return
        if isinstance(last_stmt, IfStatement):
            # Must have an else branch
            if last_stmt.false_body is None:
                return False

            # Check true branch
            if isinstance(last_stmt.true_body, Block):
                true_returns = self._all_paths_return(last_stmt.true_body.statements)
            elif isinstance(last_stmt.true_body, ReturnStatement):
                true_returns = True
            else:
                true_returns = False

            # Check false branch
            if isinstance(last_stmt.false_body, Block):
                false_returns = self._all_paths_return(last_stmt.false_body.statements)
            elif isinstance(last_stmt.false_body, ReturnStatement):
                false_returns = True
            elif isinstance(last_stmt.false_body, IfStatement):
                # Nested if/else (else if chain)
                false_returns = self._all_paths_return([last_stmt.false_body])
            else:
                false_returns = False

            return true_returns and false_returns

        return False

    def generate_overloaded_function(self, funcs: List[FunctionDefinition]) -> str:
        """Generate a single function from multiple overloaded functions.

        Combines overloaded Solidity functions into a single TypeScript function
        with optional parameters.
        """
        # Sort by parameter count - use function with most params as base
        funcs_sorted = sorted(funcs, key=lambda f: len(f.parameters), reverse=True)
        main_func = funcs_sorted[0]
        shorter_funcs = funcs_sorted[1:]

        lines = []

        # Track local variables
        self.current_local_vars = set()
        for i, p in enumerate(main_func.parameters):
            param_name = p.name if p.name else f'_arg{i}'
            self.current_local_vars.add(param_name)
            if p.type_name:
                self.var_types[param_name] = p.type_name
        for r in main_func.return_parameters:
            if r.name:
                self.current_local_vars.add(r.name)
                if r.type_name:
                    self.var_types[r.name] = r.type_name

        # Find which parameters are optional (not present in shorter overloads)
        min_param_count = min(len(f.parameters) for f in funcs)

        # Generate parameters - mark extras as optional
        param_strs = []
        for i, p in enumerate(main_func.parameters):
            param_name = self.generate_param_name(p, i)
            param_type = self.solidity_type_to_ts(p.type_name)
            if i >= min_param_count:
                param_strs.append(f'{param_name}?: {param_type}')
            else:
                param_strs.append(f'{param_name}: {param_type}')

        return_type = self.generate_return_type(main_func.return_parameters)

        visibility = ''
        if main_func.visibility == 'private':
            visibility = 'private '
        elif main_func.visibility == 'internal':
            visibility = 'protected '

        # Check if any variant is an override AND the method exists in an inherited base class
        is_override = any(f.is_override for f in funcs) and main_func.name in self.inherited_methods
        override_prefix = 'override ' if is_override else ''

        lines.append(f'{self.indent()}{visibility}{override_prefix}{main_func.name}({", ".join(param_strs)}): {return_type} {{')
        self.indent_level += 1

        # Declare named return parameters
        named_return_vars = []
        for r in main_func.return_parameters:
            if r.name:
                ts_type = self.solidity_type_to_ts(r.type_name)
                default_val = self.default_value(ts_type)
                lines.append(f'{self.indent()}let {r.name}: {ts_type} = {default_val};')
                named_return_vars.append(r.name)

        # Generate body - use main function's body but handle optional param case
        # If there's a shorter overload, we might need to compute default values
        if shorter_funcs and main_func.body:
            # Check if shorter func computes missing param from existing ones
            shorter = shorter_funcs[0]
            if len(shorter.parameters) < len(main_func.parameters):
                # The shorter function likely computes the missing param
                # Generate conditional: if param is undefined, compute it
                for i in range(len(shorter.parameters), len(main_func.parameters)):
                    extra_param = main_func.parameters[i]
                    extra_name = extra_param.name if extra_param.name else f'_arg{i}'

                    # Try to find how shorter func gets this value from its body
                    # For now, just use a simple pattern: call a getter method
                    # This is a heuristic - the shorter overload often calls a method
                    if shorter.body and shorter.body.statements:
                        for stmt in shorter.body.statements:
                            if isinstance(stmt, VariableDeclarationStatement):
                                for decl in stmt.declarations:
                                    if decl and decl.name == extra_name:
                                        # Found where shorter func declares this var
                                        init_expr = self.generate_expression(stmt.initial_value) if stmt.initial_value else 'undefined'
                                        lines.append(f'{self.indent()}if ({extra_name} === undefined) {{')
                                        lines.append(f'{self.indent()}  {extra_name} = {init_expr};')
                                        lines.append(f'{self.indent()}}}')
                                        break

            # Now generate the main body
            for stmt in main_func.body.statements:
                lines.append(self.generate_statement(stmt))

        elif main_func.body:
            for stmt in main_func.body.statements:
                lines.append(self.generate_statement(stmt))

        # Add implicit return for named return parameters
        if named_return_vars and main_func.body:
            has_explicit_return = False
            if main_func.body.statements:
                last_stmt = main_func.body.statements[-1]
                has_explicit_return = isinstance(last_stmt, ReturnStatement)
            if not has_explicit_return:
                if len(named_return_vars) == 1:
                    lines.append(f'{self.indent()}return {named_return_vars[0]};')
                else:
                    lines.append(f'{self.indent()}return [{", ".join(named_return_vars)}];')

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')

        self.current_local_vars = set()
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
        elif isinstance(stmt, DeleteStatement):
            return self.generate_delete_statement(stmt)
        elif isinstance(stmt, AssemblyStatement):
            return self.generate_assembly_statement(stmt)
        elif isinstance(stmt, ExpressionStatement):
            return self._generate_expression_statement(stmt)
        return f'{self.indent()}// Unknown statement'

    def _generate_expression_statement(self, stmt: ExpressionStatement) -> str:
        """Generate expression statement with special handling for nested mapping assignments."""
        expr = stmt.expression

        # Check if this is an assignment to a mapping
        if isinstance(expr, BinaryOperation) and expr.operator in ('=', '+=', '-=', '*=', '/='):
            left = expr.left

            # Check for nested IndexAccess on left side (mapping[key1][key2] = value)
            if isinstance(left, IndexAccess) and isinstance(left.base, IndexAccess):
                # This is a nested mapping access like mapping[a][b] = value
                # Generate initialization for intermediate mapping
                init_lines = self._generate_nested_mapping_init(left.base)
                main_expr = f'{self.indent()}{self.generate_expression(expr)};'
                if init_lines:
                    return init_lines + '\n' + main_expr
                return main_expr

            # Check for compound assignment on simple mapping (mapping[key] += value)
            if isinstance(left, IndexAccess) and expr.operator in ('+=', '-=', '*=', '/='):
                # Need to initialize the value to default before compound operation
                left_expr = self.generate_expression(left)
                # Determine default value based on likely type (bigint for most cases)
                init_line = f'{self.indent()}{left_expr} ??= 0n;'
                main_expr = f'{self.indent()}{self.generate_expression(expr)};'
                return init_line + '\n' + main_expr

        return f'{self.indent()}{self.generate_expression(expr)};'

    def _generate_nested_mapping_init(self, access: IndexAccess) -> str:
        """Generate initialization for nested mapping intermediate keys.

        For mapping[a][b] access, this generates: mapping[a] ??= {};
        For mapping[a][b] where value is array, this generates: mapping[a] ??= [];
        For arrays, no initialization is needed (they're pre-allocated).
        """
        lines = []

        # Check if this is actually a mapping (not an array)
        base_var_name = self._get_base_var_name(access)
        if base_var_name and base_var_name in self.var_types:
            type_info = self.var_types[base_var_name]
            # Skip initialization for arrays - they're already allocated
            if type_info and not type_info.is_mapping:
                return ''

        # Generate the base access (mapping[a])
        base_expr = self.generate_expression(access)

        # Recursively handle deeper nesting
        if isinstance(access.base, IndexAccess):
            deeper_init = self._generate_nested_mapping_init(access.base)
            if deeper_init:
                lines.append(deeper_init)

        # Determine the correct initialization value based on the value type
        init_value = self._get_mapping_init_value(access)
        lines.append(f'{self.indent()}{base_expr} ??= {init_value};')

        return '\n'.join(lines)

    def _get_mapping_init_value(self, access: IndexAccess) -> str:
        """Determine the initialization value for a mapping access.

        Returns '[]' if the value type is an array, '{}' otherwise.
        """
        # Get the base variable name to look up its type
        base_var_name = self._get_base_var_name(access.base)
        if not base_var_name or base_var_name not in self.var_types:
            return '{}'

        type_info = self.var_types[base_var_name]
        if not type_info or not type_info.is_mapping:
            return '{}'

        # Navigate through nested mappings to find the value type at this level
        # Count how many levels deep we are
        depth = 0
        current = access
        while isinstance(current.base, IndexAccess):
            depth += 1
            current = current.base

        # Navigate to the correct level in the type
        value_type = type_info.value_type
        for _ in range(depth):
            if value_type and value_type.is_mapping:
                value_type = value_type.value_type
            else:
                break

        # Check if the value type at this level is an array or another mapping
        if value_type:
            if value_type.is_array:
                return '[]'
            elif value_type.is_mapping:
                return '{}'

        return '{}'

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
        # Track declared variable names and types
        for decl in stmt.declarations:
            if decl and decl.name:
                self.current_local_vars.add(decl.name)
                if decl.type_name:
                    self.var_types[decl.name] = decl.type_name

        # Filter out None declarations for counting, but use original list for tuple structure
        non_none_decls = [d for d in stmt.declarations if d is not None]

        # If there's only one actual declaration and no None entries, use simple let
        if len(stmt.declarations) == 1 and stmt.declarations[0] is not None:
            decl = stmt.declarations[0]
            ts_type = self.solidity_type_to_ts(decl.type_name)
            if stmt.initial_value:
                # Check if this is a storage reference to a struct in a mapping
                # For storage structs, we need to initialize the mapping entry first,
                # then get a reference to it (so modifications persist)
                storage_init = self._get_storage_init_statement(decl, stmt.initial_value, ts_type)
                if storage_init:
                    return storage_init

                init_expr = self.generate_expression(stmt.initial_value)
                # Add default value for mapping reads (Solidity returns 0/false/etc for non-existent keys)
                init_expr = self._add_mapping_default(stmt.initial_value, ts_type, init_expr, decl.type_name)
                init = f' = {init_expr}'
            else:
                # In Solidity, uninitialized variables default to zero values
                # Initialize with default value to match Solidity semantics
                default_val = self._get_ts_default_value(ts_type, decl.type_name) or self.default_value(ts_type)
                init = f' = {default_val}'
            return f'{self.indent()}let {decl.name}: {ts_type}{init};'
        else:
            # Tuple declaration (including single value with trailing comma like (x,) = ...)
            names = ', '.join([d.name if d else '' for d in stmt.declarations])
            init = self.generate_expression(stmt.initial_value) if stmt.initial_value else ''
            return f'{self.indent()}const [{names}] = {init};'

    def _get_storage_init_statement(self, decl: 'VariableDeclaration', init_value: 'Expression', ts_type: str) -> Optional[str]:
        """Generate storage initialization for struct references from mappings.

        For Solidity 'storage' struct references from mappings, we need to:
        1. Initialize the mapping entry with ??= if it doesn't exist
        2. Return a reference to the entry (not a copy)

        This ensures modifications to the variable persist in the mapping.
        """
        # Only handle storage location structs
        if decl.storage_location != 'storage':
            return None

        # Only handle struct types (they start with Structs. or are known structs)
        if not (ts_type.startswith('Structs.') or ts_type in self.known_structs):
            return None

        # Check if init_value is a mapping access (IndexAccess)
        if not isinstance(init_value, IndexAccess):
            return None

        # Check if it's a mapping access on a state variable
        # In Solidity, state variables are accessed directly (e.g., battleConfig[key])
        # In TypeScript, they become this.battleConfig[key]
        is_mapping_access = False
        mapping_var_name = None

        # Case 1: Direct state variable access (battleConfig[key])
        if isinstance(init_value.base, Identifier):
            var_name = init_value.base.name
            if var_name in self.var_types:
                type_info = self.var_types[var_name]
                is_mapping_access = type_info.is_mapping
                mapping_var_name = var_name

        # Case 2: Explicit this.varName[key] access
        if isinstance(init_value.base, MemberAccess):
            if isinstance(init_value.base.expression, Identifier) and init_value.base.expression.name == 'this':
                member_name = init_value.base.member
                if member_name in self.var_types:
                    type_info = self.var_types[member_name]
                    is_mapping_access = type_info.is_mapping
                    mapping_var_name = member_name

        if not is_mapping_access:
            return None

        # Generate the mapping expression and key
        mapping_expr = self.generate_expression(init_value.base)
        key_expr = self.generate_expression(init_value.index)

        # Check if the mapping has numeric keys (uint/int types) - need Number() conversion
        needs_number_key = False
        if mapping_var_name and mapping_var_name in self.var_types:
            type_info = self.var_types[mapping_var_name]
            if type_info.is_mapping and type_info.key_type:
                key_type_name = type_info.key_type.name if type_info.key_type.name else ''
                needs_number_key = key_type_name.startswith('uint') or key_type_name.startswith('int')

        # Wrap bigint keys in Number() for Record access
        if needs_number_key and not key_expr.startswith('Number('):
            key_expr = f'Number({key_expr})'

        # Get the default value for the struct
        default_value = self._get_ts_default_value(ts_type, decl.type_name)
        if not default_value:
            struct_name = ts_type.replace('Structs.', '') if ts_type.startswith('Structs.') else ts_type
            # Check if this is a local struct (defined in current contract)
            if struct_name in self.current_local_structs:
                default_value = f'createDefault{struct_name}()'
            else:
                default_value = f'Structs.createDefault{struct_name}()'

        # Generate two statements:
        # 1. Initialize the mapping entry if it doesn't exist
        # 2. Get a reference to the entry
        lines = []
        lines.append(f'{self.indent()}{mapping_expr}[{key_expr}] ??= {default_value};')
        lines.append(f'{self.indent()}let {decl.name}: {ts_type} = {mapping_expr}[{key_expr}];')
        return '\n'.join(lines)

    def _add_mapping_default(self, expr: Expression, ts_type: str, generated_expr: str, solidity_type: Optional[TypeName] = None) -> str:
        """Add default value for mapping reads to simulate Solidity mapping semantics.

        In Solidity, reading from a mapping returns the default value for non-existent keys.
        In TypeScript, accessing a non-existent key returns undefined.
        """
        # Check if this is a mapping read (IndexAccess that's not an array)
        if not isinstance(expr, IndexAccess):
            return generated_expr

        # Determine if this is likely a mapping (not an array) read
        is_mapping_read = False

        # First, try to get the base variable name for local variable mappings
        base_var_name = self._get_base_var_name(expr.base)
        if base_var_name and base_var_name in self.var_types:
            type_info = self.var_types[base_var_name]
            is_mapping_read = type_info.is_mapping

        # Handle this.varName[key] pattern (state variable mappings)
        # The base would be a MemberAccess like this.battleConfig
        if isinstance(expr.base, MemberAccess):
            if isinstance(expr.base.expression, Identifier) and expr.base.expression.name == 'this':
                member_name = expr.base.member
                if member_name in self.var_types:
                    type_info = self.var_types[member_name]
                    is_mapping_read = type_info.is_mapping

        # Also check for known mapping patterns in identifier names
        if isinstance(expr.base, Identifier):
            name = expr.base.name.lower()
            mapping_keywords = ['nonce', 'balance', 'allowance', 'mapping', 'map', 'kv', 'storage']
            if any(kw in name for kw in mapping_keywords):
                is_mapping_read = True

        if not is_mapping_read:
            return generated_expr

        # Add default value based on TypeScript type and Solidity type
        default_value = self._get_ts_default_value(ts_type, solidity_type)
        if default_value:
            return f'({generated_expr} ?? {default_value})'
        return generated_expr

    def _get_ts_default_value(self, ts_type: str, solidity_type: Optional[TypeName] = None) -> Optional[str]:
        """Get the default value for a TypeScript type (matching Solidity semantics)."""
        if ts_type == 'bigint':
            return '0n'
        elif ts_type == 'boolean':
            return 'false'
        elif ts_type == 'string':
            # Check if this is a bytes32 or address type (should default to zero hex, not empty string)
            if solidity_type and solidity_type.name:
                sol_type_name = solidity_type.name.lower()
                if 'bytes32' in sol_type_name or sol_type_name == 'bytes32':
                    return '"0x0000000000000000000000000000000000000000000000000000000000000000"'
                elif 'address' in sol_type_name or sol_type_name == 'address':
                    return '"0x0000000000000000000000000000000000000000"'
            return '""'
        elif ts_type == 'number':
            return '0'
        elif ts_type == 'AddressSet':
            # EnumerableSetLib type - use constructor
            return 'new AddressSet()'
        elif ts_type == 'Uint256Set':
            # EnumerableSetLib type - use constructor
            return 'new Uint256Set()'
        elif ts_type.startswith('Structs.'):
            # Struct type - use the factory function to create a default-initialized instance
            struct_name = ts_type[8:]  # Remove 'Structs.' prefix
            return f'Structs.createDefault{struct_name}()'
        elif ts_type in self.current_local_structs:
            # Local struct (defined in current contract) - use factory without Structs. prefix
            return f'createDefault{ts_type}()'
        # For complex types (objects, arrays), return None - they need different handling
        return None

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
                # Track loop variable as local and its type
                if decl.name:
                    self.current_local_vars.add(decl.name)
                    if decl.type_name:
                        self.var_types[decl.name] = decl.type_name
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

    def generate_delete_statement(self, stmt: DeleteStatement) -> str:
        """Generate delete statement (sets value to default/removes from mapping)."""
        expr = self.generate_expression(stmt.expression)
        # In TypeScript, 'delete' works on object properties
        # For mappings and arrays, this is the correct behavior
        return f'{self.indent()}delete {expr};'

    def generate_emit_statement(self, stmt: EmitStatement) -> str:
        """Generate emit statement (as event logging)."""
        # Extract event name and args
        if isinstance(stmt.event_call, FunctionCall):
            if isinstance(stmt.event_call.function, Identifier):
                event_name = stmt.event_call.function.name
                args = ', '.join([self.generate_expression(a) for a in stmt.event_call.arguments])
                return f'{self.indent()}this._emitEvent("{event_name}", {args});'
        expr = self.generate_expression(stmt.event_call)
        return f'{self.indent()}this._emitEvent({expr});'

    def generate_revert_statement(self, stmt: RevertStatement) -> str:
        """Generate revert statement (as throw)."""
        if stmt.error_call:
            # If error_call is a simple identifier (error name), use it as a string
            if isinstance(stmt.error_call, Identifier):
                return f'{self.indent()}throw new Error("{stmt.error_call.name}");'
            # If error_call is a function call (error with args), use error name as string
            elif isinstance(stmt.error_call, FunctionCall):
                if isinstance(stmt.error_call.function, Identifier):
                    error_name = stmt.error_call.function.name
                    return f'{self.indent()}throw new Error("{error_name}");'
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

        General approach:
        1. Normalize the tokenized Yul code
        2. Parse into AST-like structure
        3. Generate TypeScript for each construct

        Key Yul operations and their TypeScript equivalents:
        - sload(slot) → this._storageRead(slotKey)
        - sstore(slot, value) → this._storageWrite(slotKey, value)
        - var.slot → get storage key for variable
        - mstore/mload → memory operations (usually no-op for simulation)
        """
        # Normalize whitespace and punctuation from tokenizer
        code = self._normalize_yul(yul_code)

        # Track slot variable mappings (e.g., slot -> monState.slot)
        slot_vars: Dict[str, str] = {}

        # Parse and generate
        return self._transpile_yul_block(code, slot_vars)

    def _normalize_yul(self, code: str) -> str:
        """Normalize Yul code by fixing tokenizer spacing."""
        code = ' '.join(code.split())
        # Use precompiled patterns for better performance
        for pattern, replacement in YUL_NORMALIZE_PATTERNS:
            code = pattern.sub(replacement, code)
        return code

    def _transpile_yul_block(self, code: str, slot_vars: Dict[str, str]) -> str:
        """Transpile a block of Yul code to TypeScript."""
        lines = []

        # Parse let bindings: let var := expr (using precompiled pattern)
        for match in YUL_LET_PATTERN.finditer(code):
            var_name = match.group(1)
            expr = match.group(2).strip()

            # Check if this is a .slot access (storage key)
            slot_match = YUL_SLOT_PATTERN.match(expr)
            if slot_match:
                storage_var = slot_match.group(1)
                slot_vars[var_name] = storage_var
                # Cast to any for storage operations since we may be passing struct references
                lines.append(f'const {var_name} = this._getStorageKey({storage_var} as any);')
            else:
                ts_expr = self._transpile_yul_expr(expr, slot_vars)
                lines.append(f'let {var_name} = {ts_expr};')

        # Parse if statements: if cond { body } (using precompiled pattern)
        for match in YUL_IF_PATTERN.finditer(code):
            cond = match.group(1).strip()
            body = match.group(2).strip()

            ts_cond = self._transpile_yul_expr(cond, slot_vars)
            ts_body = self._transpile_yul_block(body, slot_vars)

            lines.append(f'if ({ts_cond}) {{')
            for line in ts_body.split('\n'):
                if line.strip():
                    lines.append(f'  {line}')
            lines.append('}')

        # Parse standalone function calls (sstore, mstore, etc.) that aren't inside if blocks
        # Remove if block contents to avoid matching calls inside them
        code_without_ifs = YUL_IF_STRIP_PATTERN.sub('', code)
        for match in YUL_CALL_PATTERN.finditer(code_without_ifs):
            func = match.group(1)
            args = match.group(2)
            ts_stmt = self._transpile_yul_call(func, args, slot_vars)
            if ts_stmt:
                lines.append(ts_stmt)

        return '\n'.join(lines) if lines else '// Assembly: no-op'

    def _split_yul_args(self, args_str: str) -> List[str]:
        """Split Yul function arguments respecting nested parentheses."""
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
                if current.strip():
                    args.append(current.strip())
                current = ''
            else:
                current += char
        if current.strip():
            args.append(current.strip())
        return args

    def _transpile_yul_expr(self, expr: str, slot_vars: Dict[str, str]) -> str:
        """Transpile a Yul expression to TypeScript."""
        expr = expr.strip()

        # sload(slot) - storage read
        sload_match = re.match(r'sload\((\w+)\)', expr)
        if sload_match:
            slot = sload_match.group(1)
            if slot in slot_vars:
                return f'this._storageRead({slot_vars[slot]} as any)'
            return f'this._storageRead({slot})'

        # Function calls (including no-argument calls)
        call_match = re.match(r'(\w+)\((.*)\)', expr)
        if call_match:
            func = call_match.group(1)
            args_str = call_match.group(2).strip()
            # Parse arguments respecting nested parentheses
            args = self._split_yul_args(args_str) if args_str else []
            ts_args = [self._transpile_yul_expr(a, slot_vars) for a in args]

            # Yul built-in functions
            if func in ('add', 'sub', 'mul', 'div', 'mod') and len(ts_args) >= 2:
                ops = {'add': '+', 'sub': '-', 'mul': '*', 'div': '/', 'mod': '%'}
                return f'({ts_args[0]} {ops[func]} {ts_args[1]})'
            if func in ('and', 'or', 'xor') and len(ts_args) >= 2:
                ops = {'and': '&', 'or': '|', 'xor': '^'}
                return f'({ts_args[0]} {ops[func]} {ts_args[1]})'
            if func == 'or' and len(ts_args) == 1:
                return ts_args[0]  # Single arg or() is identity
            if func == 'not' and len(ts_args) >= 1:
                return f'(~{ts_args[0]})'
            if func in ('shl', 'shr') and len(ts_args) >= 2:
                # shl(shift, value) -> value << shift
                return f'({ts_args[1]} {"<<" if func == "shl" else ">>"} {ts_args[0]})'
            if func in ('lt', 'gt', 'eq') and len(ts_args) >= 2:
                ops = {'lt': '<', 'gt': '>', 'eq': '==='}
                return f'({ts_args[0]} {ops[func]} {ts_args[1]} ? 1n : 0n)'
            if func == 'iszero' and len(ts_args) >= 1:
                return f'({ts_args[0]} === 0n ? 1n : 0n)'
            if func == 'caller' and len(ts_args) == 0:
                return 'this._msg.sender'
            if func == 'timestamp' and len(ts_args) == 0:
                return 'this._block.timestamp'
            if func == 'origin' and len(ts_args) == 0:
                return 'this._tx.origin'
            return f'{func}({", ".join(ts_args)})'

        # Hex literals
        if expr.startswith('0x'):
            return f'BigInt("{expr}")'

        # Numeric literals
        if expr.isdigit():
            return f'{expr}n'

        # Identifiers - check if it's a static class member first
        if expr in self.current_static_vars:
            return f'{self.current_class_name}.{expr}'
        # Apply prefix logic for known types (Structs., Enums., Constants.)
        return self.get_qualified_name(expr)

    def _transpile_yul_call(self, func: str, args_str: str, slot_vars: Dict[str, str]) -> str:
        """Transpile a Yul function call statement."""
        args = [a.strip() for a in args_str.split(',')]

        if func == 'sstore':
            slot = args[0]
            value = self._transpile_yul_expr(args[1], slot_vars) if len(args) > 1 else '0n'
            if slot in slot_vars:
                return f'this._storageWrite({slot_vars[slot]} as any, {value});'
            return f'this._storageWrite({slot}, {value});'

        if func == 'mstore':
            # Memory store - in simulation, often used for array length
            ptr = args[0]
            value = self._transpile_yul_expr(args[1], slot_vars) if len(args) > 1 else '0n'
            return f'// mstore: {ptr}.length = Number({value});'

        if func == 'revert':
            return 'throw new Error("Revert");'

        # Log operations (events) - no-op in simulation
        if func in ('log0', 'log1', 'log2', 'log3', 'log4'):
            return f'// {func}({args_str}) - event logging skipped in simulation'

        return f'// Yul: {func}({args_str})'

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
        elif isinstance(expr, ArrayLiteral):
            return self.generate_array_literal(expr)
        elif isinstance(expr, TypeCast):
            return self.generate_type_cast(expr)

        return '/* unknown expression */'

    def generate_array_literal(self, arr: ArrayLiteral) -> str:
        """Generate array literal."""
        elements = ', '.join([self.generate_expression(e) for e in arr.elements])
        return f'[{elements}]'

    def generate_literal(self, lit: Literal) -> str:
        """Generate literal."""
        if lit.kind == 'number':
            # Use bigint literal syntax (Xn) which is more efficient than BigInt(X)
            # For large numbers (> 2^53), use BigInt("X") to avoid precision loss
            clean_value = lit.value.replace('_', '')
            if len(clean_value) > 15:
                return f'BigInt("{lit.value}")'
            return f'{lit.value}n'
        elif lit.kind == 'hex':
            # Hex literals: 0x... -> BigInt("0x...")
            return f'BigInt("{lit.value}")'
        elif lit.kind == 'string':
            return lit.value  # Already has quotes
        elif lit.kind == 'bool':
            return lit.value
        return lit.value

    def generate_identifier(self, ident: Identifier) -> str:
        """Generate identifier."""
        name = ident.name

        # Handle special identifiers
        # In base constructor arguments, we can't use 'this' before super()
        # Use placeholder values instead
        if name == 'msg':
            if self._in_base_constructor_args:
                return '{ sender: ADDRESS_ZERO, value: 0n, data: "0x" as `0x${string}` }'
            return 'this._msg'
        elif name == 'block':
            if self._in_base_constructor_args:
                return '{ timestamp: 0n, number: 0n }'
            return 'this._block'
        elif name == 'tx':
            if self._in_base_constructor_args:
                return '{ origin: ADDRESS_ZERO }'
            return 'this._tx'
        elif name == 'this':
            return 'this'

        # Add ClassName. prefix for static constants (check before global constants)
        if name in self.current_static_vars:
            return f'{self.current_class_name}.{name}'

        # Add module prefixes for known types (but not for self-references)
        qualified = self.get_qualified_name(name)
        if qualified != name:
            return qualified

        # Add this. prefix for state variables and methods (but not local vars)
        if name not in self.current_local_vars:
            if name in self.current_state_vars or name in self.current_methods:
                return f'this.{name}'

        return name

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

        # For assignment operators, don't wrap tuple on left side (destructuring)
        is_assignment = operator in ('=', '+=', '-=', '*=', '/=', '%=', '|=', '&=', '^=')

        # Only add parens around complex sub-expressions
        if not (is_assignment and isinstance(op.left, TupleExpression)):
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
        # Handle new expressions
        if isinstance(call.function, NewExpression):
            if call.function.type_name.is_array:
                # Array allocation: new Type[](size) -> new Array(size)
                if call.arguments:
                    size_arg = call.arguments[0]
                    size = self.generate_expression(size_arg)
                    # Convert BigInt to Number for array size
                    if size.startswith('BigInt('):
                        inner = size[7:-1]  # Extract content between BigInt( and )
                        if inner.isdigit():
                            size = inner
                        else:
                            size = f'Number({size})'
                    elif size.endswith('n') and size[:-1].isdigit():
                        # Only strip 'n' from BigInt literals like "5n", not variable names like "globalLen"
                        size = size[:-1]
                    elif isinstance(size_arg, Identifier):
                        # Variable size needs Number() conversion
                        size = f'Number({size})'
                    return f'new Array({size})'
                # No-argument array creation
                return f'[]'
            else:
                # Contract/class creation: new Contract(args) -> new Contract(args)
                type_name = call.function.type_name.name
                # Handle special types that can't use 'new' in TypeScript
                if type_name == 'string':
                    # In Solidity, new string(length) creates an empty string of given length
                    # In TypeScript, we just return an empty string (content is usually filled via assembly)
                    return '""'
                if type_name.startswith('bytes') and type_name != 'bytes32':
                    # Similar for bytes types
                    return '""'
                args = ', '.join([self.generate_expression(arg) for arg in call.arguments])
                return f'new {type_name}({args})'

        func = self.generate_expression(call.function)

        # Handle abi.decode specially - need to swap args and format types
        if isinstance(call.function, MemberAccess):
            if (isinstance(call.function.expression, Identifier) and
                call.function.expression.name == 'abi'):
                if call.function.member == 'decode':
                    if len(call.arguments) >= 2:
                        data_arg = self.generate_expression(call.arguments[0])
                        types_arg = call.arguments[1]
                        # Convert types tuple to viem format
                        type_params = self._convert_abi_types(types_arg)
                        # Cast data to hex string type for viem
                        return f'decodeAbiParameters({type_params}, {data_arg} as `0x${{string}}`)'
                elif call.function.member == 'encode':
                    # abi.encode(val1, val2, ...) -> encodeAbiParameters([{type}...], [val1, val2, ...])
                    if call.arguments:
                        type_params = self._infer_abi_types_from_values(call.arguments)
                        values = ', '.join([self._convert_abi_value(a) for a in call.arguments])
                        return f'encodeAbiParameters({type_params}, [{values}])'
                elif call.function.member == 'encodePacked':
                    # abi.encodePacked(val1, val2, ...) -> encodePacked([type1, type2, ...], [val1, val2, ...])
                    if call.arguments:
                        types = self._infer_packed_abi_types(call.arguments)
                        values = ', '.join([self._convert_abi_value(a) for a in call.arguments])
                        return f'encodePacked({types}, [{values}])'

        args = ', '.join([self.generate_expression(a) for a in call.arguments])

        # Handle special function calls
        if isinstance(call.function, Identifier):
            name = call.function.name
            if name == 'keccak256':
                return f'keccak256({args})'
            elif name == 'sha256':
                # Special case: sha256(abi.encode("string")) -> sha256String("string")
                if len(call.arguments) == 1:
                    arg = call.arguments[0]
                    if isinstance(arg, FunctionCall):
                        if isinstance(arg.function, MemberAccess):
                            if (isinstance(arg.function.expression, Identifier) and
                                arg.function.expression.name == 'abi' and
                                arg.function.member == 'encode'):
                                # It's abi.encode(...) - check if single string argument
                                if len(arg.arguments) == 1:
                                    inner_arg = arg.arguments[0]
                                    if isinstance(inner_arg, Literal) and inner_arg.kind == 'string':
                                        return f'sha256String({self.generate_expression(inner_arg)})'
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
                # Use efficient bigint literal syntax for simple numbers
                if args.isdigit():
                    return f'{args}n'
                return f'BigInt({args})'
            elif name == 'address':
                # Handle address literals like address(0xdead)
                if call.arguments:
                    arg = call.arguments[0]
                    if isinstance(arg, Literal) and arg.kind in ('number', 'hex'):
                        return self._to_padded_address(arg.value)
                    # Handle address(this) -> this._contractAddress
                    if isinstance(arg, Identifier) and arg.name == 'this':
                        return 'this._contractAddress'
                    # Check if arg is already an address type (msg.sender, tx.origin, etc.)
                    if self._is_already_address_type(arg):
                        return self.generate_expression(arg)
                    # Check if arg is a numeric type cast (uint160, uint256, etc.)
                    # In this case, convert the bigint to a hex address string
                    if self._is_numeric_type_cast(arg):
                        inner = self.generate_expression(arg)
                        return f'`0x${{({inner}).toString(16).padStart(40, "0")}}`'
                    # Handle address(someContract) -> someContract._contractAddress
                    # For contract instances, get their address
                    inner = self.generate_expression(arg)
                    if inner != 'this' and not inner.startswith('"') and not inner.startswith("'"):
                        return f'{inner}._contractAddress'
                return args  # Pass through - addresses are strings
            elif name == 'bool':
                return args  # Pass through - JS truthy works
            elif name == 'bytes32':
                # Handle bytes32 literals like bytes32(0)
                if call.arguments:
                    arg = call.arguments[0]
                    if isinstance(arg, Literal) and arg.kind in ('number', 'hex'):
                        return self._to_padded_bytes32(arg.value)
                return args  # Pass through
            elif name.startswith('bytes'):
                return args  # Pass through
            # Handle interface type casts like IMatchmaker(x) -> x
            # Also handles struct constructors without args -> default object
            elif name.startswith('I') and name[1].isupper():
                # Interface cast - special handling for IEffect(address(this)) pattern
                # In this case, we want to return the object, not its address
                # Cast to 'any' to allow calling methods defined on the interface
                if call.arguments and len(call.arguments) == 1:
                    arg = call.arguments[0]
                    # Check for IEffect(address(x)) pattern
                    if isinstance(arg, FunctionCall) and isinstance(arg.function, Identifier) and arg.function.name == 'address':
                        if arg.arguments and len(arg.arguments) == 1:
                            inner_arg = arg.arguments[0]
                            if isinstance(inner_arg, Identifier) and inner_arg.name == 'this':
                                # Cast to any to allow interface method calls
                                return '(this as any)'
                            # For address(someVar), return the variable itself cast to any
                            inner_expr = self.generate_expression(inner_arg)
                            return f'({inner_expr} as any)'
                    # Check for TypeCast address(x) pattern
                    if isinstance(arg, TypeCast) and arg.type_name.name == 'address':
                        inner_arg = arg.expression
                        if isinstance(inner_arg, Identifier) and inner_arg.name == 'this':
                            return '(this as any)'
                        inner_expr = self.generate_expression(inner_arg)
                        return f'({inner_expr} as any)'
                # Normal interface cast - pass through the value cast to any
                if args:
                    return f'({args} as any)'
                return '{}'  # Empty interface cast
            # Handle struct "constructors" with named arguments
            elif name[0].isupper() and call.named_arguments:
                # Struct constructor with named args: ATTACK_PARAMS({NAME: "x", ...})
                qualified = self.get_qualified_name(name)
                # Track external structs for import generation
                if self._registry and name in self._registry.struct_paths:
                    self.external_structs_used[name] = self._registry.struct_paths[name]
                fields = ', '.join([
                    f'{k}: {self.generate_expression(v)}'
                    for k, v in call.named_arguments.items()
                ])
                return f'{{ {fields} }} as {qualified}'
            # Handle custom type casts and struct "constructors" with no args
            elif name[0].isupper() and not args:
                # Struct with no args - return default object with proper prefix
                qualified = self.get_qualified_name(name)
                # Track external structs for import generation
                if self._registry and name in self._registry.struct_paths:
                    self.external_structs_used[name] = self._registry.struct_paths[name]
                return f'{{}} as {qualified}'
            # Handle enum type casts: Type(newValue) -> Number(newValue) as Enums.Type
            elif name in self.known_enums:
                qualified = self.get_qualified_name(name)
                return f'Number({args}) as {qualified}'

        # For bare function calls that start with _ (internal/protected methods),
        # add this. prefix if not already there. This handles inherited methods
        # that may not have been discovered during type discovery.
        if isinstance(call.function, Identifier):
            name = call.function.name
            if name.startswith('_') and not func.startswith('this.'):
                return f'this.{func}({args})'

        # Handle public state variable getter calls
        # In Solidity, public state variables generate getter functions that can be called with ()
        # In TypeScript, we generate these as properties, so we need to remove the ()
        if not args and isinstance(call.function, MemberAccess):
            member_name = call.function.member
            # Check if this is a known public state variable getter
            # These are typically called on contract instances with no arguments
            if member_name in self.known_public_state_vars:
                # It's a public state variable getter - return property access without ()
                return func

        # Handle EnumerableSetLib method calls that are now property getters in TypeScript
        # In Solidity: set.length() is a function call via 'using for' directive
        # In TypeScript: Uint256Set.length is a property getter
        if isinstance(call.function, MemberAccess):
            member_name = call.function.member
            # Set methods that are property getters in our TS implementation
            if member_name == 'length':
                # Already wrapped in BigInt by generate_member_access, just return without ()
                return func
            # Set methods that are still methods in our TS implementation
            if member_name in ('contains', 'add', 'remove', 'values', 'at'):
                # These remain as method calls
                pass

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
            # Track library references for imports
            elif access.expression.name in self.known_libraries:
                self.libraries_referenced.add(access.expression.name)

        # Handle type(TypeName).max/min - compute the actual values
        if isinstance(access.expression, FunctionCall):
            if isinstance(access.expression.function, Identifier) and access.expression.function.name == 'type':
                if access.expression.arguments:
                    type_arg = access.expression.arguments[0]
                    if isinstance(type_arg, Identifier):
                        type_name = type_arg.name
                        if member == 'max':
                            return self._type_max(type_name)
                        elif member == 'min':
                            return self._type_min(type_name)

        # Handle .slot for storage variables
        if member == 'slot':
            return f'/* {expr}.slot */'

        # Handle .length - in JS arrays return number, but Solidity expects uint256 (bigint)
        # For EnumerableSetLib types (Uint256Set, AddressSet, etc.), our TS implementation
        # already returns bigint, so we don't need to wrap in BigInt()
        if member == 'length':
            # Check if base is a known Set type (from EnumerableSetLib)
            base_var_name = self._get_base_var_name(access.expression)
            if base_var_name and base_var_name in self.var_types:
                type_info = self.var_types[base_var_name]
                type_name = type_info.name if type_info else ''
                # EnumerableSetLib types - .length returns bigint already
                # Be specific to avoid false matches with interface names like IMoveSet
                enumerable_set_types = ('AddressSet', 'Uint256Set', 'Bytes32Set', 'Int256Set')
                if type_name in enumerable_set_types or type_name.startswith('EnumerableSetLib.'):
                    return f'{expr}.{member}'
            # Regular arrays - wrap in BigInt
            return f'BigInt({expr}.{member})'

        return f'{expr}.{member}'

    def _type_max(self, type_name: str) -> str:
        """Get the maximum value for a Solidity integer type."""
        if type_name.startswith('uint'):
            bits = int(type_name[4:]) if len(type_name) > 4 else 256
            max_val = (2 ** bits) - 1
            return f'BigInt("{max_val}")'
        elif type_name.startswith('int'):
            bits = int(type_name[3:]) if len(type_name) > 3 else 256
            max_val = (2 ** (bits - 1)) - 1
            return f'BigInt("{max_val}")'
        return '0n'

    def _type_min(self, type_name: str) -> str:
        """Get the minimum value for a Solidity integer type."""
        if type_name.startswith('uint'):
            return '0n'
        elif type_name.startswith('int'):
            bits = int(type_name[3:]) if len(type_name) > 3 else 256
            min_val = -(2 ** (bits - 1))
            return f'BigInt("{min_val}")'
        return '0n'

    def _convert_abi_types(self, types_expr: Expression) -> str:
        """Convert Solidity type tuple to viem ABI parameter format."""
        # Handle tuple expression like (int32) or (uint256, uint256, EnumType, int32)
        if isinstance(types_expr, TupleExpression):
            type_strs = []
            for comp in types_expr.components:
                if comp:
                    type_strs.append(self._solidity_type_to_abi_param(comp))
            return f'[{", ".join(type_strs)}]'
        # Single type without tuple
        return f'[{self._solidity_type_to_abi_param(types_expr)}]'

    def _solidity_type_to_abi_param(self, type_expr: Expression) -> str:
        """Convert a Solidity type expression to viem ABI parameter object."""
        if isinstance(type_expr, Identifier):
            name = type_expr.name
            # Handle primitive types
            if name.startswith('uint') or name.startswith('int') or name == 'address' or name == 'bool' or name.startswith('bytes'):
                return f"{{type: '{name}'}}"
            # Handle enum types - treat as uint8
            if name in self.known_enums:
                return "{type: 'uint8'}"
            # Handle struct types - simplified as bytes
            return "{type: 'bytes'}"
        # Fallback
        return "{type: 'bytes'}"

    def _infer_abi_types_from_values(self, args: List[Expression]) -> str:
        """Infer ABI types from value expressions (for abi.encode)."""
        type_strs = []
        for arg in args:
            type_str = self._infer_single_abi_type(arg)
            type_strs.append(type_str)
        return f'[{", ".join(type_strs)}]'

    def _infer_packed_abi_types(self, args: List[Expression]) -> str:
        """Infer packed ABI types from value expressions (for abi.encodePacked).

        encodePacked uses a simpler format: ['uint256', 'address'] instead of
        [{type: 'uint256'}, {type: 'address'}].
        """
        type_strs = []
        for arg in args:
            type_str = self._infer_single_packed_type(arg)
            type_strs.append(f"'{type_str}'")
        return f'[{", ".join(type_strs)}]'

    def _infer_single_packed_type(self, arg: Expression) -> str:
        """Infer packed ABI type from a single value expression."""
        # If it's an identifier, look up its type
        if isinstance(arg, Identifier):
            name = arg.name
            # Check known variable types
            if name in self.var_types:
                type_info = self.var_types[name]
                if type_info.name:
                    type_name = type_info.name
                    # Handle array types - append []
                    array_suffix = '[]' if type_info.is_array else ''
                    if type_name == 'address':
                        return f'address{array_suffix}'
                    if type_name.startswith('uint') or type_name.startswith('int'):
                        return f'{type_name}{array_suffix}'
                    if type_name == 'bool':
                        return f'bool{array_suffix}'
                    if type_name.startswith('bytes'):
                        return f'{type_name}{array_suffix}'
                    if type_name == 'string':
                        return f'string{array_suffix}'
                    if type_name in self.known_enums:
                        return f'uint8{array_suffix}'
            # Check known enum members
            if name in self.known_enums:
                return 'uint8'
            # Default to uint256 for identifiers (common case)
            return 'uint256'
        # For literals
        if isinstance(arg, Literal):
            if arg.kind == 'string':
                return 'string'
            elif arg.kind in ('number', 'hex'):
                return 'uint256'
            elif arg.kind == 'bool':
                return 'bool'
        # For member access like Enums.Something or msg.sender or battle.p0
        if isinstance(arg, MemberAccess):
            # Check for _contractAddress access (always address)
            if arg.member == '_contractAddress':
                return 'address'
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return 'uint8'
                if arg.expression.name in ('this', 'msg', 'tx'):
                    member = arg.member
                    if member in ('sender', 'origin'):
                        return 'address'
                # Check if this is a struct field access (e.g., proposal.p0)
                var_name = arg.expression.name
                if var_name in self.var_types:
                    type_info = self.var_types[var_name]
                    if type_info.name and type_info.name in self.known_struct_fields:
                        struct_fields = self.known_struct_fields[type_info.name]
                        if arg.member in struct_fields:
                            field_info = struct_fields[arg.member]
                            # Handle tuple format (type_name, is_array) or string format
                            if isinstance(field_info, tuple):
                                field_type, is_array = field_info
                            else:
                                field_type, is_array = field_info, False
                            array_suffix = '[]' if is_array else ''
                            # Handle common types
                            if field_type == 'address':
                                return f'address{array_suffix}'
                            if field_type == 'bytes32':
                                return f'bytes32{array_suffix}'
                            if field_type.startswith('uint') or field_type.startswith('int'):
                                return f'{field_type}{array_suffix}'
                            if field_type.startswith('bytes'):
                                return f'{field_type}{array_suffix}'
                            if field_type == 'bool':
                                return f'bool{array_suffix}'
                            if field_type == 'string':
                                return f'string{array_suffix}'
                            # Contract/interface types are encoded as addresses
                            if field_type in self.known_contracts or field_type in self.known_interfaces:
                                return f'address{array_suffix}'
        # For function calls that return specific types
        if isinstance(arg, FunctionCall):
            if isinstance(arg.function, Identifier):
                func_name = arg.function.name
                # blockhash returns bytes32
                if func_name == 'blockhash':
                    return 'bytes32'
                if func_name == 'keccak256':
                    return 'bytes32'
                # name() typically returns string (ERC20/metadata standard)
                if func_name == 'name':
                    return 'string'
            # this.name() also returns string
            elif isinstance(arg.function, MemberAccess):
                if arg.function.member == 'name':
                    return 'string'
        # Default fallback
        return 'uint256'

    def _infer_single_abi_type(self, arg: Expression) -> str:
        """Infer ABI type from a single value expression."""
        # If it's an identifier, look up its type
        if isinstance(arg, Identifier):
            name = arg.name
            # Check known variable types
            if name in self.var_types:
                type_info = self.var_types[name]
                if type_info.name:
                    type_name = type_info.name
                    if type_name == 'address':
                        return "{type: 'address'}"
                    if type_name == 'string':
                        return "{type: 'string'}"
                    if type_name.startswith('uint') or type_name.startswith('int') or type_name == 'bool' or type_name.startswith('bytes'):
                        return f"{{type: '{type_name}'}}"
                    if type_name in self.known_enums:
                        return "{type: 'uint8'}"
            # Check known enum members
            if name in self.known_enums:
                return "{type: 'uint8'}"
            # Default to uint256 for identifiers (common case)
            return "{type: 'uint256'}"
        # For literals
        if isinstance(arg, Literal):
            if arg.kind == 'string':
                return "{type: 'string'}"
            elif arg.kind in ('number', 'hex'):
                return "{type: 'uint256'}"
            elif arg.kind == 'bool':
                return "{type: 'bool'}"
        # For member access like Enums.Something or this._contractAddress or battle.p0
        if isinstance(arg, MemberAccess):
            # Check for _contractAddress access on any expression (returns address)
            if arg.member == '_contractAddress':
                return "{type: 'address'}"
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return "{type: 'uint8'}"
                if arg.expression.name in ('this', 'msg', 'tx'):
                    member = arg.member
                    if member in ('sender', 'origin', '_contractAddress'):
                        return "{type: 'address'}"
                # Check if this is a struct field access (e.g., battle.p0)
                var_name = arg.expression.name
                if var_name in self.var_types:
                    type_info = self.var_types[var_name]
                    if type_info.name and type_info.name in self.known_struct_fields:
                        struct_fields = self.known_struct_fields[type_info.name]
                        if arg.member in struct_fields:
                            field_info = struct_fields[arg.member]
                            # Handle tuple format (type_name, is_array) or string format
                            if isinstance(field_info, tuple):
                                field_type, is_array = field_info
                            else:
                                field_type, is_array = field_info, False
                            return self._solidity_type_to_abi_type(field_type, is_array)
        # For function calls, check for type casts and look up return types
        if isinstance(arg, FunctionCall):
            # Check for type cast function calls like address(x), uint256(x), etc.
            if isinstance(arg.function, Identifier):
                func_name = arg.function.name
                # address() cast returns address type
                if func_name == 'address':
                    return "{type: 'address'}"
                # uint/int casts
                if func_name.startswith('uint') or func_name.startswith('int'):
                    return f"{{type: '{func_name}'}}"
                # bytes32 cast
                if func_name == 'bytes32' or func_name.startswith('bytes'):
                    return f"{{type: '{func_name}'}}"
                # keccak256, blockhash, sha256 return bytes32
                if func_name in ('keccak256', 'blockhash', 'sha256'):
                    return "{type: 'bytes32'}"
            method_name = None
            # Handle this.method() or just method()
            if isinstance(arg.function, Identifier):
                method_name = arg.function.name
            elif isinstance(arg.function, MemberAccess):
                if isinstance(arg.function.expression, Identifier):
                    if arg.function.expression.name == 'this':
                        method_name = arg.function.member
            # Look up the method return type
            if method_name and hasattr(self, 'current_method_return_types'):
                if method_name in self.current_method_return_types:
                    return_type = self.current_method_return_types[method_name]
                    return self._solidity_type_to_abi_type(return_type)
        # For TypeCast expressions
        if isinstance(arg, TypeCast):
            type_name = arg.type_name.name
            if type_name == 'address':
                return "{type: 'address'}"
            if type_name.startswith('uint') or type_name.startswith('int'):
                return f"{{type: '{type_name}'}}"
            if type_name == 'bytes32' or type_name.startswith('bytes'):
                return f"{{type: '{type_name}'}}"
        # Default fallback
        return "{type: 'uint256'}"

    def _solidity_type_to_abi_type(self, type_name: str, is_array: bool = False) -> str:
        """Convert a Solidity type name to ABI type format."""
        array_suffix = '[]' if is_array else ''
        if type_name == 'string':
            return f"{{type: 'string{array_suffix}'}}"
        if type_name == 'address':
            return f"{{type: 'address{array_suffix}'}}"
        if type_name == 'bool':
            return f"{{type: 'bool{array_suffix}'}}"
        if type_name.startswith('uint') or type_name.startswith('int'):
            return f"{{type: '{type_name}{array_suffix}'}}"
        if type_name.startswith('bytes'):
            return f"{{type: '{type_name}{array_suffix}'}}"
        if type_name in self.known_enums:
            return f"{{type: 'uint8{array_suffix}'}}"
        # Contract/interface types are encoded as addresses
        if type_name in self.known_contracts or type_name in self.known_interfaces:
            return f"{{type: 'address{array_suffix}'}}"
        # Default to uint256 for unknown types
        return f"{{type: 'uint256{array_suffix}'}}"

    def _convert_abi_value(self, arg: Expression) -> str:
        """Convert value for ABI encoding, ensuring proper types."""
        expr = self.generate_expression(arg)
        var_type_name = None

        # Get the type name for this expression
        if isinstance(arg, Identifier):
            name = arg.name
            if name in self.var_types:
                type_info = self.var_types[name]
                if type_info.name:
                    var_type_name = type_info.name
                    if var_type_name in self.known_enums:
                        # Enums should be converted to number for viem (uint8)
                        return f'Number({expr})'
                    # bytes32 and address types need hex string cast
                    # For arrays, cast to array of hex strings
                    if var_type_name == 'bytes32' or var_type_name == 'address':
                        if type_info.is_array:
                            return f'{expr} as `0x${{string}}`[]'
                        else:
                            return f'{expr} as `0x${{string}}`'
                    # Small integer types need Number() conversion for viem
                    if var_type_name in ('int8', 'int16', 'int32', 'int64', 'int128',
                                          'uint8', 'uint16', 'uint32', 'uint64', 'uint128'):
                        return f'Number({expr})'

        # Member access like Enums.Something also needs Number conversion
        if isinstance(arg, MemberAccess):
            # Check for address-returning members that need hex string cast
            if arg.member in ('sender', 'origin', '_contractAddress'):
                return f'{expr} as `0x${{string}}`'
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return f'Number({expr})'
                # Check if this is a struct field access
                var_name = arg.expression.name
                if var_name in self.var_types:
                    type_info = self.var_types[var_name]
                    if type_info.name and type_info.name in self.known_struct_fields:
                        struct_fields = self.known_struct_fields[type_info.name]
                        if arg.member in struct_fields:
                            field_info = struct_fields[arg.member]
                            # Handle tuple format (type_name, is_array) or string format
                            if isinstance(field_info, tuple):
                                field_type, is_array = field_info
                            else:
                                field_type, is_array = field_info, False
                            if field_type == 'address' or field_type == 'bytes32':
                                if is_array:
                                    return f'{expr} as `0x${{string}}`[]'
                                else:
                                    return f'{expr} as `0x${{string}}`'
                            # Contract/interface types also need address cast
                            if field_type in self.known_contracts or field_type in self.known_interfaces:
                                if is_array:
                                    # For arrays of contracts, we need to map to addresses
                                    return f'{expr}.map((c: any) => c._contractAddress as `0x${{string}}`)'
                                else:
                                    return f'{expr}._contractAddress as `0x${{string}}`'

        # Function calls that return bytes32/address need to be cast
        if isinstance(arg, FunctionCall):
            # Check for functions known to return bytes32
            func_name = None
            if isinstance(arg.function, Identifier):
                func_name = arg.function.name
            elif isinstance(arg.function, MemberAccess):
                func_name = arg.function.member
            if func_name:
                # address() cast returns address type - needs hex string cast
                if func_name == 'address':
                    return f'{expr} as `0x${{string}}`'
                # keccak256, sha256, blockhash, etc. return bytes32
                if func_name in ('keccak256', 'sha256', 'blockhash', 'hashBattle', 'hashBattleOffer'):
                    return f'{expr} as `0x${{string}}`'
                # Look up method return types for custom methods
                if hasattr(self, 'current_method_return_types') and func_name in self.current_method_return_types:
                    return_type = self.current_method_return_types[func_name]
                    if return_type in ('bytes32', 'address'):
                        return f'{expr} as `0x${{string}}`'

        # Type casts to address/bytes32 also need hex string cast
        if isinstance(arg, TypeCast):
            type_name = arg.type_name.name
            if type_name in ('address', 'bytes32'):
                return f'{expr} as `0x${{string}}`'

        return expr

    def generate_index_access(self, access: IndexAccess) -> str:
        """Generate index access using [] syntax for both arrays and objects."""
        base = self.generate_expression(access.base)
        index = self.generate_expression(access.index)

        # Determine if this is likely an array access (needs numeric index) or
        # mapping/object access (uses string key)
        is_likely_array = self._is_likely_array_access(access)

        # Check if the base is a mapping type (converts to Map in TS)
        base_var_name = self._get_base_var_name(access.base)
        is_mapping = False
        if base_var_name and base_var_name in self.var_types:
            type_info = self.var_types[base_var_name]
            is_mapping = type_info.is_mapping

        # Check if mapping has a numeric key type (needs Number conversion)
        mapping_has_numeric_key = False
        if base_var_name and base_var_name in self.var_types:
            type_info = self.var_types[base_var_name]
            if type_info.is_mapping and type_info.key_type:
                key_type_name = type_info.key_type.name if type_info.key_type.name else ''
                # Numeric key types need Number conversion
                mapping_has_numeric_key = key_type_name.startswith('uint') or key_type_name.startswith('int')

        # For struct field access like config.globalEffects, check if it's a mapping field
        if isinstance(access.base, MemberAccess):
            member_name = access.base.member
            # Known mapping fields in structs with numeric keys
            numeric_key_mapping_fields = {
                'p0Team', 'p1Team', 'p0States', 'p1States',
                'globalEffects', 'p0Effects', 'p1Effects', 'engineHooks'
            }
            if member_name in numeric_key_mapping_fields:
                is_mapping = True
                mapping_has_numeric_key = True

        # Convert index to appropriate type for array/object access
        # Arrays need Number, mappings with numeric keys need Number, but string/bytes32/address keys don't
        needs_number_conversion = is_likely_array or (is_mapping and mapping_has_numeric_key)

        if index.startswith('BigInt('):
            # BigInt(n) -> n for simple literals
            inner = index[7:-1]  # Extract content between BigInt( and )
            if inner.isdigit():
                index = inner
            elif needs_number_conversion:
                index = f'Number({index})'
        elif isinstance(access.index, Literal) and index.endswith('n'):
            # 0n -> 0 only for simple bigint literals, not binary expressions like "i - 1n"
            index = index[:-1]
        elif needs_number_conversion and isinstance(access.index, Identifier):
            # For loop variables (i, j, etc.) accessing arrays/mappings, convert to Number
            index = f'Number({index})'
        elif needs_number_conversion and isinstance(access.index, BinaryOperation):
            # For expressions like baseSlot + i, wrap in Number()
            index = f'Number({index})'
        elif needs_number_conversion and isinstance(access.index, UnaryOperation):
            # For expressions like index++ or ++index, wrap in Number()
            index = f'Number({index})'
        elif needs_number_conversion and isinstance(access.index, IndexAccess):
            # For nested array access like moves[typeAdvantagedMoves[i]], wrap in Number()
            # because the inner array returns a bigint
            index = f'Number({index})'
        elif needs_number_conversion and isinstance(access.index, MemberAccess):
            # For struct field access like players[ctx.playerIndex], wrap in Number()
            # since struct fields of uint type are bigint in TS
            index = f'Number({index})'
        elif isinstance(access.index, Identifier) and self._is_bigint_typed_identifier(access.index):
            # Fallback: even if base type doesn't require Number conversion,
            # if the index is a bigint-typed variable, convert it for Record access
            # This handles nested mappings like teams[addr][uint256Index]
            if not index.startswith('Number('):
                index = f'Number({index})'
        # For string/address mapping keys - leave as-is

        return f'{base}[{index}]'

    def _is_already_address_type(self, expr: Expression) -> bool:
        """Check if expression is already an address type (doesn't need ._contractAddress).

        Returns True for expressions like msg.sender, tx.origin, etc. that are
        already strings representing addresses in the TypeScript runtime.
        """
        # Check for msg.sender, msg.origin patterns
        if isinstance(expr, MemberAccess):
            if isinstance(expr.expression, Identifier):
                base_name = expr.expression.name
                member = expr.member
                # msg.sender is already an address string
                if base_name == 'msg' and member == 'sender':
                    return True
                # tx.origin is already an address string
                if base_name == 'tx' and member == 'origin':
                    return True
                # Check if this is a struct field that's already an address type
                if base_name in self.var_types:
                    type_info = self.var_types[base_name]
                    if type_info.name and type_info.name in self.known_struct_fields:
                        struct_fields = self.known_struct_fields[type_info.name]
                        if member in struct_fields:
                            field_info = struct_fields[member]
                            field_type = field_info[0] if isinstance(field_info, tuple) else field_info
                            if field_type == 'address':
                                return True
        # Check if it's a simple identifier with address type
        if isinstance(expr, Identifier):
            if expr.name in self.var_types:
                type_info = self.var_types[expr.name]
                if type_info.name == 'address':
                    return True
        return False

    def _is_numeric_type_cast(self, expr: Expression) -> bool:
        """Check if expression is a numeric type cast (uint160, uint256, etc.).

        Returns True for expressions that cast to integer types and produce bigint values.
        This is used to properly handle address(uint160(...)) patterns.
        """
        # Check for TypeCast to numeric types
        if isinstance(expr, TypeCast):
            type_name = expr.type_name.name
            if type_name.startswith('uint') or type_name.startswith('int'):
                return True
        # Check for function call casts like uint160(x)
        if isinstance(expr, FunctionCall):
            if isinstance(expr.function, Identifier):
                func_name = expr.function.name
                if func_name.startswith('uint') or func_name.startswith('int'):
                    return True
        return False

    def _is_likely_array_access(self, access: IndexAccess) -> bool:
        """Determine if this is an array access (needs Number index) vs mapping access.

        Uses type registry for accurate detection instead of name heuristics.
        """
        # Get the base variable name to look up its type
        base_var_name = self._get_base_var_name(access.base)

        if base_var_name and base_var_name in self.var_types:
            type_info = self.var_types[base_var_name]
            # Check the type - arrays need Number(), mappings don't
            if type_info.is_array:
                return True
            if type_info.is_mapping:
                return False

        # For member access (e.g., config.p0States[j]), check if the member type is array
        if isinstance(access.base, MemberAccess):
            # The member access itself may be accessing an array field in a struct
            # Without full struct type info, use the index type as a hint
            pass

        # Fallback: check if index is a known integer type variable
        if isinstance(access.index, Identifier):
            index_name = access.index.name
            if index_name in self.var_types:
                index_type = self.var_types[index_name]
                # If index is declared as uint/int, it's likely an array access
                if index_type.name and (index_type.name.startswith('uint') or index_type.name.startswith('int')):
                    return True

        return False

    def _get_base_var_name(self, expr: Expression) -> Optional[str]:
        """Extract the root variable name from an expression."""
        if isinstance(expr, Identifier):
            return expr.name
        if isinstance(expr, MemberAccess):
            # For nested access like a.b.c, get the root 'a'
            return self._get_base_var_name(expr.expression)
        if isinstance(expr, IndexAccess):
            # For nested index like a[x][y], get the root 'a'
            return self._get_base_var_name(expr.base)
        return None

    def _is_bigint_typed_identifier(self, expr: Expression) -> bool:
        """Check if expression is an identifier with uint/int type (bigint in TypeScript)."""
        if isinstance(expr, Identifier):
            name = expr.name
            if name in self.var_types:
                type_name = self.var_types[name].name or ''
                return type_name.startswith('uint') or type_name.startswith('int')
        return False

    def generate_new_expression(self, expr: NewExpression) -> str:
        """Generate new expression."""
        type_name = expr.type_name.name
        if expr.type_name.is_array:
            return f'new Array()'
        return f'new {type_name}()'

    def generate_tuple_expression(self, expr: TupleExpression) -> str:
        """Generate tuple expression."""
        # For empty components (discarded values in destructuring), use empty string
        # In TypeScript: [a, ] = ... discards second value, or [, b] = ... discards first
        components = [self.generate_expression(c) if c else '' for c in expr.components]
        return f'[{", ".join(components)}]'

    def generate_type_cast(self, cast: TypeCast) -> str:
        """Generate type cast - simplified for simulation (no strict bit masking)."""
        type_name = cast.type_name.name
        inner_expr = cast.expression

        # Handle address literals like address(0xdead) and address(this)
        if type_name == 'address':
            if isinstance(inner_expr, Literal) and inner_expr.kind in ('number', 'hex'):
                return self._to_padded_address(inner_expr.value)
            # Handle address(this) -> this._contractAddress
            if isinstance(inner_expr, Identifier) and inner_expr.name == 'this':
                return 'this._contractAddress'
            # Check if inner expression is already an address type (msg.sender, tx.origin, etc.)
            if self._is_already_address_type(inner_expr):
                return self.generate_expression(inner_expr)

            # Check if inner expression is a numeric type cast (uint160, uint256, etc.)
            # In this case, the result is a bigint that needs to be converted to hex address string
            is_numeric_cast = self._is_numeric_type_cast(inner_expr)

            expr = self.generate_expression(inner_expr)
            if expr.startswith('"') or expr.startswith("'"):
                return expr

            # If the inner expression is a numeric cast (like uint160(...)), convert bigint to address string
            if is_numeric_cast:
                return f'`0x${{({expr}).toString(16).padStart(40, "0")}}`'

            # Handle address(someContract) -> someContract._contractAddress
            if expr != 'this' and not expr.startswith('"') and not expr.startswith("'"):
                return f'{expr}._contractAddress'
            return expr  # Already a string in most cases

        # Handle bytes32 casts
        if type_name == 'bytes32':
            if isinstance(inner_expr, Literal) and inner_expr.kind in ('number', 'hex'):
                return self._to_padded_bytes32(inner_expr.value)
            # Handle string literal to bytes32: bytes32("STRING") -> hex encoding of string
            if isinstance(inner_expr, Literal) and inner_expr.kind == 'string':
                # Convert string to hex, padding to 32 bytes
                string_val = inner_expr.value.strip('"\'')  # Remove quotes
                hex_val = string_val.encode('utf-8').hex()
                hex_val = hex_val[:64]  # Truncate if too long
                hex_val = hex_val.ljust(64, '0')  # Pad with zeros to 32 bytes
                return f'"0x{hex_val}"'
            # For computed expressions, convert bigint to 64-char hex string
            expr = self.generate_expression(inner_expr)
            return f'`0x${{({expr}).toString(16).padStart(64, "0")}}`'

        expr = self.generate_expression(inner_expr)

        # For integers, apply proper bit masking (Solidity truncates to the target size)
        if type_name.startswith('uint'):
            # Extract bit width from type name (e.g., uint192 -> 192)
            bits = int(type_name[4:]) if len(type_name) > 4 else 256

            # Check if inner expression is an address cast - need to use addressToUint
            is_address_expr = (
                (isinstance(inner_expr, TypeCast) and inner_expr.type_name.name == 'address') or
                (isinstance(inner_expr, FunctionCall) and isinstance(inner_expr.function, Identifier) and inner_expr.function.name == 'address')
            )

            if bits < 256:
                # Apply mask for truncation: value & ((1 << bits) - 1)
                mask = (1 << bits) - 1
                if is_address_expr:
                    return f'(addressToUint({expr}) & {mask}n)'
                return f'(BigInt({expr}) & {mask}n)'
            else:
                # uint256 - no masking needed
                if is_address_expr:
                    return f'addressToUint({expr})'
                if expr.startswith('BigInt(') or expr.isdigit() or expr.endswith('n'):
                    return expr
                return f'BigInt({expr})'
        elif type_name.startswith('int'):
            # For signed ints, masking is more complex - just use BigInt for now
            if expr.startswith('BigInt(') or expr.isdigit() or expr.endswith('n'):
                return expr
            return f'BigInt({expr})'
        elif type_name == 'bool':
            return expr  # JS truthy/falsy works fine
        elif type_name.startswith('bytes'):
            return expr  # Pass through

        # For custom types (structs, enums), just pass through
        return expr

    def solidity_type_to_ts(self, type_name: TypeName) -> str:
        """Convert Solidity type to TypeScript type."""
        if type_name.is_mapping:
            # Use Record for consistency with state variable generation
            # Record<string, V> allows [] access and works with Solidity mapping semantics
            value = self.solidity_type_to_ts(type_name.value_type)
            return f'Record<string, {value}>'

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
        elif name in self.known_interfaces:
            ts_type = 'any'  # Interfaces become 'any' in TypeScript
        elif name in self.known_structs or name in self.known_enums:
            ts_type = self.get_qualified_name(name)
            # Track external structs (from files other than Structs.ts)
            if self._registry and name in self._registry.struct_paths:
                self.external_structs_used[name] = self._registry.struct_paths[name]
        elif name in self.known_contracts:
            # Contract type - track for import generation
            self.contracts_referenced.add(name)
            ts_type = name
        elif name.startswith('EnumerableSetLib.'):
            # Handle EnumerableSetLib types - runtime exports them directly
            set_type = name.split('.')[1]  # e.g., 'Uint256Set'
            self.set_types_used.add(set_type)
            ts_type = set_type
        else:
            ts_type = name  # Other custom types

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
        elif ts_type.startswith('Map<') or ts_type.startswith('Record<'):
            return '{}'
        elif ts_type.startswith('Structs.') or ts_type.startswith('Enums.'):
            # Struct types should be initialized as empty objects
            return f'{{}} as {ts_type}'
        elif ts_type in self.known_structs:
            return f'{{}} as {ts_type}'
        return 'undefined as any'


# =============================================================================
# MAIN TRANSPILER CLASS
# =============================================================================

class SolidityToTypeScriptTranspiler:
    """Main transpiler class that orchestrates the conversion process."""

    def __init__(self, source_dir: str = '.', output_dir: str = './ts-output',
                 discovery_dirs: Optional[List[str]] = None,
                 stubbed_contracts: Optional[List[str]] = None,
                 emit_metadata: bool = False):
        self.source_dir = Path(source_dir)
        self.output_dir = Path(output_dir)
        self.parsed_files: Dict[str, SourceUnit] = {}
        self.registry = TypeRegistry()
        self.stubbed_contracts = set(stubbed_contracts or [])
        self.emit_metadata = emit_metadata

        # Metadata and dependency tracking
        self.metadata_extractor: Optional[MetadataExtractor] = None
        self.dependency_manifest = DependencyManifest()

        # Load runtime replacements configuration
        self.runtime_replacements: Dict[str, dict] = {}
        self.runtime_replacement_classes: Set[str] = set()  # Set of class names that are runtime replacements
        self.runtime_replacement_mixins: Dict[str, str] = {}  # Class name -> mixin code for secondary inheritance
        self._load_runtime_replacements()

        # Run type discovery on specified directories
        if discovery_dirs:
            for dir_path in discovery_dirs:
                self.registry.discover_from_directory(dir_path)

    def _load_runtime_replacements(self) -> None:
        """Load the runtime-replacements.json configuration file."""
        script_dir = Path(__file__).parent
        replacements_file = script_dir / 'runtime-replacements.json'

        if replacements_file.exists():
            try:
                with open(replacements_file, 'r') as f:
                    config = json.load(f)
                for replacement in config.get('replacements', []):
                    source_path = replacement.get('source', '')
                    if source_path:
                        # Normalize the source path for matching
                        self.runtime_replacements[source_path] = replacement
                        # Track class names that are runtime replacements
                        for export in replacement.get('exports', []):
                            self.runtime_replacement_classes.add(export)
                        # Extract mixin code if defined
                        interface = replacement.get('interface', {})
                        class_name = interface.get('class', '')
                        mixin_code = interface.get('mixin', '')
                        if class_name and mixin_code:
                            self.runtime_replacement_mixins[class_name] = mixin_code
                print(f"Loaded {len(self.runtime_replacements)} runtime replacements, {len(self.runtime_replacement_mixins)} mixins")
            except (json.JSONDecodeError, KeyError) as e:
                print(f"Warning: Failed to load runtime-replacements.json: {e}")

    def _get_runtime_replacement(self, filepath: str) -> Optional[dict]:
        """Check if a file should be replaced with a runtime implementation."""
        # Get the relative path from source_dir
        try:
            rel_path = Path(filepath).relative_to(self.source_dir)
            rel_str = str(rel_path).replace('\\', '/')  # Normalize path separators
        except ValueError:
            # File is not under source_dir, try matching just the filename parts
            rel_str = str(Path(filepath)).replace('\\', '/')

        # Check against replacement patterns
        for source_pattern, replacement in self.runtime_replacements.items():
            # Match if the relative path ends with the pattern
            if rel_str.endswith(source_pattern) or rel_str == source_pattern:
                return replacement

        return None

    def _generate_runtime_reexport(self, replacement: dict, file_depth: int) -> str:
        """Generate a re-export file for a runtime replacement."""
        runtime_module = replacement.get('runtimeModule', '../runtime')
        exports = replacement.get('exports', [])
        reason = replacement.get('reason', 'Complex Yul assembly')

        # Adjust the import path based on file depth
        if file_depth > 0:
            # Add extra ../ for each level of depth beyond the first
            runtime_path = '../' * file_depth + 'runtime'
        else:
            runtime_path = runtime_module

        lines = [
            "// Auto-generated by sol2ts transpiler",
            f"// Runtime replacement: {reason}",
            "// See transpiler/runtime-replacements.json for configuration",
            "",
        ]

        if exports:
            export_list = ', '.join(exports)
            lines.append(f"export {{ {export_list} }} from '{runtime_path}';")
        else:
            lines.append(f"export * from '{runtime_path}';")

        return '\n'.join(lines) + '\n'

    def discover_types(self, directory: str, pattern: str = '**/*.sol') -> None:
        """Run type discovery on a directory of Solidity files."""
        self.registry.discover_from_directory(directory, pattern)

    def transpile_file(self, filepath: str, use_registry: bool = True) -> str:
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

        # Also discover types from this file if not already done
        self.registry.discover_from_ast(ast)

        # Extract metadata if enabled
        if self.emit_metadata:
            if self.metadata_extractor is None:
                self.metadata_extractor = MetadataExtractor(self.registry)
            # Get relative path if possible, otherwise use filename
            try:
                if self.source_dir.exists() and Path(filepath).is_relative_to(self.source_dir):
                    rel_path = str(Path(filepath).relative_to(self.source_dir))
                else:
                    rel_path = Path(filepath).name
            except (ValueError, TypeError):
                rel_path = Path(filepath).name
            metadata_list = self.metadata_extractor.extract_from_ast(ast, rel_path)
            for metadata in metadata_list:
                self.dependency_manifest.add_metadata(metadata)

        # Check if any contract in this file is stubbed
        contract_name = Path(filepath).stem
        if contract_name in self.stubbed_contracts:
            return self._generate_stub(ast, contract_name)

        # Calculate file depth and path for relative imports
        # Only count depth if file is within source_dir (directory transpilation)
        current_file_path = ''
        try:
            resolved_filepath = Path(filepath).resolve()
            resolved_source_dir = self.source_dir.resolve()
            if resolved_filepath.is_relative_to(resolved_source_dir):
                rel_path = resolved_filepath.relative_to(resolved_source_dir)
                file_depth = len(rel_path.parent.parts)
                current_file_path = str(rel_path.with_suffix(''))
            else:
                # Single file transpilation - output goes to root of output_dir
                file_depth = 0
        except (ValueError, TypeError, AttributeError):
            file_depth = 0

        # Check if this file should be replaced with a runtime implementation
        replacement = self._get_runtime_replacement(filepath)
        if replacement:
            print(f"  -> Using runtime replacement for: {Path(filepath).name}")
            return self._generate_runtime_reexport(replacement, file_depth)

        # Generate TypeScript
        generator = TypeScriptCodeGenerator(
            self.registry if use_registry else None,
            file_depth=file_depth,
            current_file_path=current_file_path,
            runtime_replacement_classes=self.runtime_replacement_classes,
            runtime_replacement_mixins=self.runtime_replacement_mixins
        )
        ts_code = generator.generate(ast)

        return ts_code

    def _generate_stub(self, ast: SourceUnit, contract_name: str) -> str:
        """Generate a minimal stub for a contract that doesn't need full transpilation."""
        lines = [
            "// Auto-generated stub by sol2ts transpiler",
            "// This contract is stubbed - only minimal implementation provided",
            "",
            "import { Contract, ADDRESS_ZERO } from './runtime';",
            "",
        ]

        for definition in ast.definitions:
            if isinstance(definition, ContractDefinition) and definition.name == contract_name:
                # Generate minimal class
                base_class = "Contract"
                if definition.base_contracts:
                    # Use the first base contract if available
                    base_class = definition.base_contracts[0]

                abstract_modifier = "abstract " if definition.is_abstract else ""
                lines.append(f"export {abstract_modifier}class {definition.name} extends {base_class} {{")

                # Generate empty implementations for public/external functions
                for member in definition.members:
                    if isinstance(member, FunctionDefinition):
                        if member.visibility in ('public', 'external') and member.name:
                            # Generate empty stub method
                            params = ', '.join([f'_{p.name}: any' for p in member.parameters])
                            if member.return_parameters:
                                return_type = 'any' if len(member.return_parameters) == 1 else f'[{", ".join(["any"] * len(member.return_parameters))}]'
                                lines.append(f"  {member.name}({params}): {return_type} {{ return undefined as any; }}")
                            else:
                                lines.append(f"  {member.name}({params}): void {{}}")

                lines.append("}")
                break

        return '\n'.join(lines) + '\n'

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

        # Copy runtime support files to output directory
        self._copy_runtime()

    def _copy_runtime(self) -> None:
        """Copy runtime files to output directory."""
        # Locate runtime directory relative to this script
        script_dir = Path(__file__).parent
        runtime_src = script_dir / 'runtime'
        runtime_dest = self.output_dir / 'runtime'

        if runtime_src.exists():
            # Remove existing runtime dir to ensure clean copy
            if runtime_dest.exists():
                shutil.rmtree(runtime_dest)
            shutil.copytree(runtime_src, runtime_dest)
            print(f"Copied runtime to: {runtime_dest}")
        else:
            print(f"Warning: Runtime directory not found at {runtime_src}")

    def write_metadata(self, output_path: Optional[str] = None):
        """Write the dependency manifest and metadata to JSON files."""
        if not self.emit_metadata:
            return

        output_dir = Path(output_path) if output_path else self.output_dir

        # Write dependency manifest
        manifest_path = output_dir / 'dependency-manifest.json'
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        with open(manifest_path, 'w') as f:
            json.dump(self.dependency_manifest.to_dict(), f, indent=2)
        print(f"Written: {manifest_path}")

        # Write factory functions
        factories_path = output_dir / 'factories.ts'
        with open(factories_path, 'w') as f:
            f.write(self.dependency_manifest.generate_factories_ts())
        print(f"Written: {factories_path}")

    def get_metadata_json(self) -> str:
        """Get the dependency manifest as a JSON string."""
        return json.dumps(self.dependency_manifest.to_dict(), indent=2)


# =============================================================================
# METADATA AND DEPENDENCY EXTRACTION
# =============================================================================

@dataclass
class ContractDependency:
    """Represents a dependency required by a contract's constructor."""
    name: str  # Parameter name
    type_name: str  # Type name (e.g., 'IEngine', 'Baselight')
    is_interface: bool  # Whether the type is an interface

    def to_dict(self) -> Dict[str, Any]:
        return {
            'name': self.name,
            'typeName': self.type_name,
            'isInterface': self.is_interface
        }


@dataclass
class ContractMetadata:
    """Metadata extracted from a contract for dependency injection and UI purposes."""
    name: str
    file_path: str
    inherits_from: List[str]
    dependencies: List[ContractDependency]
    constants: Dict[str, Any]
    public_methods: List[str]
    is_move: bool  # Implements IMoveSet
    is_effect: bool  # Implements IEffect
    is_abstract: bool  # Abstract contract (cannot be instantiated)
    move_properties: Optional[Dict[str, Any]] = None  # Extracted move metadata if is_move

    def to_dict(self) -> Dict[str, Any]:
        result = {
            'name': self.name,
            'filePath': self.file_path,
            'inheritsFrom': self.inherits_from,
            'dependencies': [d.to_dict() for d in self.dependencies],
            'constants': self.constants,
            'publicMethods': self.public_methods,
            'isMove': self.is_move,
            'isEffect': self.is_effect,
            'isAbstract': self.is_abstract,
        }
        if self.move_properties:
            result['moveProperties'] = self.move_properties
        return result


class MetadataExtractor:
    """Extracts metadata from parsed Solidity ASTs for dependency injection and UI purposes."""

    def __init__(self, registry: TypeRegistry):
        self.registry = registry
        self.move_interfaces = {'IMoveSet'}
        self.effect_interfaces = {'IEffect'}
        self.standard_attack_bases = {'StandardAttack'}

    def extract_from_ast(self, ast: 'SourceUnit', file_path: str) -> List[ContractMetadata]:
        """Extract metadata from all contracts in an AST."""
        results = []
        for contract in ast.contracts:
            if contract.kind != 'interface':
                metadata = self._extract_contract_metadata(contract, file_path)
                results.append(metadata)
        return results

    def _extract_contract_metadata(self, contract: 'ContractDefinition', file_path: str) -> ContractMetadata:
        """Extract metadata from a single contract."""
        # Determine if this is a move or effect
        is_move = self._implements_interface(contract, self.move_interfaces)
        is_effect = self._implements_interface(contract, self.effect_interfaces)

        # Extract dependencies from constructor
        dependencies = self._extract_constructor_dependencies(contract)

        # Extract constants
        constants = self._extract_constants(contract)

        # Extract public methods
        public_methods = [
            f.name for f in contract.functions
            if f.name and f.visibility in ('public', 'external')
        ]

        # Extract move properties if applicable
        move_properties = None
        if is_move:
            move_properties = self._extract_move_properties(contract)

        return ContractMetadata(
            name=contract.name,
            file_path=file_path,
            inherits_from=contract.base_contracts or [],
            dependencies=dependencies,
            constants=constants,
            public_methods=public_methods,
            is_move=is_move,
            is_effect=is_effect,
            is_abstract=contract.kind in ('abstract', 'library'),
            move_properties=move_properties
        )

    def _implements_interface(self, contract: 'ContractDefinition', interfaces: Set[str]) -> bool:
        """Check if a contract implements any of the given interfaces."""
        if not contract.base_contracts:
            return False

        for base in contract.base_contracts:
            if base in interfaces:
                return True
            # Check if base contract is a known move base (like StandardAttack)
            if base in self.standard_attack_bases:
                return True
            # Recursively check if base implements the interface
            if base in self.registry.contracts:
                # Check if the base contract's bases include the interface
                if base in self.registry.contract_methods:
                    # This is a simplified check - a full implementation would
                    # traverse the inheritance tree
                    pass
        return False

    def _extract_constructor_dependencies(self, contract: 'ContractDefinition') -> List[ContractDependency]:
        """Extract dependencies from constructor parameters."""
        dependencies = []
        if not contract.constructor:
            return dependencies

        for param in contract.constructor.parameters:
            type_name = param.type_name.name if param.type_name else 'unknown'

            # Skip basic types
            if type_name in ('uint256', 'uint128', 'uint64', 'uint32', 'uint16', 'uint8',
                            'int256', 'int128', 'int64', 'int32', 'int16', 'int8',
                            'bool', 'address', 'bytes32', 'bytes', 'string'):
                continue

            is_interface = (type_name.startswith('I') and len(type_name) > 1 and
                          type_name[1].isupper()) or type_name in self.registry.interfaces

            dependencies.append(ContractDependency(
                name=param.name,
                type_name=type_name,
                is_interface=is_interface
            ))

        return dependencies

    def _extract_constants(self, contract: 'ContractDefinition') -> Dict[str, Any]:
        """Extract constant values from a contract."""
        constants = {}
        for var in contract.state_variables:
            if var.mutability == 'constant' and var.initial_value:
                value = self._extract_literal_value(var.initial_value)
                if value is not None:
                    constants[var.name] = value
        return constants

    def _extract_literal_value(self, expr: 'Expression') -> Any:
        """Extract a literal value from an expression."""
        if isinstance(expr, Literal):
            if expr.kind == 'number':
                try:
                    return int(expr.value)
                except ValueError:
                    return expr.value
            elif expr.kind == 'hex':
                return expr.value
            elif expr.kind == 'string':
                # Remove surrounding quotes
                return expr.value[1:-1] if expr.value.startswith('"') else expr.value
            elif expr.kind == 'bool':
                return expr.value == 'true'
        return None

    def _extract_move_properties(self, contract: 'ContractDefinition') -> Dict[str, Any]:
        """Extract move-specific properties from a contract."""
        properties: Dict[str, Any] = {}

        # Extract from constants
        constants = self._extract_constants(contract)
        for name, value in constants.items():
            properties[name] = value

        # Try to extract properties from getter functions
        for func in contract.functions:
            if not func.name or func.visibility not in ('public', 'external', 'internal'):
                continue

            # Check for pure/view functions that return single values
            if func.mutability not in ('pure', 'view'):
                continue

            if func.return_parameters and len(func.return_parameters) == 1:
                # Check for simple return statements
                if func.body and func.body.statements:
                    for stmt in func.body.statements:
                        if isinstance(stmt, ReturnStatement) and stmt.expression:
                            value = self._extract_literal_value(stmt.expression)
                            if value is not None:
                                properties[func.name] = value

        return properties


class DependencyManifest:
    """Generates a dependency manifest for all contracts."""

    def __init__(self):
        self.contracts: Dict[str, ContractMetadata] = {}

    def add_metadata(self, metadata: ContractMetadata) -> None:
        """Add contract metadata to the manifest."""
        self.contracts[metadata.name] = metadata

    def to_dict(self) -> Dict[str, Any]:
        """Convert to a dictionary for JSON serialization."""
        return {
            'contracts': {name: m.to_dict() for name, m in self.contracts.items()},
            'moves': {name: m.to_dict() for name, m in self.contracts.items() if m.is_move},
            'effects': {name: m.to_dict() for name, m in self.contracts.items() if m.is_effect},
            'dependencyGraph': self._build_dependency_graph()
        }

    def _build_dependency_graph(self) -> Dict[str, List[str]]:
        """Build a graph of contract dependencies."""
        graph = {}
        for name, metadata in self.contracts.items():
            deps = [d.type_name for d in metadata.dependencies]
            if deps:
                graph[name] = deps
        return graph

    def _build_interface_mappings(self) -> Dict[str, List[str]]:
        """Build a mapping of interface names to their concrete implementations.

        Uses the inherits_from field to find which contracts implement which interfaces.
        Only includes interfaces (names starting with 'I' followed by uppercase).
        Excludes abstract contracts since they cannot be instantiated.
        """
        interface_to_impls: Dict[str, List[str]] = {}

        for name, metadata in self.contracts.items():
            # Skip abstract contracts - they can't be instantiated
            if metadata.is_abstract:
                continue
            for base in metadata.inherits_from:
                # Check if base looks like an interface (IFoo pattern)
                if (base.startswith('I') and len(base) > 1 and
                    base[1].isupper() and not base.startswith('Interface')):
                    if base not in interface_to_impls:
                        interface_to_impls[base] = []
                    interface_to_impls[base].append(name)

        return interface_to_impls

    def _get_single_impl_aliases(self) -> Dict[str, str]:
        """Get interface aliases for interfaces with exactly one implementation."""
        mappings = self._build_interface_mappings()
        return {
            iface: impls[0]
            for iface, impls in mappings.items()
            if len(impls) == 1
        }

    def generate_factories_ts(self) -> str:
        """Generate TypeScript factory functions for dependency injection."""
        lines = [
            '// Auto-generated by sol2ts transpiler',
            '// Dependency injection configuration',
            '',
            "import { ContractContainer } from '../runtime';",
            ''
        ]

        # Only import non-abstract contracts (abstract ones can't be instantiated)
        for name in sorted(self.contracts.keys()):
            metadata = self.contracts[name]
            if metadata.is_abstract:
                continue
            # Convert file_path from .sol to .ts path (e.g., "types/TypeCalculator.sol" -> "./types/TypeCalculator")
            import_path = './' + metadata.file_path.replace('.sol', '')
            lines.append(f"import {{ {name} }} from '{import_path}';")

        # Build interface aliases
        single_impl_aliases = self._get_single_impl_aliases()

        # Generate the contracts registry - single source of truth
        lines.append('')
        lines.append('// Contract registry: maps contract names to their class and dependencies')
        lines.append('// This is the single source of truth for dependency injection')
        lines.append('export const contracts: Record<string, { cls: new (...args: any[]) => any; deps: string[] }> = {')
        for name, metadata in sorted(self.contracts.items()):
            if metadata.is_abstract:
                continue
            deps = [d.type_name for d in metadata.dependencies]
            lines.append(f"  {name}: {{ cls: {name}, deps: {deps} }},")
        lines.append('};')

        # Generate interface aliases
        lines.append('')
        lines.append('// Interface aliases: maps interface names to their implementation')
        lines.append('// Only includes interfaces with exactly one implementing contract')
        lines.append('export const interfaceAliases: Record<string, string> = {')
        for iface, impl in sorted(single_impl_aliases.items()):
            lines.append(f"  {iface}: '{impl}',")
        lines.append('};')

        # Generate container setup function that iterates over the data
        lines.append('')
        lines.append('// Container setup - registers all contracts and aliases')
        lines.append('export function setupContainer(container: ContractContainer): void {')
        lines.append('  // Register all contracts')
        lines.append('  for (const [name, { cls, deps }] of Object.entries(contracts)) {')
        lines.append('    if (deps.length === 0) {')
        lines.append('      container.registerLazySingleton(name, deps, () => new cls());')
        lines.append('    } else {')
        lines.append('      container.registerFactory(name, deps, (...args: any[]) => new cls(...args));')
        lines.append('    }')
        lines.append('  }')
        lines.append('')
        lines.append('  // Register interface aliases')
        lines.append('  for (const [iface, impl] of Object.entries(interfaceAliases)) {')
        lines.append('    container.registerAlias(iface, impl);')
        lines.append('  }')
        lines.append('}')
        lines.append('')

        return '\n'.join(lines)


# =============================================================================
# CLI INTERFACE
# =============================================================================

def main():
    import argparse

    parser = argparse.ArgumentParser(description='Solidity to TypeScript Transpiler')
    parser.add_argument('input', help='Input Solidity file or directory')
    parser.add_argument('-o', '--output', default='transpiler/ts-output', help='Output directory')
    parser.add_argument('--stdout', action='store_true', help='Print to stdout instead of file')
    parser.add_argument('-d', '--discover', action='append', metavar='DIR',
                        help='Directory to scan for type discovery (can be specified multiple times)')
    parser.add_argument('--stub', action='append', metavar='CONTRACT',
                        help='Contract name to generate as minimal stub (can be specified multiple times)')
    parser.add_argument('--emit-metadata', action='store_true',
                        help='Emit dependency manifest and factory functions')
    parser.add_argument('--metadata-only', action='store_true',
                        help='Only emit metadata, skip TypeScript generation')

    args = parser.parse_args()

    input_path = Path(args.input)

    # Collect discovery directories and stubbed contracts
    # Default to input directory if no discovery dirs specified
    if args.discover:
        discovery_dirs = args.discover
    elif input_path.is_dir():
        discovery_dirs = [str(input_path)]
    else:
        discovery_dirs = [str(input_path.parent)]
    stubbed_contracts = args.stub or []
    emit_metadata = args.emit_metadata or args.metadata_only

    if input_path.is_file():
        transpiler = SolidityToTypeScriptTranspiler(
            output_dir=args.output,
            discovery_dirs=discovery_dirs,
            stubbed_contracts=stubbed_contracts,
            emit_metadata=emit_metadata
        )

        # If no discovery dirs specified, try to find the project root
        # by looking for common Solidity project directories
        if not discovery_dirs:
            # Try parent directories for src/ or contracts/
            for parent in input_path.resolve().parents:
                src_dir = parent / 'src'
                contracts_dir = parent / 'contracts'
                if src_dir.exists():
                    transpiler.discover_types(str(src_dir))
                    break
                elif contracts_dir.exists():
                    transpiler.discover_types(str(contracts_dir))
                    break

        ts_code = transpiler.transpile_file(str(input_path))

        if args.metadata_only:
            # Only output metadata
            print(transpiler.get_metadata_json())
        elif args.stdout:
            print(ts_code)
        else:
            output_path = Path(args.output) / input_path.with_suffix('.ts').name
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, 'w') as f:
                f.write(ts_code)
            print(f"Written: {output_path}")

            # Copy runtime support files
            transpiler._copy_runtime()

            if emit_metadata:
                transpiler.write_metadata(args.output)

    elif input_path.is_dir():
        transpiler = SolidityToTypeScriptTranspiler(
            str(input_path), args.output, discovery_dirs, stubbed_contracts,
            emit_metadata=emit_metadata
        )
        # Also discover from the input directory itself
        transpiler.discover_types(str(input_path))

        if not args.metadata_only:
            results = transpiler.transpile_directory()
            transpiler.write_output(results)

        if emit_metadata:
            transpiler.write_metadata(args.output)

    else:
        print(f"Error: {args.input} is not a valid file or directory")
        sys.exit(1)


if __name__ == '__main__':
    main()

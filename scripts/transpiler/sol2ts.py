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

    def discover_from_source(self, source: str) -> None:
        """Discover types from a single Solidity source string."""
        lexer = Lexer(source)
        tokens = lexer.tokenize()
        parser = Parser(tokens)
        ast = parser.parse()
        self.discover_from_ast(ast)

    def discover_from_file(self, filepath: str) -> None:
        """Discover types from a Solidity file."""
        with open(filepath, 'r') as f:
            source = f.read()
        self.discover_from_source(source)

    def discover_from_directory(self, directory: str, pattern: str = '**/*.sol') -> None:
        """Discover types from all Solidity files in a directory."""
        from pathlib import Path
        for sol_file in Path(directory).glob(pattern):
            try:
                self.discover_from_file(str(sol_file))
            except Exception as e:
                print(f"Warning: Could not parse {sol_file} for type discovery: {e}")

    def discover_from_ast(self, ast: SourceUnit) -> None:
        """Extract type information from a parsed AST."""
        # Top-level structs
        for struct in ast.structs:
            self.structs.add(struct.name)

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

            # Collect structs defined inside contracts
            for struct in contract.structs:
                self.structs.add(struct.name)

            # Collect enums defined inside contracts
            for enum in contract.enums:
                self.enums.add(enum.name)

            # Collect methods
            methods = set()
            for func in contract.functions:
                if func.name:
                    methods.add(func.name)
            if contract.constructor:
                methods.add('constructor')
            if methods:
                self.contract_methods[name] = methods

            # Collect state variables
            state_vars = set()
            for var in contract.state_variables:
                state_vars.add(var.name)
                if var.mutability == 'constant':
                    self.constants.add(var.name)
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


# =============================================================================
# CODE GENERATOR
# =============================================================================

class TypeScriptCodeGenerator:
    """Generates TypeScript code from the AST."""

    def __init__(self, registry: Optional[TypeRegistry] = None):
        self.indent_level = 0
        self.indent_str = '  '
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

        # Base contracts needed for current file (for import generation)
        self.base_contracts_needed: Set[str] = set()
        # Library contracts referenced (for import generation)
        self.libraries_referenced: Set[str] = set()
        # Current file type (to avoid self-referencing prefixes)
        self.current_file_type = ''

    def indent(self) -> str:
        return self.indent_str * self.indent_level

    def get_qualified_name(self, name: str) -> str:
        """Get the qualified name for a type, adding appropriate prefix if needed.

        Handles Structs., Enums., Constants. prefixes based on the current file context.
        """
        if name in self.known_structs and self.current_file_type != 'Structs':
            return f'Structs.{name}'
        if name in self.known_enums and self.current_file_type != 'Enums':
            return f'Enums.{name}'
        if name in self.known_constants and self.current_file_type != 'Constants':
            return f'Constants.{name}'
        return name

    def generate(self, ast: SourceUnit) -> str:
        """Generate TypeScript code from the AST."""
        output = []

        # Reset base contracts needed for this file
        self.base_contracts_needed = set()
        self.libraries_referenced = set()

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

    def generate_imports(self, contract_name: str = '') -> str:
        """Generate import statements."""
        lines = []
        lines.append("import { keccak256, encodePacked, encodeAbiParameters, decodeAbiParameters, parseAbiParameters } from 'viem';")
        lines.append("import { Contract, Storage, ADDRESS_ZERO, sha256, sha256String } from './runtime';")

        # Import base contracts needed for inheritance
        for base_contract in sorted(self.base_contracts_needed):
            lines.append(f"import {{ {base_contract} }} from './{base_contract}';")

        # Import library contracts that are referenced
        for library in sorted(self.libraries_referenced):
            lines.append(f"import {{ {library} }} from './{library}';")

        # Import types based on current file type:
        # - Enums.ts: no imports needed from other modules
        # - Structs.ts: needs Enums (for Type, etc.) but not itself
        # - Constants.ts: may need Enums and Structs
        # - Other files: import all three
        if contract_name == 'Enums':
            pass  # Enums doesn't need to import anything
        elif contract_name == 'Structs':
            lines.append("import * as Enums from './Enums';")
        elif contract_name == 'Constants':
            lines.append("import * as Structs from './Structs';")
            lines.append("import * as Enums from './Enums';")
        elif contract_name:
            lines.append("import * as Structs from './Structs';")
            lines.append("import * as Enums from './Enums';")
            lines.append("import * as Constants from './Constants';")

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

        # Track this contract as known for future inheritance
        self.known_contracts.add(contract.name)
        self.current_class_name = contract.name
        self.current_contract_kind = contract.kind

        # Collect state variable and method names for this. prefix handling
        self.current_state_vars = {var.name for var in contract.state_variables
                                   if var.mutability != 'constant'}
        self.current_static_vars = {var.name for var in contract.state_variables
                                    if var.mutability == 'constant'}
        self.current_methods = {func.name for func in contract.functions}
        # Add runtime base class methods that need this. prefix
        self.current_methods.update({
            '_yulStorageKey', '_storageRead', '_storageWrite', '_emitEvent',
        })
        self.current_local_vars = set()
        # Populate type registry with state variable types
        self.var_types = {var.name: var.type_name for var in contract.state_variables}

        # Determine the extends clause based on base_contracts
        extends = ''
        self.current_base_classes = []  # Reset for this contract
        if contract.base_contracts:
            # Filter to known contracts (skip interfaces which are handled differently)
            base_classes = [bc for bc in contract.base_contracts
                           if bc not in self.known_interfaces]
            if base_classes:
                # Use the first non-interface base contract
                base_class = base_classes[0]
                extends = f' extends {base_class}'
                self.base_contracts_needed.add(base_class)
                self.current_base_classes = base_classes
                # Add base class methods to current_methods for this. prefix handling
                if base_class in self.known_contract_methods:
                    self.current_methods.update(self.known_contract_methods[base_class])
                # Add base class state variables to current_state_vars for this. prefix handling
                if base_class in self.known_contract_vars:
                    self.current_state_vars.update(self.known_contract_vars[base_class])
            else:
                extends = ' extends Contract'
        else:
            extends = ' extends Contract'

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
            # Use Record (plain object) for mappings - allows [] access
            value_type = self.solidity_type_to_ts(var.type_name.value_type)
            # Nested mappings become nested Records
            if var.type_name.value_type.is_mapping:
                inner_value = self.solidity_type_to_ts(var.type_name.value_type.value_type)
                return f'{self.indent()}{modifier}{var.name}: Record<string, Record<string, {inner_value}>> = {{}};'
            return f'{self.indent()}{modifier}{var.name}: Record<string, {value_type}> = {{}};'

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
                            args = ', '.join([
                                self.generate_expression(arg)
                                for arg in base_call.arguments
                            ])
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

        lines.append(f'{self.indent()}{visibility}{static_prefix}{func.name}({params}): {return_type} {{')
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
            # Check if last statement is already a return
            has_explicit_return = False
            if func.body.statements:
                last_stmt = func.body.statements[-1]
                has_explicit_return = isinstance(last_stmt, ReturnStatement)
            if not has_explicit_return:
                if len(named_return_vars) == 1:
                    lines.append(f'{self.indent()}return {named_return_vars[0]};')
                else:
                    lines.append(f'{self.indent()}return [{", ".join(named_return_vars)}];')

        self.indent_level -= 1
        lines.append(f'{self.indent()}}}')
        lines.append('')

        # Clear local vars after function
        self.current_local_vars = set()
        return '\n'.join(lines)

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

        lines.append(f'{self.indent()}{visibility}{main_func.name}({", ".join(param_strs)}): {return_type} {{')
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
            init = ''
            if stmt.initial_value:
                init = f' = {self.generate_expression(stmt.initial_value)}'
            return f'{self.indent()}let {decl.name}: {ts_type}{init};'
        else:
            # Tuple declaration (including single value with trailing comma like (x,) = ...)
            names = ', '.join([d.name if d else '' for d in stmt.declarations])
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
        code = re.sub(r':\s*=', ':=', code)           # ": =" -> ":="
        code = re.sub(r'\s*\.\s*', '.', code)         # " . " -> "."
        code = re.sub(r'(\w)\s+\(', r'\1(', code)     # "func (" -> "func("
        code = re.sub(r'\(\s+', '(', code)            # "( " -> "("
        code = re.sub(r'\s+\)', ')', code)            # " )" -> ")"
        code = re.sub(r'\s+,', ',', code)             # " ," -> ","
        code = re.sub(r',\s+', ', ', code)            # normalize comma spacing
        return code

    def _transpile_yul_block(self, code: str, slot_vars: Dict[str, str]) -> str:
        """Transpile a block of Yul code to TypeScript."""
        lines = []

        # Parse let bindings: let var := expr
        let_pattern = re.compile(r'let\s+(\w+)\s*:=\s*([^{}\n]+?)(?=\s+(?:let|if|for|switch|$)|\s*$)')
        for match in let_pattern.finditer(code):
            var_name = match.group(1)
            expr = match.group(2).strip()

            # Check if this is a .slot access (storage key)
            slot_match = re.match(r'(\w+)\.slot', expr)
            if slot_match:
                storage_var = slot_match.group(1)
                slot_vars[var_name] = storage_var
                # Cast to any for storage operations since we may be passing struct references
                lines.append(f'const {var_name} = this._getStorageKey({storage_var} as any);')
            else:
                ts_expr = self._transpile_yul_expr(expr, slot_vars)
                lines.append(f'let {var_name} = {ts_expr};')

        # Parse if statements: if cond { body }
        if_pattern = re.compile(r'if\s+([^{]+)\s*\{([^}]*)\}')
        for match in if_pattern.finditer(code):
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
        code_without_ifs = re.sub(r'if\s+[^{]+\{[^}]*\}', '', code)
        call_pattern = re.compile(r'\b(sstore|mstore|revert)\s*\(([^)]+)\)')
        for match in call_pattern.finditer(code_without_ifs):
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

        # Identifiers - apply prefix logic for known types
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
        name = ident.name

        # Handle special identifiers
        if name == 'msg':
            return 'this._msg'
        elif name == 'block':
            return 'this._block'
        elif name == 'tx':
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
        # Handle array allocation: new Type[](size) -> new Array(size)
        if isinstance(call.function, NewExpression):
            if call.function.type_name.is_array and call.arguments:
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
                return f'BigInt({args})'
            elif name == 'address':
                # Handle address literals like address(0xdead)
                if call.arguments:
                    arg = call.arguments[0]
                    if isinstance(arg, Literal) and arg.kind in ('number', 'hex'):
                        val = arg.value
                        # Convert to padded 40-char hex address
                        if val.startswith('0x') or val.startswith('0X'):
                            hex_val = val[2:].lower()
                        else:
                            hex_val = hex(int(val))[2:]
                        return f'"0x{hex_val.zfill(40)}"'
                return args  # Pass through - addresses are strings
            elif name == 'bool':
                return args  # Pass through - JS truthy works
            elif name == 'bytes32':
                # Handle bytes32 literals like bytes32(0)
                if call.arguments:
                    arg = call.arguments[0]
                    if isinstance(arg, Literal) and arg.kind in ('number', 'hex'):
                        val = arg.value
                        if val == '0':
                            return '"0x' + '0' * 64 + '"'
                        elif val.startswith('0x') or val.startswith('0X'):
                            hex_val = val[2:].lower()
                            return f'"0x{hex_val.zfill(64)}"'
                        else:
                            # Decimal literal
                            hex_val = hex(int(val))[2:]
                            return f'"0x{hex_val.zfill(64)}"'
                return args  # Pass through
            elif name.startswith('bytes'):
                return args  # Pass through
            # Handle interface type casts like IMatchmaker(x) -> x
            # Also handles struct constructors without args -> default object
            elif name.startswith('I') and name[1].isupper():
                # Interface cast - just pass through the value
                if args:
                    return args
                return '{}'  # Empty interface cast
            # Handle struct "constructors" with named arguments
            elif name[0].isupper() and call.named_arguments:
                # Struct constructor with named args: ATTACK_PARAMS({NAME: "x", ...})
                qualified = self.get_qualified_name(name)
                fields = ', '.join([
                    f'{k}: {self.generate_expression(v)}'
                    for k, v in call.named_arguments.items()
                ])
                return f'{{ {fields} }} as {qualified}'
            # Handle custom type casts and struct "constructors" with no args
            elif name[0].isupper() and not args:
                # Struct with no args - return default object with proper prefix
                qualified = self.get_qualified_name(name)
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

        # Handle .length - in JS returns number, but Solidity expects uint256 (bigint)
        if member == 'length':
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
        # For member access like Enums.Something
        if isinstance(arg, MemberAccess):
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return "{type: 'uint8'}"
        # Default fallback
        return "{type: 'uint256'}"

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
                    if var_type_name == 'bytes32' or var_type_name == 'address':
                        return f'{expr} as `0x${{string}}`'
                    # Small integer types need Number() conversion for viem
                    if var_type_name in ('int8', 'int16', 'int32', 'int64', 'int128',
                                          'uint8', 'uint16', 'uint32', 'uint64', 'uint128'):
                        return f'Number({expr})'

        # Member access like Enums.Something also needs Number conversion
        if isinstance(arg, MemberAccess):
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return f'Number({expr})'

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
        elif index.endswith('n'):
            # 0n -> 0
            index = index[:-1]
        elif needs_number_conversion and isinstance(access.index, Identifier):
            # For loop variables (i, j, etc.) accessing arrays/mappings, convert to Number
            index = f'Number({index})'
        elif needs_number_conversion and isinstance(access.index, BinaryOperation):
            # For expressions like baseSlot + i, wrap in Number()
            index = f'Number({index})'
        # For string/address mapping keys - leave as-is

        return f'{base}[{index}]'

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

        # Handle address literals like address(0xdead)
        if type_name == 'address':
            if isinstance(inner_expr, Literal) and inner_expr.kind in ('number', 'hex'):
                val = inner_expr.value
                # Convert to padded 40-char hex address
                if val.startswith('0x') or val.startswith('0X'):
                    hex_val = val[2:].lower()
                else:
                    hex_val = hex(int(val))[2:]
                return f'"0x{hex_val.zfill(40)}"'
            expr = self.generate_expression(inner_expr)
            if expr.startswith('"') or expr.startswith("'"):
                return expr
            return expr  # Already a string in most cases

        # Handle bytes32 casts
        if type_name == 'bytes32':
            if isinstance(inner_expr, Literal) and inner_expr.kind in ('number', 'hex'):
                val = inner_expr.value
                if val == '0':
                    return '"0x' + '0' * 64 + '"'
                elif val.startswith('0x') or val.startswith('0X'):
                    hex_val = val[2:].lower()
                    return f'"0x{hex_val.zfill(64)}"'
                else:
                    hex_val = hex(int(val))[2:]
                    return f'"0x{hex_val.zfill(64)}"'
            # For computed expressions, convert bigint to 64-char hex string
            expr = self.generate_expression(inner_expr)
            return f'`0x${{({expr}).toString(16).padStart(64, "0")}}`'

        expr = self.generate_expression(inner_expr)

        # For integers, just ensure it's a BigInt - skip bit masking for simplicity
        if type_name.startswith('uint') or type_name.startswith('int'):
            # If already looks like a BigInt or number, just use it
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
        elif name in self.known_interfaces:
            ts_type = 'any'  # Interfaces become 'any' in TypeScript
        elif name in self.known_structs or name in self.known_enums:
            ts_type = self.get_qualified_name(name)
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
        return 'undefined as any'


# =============================================================================
# MAIN TRANSPILER CLASS
# =============================================================================

class SolidityToTypeScriptTranspiler:
    """Main transpiler class that orchestrates the conversion process."""

    def __init__(self, source_dir: str = '.', output_dir: str = './ts-output',
                 discovery_dirs: Optional[List[str]] = None):
        self.source_dir = Path(source_dir)
        self.output_dir = Path(output_dir)
        self.parsed_files: Dict[str, SourceUnit] = {}
        self.registry = TypeRegistry()

        # Run type discovery on specified directories
        if discovery_dirs:
            for dir_path in discovery_dirs:
                self.registry.discover_from_directory(dir_path)

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

        # Generate TypeScript
        generator = TypeScriptCodeGenerator(self.registry if use_registry else None)
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
    parser.add_argument('-d', '--discover', action='append', metavar='DIR',
                        help='Directory to scan for type discovery (can be specified multiple times)')

    args = parser.parse_args()

    input_path = Path(args.input)

    # Collect discovery directories
    discovery_dirs = args.discover or []

    if input_path.is_file():
        transpiler = SolidityToTypeScriptTranspiler(discovery_dirs=discovery_dirs)

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

        if args.stdout:
            print(ts_code)
        else:
            output_path = Path(args.output) / input_path.with_suffix('.ts').name
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, 'w') as f:
                f.write(ts_code)
            print(f"Written: {output_path}")

    elif input_path.is_dir():
        transpiler = SolidityToTypeScriptTranspiler(str(input_path), args.output, discovery_dirs)
        # Also discover from the input directory itself
        transpiler.discover_types(str(input_path))
        results = transpiler.transpile_directory()
        transpiler.write_output(results)

    else:
        print(f"Error: {args.input} is not a valid file or directory")
        sys.exit(1)


if __name__ == '__main__':
    main()

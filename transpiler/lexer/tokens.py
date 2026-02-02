"""
Token definitions for the Solidity lexer.

This module contains the TokenType enum, Token dataclass, and
constant mappings for keywords and operators.
"""

from dataclasses import dataclass
from enum import Enum, auto


class TokenType(Enum):
    """Enumeration of all token types recognized by the Solidity lexer."""

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
    """Represents a single token from the lexer."""
    type: TokenType
    value: str
    line: int
    column: int


# Keyword to TokenType mapping
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

# Two-character operators
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

# Single-character operators and delimiters
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

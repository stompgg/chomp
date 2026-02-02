"""
Lexer implementation for Solidity source code.

The Lexer tokenizes Solidity source code into a stream of tokens
that can be consumed by the parser.
"""

from typing import List, Tuple

from .tokens import Token, TokenType, KEYWORDS, TWO_CHAR_OPS, SINGLE_CHAR_OPS


class Lexer:
    """
    Lexer for Solidity source code.

    Converts source text into a list of tokens for parsing.
    """

    def __init__(self, source: str):
        self.source = source
        self.pos = 0
        self.line = 1
        self.column = 1
        self.tokens: List[Token] = []

    def peek(self, offset: int = 0) -> str:
        """Look ahead in the source without consuming."""
        pos = self.pos + offset
        if pos >= len(self.source):
            return ''
        return self.source[pos]

    def advance(self) -> str:
        """Consume and return the current character."""
        ch = self.peek()
        self.pos += 1
        if ch == '\n':
            self.line += 1
            self.column = 1
        else:
            self.column += 1
        return ch

    def skip_whitespace(self) -> None:
        """Skip over whitespace characters."""
        ch = self.peek()
        while ch and ch in ' \t\r\n':
            self.advance()
            ch = self.peek()

    def skip_comment(self) -> None:
        """Skip over single-line and multi-line comments."""
        if self.peek() == '/' and self.peek(1) == '/':
            # Single-line comment
            while self.peek() and self.peek() != '\n':
                self.advance()
        elif self.peek() == '/' and self.peek(1) == '*':
            # Multi-line comment
            self.advance()  # skip /
            self.advance()  # skip *
            while self.peek():
                if self.peek() == '*' and self.peek(1) == '/':
                    self.advance()  # skip *
                    self.advance()  # skip /
                    break
                self.advance()

    def read_string(self) -> str:
        """Read a string literal including its quotes."""
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
        """Read a numeric literal (decimal or hex)."""
        result = ''
        token_type = TokenType.NUMBER

        if self.peek() == '0' and self.peek(1) in 'xX':
            # Hexadecimal number
            result += self.advance()  # 0
            result += self.advance()  # x
            token_type = TokenType.HEX_NUMBER
            while self.peek() in '0123456789abcdefABCDEF_':
                if self.peek() != '_':
                    result += self.advance()
                else:
                    self.advance()  # skip underscore
        else:
            # Decimal number
            while self.peek() in '0123456789_':
                if self.peek() != '_':
                    result += self.advance()
                else:
                    self.advance()  # skip underscore
            # Handle decimal point
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
        """Read an identifier or keyword."""
        result = ''
        while self.peek() and (self.peek().isalnum() or self.peek() == '_'):
            result += self.advance()
        return result

    def add_token(self, token_type: TokenType, value: str) -> None:
        """Add a token to the token list."""
        self.tokens.append(Token(token_type, value, self.line, self.column))

    def tokenize(self) -> List[Token]:
        """
        Tokenize the entire source and return a list of tokens.

        Returns:
            List of Token objects, ending with an EOF token.
        """
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
            if two_char in TWO_CHAR_OPS:
                self.advance()
                self.advance()
                self.tokens.append(Token(TWO_CHAR_OPS[two_char], two_char, start_line, start_col))
                continue

            # Single-character operators and delimiters
            if ch in SINGLE_CHAR_OPS:
                self.advance()
                self.tokens.append(Token(SINGLE_CHAR_OPS[ch], ch, start_line, start_col))
                continue

            # Unknown character - skip
            self.advance()

        self.tokens.append(Token(TokenType.EOF, '', self.line, self.column))
        return self.tokens

"""
Yul/Assembly transpiler for inline assembly blocks.

This module handles the conversion of Yul (inline assembly) code to
TypeScript equivalents for storage operations and other low-level functions.

Uses a proper recursive descent parser instead of regex for reliable handling
of nested constructs (if blocks, for loops, switch/case, nested function calls).
"""

from typing import Dict, List, Optional, Tuple
from dataclasses import dataclass, field


# =============================================================================
# YUL AST NODES
# =============================================================================

@dataclass
class YulNode:
    """Base class for Yul AST nodes."""
    pass


@dataclass
class YulBlock(YulNode):
    """A block of Yul statements: { stmt1 stmt2 ... }"""
    statements: List[YulNode] = field(default_factory=list)


@dataclass
class YulLet(YulNode):
    """Variable declaration: let x := expr"""
    name: str = ''
    value: Optional['YulExpression'] = None


@dataclass
class YulAssignment(YulNode):
    """Variable assignment: x := expr"""
    name: str = ''
    value: Optional['YulExpression'] = None


@dataclass
class YulIf(YulNode):
    """If statement: if cond { body }"""
    condition: Optional['YulExpression'] = None
    body: Optional[YulBlock] = None


@dataclass
class YulFor(YulNode):
    """For loop: for { init } cond { post } { body }"""
    init: Optional[YulBlock] = None
    condition: Optional['YulExpression'] = None
    post: Optional[YulBlock] = None
    body: Optional[YulBlock] = None


@dataclass
class YulSwitch(YulNode):
    """Switch statement: switch expr case val { body } default { body }"""
    expression: Optional['YulExpression'] = None
    cases: List[Tuple[Optional['YulExpression'], YulBlock]] = field(default_factory=list)


@dataclass
class YulBreak(YulNode):
    """Break statement."""
    pass


@dataclass
class YulContinue(YulNode):
    """Continue statement."""
    pass


@dataclass
class YulLeave(YulNode):
    """Leave statement (return from Yul function)."""
    pass


@dataclass
class YulExpressionStatement(YulNode):
    """Expression used as statement (function call)."""
    expression: Optional['YulExpression'] = None


@dataclass
class YulExpression:
    """Base class for Yul expressions."""
    pass


@dataclass
class YulLiteral(YulExpression):
    """Literal value: 0x1234, 42, true, "string"."""
    value: str = ''
    kind: str = 'number'  # 'number', 'hex', 'string', 'bool'


@dataclass
class YulIdentifier(YulExpression):
    """Variable or function name reference."""
    name: str = ''


@dataclass
class YulFunctionCall(YulExpression):
    """Function call: func(arg1, arg2, ...)."""
    name: str = ''
    arguments: List[YulExpression] = field(default_factory=list)


@dataclass
class YulSlotAccess(YulExpression):
    """Storage slot access: var.slot."""
    variable: str = ''


@dataclass
class YulOffsetAccess(YulExpression):
    """Storage offset access: var.offset."""
    variable: str = ''


# =============================================================================
# YUL TOKENIZER
# =============================================================================

@dataclass
class YulToken:
    """A token produced by the Yul tokenizer."""
    type: str  # 'keyword', 'identifier', 'number', 'hex', 'string', 'symbol'
    value: str
    pos: int = 0


YUL_KEYWORDS = {
    'let', 'if', 'for', 'switch', 'case', 'default',
    'break', 'continue', 'leave', 'function',
    'true', 'false',
}


class YulTokenizer:
    """Tokenizes Yul source code into a stream of tokens."""

    def __init__(self, source: str):
        self._source = source
        self._pos = 0
        self._tokens: List[YulToken] = []

    def tokenize(self) -> List[YulToken]:
        """Tokenize the entire source into a list of tokens."""
        while self._pos < len(self._source):
            self._skip_whitespace()
            if self._pos >= len(self._source):
                break

            ch = self._source[self._pos]

            # Single-line comment
            if ch == '/' and self._pos + 1 < len(self._source) and self._source[self._pos + 1] == '/':
                self._skip_line_comment()
                continue

            # Multi-line comment
            if ch == '/' and self._pos + 1 < len(self._source) and self._source[self._pos + 1] == '*':
                self._skip_block_comment()
                continue

            # Assignment operator := (must check before single-char ':')
            if ch == ':' and self._pos + 1 < len(self._source) and self._source[self._pos + 1] == '=':
                self._tokens.append(YulToken('symbol', ':=', self._pos))
                self._pos += 2
                continue

            # Symbols
            if ch in '{}(),:':
                self._tokens.append(YulToken('symbol', ch, self._pos))
                self._pos += 1
                continue

            # Dot (for .slot, .offset)
            if ch == '.':
                self._tokens.append(YulToken('symbol', '.', self._pos))
                self._pos += 1
                continue

            # Hex literal
            if ch == '0' and self._pos + 1 < len(self._source) and self._source[self._pos + 1] in 'xX':
                self._read_hex()
                continue

            # Number literal
            if ch.isdigit():
                self._read_number()
                continue

            # String literal
            if ch in '"\'':
                self._read_string(ch)
                continue

            # Hex string literal (hex"...")
            if ch == 'h' and self._source[self._pos:self._pos + 4] in ('hex"', "hex'"):
                self._read_hex_string()
                continue

            # Identifier or keyword
            if ch.isalpha() or ch == '_' or ch == '$':
                self._read_identifier()
                continue

            # Skip unknown characters
            self._pos += 1

        return self._tokens

    def _skip_whitespace(self):
        while self._pos < len(self._source) and self._source[self._pos] in ' \t\n\r':
            self._pos += 1

    def _skip_line_comment(self):
        while self._pos < len(self._source) and self._source[self._pos] != '\n':
            self._pos += 1

    def _skip_block_comment(self):
        self._pos += 2  # skip /*
        while self._pos + 1 < len(self._source):
            if self._source[self._pos] == '*' and self._source[self._pos + 1] == '/':
                self._pos += 2
                return
            self._pos += 1
        self._pos = len(self._source)

    def _read_hex(self):
        start = self._pos
        self._pos += 2  # skip 0x
        while self._pos < len(self._source) and (self._source[self._pos].isalnum() or self._source[self._pos] == '_'):
            self._pos += 1
        value = self._source[start:self._pos].replace('_', '')
        self._tokens.append(YulToken('hex', value, start))

    def _read_number(self):
        start = self._pos
        while self._pos < len(self._source) and (self._source[self._pos].isdigit() or self._source[self._pos] == '_'):
            self._pos += 1
        value = self._source[start:self._pos].replace('_', '')
        self._tokens.append(YulToken('number', value, start))

    def _read_string(self, quote: str):
        start = self._pos
        self._pos += 1  # skip opening quote
        while self._pos < len(self._source) and self._source[self._pos] != quote:
            if self._source[self._pos] == '\\':
                self._pos += 1  # skip escape
            self._pos += 1
        if self._pos < len(self._source):
            self._pos += 1  # skip closing quote
        value = self._source[start:self._pos]
        self._tokens.append(YulToken('string', value, start))

    def _read_hex_string(self):
        start = self._pos
        self._pos += 3  # skip hex"
        quote = self._source[self._pos - 1]
        while self._pos < len(self._source) and self._source[self._pos] != quote:
            self._pos += 1
        if self._pos < len(self._source):
            self._pos += 1  # skip closing quote
        # Extract just the hex content (strip "hex" prefix, quotes, underscores and whitespace)
        raw = self._source[start + 4:self._pos - 1]
        hex_content = raw.replace('_', '').replace(' ', '')
        self._tokens.append(YulToken('hex', f'0x{hex_content}', start))

    def _read_identifier(self):
        start = self._pos
        while self._pos < len(self._source) and (
            self._source[self._pos].isalnum() or self._source[self._pos] in '_$'
        ):
            self._pos += 1
        value = self._source[start:self._pos]
        if value in YUL_KEYWORDS:
            self._tokens.append(YulToken('keyword', value, start))
        else:
            self._tokens.append(YulToken('identifier', value, start))


# =============================================================================
# YUL PARSER (RECURSIVE DESCENT)
# =============================================================================

class YulParser:
    """
    Recursive descent parser for Yul assembly code.

    Produces a YulBlock AST from a token stream.
    """

    def __init__(self, tokens: List[YulToken]):
        self._tokens = tokens
        self._pos = 0

    def parse(self) -> YulBlock:
        """Parse the token stream into a YulBlock AST."""
        statements = []
        while self._pos < len(self._tokens):
            stmt = self._parse_statement()
            if stmt is not None:
                statements.append(stmt)
        return YulBlock(statements=statements)

    def _peek(self) -> Optional[YulToken]:
        if self._pos < len(self._tokens):
            return self._tokens[self._pos]
        return None

    def _advance(self) -> Optional[YulToken]:
        tok = self._peek()
        if tok:
            self._pos += 1
        return tok

    def _expect(self, type: str, value: Optional[str] = None) -> YulToken:
        tok = self._advance()
        if tok is None:
            raise SyntaxError(f"Expected {type} {value!r}, got EOF")
        if tok.type != type or (value is not None and tok.value != value):
            raise SyntaxError(f"Expected {type} {value!r}, got {tok.type} {tok.value!r}")
        return tok

    def _match(self, type: str, value: Optional[str] = None) -> bool:
        tok = self._peek()
        if tok and tok.type == type and (value is None or tok.value == value):
            return True
        return False

    def _parse_statement(self) -> Optional[YulNode]:
        """Parse a single Yul statement."""
        tok = self._peek()
        if tok is None:
            return None

        # Block
        if tok.type == 'symbol' and tok.value == '{':
            return self._parse_block()

        # Keywords
        if tok.type == 'keyword':
            if tok.value == 'let':
                return self._parse_let()
            elif tok.value == 'if':
                return self._parse_if()
            elif tok.value == 'for':
                return self._parse_for()
            elif tok.value == 'switch':
                return self._parse_switch()
            elif tok.value == 'break':
                self._advance()
                return YulBreak()
            elif tok.value == 'continue':
                self._advance()
                return YulContinue()
            elif tok.value == 'leave':
                self._advance()
                return YulLeave()
            elif tok.value == 'function':
                return self._parse_yul_function()

        # Assignment or expression statement
        if tok.type == 'identifier':
            return self._parse_assignment_or_expression()

        # Skip unexpected tokens
        self._advance()
        return None

    def _parse_block(self) -> YulBlock:
        """Parse a { ... } block."""
        self._expect('symbol', '{')
        statements = []
        while not self._match('symbol', '}'):
            if self._peek() is None:
                break
            stmt = self._parse_statement()
            if stmt is not None:
                statements.append(stmt)
        if self._match('symbol', '}'):
            self._advance()
        return YulBlock(statements=statements)

    def _parse_let(self) -> YulLet:
        """Parse: let name := expr"""
        self._expect('keyword', 'let')
        name_tok = self._expect('identifier')
        value = None
        if self._match('symbol', ':='):
            self._advance()
            value = self._parse_expression()
        return YulLet(name=name_tok.value, value=value)

    def _parse_assignment_or_expression(self) -> YulNode:
        """Parse: name := expr  OR  funcCall(args)"""
        # Look ahead for :=
        if self._pos + 1 < len(self._tokens) and self._tokens[self._pos + 1].value == ':=':
            name_tok = self._advance()
            self._advance()  # skip :=
            value = self._parse_expression()
            return YulAssignment(name=name_tok.value, value=value)

        # Otherwise it's an expression statement (function call)
        expr = self._parse_expression()
        return YulExpressionStatement(expression=expr)

    def _parse_if(self) -> YulIf:
        """Parse: if cond { body }"""
        self._expect('keyword', 'if')
        condition = self._parse_expression()
        body = self._parse_block()
        return YulIf(condition=condition, body=body)

    def _parse_for(self) -> YulFor:
        """Parse: for { init } cond { post } { body }"""
        self._expect('keyword', 'for')
        init = self._parse_block()
        condition = self._parse_expression()
        post = self._parse_block()
        body = self._parse_block()
        return YulFor(init=init, condition=condition, post=post, body=body)

    def _parse_switch(self) -> YulSwitch:
        """Parse: switch expr case val { body } ... default { body }"""
        self._expect('keyword', 'switch')
        expression = self._parse_expression()
        cases: List[Tuple[Optional[YulExpression], YulBlock]] = []

        while self._match('keyword', 'case') or self._match('keyword', 'default'):
            tok = self._advance()
            if tok.value == 'case':
                case_value = self._parse_expression()
                case_body = self._parse_block()
                cases.append((case_value, case_body))
            else:  # default
                case_body = self._parse_block()
                cases.append((None, case_body))

        return YulSwitch(expression=expression, cases=cases)

    def _parse_yul_function(self) -> Optional[YulNode]:
        """Parse Yul function definition (skip for now, not needed for transpilation)."""
        self._expect('keyword', 'function')
        # Skip until we find and consume the body block
        self._expect('identifier')  # function name
        if self._match('symbol', '('):
            self._advance()
            while not self._match('symbol', ')'):
                if self._peek() is None:
                    break
                self._advance()
            if self._match('symbol', ')'):
                self._advance()
        # Optional return values
        if self._match('symbol', '-') or (self._peek() and self._peek().value == '->'):
            self._advance()  # skip ->
            if self._peek() and self._peek().value == '>':
                self._advance()
            # Skip return vars
            while self._peek() and not self._match('symbol', '{'):
                self._advance()
        if self._match('symbol', '{'):
            self._parse_block()  # consume but ignore body
        return None

    def _parse_expression(self) -> YulExpression:
        """Parse a Yul expression."""
        tok = self._peek()
        if tok is None:
            return YulLiteral(value='0', kind='number')

        # Literal: number
        if tok.type == 'number':
            self._advance()
            return YulLiteral(value=tok.value, kind='number')

        # Literal: hex
        if tok.type == 'hex':
            self._advance()
            return YulLiteral(value=tok.value, kind='hex')

        # Literal: string
        if tok.type == 'string':
            self._advance()
            return YulLiteral(value=tok.value, kind='string')

        # Literal: true/false
        if tok.type == 'keyword' and tok.value in ('true', 'false'):
            self._advance()
            return YulLiteral(value=tok.value, kind='bool')

        # Identifier, potentially followed by ( for function call or . for slot/offset
        if tok.type == 'identifier':
            self._advance()
            name = tok.value

            # Check for .slot or .offset
            if self._match('symbol', '.'):
                self._advance()
                member_tok = self._peek()
                if member_tok and member_tok.type == 'identifier':
                    self._advance()
                    if member_tok.value == 'slot':
                        return YulSlotAccess(variable=name)
                    elif member_tok.value == 'offset':
                        return YulOffsetAccess(variable=name)
                    # Other member access: treat as identifier
                    return YulIdentifier(name=f'{name}.{member_tok.value}')

            # Check for function call
            if self._match('symbol', '('):
                self._advance()
                args = []
                if not self._match('symbol', ')'):
                    args.append(self._parse_expression())
                    while self._match('symbol', ','):
                        self._advance()
                        args.append(self._parse_expression())
                if self._match('symbol', ')'):
                    self._advance()
                return YulFunctionCall(name=name, arguments=args)

            return YulIdentifier(name=name)

        # Unknown - skip and return placeholder
        self._advance()
        return YulLiteral(value='0', kind='number')


# =============================================================================
# YUL CODE GENERATOR (AST -> TypeScript)
# =============================================================================

class YulTranspiler:
    """
    Transpiler for Yul/inline assembly code.

    Converts Yul assembly blocks to equivalent TypeScript code for
    simulation purposes using a proper AST-based approach.

    Key Yul operations and their TypeScript equivalents:
    - sload(slot) -> this._storageRead(slotKey)
    - sstore(slot, value) -> this._storageWrite(slotKey, value)
    - var.slot -> get storage key for variable
    - mstore/mload -> memory operations (usually no-op for simulation)
    """

    def __init__(self, known_constants: set = None):
        """Initialize with optional set of known constant names.

        Args:
            known_constants: Set of constant names that should be prefixed with 'Constants.'
        """
        self._known_constants = known_constants or set()
        self._warnings: List[str] = []

    @property
    def warnings(self) -> List[str]:
        """Get warnings generated during transpilation."""
        return self._warnings

    def transpile(self, yul_code: str) -> str:
        """
        Transpile a Yul assembly block to TypeScript.

        Args:
            yul_code: The raw Yul code string

        Returns:
            TypeScript code equivalent
        """
        self._warnings = []
        slot_vars: Dict[str, str] = {}

        try:
            tokenizer = YulTokenizer(yul_code)
            tokens = tokenizer.tokenize()
            parser = YulParser(tokens)
            ast = parser.parse()
            return self._generate_block_contents(ast, slot_vars, indent=0)
        except SyntaxError as e:
            self._warnings.append(f"Yul parse error: {e}")
            return f'// Yul parse error: {e}'

    def _generate_block_contents(
        self,
        block: YulBlock,
        slot_vars: Dict[str, str],
        indent: int = 0
    ) -> str:
        """Generate TypeScript code from a YulBlock's statements."""
        lines = []
        for stmt in block.statements:
            line = self._generate_statement(stmt, slot_vars, indent)
            if line:
                lines.append(line)
        return '\n'.join(lines) if lines else '// Assembly: no-op'

    def _generate_statement(
        self,
        stmt: YulNode,
        slot_vars: Dict[str, str],
        indent: int
    ) -> str:
        """Generate TypeScript code from a single Yul statement."""
        prefix = '  ' * indent

        if isinstance(stmt, YulLet):
            return self._generate_let(stmt, slot_vars, prefix)
        elif isinstance(stmt, YulAssignment):
            return self._generate_assignment(stmt, slot_vars, prefix)
        elif isinstance(stmt, YulIf):
            return self._generate_if(stmt, slot_vars, indent, prefix)
        elif isinstance(stmt, YulFor):
            return self._generate_for(stmt, slot_vars, indent, prefix)
        elif isinstance(stmt, YulSwitch):
            return self._generate_switch(stmt, slot_vars, indent, prefix)
        elif isinstance(stmt, YulBreak):
            return f'{prefix}break;'
        elif isinstance(stmt, YulContinue):
            return f'{prefix}continue;'
        elif isinstance(stmt, YulLeave):
            return f'{prefix}return;'
        elif isinstance(stmt, YulExpressionStatement):
            return self._generate_expr_statement(stmt, slot_vars, prefix)
        elif isinstance(stmt, YulBlock):
            # Nested block
            lines = [f'{prefix}{{']
            lines.append(self._generate_block_contents(stmt, slot_vars, indent + 1))
            lines.append(f'{prefix}}}')
            return '\n'.join(lines)

        return ''

    def _generate_let(
        self,
        stmt: YulLet,
        slot_vars: Dict[str, str],
        prefix: str
    ) -> str:
        """Generate: let name = expr;"""
        if stmt.value is None:
            return f'{prefix}let {stmt.name} = 0n;'

        # Check if this is a .slot access
        if isinstance(stmt.value, YulSlotAccess):
            storage_var = stmt.value.variable
            slot_vars[stmt.name] = storage_var
            return f'{prefix}const {stmt.name} = this._getStorageKey({storage_var} as any);'

        ts_expr = self._generate_expression(stmt.value, slot_vars)
        return f'{prefix}let {stmt.name} = {ts_expr};'

    def _generate_assignment(
        self,
        stmt: YulAssignment,
        slot_vars: Dict[str, str],
        prefix: str
    ) -> str:
        """Generate: name = expr;"""
        if stmt.value is None:
            return f'{prefix}{stmt.name} = 0n;'

        if isinstance(stmt.value, YulSlotAccess):
            storage_var = stmt.value.variable
            slot_vars[stmt.name] = storage_var
            return f'{prefix}{stmt.name} = this._getStorageKey({storage_var} as any);'

        ts_expr = self._generate_expression(stmt.value, slot_vars)
        return f'{prefix}{stmt.name} = {ts_expr};'

    def _generate_if(
        self,
        stmt: YulIf,
        slot_vars: Dict[str, str],
        indent: int,
        prefix: str
    ) -> str:
        """Generate: if (cond) { body }"""
        cond = self._generate_expression(stmt.condition, slot_vars)
        body = self._generate_block_contents(stmt.body, slot_vars, indent + 1) if stmt.body else ''
        lines = [f'{prefix}if ({cond}) {{']
        if body and body != '// Assembly: no-op':
            lines.append(body)
        lines.append(f'{prefix}}}')
        return '\n'.join(lines)

    def _generate_for(
        self,
        stmt: YulFor,
        slot_vars: Dict[str, str],
        indent: int,
        prefix: str
    ) -> str:
        """Generate: for loop from Yul for { init } cond { post } { body }."""
        lines = []

        # Generate init block before loop
        if stmt.init and stmt.init.statements:
            init_code = self._generate_block_contents(stmt.init, slot_vars, indent)
            if init_code and init_code != '// Assembly: no-op':
                lines.append(init_code)

        # Condition
        cond = self._generate_expression(stmt.condition, slot_vars) if stmt.condition else 'true'

        lines.append(f'{prefix}while ({cond}) {{')

        # Body
        if stmt.body and stmt.body.statements:
            body_code = self._generate_block_contents(stmt.body, slot_vars, indent + 1)
            if body_code and body_code != '// Assembly: no-op':
                lines.append(body_code)

        # Post
        if stmt.post and stmt.post.statements:
            post_code = self._generate_block_contents(stmt.post, slot_vars, indent + 1)
            if post_code and post_code != '// Assembly: no-op':
                lines.append(post_code)

        lines.append(f'{prefix}}}')
        return '\n'.join(lines)

    def _generate_switch(
        self,
        stmt: YulSwitch,
        slot_vars: Dict[str, str],
        indent: int,
        prefix: str
    ) -> str:
        """Generate: switch/case as if/else-if chain."""
        expr = self._generate_expression(stmt.expression, slot_vars)
        lines = []
        first = True

        for case_value, case_body in stmt.cases:
            if case_value is None:
                # default case
                if first:
                    lines.append(f'{prefix}{{')
                else:
                    lines.append(f'{prefix}}} else {{')
            else:
                case_val = self._generate_expression(case_value, slot_vars)
                keyword = 'if' if first else '} else if'
                lines.append(f'{prefix}{keyword} ({expr} === {case_val}) {{')
            first = False

            body = self._generate_block_contents(case_body, slot_vars, indent + 1)
            if body and body != '// Assembly: no-op':
                lines.append(body)

        if stmt.cases:
            lines.append(f'{prefix}}}')

        return '\n'.join(lines)

    def _generate_expr_statement(
        self,
        stmt: YulExpressionStatement,
        slot_vars: Dict[str, str],
        prefix: str
    ) -> str:
        """Generate an expression statement (function call)."""
        if stmt.expression is None:
            return ''

        if isinstance(stmt.expression, YulFunctionCall):
            return self._generate_call_statement(stmt.expression, slot_vars, prefix)

        ts_expr = self._generate_expression(stmt.expression, slot_vars)
        return f'{prefix}{ts_expr};'

    def _generate_call_statement(
        self,
        call: YulFunctionCall,
        slot_vars: Dict[str, str],
        prefix: str
    ) -> str:
        """Generate a function call used as a statement."""
        func = call.name

        if func == 'sstore' and len(call.arguments) >= 2:
            slot_expr = call.arguments[0]
            value = self._generate_expression(call.arguments[1], slot_vars)
            if isinstance(slot_expr, YulIdentifier) and slot_expr.name in slot_vars:
                return f'{prefix}this._storageWrite({slot_vars[slot_expr.name]} as any, {value});'
            slot = self._generate_expression(slot_expr, slot_vars)
            return f'{prefix}this._storageWrite({slot}, {value});'
        elif func == 'mstore':
            return f'{prefix}// mstore (no-op for simulation)'
        elif func == 'mstore8':
            return f'{prefix}// mstore8 (no-op for simulation)'
        elif func == 'revert':
            return f'{prefix}throw new Error("Revert");'
        elif func == 'pop':
            if call.arguments:
                inner = self._generate_expression(call.arguments[0], slot_vars)
                return f'{prefix}/* pop */ {inner};'
            return f'{prefix}// pop'
        elif func == 'stop':
            return f'{prefix}return;'
        elif func == 'return':
            return f'{prefix}return;'
        elif func == 'invalid':
            return f'{prefix}throw new Error("Invalid");'
        elif func.startswith('log'):
            args_str = ', '.join(self._generate_expression(a, slot_vars) for a in call.arguments)
            return f'{prefix}// {func}({args_str})'
        elif func == 'selfdestruct':
            return f'{prefix}// selfdestruct (no-op for simulation)'

        # Generic call statement
        args = ', '.join(self._generate_expression(a, slot_vars) for a in call.arguments)
        return f'{prefix}{func}({args});'

    # =========================================================================
    # EXPRESSION GENERATION
    # =========================================================================

    def _generate_expression(
        self,
        expr: YulExpression,
        slot_vars: Dict[str, str]
    ) -> str:
        """Generate TypeScript from a Yul expression."""
        if isinstance(expr, YulLiteral):
            return self._generate_literal(expr)
        elif isinstance(expr, YulIdentifier):
            return self._generate_identifier(expr, slot_vars)
        elif isinstance(expr, YulFunctionCall):
            return self._generate_function_call(expr, slot_vars)
        elif isinstance(expr, YulSlotAccess):
            return f'this._getStorageKey({expr.variable} as any)'
        elif isinstance(expr, YulOffsetAccess):
            return '0n  // .offset'
        return '0n'

    def _generate_literal(self, lit: YulLiteral) -> str:
        """Generate TypeScript for a Yul literal."""
        if lit.kind == 'hex':
            return f'BigInt("{lit.value}")'
        elif lit.kind == 'number':
            return f'{lit.value}n'
        elif lit.kind == 'bool':
            return 'true' if lit.value == 'true' else 'false'
        elif lit.kind == 'string':
            return lit.value
        return lit.value

    def _generate_identifier(self, ident: YulIdentifier, slot_vars: Dict[str, str]) -> str:
        """Generate TypeScript for a Yul identifier."""
        name = ident.name
        if name in slot_vars:
            return name
        if name in self._known_constants:
            return f'Constants.{name}'
        return name

    def _generate_function_call(
        self,
        call: YulFunctionCall,
        slot_vars: Dict[str, str]
    ) -> str:
        """Generate TypeScript for a Yul function call expression."""
        func = call.name
        args = call.arguments

        # Storage operations
        if func == 'sload':
            if args:
                slot_expr = args[0]
                if isinstance(slot_expr, YulIdentifier) and slot_expr.name in slot_vars:
                    return f'this._storageRead({slot_vars[slot_expr.name]} as any)'
                slot = self._generate_expression(slot_expr, slot_vars)
                return f'this._storageRead({slot})'
            return 'this._storageRead(0n)'

        # Arithmetic
        if func == 'add' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) + BigInt({right}))'

        if func == 'sub' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) - BigInt({right}))'

        if func == 'mul' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) * BigInt({right}))'

        if func == 'div' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) / BigInt({right}))'

        if func == 'sdiv' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) / BigInt({right}))'

        if func == 'mod' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) % BigInt({right}))'

        if func == 'exp' and len(args) == 2:
            base = self._generate_expression(args[0], slot_vars)
            exp = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({base}) ** BigInt({exp}))'

        if func == 'addmod' and len(args) == 3:
            a = self._generate_expression(args[0], slot_vars)
            b = self._generate_expression(args[1], slot_vars)
            m = self._generate_expression(args[2], slot_vars)
            return f'((BigInt({a}) + BigInt({b})) % BigInt({m}))'

        if func == 'mulmod' and len(args) == 3:
            a = self._generate_expression(args[0], slot_vars)
            b = self._generate_expression(args[1], slot_vars)
            m = self._generate_expression(args[2], slot_vars)
            return f'((BigInt({a}) * BigInt({b})) % BigInt({m}))'

        # Bitwise operations
        if func == 'and' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) & BigInt({right}))'

        if func == 'or' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) | BigInt({right}))'

        if func == 'xor' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) ^ BigInt({right}))'

        if func == 'not' and len(args) >= 1:
            operand = self._generate_expression(args[0], slot_vars)
            return f'(~BigInt({operand}))'

        if func == 'shl' and len(args) == 2:
            shift = self._generate_expression(args[0], slot_vars)
            val = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({val}) << BigInt({shift}))'

        if func == 'shr' and len(args) == 2:
            shift = self._generate_expression(args[0], slot_vars)
            val = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({val}) >> BigInt({shift}))'

        if func == 'sar' and len(args) == 2:
            shift = self._generate_expression(args[0], slot_vars)
            val = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({val}) >> BigInt({shift}))'

        if func == 'byte' and len(args) == 2:
            pos = self._generate_expression(args[0], slot_vars)
            val = self._generate_expression(args[1], slot_vars)
            return f'((BigInt({val}) >> (BigInt(248) - BigInt({pos}) * 8n)) & 0xFFn)'

        if func == 'signextend' and len(args) == 2:
            b = self._generate_expression(args[0], slot_vars)
            val = self._generate_expression(args[1], slot_vars)
            return f'BigInt.asIntN(Number(BigInt({b}) + 1n) * 8, BigInt({val}))'

        # Comparison
        if func == 'eq' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) === BigInt({right}) ? 1n : 0n)'

        if func == 'lt' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) < BigInt({right}) ? 1n : 0n)'

        if func == 'gt' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) > BigInt({right}) ? 1n : 0n)'

        if func == 'slt' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) < BigInt({right}) ? 1n : 0n)'

        if func == 'sgt' and len(args) == 2:
            left = self._generate_expression(args[0], slot_vars)
            right = self._generate_expression(args[1], slot_vars)
            return f'(BigInt({left}) > BigInt({right}) ? 1n : 0n)'

        if func == 'iszero' and len(args) >= 1:
            operand = self._generate_expression(args[0], slot_vars)
            return f'(BigInt({operand}) === 0n ? 1n : 0n)'

        # Memory operations (return placeholders for simulation)
        if func in ('mload', 'calldataload', 'returndatasize', 'codesize',
                     'extcodesize', 'returndatacopy', 'codecopy', 'extcodecopy',
                     'extcodehash', 'calldatacopy', 'calldatasize'):
            return '0n'

        # Hashing
        if func == 'keccak256' and len(args) >= 2:
            return '0n  // keccak256 (requires memory model)'

        # Context functions
        if func == 'caller':
            return 'this._msgSender()'

        if func == 'callvalue':
            return 'this._msg.value'

        if func == 'timestamp':
            return 'BigInt(Math.floor(Date.now() / 1000))'

        if func == 'number':
            return '0n  // block number placeholder'

        if func == 'gas' or func == 'gasprice':
            return '1000000n  // gas placeholder'

        if func == 'origin':
            return 'this._msg.sender'

        if func == 'chainid':
            return '31337n  // chainid placeholder'

        if func == 'address':
            if not args:
                return 'this._contractAddress'
            return self._generate_expression(args[0], slot_vars)

        if func == 'balance':
            return '0n  // balance placeholder'

        if func == 'selfbalance':
            return '0n  // selfbalance placeholder'

        if func == 'blockhash':
            return '"0x0000000000000000000000000000000000000000000000000000000000000000"'

        if func == 'coinbase':
            return '"0x0000000000000000000000000000000000000000"'

        if func == 'difficulty' or func == 'prevrandao':
            return '0n  // difficulty/prevrandao placeholder'

        if func == 'gaslimit':
            return '30000000n  // gaslimit placeholder'

        if func == 'basefee':
            return '0n  // basefee placeholder'

        # Create operations
        if func in ('create', 'create2'):
            return '"0x0000000000000000000000000000000000000000"  // create placeholder'

        # Call operations
        if func in ('call', 'staticcall', 'delegatecall'):
            return '1n  // call placeholder (success)'

        if func == 'returndatasize':
            return '0n'

        # Data size
        if func == 'datasize':
            return '0n'

        if func == 'dataoffset':
            return '0n'

        # Generic: transpile as function call
        ts_args = ', '.join(self._generate_expression(a, slot_vars) for a in args)
        return f'{func}({ts_args})'

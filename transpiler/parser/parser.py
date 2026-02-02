"""
Solidity parser implementation.

The Parser converts a stream of tokens from the Lexer into an Abstract
Syntax Tree (AST) representation of the Solidity source code.
"""

from typing import List, Dict, Tuple, Optional

from ..lexer import Token, TokenType
from .ast_nodes import (
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


class Parser:
    """
    Recursive descent parser for Solidity source code.

    Parses a stream of tokens into an AST (Abstract Syntax Tree).
    """

    def __init__(self, tokens: List[Token]):
        self.tokens = tokens
        self.pos = 0

    def peek(self, offset: int = 0) -> Token:
        """Look ahead in the token stream without consuming."""
        pos = self.pos + offset
        if pos >= len(self.tokens):
            return self.tokens[-1]  # Return EOF
        return self.tokens[pos]

    def current(self) -> Token:
        """Return the current token."""
        return self.peek()

    def advance(self) -> Token:
        """Consume and return the current token."""
        token = self.current()
        self.pos += 1
        return token

    def match(self, *types: TokenType) -> bool:
        """Check if current token matches any of the given types."""
        return self.current().type in types

    def expect(self, token_type: TokenType, message: str = '') -> Token:
        """Consume the current token if it matches, otherwise raise an error."""
        if self.current().type != token_type:
            raise SyntaxError(
                f"Expected {token_type.name} but got {self.current().type.name} "
                f"at line {self.current().line}, column {self.current().column}: {message}"
            )
        return self.advance()

    # =========================================================================
    # TOP-LEVEL PARSING
    # =========================================================================

    def parse(self) -> SourceUnit:
        """Parse the entire source file into a SourceUnit AST."""
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
        """Parse a pragma directive."""
        self.expect(TokenType.PRAGMA)
        name = self.advance().value
        # Collect the rest until semicolon
        value = ''
        while not self.match(TokenType.SEMICOLON, TokenType.EOF):
            value += self.advance().value + ' '
        self.expect(TokenType.SEMICOLON)
        return PragmaDirective(name, value.strip())

    def parse_import(self) -> ImportDirective:
        """Parse an import directive."""
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

    # =========================================================================
    # CONTRACT PARSING
    # =========================================================================

    def parse_contract(self) -> ContractDefinition:
        """Parse a contract, interface, library, or abstract contract."""
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
        """Parse a 'using X for Y' directive."""
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

    # =========================================================================
    # DEFINITION PARSING
    # =========================================================================

    def parse_struct(self) -> StructDefinition:
        """Parse a struct definition."""
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
        """Parse an enum definition."""
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
        """Parse an event definition."""
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
        """Parse an error definition."""
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
        """Parse a modifier definition."""
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

    # =========================================================================
    # FUNCTION PARSING
    # =========================================================================

    def parse_function(self) -> FunctionDefinition:
        """Parse a function definition."""
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
        """Parse a constructor definition."""
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

    def skip_function(self) -> None:
        """Skip a function body (for receive/fallback)."""
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

    # =========================================================================
    # PARAMETER AND VARIABLE PARSING
    # =========================================================================

    def parse_parameter(self) -> VariableDeclaration:
        """Parse a function parameter."""
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
        """Parse a state variable declaration."""
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

    # =========================================================================
    # TYPE PARSING
    # =========================================================================

    def parse_type_name(self) -> TypeName:
        """Parse a type name (including mappings and arrays)."""
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
        type_name.array_dimensions = array_dimensions if is_array else 0
        return type_name

    def parse_mapping_type(self) -> TypeName:
        """Parse a mapping type."""
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

    # =========================================================================
    # STATEMENT PARSING
    # =========================================================================

    def parse_block(self) -> Block:
        """Parse a block of statements."""
        self.expect(TokenType.LBRACE)
        statements = []

        while not self.match(TokenType.RBRACE, TokenType.EOF):
            stmt = self.parse_statement()
            if stmt:
                statements.append(stmt)

        self.expect(TokenType.RBRACE)
        return Block(statements=statements)

    def parse_statement(self) -> Optional[Statement]:
        """Parse a single statement."""
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
            # unchecked { ... } - parse as a regular block
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
        saved_pos = self.pos

        try:
            # Check for tuple declaration
            if self.match(TokenType.LPAREN):
                self.advance()
                # Skip leading commas (skipped elements)
                while self.match(TokenType.COMMA):
                    self.advance()
                if self.match(TokenType.RPAREN):
                    return False
                # Check if first non-skipped item is a type
                if self.match(TokenType.IDENTIFIER, TokenType.UINT, TokenType.INT,
                             TokenType.BOOL, TokenType.ADDRESS, TokenType.BYTES,
                             TokenType.STRING, TokenType.BYTES32):
                    self.advance()
                    # Skip qualified names
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

            self.advance()

            # Skip qualified names
            while self.match(TokenType.DOT):
                self.advance()
                if self.match(TokenType.IDENTIFIER):
                    self.advance()

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
        """Parse a variable declaration statement."""
        # Check for tuple declaration
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
        """Parse a tuple variable declaration."""
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
                if self.match(TokenType.RPAREN):
                    declarations.append(None)

        self.expect(TokenType.RPAREN)
        self.expect(TokenType.EQ)
        initial_value = self.parse_expression()
        self.expect(TokenType.SEMICOLON)

        return VariableDeclarationStatement(
            declarations=declarations,
            initial_value=initial_value,
        )

    def parse_if_statement(self) -> IfStatement:
        """Parse an if statement."""
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
        """Parse a for statement."""
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
        """Parse a while statement."""
        self.expect(TokenType.WHILE)
        self.expect(TokenType.LPAREN)
        condition = self.parse_expression()
        self.expect(TokenType.RPAREN)
        body = self.parse_statement()
        return WhileStatement(condition=condition, body=body)

    def parse_do_while_statement(self) -> DoWhileStatement:
        """Parse a do-while statement."""
        self.expect(TokenType.DO)
        body = self.parse_statement()
        self.expect(TokenType.WHILE)
        self.expect(TokenType.LPAREN)
        condition = self.parse_expression()
        self.expect(TokenType.RPAREN)
        self.expect(TokenType.SEMICOLON)
        return DoWhileStatement(body=body, condition=condition)

    def parse_return_statement(self) -> ReturnStatement:
        """Parse a return statement."""
        self.expect(TokenType.RETURN)
        expr = None
        if not self.match(TokenType.SEMICOLON):
            expr = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return ReturnStatement(expression=expr)

    def parse_emit_statement(self) -> EmitStatement:
        """Parse an emit statement."""
        self.expect(TokenType.EMIT)
        event_call = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return EmitStatement(event_call=event_call)

    def parse_revert_statement(self) -> RevertStatement:
        """Parse a revert statement."""
        self.expect(TokenType.REVERT)
        error_call = None
        if not self.match(TokenType.SEMICOLON):
            error_call = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return RevertStatement(error_call=error_call)

    def parse_try_statement(self) -> Block:
        """Parse try/catch statement - skip and return empty block."""
        self.expect(TokenType.TRY)

        while not self.match(TokenType.LBRACE, TokenType.EOF):
            self.advance()

        if self.match(TokenType.LBRACE):
            depth = 1
            self.advance()
            while depth > 0 and not self.match(TokenType.EOF):
                if self.match(TokenType.LBRACE):
                    depth += 1
                elif self.match(TokenType.RBRACE):
                    depth -= 1
                self.advance()

        while self.match(TokenType.CATCH):
            self.advance()
            while not self.match(TokenType.LBRACE, TokenType.EOF):
                self.advance()
            if self.match(TokenType.LBRACE):
                depth = 1
                self.advance()
                while depth > 0 and not self.match(TokenType.EOF):
                    if self.match(TokenType.LBRACE):
                        depth += 1
                    elif self.match(TokenType.RBRACE):
                        depth -= 1
                    self.advance()

        return Block(statements=[])

    def parse_delete_statement(self) -> DeleteStatement:
        """Parse a delete statement."""
        self.expect(TokenType.DELETE)
        expression = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return DeleteStatement(expression=expression)

    def parse_assembly_statement(self) -> AssemblyStatement:
        """Parse an assembly statement."""
        self.expect(TokenType.ASSEMBLY)

        flags = []
        if self.match(TokenType.LPAREN):
            self.advance()
            while not self.match(TokenType.RPAREN, TokenType.EOF):
                flags.append(self.advance().value)
            self.expect(TokenType.RPAREN)

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
        """Parse an expression statement."""
        expr = self.parse_expression()
        self.expect(TokenType.SEMICOLON)
        return ExpressionStatement(expression=expr)

    # =========================================================================
    # EXPRESSION PARSING
    # =========================================================================

    def parse_expression(self) -> Expression:
        """Parse an expression."""
        return self.parse_assignment()

    def parse_assignment(self) -> Expression:
        """Parse an assignment expression."""
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
        """Parse a ternary expression."""
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
        """Parse a logical OR expression."""
        left = self.parse_and()
        while self.match(TokenType.PIPE_PIPE):
            op = self.advance().value
            right = self.parse_and()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_and(self) -> Expression:
        """Parse a logical AND expression."""
        left = self.parse_bitwise_or()
        while self.match(TokenType.AMPERSAND_AMPERSAND):
            op = self.advance().value
            right = self.parse_bitwise_or()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_bitwise_or(self) -> Expression:
        """Parse a bitwise OR expression."""
        left = self.parse_bitwise_xor()
        while self.match(TokenType.PIPE):
            op = self.advance().value
            right = self.parse_bitwise_xor()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_bitwise_xor(self) -> Expression:
        """Parse a bitwise XOR expression."""
        left = self.parse_bitwise_and()
        while self.match(TokenType.CARET):
            op = self.advance().value
            right = self.parse_bitwise_and()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_bitwise_and(self) -> Expression:
        """Parse a bitwise AND expression."""
        left = self.parse_equality()
        while self.match(TokenType.AMPERSAND):
            op = self.advance().value
            right = self.parse_equality()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_equality(self) -> Expression:
        """Parse an equality expression."""
        left = self.parse_comparison()
        while self.match(TokenType.EQ_EQ, TokenType.BANG_EQ):
            op = self.advance().value
            right = self.parse_comparison()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_comparison(self) -> Expression:
        """Parse a comparison expression."""
        left = self.parse_shift()
        while self.match(TokenType.LT, TokenType.GT, TokenType.LT_EQ, TokenType.GT_EQ):
            op = self.advance().value
            right = self.parse_shift()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_shift(self) -> Expression:
        """Parse a shift expression."""
        left = self.parse_additive()
        while self.match(TokenType.LT_LT, TokenType.GT_GT):
            op = self.advance().value
            right = self.parse_additive()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_additive(self) -> Expression:
        """Parse an additive expression."""
        left = self.parse_multiplicative()
        while self.match(TokenType.PLUS, TokenType.MINUS):
            op = self.advance().value
            right = self.parse_multiplicative()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_multiplicative(self) -> Expression:
        """Parse a multiplicative expression."""
        left = self.parse_exponentiation()
        while self.match(TokenType.STAR, TokenType.SLASH, TokenType.PERCENT):
            op = self.advance().value
            right = self.parse_exponentiation()
            left = BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_exponentiation(self) -> Expression:
        """Parse an exponentiation expression (right-associative)."""
        left = self.parse_unary()
        if self.match(TokenType.STAR_STAR):
            op = self.advance().value
            right = self.parse_exponentiation()
            return BinaryOperation(left=left, operator=op, right=right)
        return left

    def parse_unary(self) -> Expression:
        """Parse a unary expression."""
        if self.match(TokenType.BANG, TokenType.TILDE, TokenType.MINUS,
                     TokenType.PLUS_PLUS, TokenType.MINUS_MINUS):
            op = self.advance().value
            operand = self.parse_unary()
            return UnaryOperation(operator=op, operand=operand, is_prefix=True)

        return self.parse_postfix()

    def parse_postfix(self) -> Expression:
        """Parse a postfix expression."""
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
        """Parse function call arguments."""
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
        """Parse a primary expression."""
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

        # New expression
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

        # Array literal
        if self.match(TokenType.LBRACKET):
            self.advance()
            elements = []
            while not self.match(TokenType.RBRACKET, TokenType.EOF):
                elements.append(self.parse_expression())
                if self.match(TokenType.COMMA):
                    self.advance()
            self.expect(TokenType.RBRACKET)
            return ArrayLiteral(elements=elements)

        # Identifier
        if self.match(TokenType.IDENTIFIER):
            name = self.advance().value
            return Identifier(name=name)

        # Fallback
        return Identifier(name='')

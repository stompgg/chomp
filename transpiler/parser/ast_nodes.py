"""
AST node definitions for Solidity parsing.

This module contains all the dataclasses representing nodes in the
Abstract Syntax Tree (AST) produced by the Solidity parser.
"""

from dataclasses import dataclass, field
from typing import Optional, List, Dict, Tuple


# =============================================================================
# BASE NODE
# =============================================================================

@dataclass
class ASTNode:
    """Base class for all AST nodes."""
    pass


# =============================================================================
# TOP-LEVEL NODES
# =============================================================================

@dataclass
class PragmaDirective(ASTNode):
    """Represents a pragma directive (e.g., pragma solidity ^0.8.0)."""
    name: str
    value: str


@dataclass
class ImportDirective(ASTNode):
    """Represents an import statement."""
    path: str
    symbols: List[Tuple[str, Optional[str]]] = field(default_factory=list)  # (name, alias)


@dataclass
class UsingDirective(ASTNode):
    """Represents a 'using X for Y' directive."""
    library: str
    type_name: Optional[str] = None


@dataclass
class SourceUnit(ASTNode):
    """Root node representing an entire Solidity source file."""
    pragmas: List[PragmaDirective] = field(default_factory=list)
    imports: List[ImportDirective] = field(default_factory=list)
    contracts: List['ContractDefinition'] = field(default_factory=list)
    enums: List['EnumDefinition'] = field(default_factory=list)
    structs: List['StructDefinition'] = field(default_factory=list)
    constants: List['StateVariableDeclaration'] = field(default_factory=list)


# =============================================================================
# TYPE AND VARIABLE NODES
# =============================================================================

@dataclass
class TypeName(ASTNode):
    """Represents a type name (e.g., uint256, address, mapping(x => y))."""
    name: str
    is_array: bool = False
    array_size: Optional['Expression'] = None
    array_dimensions: int = 0  # For multi-dimensional arrays (e.g., 2 for int[][])
    key_type: Optional['TypeName'] = None  # For mappings
    value_type: Optional['TypeName'] = None  # For mappings
    is_mapping: bool = False


@dataclass
class VariableDeclaration(ASTNode):
    """Represents a variable declaration."""
    name: str
    type_name: TypeName
    visibility: str = 'internal'
    mutability: str = ''  # '', 'constant', 'immutable', 'transient'
    storage_location: str = ''  # '', 'storage', 'memory', 'calldata'
    is_indexed: bool = False
    initial_value: Optional['Expression'] = None


@dataclass
class StateVariableDeclaration(VariableDeclaration):
    """Represents a state variable declaration in a contract."""
    pass


# =============================================================================
# DEFINITION NODES
# =============================================================================

@dataclass
class StructDefinition(ASTNode):
    """Represents a struct definition."""
    name: str
    members: List[VariableDeclaration] = field(default_factory=list)


@dataclass
class EnumDefinition(ASTNode):
    """Represents an enum definition."""
    name: str
    members: List[str] = field(default_factory=list)


@dataclass
class EventDefinition(ASTNode):
    """Represents an event definition."""
    name: str
    parameters: List[VariableDeclaration] = field(default_factory=list)


@dataclass
class ErrorDefinition(ASTNode):
    """Represents a custom error definition."""
    name: str
    parameters: List[VariableDeclaration] = field(default_factory=list)


@dataclass
class ModifierDefinition(ASTNode):
    """Represents a modifier definition."""
    name: str
    parameters: List[VariableDeclaration] = field(default_factory=list)
    body: Optional['Block'] = None


@dataclass
class BaseConstructorCall(ASTNode):
    """Represents a base constructor call in a constructor definition."""
    base_name: str
    arguments: List['Expression'] = field(default_factory=list)


@dataclass
class FunctionDefinition(ASTNode):
    """Represents a function, constructor, or special function definition."""
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


@dataclass
class ContractDefinition(ASTNode):
    """Represents a contract, interface, library, or abstract contract."""
    name: str
    kind: str  # 'contract', 'interface', 'library', 'abstract'
    base_contracts: List[str] = field(default_factory=list)
    state_variables: List[StateVariableDeclaration] = field(default_factory=list)
    functions: List[FunctionDefinition] = field(default_factory=list)
    modifiers: List[ModifierDefinition] = field(default_factory=list)
    events: List[EventDefinition] = field(default_factory=list)
    errors: List[ErrorDefinition] = field(default_factory=list)
    structs: List[StructDefinition] = field(default_factory=list)
    enums: List[EnumDefinition] = field(default_factory=list)
    constructor: Optional[FunctionDefinition] = None
    using_directives: List[UsingDirective] = field(default_factory=list)


# =============================================================================
# EXPRESSION NODES
# =============================================================================

@dataclass
class Expression(ASTNode):
    """Base class for all expression nodes."""
    pass


@dataclass
class Literal(Expression):
    """Represents a literal value (number, string, bool, hex)."""
    value: str
    kind: str  # 'number', 'string', 'bool', 'hex'


@dataclass
class Identifier(Expression):
    """Represents an identifier reference."""
    name: str


@dataclass
class BinaryOperation(Expression):
    """Represents a binary operation (e.g., a + b)."""
    left: Expression
    operator: str
    right: Expression


@dataclass
class UnaryOperation(Expression):
    """Represents a unary operation (e.g., !x, -y, x++)."""
    operator: str
    operand: Expression
    is_prefix: bool = True


@dataclass
class TernaryOperation(Expression):
    """Represents a ternary/conditional operation (a ? b : c)."""
    condition: Expression
    true_expression: Expression
    false_expression: Expression


@dataclass
class FunctionCall(Expression):
    """Represents a function call."""
    function: Expression
    arguments: List[Expression] = field(default_factory=list)
    named_arguments: Dict[str, Expression] = field(default_factory=dict)
    call_options: Dict[str, Expression] = field(default_factory=dict)


@dataclass
class MemberAccess(Expression):
    """Represents member access (e.g., obj.member)."""
    expression: Expression
    member: str


@dataclass
class IndexAccess(Expression):
    """Represents index access (e.g., arr[i])."""
    base: Expression
    index: Expression


@dataclass
class NewExpression(Expression):
    """Represents a 'new' expression for contract/array creation."""
    type_name: TypeName


@dataclass
class TupleExpression(Expression):
    """Represents a tuple expression (e.g., (a, b, c))."""
    components: List[Optional[Expression]] = field(default_factory=list)


@dataclass
class ArrayLiteral(Expression):
    """Represents an array literal (e.g., [1, 2, 3])."""
    elements: List[Expression] = field(default_factory=list)


@dataclass
class TypeCast(Expression):
    """Represents a type cast (e.g., uint256(x))."""
    type_name: TypeName
    expression: Expression


@dataclass
class AssemblyBlock(Expression):
    """Represents an inline assembly/Yul block."""
    code: str
    flags: List[str] = field(default_factory=list)


# =============================================================================
# STATEMENT NODES
# =============================================================================

@dataclass
class Statement(ASTNode):
    """Base class for all statement nodes."""
    pass


@dataclass
class Block(Statement):
    """Represents a block of statements enclosed in braces."""
    statements: List[Statement] = field(default_factory=list)


@dataclass
class ExpressionStatement(Statement):
    """Represents an expression used as a statement."""
    expression: Expression


@dataclass
class VariableDeclarationStatement(Statement):
    """Represents a variable declaration statement."""
    declarations: List[VariableDeclaration]
    initial_value: Optional[Expression] = None


@dataclass
class IfStatement(Statement):
    """Represents an if/else statement."""
    condition: Expression
    true_body: Statement
    false_body: Optional[Statement] = None


@dataclass
class ForStatement(Statement):
    """Represents a for loop."""
    init: Optional[Statement] = None
    condition: Optional[Expression] = None
    post: Optional[Expression] = None
    body: Optional[Statement] = None


@dataclass
class WhileStatement(Statement):
    """Represents a while loop."""
    condition: Expression
    body: Statement


@dataclass
class DoWhileStatement(Statement):
    """Represents a do-while loop."""
    body: Statement
    condition: Expression


@dataclass
class ReturnStatement(Statement):
    """Represents a return statement."""
    expression: Optional[Expression] = None


@dataclass
class EmitStatement(Statement):
    """Represents an emit statement for events."""
    event_call: FunctionCall


@dataclass
class RevertStatement(Statement):
    """Represents a revert statement."""
    error_call: Optional[FunctionCall] = None


@dataclass
class BreakStatement(Statement):
    """Represents a break statement."""
    pass


@dataclass
class ContinueStatement(Statement):
    """Represents a continue statement."""
    pass


@dataclass
class DeleteStatement(Statement):
    """Represents a delete statement."""
    expression: Expression


@dataclass
class AssemblyStatement(Statement):
    """Represents an assembly block statement."""
    block: AssemblyBlock

"""Internal AST lowering before TypeScript code generation.

Lowering normalizes Solidity constructs into a smaller set of AST shapes while
preserving the public parser/codegen APIs. The first pass is intentionally
small: primitive cast-style function calls become explicit ``TypeCast`` nodes.
"""

from dataclasses import fields, is_dataclass

from .parser.ast_nodes import (
    ASTNode,
    FunctionCall,
    Identifier,
    TypeCast,
    TypeName,
)


PRIMITIVE_CAST_NAMES = {
    'address',
    'bool',
    'bytes',
    'bytes32',
    'payable',
    'string',
}


def lower_ast(ast: ASTNode) -> ASTNode:
    """Lower an AST in place and return it."""
    return SolidityLowerer().visit(ast)


def is_primitive_cast_name(name: str) -> bool:
    return (
        name in PRIMITIVE_CAST_NAMES
        or name.startswith('uint')
        or name.startswith('int')
        or (name.startswith('bytes') and name[5:].isdigit())
    )


class SolidityLowerer:
    """Small in-place AST transformer."""

    def visit(self, node):
        if node is None:
            return None
        if isinstance(node, ASTNode):
            method = getattr(self, f'visit_{type(node).__name__}', self.generic_visit)
            return method(node)
        return node

    def generic_visit(self, node: ASTNode):
        if not is_dataclass(node):
            return node
        for field in fields(node):
            setattr(node, field.name, self._lower_value(getattr(node, field.name)))
        return node

    def _lower_value(self, value):
        if isinstance(value, ASTNode):
            return self.visit(value)
        if isinstance(value, list):
            return [self._lower_value(item) for item in value]
        if isinstance(value, tuple):
            return tuple(self._lower_value(item) for item in value)
        if isinstance(value, dict):
            return {key: self._lower_value(item) for key, item in value.items()}
        return value

    def visit_FunctionCall(self, node: FunctionCall):
        self.generic_visit(node)
        if not isinstance(node.function, Identifier):
            return node
        if node.named_arguments or node.call_options:
            return node
        if len(node.arguments) != 1:
            return node
        name = node.function.name
        if not is_primitive_cast_name(name):
            return node
        return TypeCast(type_name=TypeName(name=name), expression=node.arguments[0])

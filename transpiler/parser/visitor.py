"""Small generic visitor for Solidity AST nodes."""

from dataclasses import fields, is_dataclass
from typing import Iterator

from .ast_nodes import ASTNode


def iter_child_nodes(node: ASTNode) -> Iterator[ASTNode]:
    """Yield AST children from dataclass fields, lists, tuples, and dict values."""
    if not is_dataclass(node):
        return

    for field in fields(node):
        yield from _iter_node_values(getattr(node, field.name))


def _iter_node_values(value) -> Iterator[ASTNode]:
    if isinstance(value, ASTNode):
        yield value
    elif isinstance(value, (list, tuple)):
        for item in value:
            yield from _iter_node_values(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from _iter_node_values(item)


class ASTVisitor:
    """Pre-order visitor with ``visit_<ClassName>`` dispatch."""

    def visit(self, node: ASTNode):
        if node is None:
            return None
        method = getattr(self, f'visit_{type(node).__name__}', self.generic_visit)
        return method(node)

    def generic_visit(self, node: ASTNode):
        for child in iter_child_nodes(node):
            self.visit(child)
        return None

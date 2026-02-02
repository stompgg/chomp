"""
ABI type inference for Solidity expressions.

This module provides utilities for inferring ABI types from Solidity
expressions, used for encoding/decoding operations like abi.encode,
abi.encodePacked, etc.
"""

from typing import List, Optional, Dict, Set

from ..parser.ast_nodes import (
    Expression,
    Identifier,
    Literal,
    MemberAccess,
    FunctionCall,
    TypeCast,
    TupleExpression,
    TypeName,
)


class AbiTypeInferer:
    """
    Infers ABI types from Solidity expressions.

    Used for generating viem-compatible ABI encoding calls when
    the Solidity source uses abi.encode, abi.encodePacked, etc.
    """

    def __init__(
        self,
        var_types: Optional[Dict[str, TypeName]] = None,
        known_enums: Optional[Set[str]] = None,
        known_contracts: Optional[Set[str]] = None,
        known_interfaces: Optional[Set[str]] = None,
        known_struct_fields: Optional[Dict[str, Dict[str, str]]] = None,
        method_return_types: Optional[Dict[str, str]] = None,
    ):
        """
        Initialize the ABI type inferer.

        Args:
            var_types: Maps variable names to their TypeName nodes
            known_enums: Set of known enum type names
            known_contracts: Set of known contract type names
            known_interfaces: Set of known interface type names
            known_struct_fields: Maps struct names to their field types
            method_return_types: Maps method names to their return types
        """
        self.var_types = var_types or {}
        self.known_enums = known_enums or set()
        self.known_contracts = known_contracts or set()
        self.known_interfaces = known_interfaces or set()
        self.known_struct_fields = known_struct_fields or {}
        self.method_return_types = method_return_types or {}

    def infer_abi_types(self, args: List[Expression]) -> str:
        """
        Infer ABI types from value expressions (for abi.encode).

        Args:
            args: List of expression arguments

        Returns:
            TypeScript array literal of ABI type objects
        """
        type_strs = [self._infer_single_type(arg) for arg in args]
        return f'[{", ".join(type_strs)}]'

    def infer_packed_types(self, args: List[Expression]) -> str:
        """
        Infer packed ABI types from value expressions (for abi.encodePacked).

        encodePacked uses a simpler format: ['uint256', 'address'] instead of
        [{type: 'uint256'}, {type: 'address'}].

        Args:
            args: List of expression arguments

        Returns:
            TypeScript array literal of type strings
        """
        type_strs = [f"'{self._infer_single_packed_type(arg)}'" for arg in args]
        return f'[{", ".join(type_strs)}]'

    def convert_types_expr(self, types_expr: Expression) -> str:
        """
        Convert Solidity type tuple to viem ABI parameter format.

        Args:
            types_expr: The type tuple expression (e.g., (int32) or (uint256, address))

        Returns:
            TypeScript array literal of ABI type objects
        """
        if isinstance(types_expr, TupleExpression):
            type_strs = []
            for comp in types_expr.components:
                if comp:
                    type_strs.append(self._type_expr_to_abi_param(comp))
            return f'[{", ".join(type_strs)}]'
        return f'[{self._type_expr_to_abi_param(types_expr)}]'

    def _type_expr_to_abi_param(self, type_expr: Expression) -> str:
        """Convert a type expression to ABI parameter object."""
        if isinstance(type_expr, Identifier):
            name = type_expr.name
            if name.startswith(('uint', 'int')) or name in ('address', 'bool') or name.startswith('bytes'):
                return f"{{type: '{name}'}}"
            if name in self.known_enums:
                return "{type: 'uint8'}"
            return "{type: 'bytes'}"
        return "{type: 'bytes'}"

    def _infer_single_type(self, arg: Expression) -> str:
        """Infer ABI type from a single value expression."""
        if isinstance(arg, Identifier):
            return self._infer_identifier_type(arg)
        if isinstance(arg, Literal):
            return self._infer_literal_type(arg)
        if isinstance(arg, MemberAccess):
            return self._infer_member_access_type(arg)
        if isinstance(arg, FunctionCall):
            return self._infer_function_call_type(arg)
        if isinstance(arg, TypeCast):
            return self._infer_type_cast_type(arg)
        return "{type: 'uint256'}"

    def _infer_identifier_type(self, arg: Identifier) -> str:
        """Infer ABI type from an identifier."""
        name = arg.name
        if name in self.var_types:
            type_info = self.var_types[name]
            if type_info.name:
                return self._type_name_to_abi_type(type_info.name)
        if name in self.known_enums:
            return "{type: 'uint8'}"
        return "{type: 'uint256'}"

    def _infer_literal_type(self, arg: Literal) -> str:
        """Infer ABI type from a literal."""
        if arg.kind == 'string':
            return "{type: 'string'}"
        elif arg.kind in ('number', 'hex'):
            return "{type: 'uint256'}"
        elif arg.kind == 'bool':
            return "{type: 'bool'}"
        return "{type: 'uint256'}"

    def _infer_member_access_type(self, arg: MemberAccess) -> str:
        """Infer ABI type from a member access expression."""
        if arg.member == '_contractAddress':
            return "{type: 'address'}"
        if isinstance(arg.expression, Identifier):
            if arg.expression.name == 'Enums':
                return "{type: 'uint8'}"
            if arg.expression.name in ('this', 'msg', 'tx'):
                if arg.member in ('sender', 'origin', '_contractAddress'):
                    return "{type: 'address'}"
            # Check for struct field access
            var_name = arg.expression.name
            if var_name in self.var_types:
                type_info = self.var_types[var_name]
                if type_info.name and type_info.name in self.known_struct_fields:
                    struct_fields = self.known_struct_fields[type_info.name]
                    if arg.member in struct_fields:
                        field_info = struct_fields[arg.member]
                        if isinstance(field_info, tuple):
                            field_type, is_array = field_info
                        else:
                            field_type, is_array = field_info, False
                        return self._solidity_type_to_abi(field_type, is_array)
        return "{type: 'uint256'}"

    def _infer_function_call_type(self, arg: FunctionCall) -> str:
        """Infer ABI type from a function call expression."""
        if isinstance(arg.function, Identifier):
            func_name = arg.function.name
            if func_name == 'address':
                return "{type: 'address'}"
            if func_name.startswith(('uint', 'int')):
                return f"{{type: '{func_name}'}}"
            if func_name == 'bytes32' or func_name.startswith('bytes'):
                return f"{{type: '{func_name}'}}"
            if func_name in ('keccak256', 'blockhash', 'sha256'):
                return "{type: 'bytes32'}"
        # Check method return types
        method_name = None
        if isinstance(arg.function, Identifier):
            method_name = arg.function.name
        elif isinstance(arg.function, MemberAccess):
            if isinstance(arg.function.expression, Identifier):
                if arg.function.expression.name == 'this':
                    method_name = arg.function.member
        if method_name and method_name in self.method_return_types:
            return_type = self.method_return_types[method_name]
            return self._solidity_type_to_abi(return_type)
        return "{type: 'uint256'}"

    def _infer_type_cast_type(self, arg: TypeCast) -> str:
        """Infer ABI type from a type cast expression."""
        type_name = arg.type_name.name
        if type_name == 'address':
            return "{type: 'address'}"
        if type_name.startswith(('uint', 'int')):
            return f"{{type: '{type_name}'}}"
        if type_name == 'bytes32' or type_name.startswith('bytes'):
            return f"{{type: '{type_name}'}}"
        return "{type: 'uint256'}"

    def _type_name_to_abi_type(self, type_name: str) -> str:
        """Convert a Solidity type name to ABI type format."""
        if type_name == 'address':
            return "{type: 'address'}"
        if type_name == 'string':
            return "{type: 'string'}"
        if type_name.startswith(('uint', 'int')) or type_name == 'bool' or type_name.startswith('bytes'):
            return f"{{type: '{type_name}'}}"
        if type_name in self.known_enums:
            return "{type: 'uint8'}"
        return "{type: 'uint256'}"

    def _solidity_type_to_abi(self, type_name: str, is_array: bool = False) -> str:
        """Convert a Solidity type to ABI type format with optional array suffix."""
        array_suffix = '[]' if is_array else ''
        if type_name == 'string':
            return f"{{type: 'string{array_suffix}'}}"
        if type_name == 'address':
            return f"{{type: 'address{array_suffix}'}}"
        if type_name == 'bool':
            return f"{{type: 'bool{array_suffix}'}}"
        if type_name.startswith(('uint', 'int')):
            return f"{{type: '{type_name}{array_suffix}'}}"
        if type_name.startswith('bytes'):
            return f"{{type: '{type_name}{array_suffix}'}}"
        if type_name in self.known_enums:
            return f"{{type: 'uint8{array_suffix}'}}"
        if type_name in self.known_contracts or type_name in self.known_interfaces:
            return f"{{type: 'address{array_suffix}'}}"
        return f"{{type: 'uint256{array_suffix}'}}"

    def _infer_single_packed_type(self, arg: Expression) -> str:
        """Infer packed ABI type from a single expression (returns type string)."""
        if isinstance(arg, Identifier):
            name = arg.name
            if name in self.var_types:
                type_info = self.var_types[name]
                if type_info.name:
                    return self._get_packed_type(type_info.name, type_info.is_array)
            if name in self.known_enums:
                return 'uint8'
            return 'uint256'
        if isinstance(arg, Literal):
            if arg.kind == 'string':
                return 'string'
            elif arg.kind in ('number', 'hex'):
                return 'uint256'
            elif arg.kind == 'bool':
                return 'bool'
        if isinstance(arg, MemberAccess):
            if arg.member == '_contractAddress':
                return 'address'
            if isinstance(arg.expression, Identifier):
                if arg.expression.name == 'Enums':
                    return 'uint8'
                if arg.expression.name in ('this', 'msg', 'tx'):
                    if arg.member in ('sender', 'origin'):
                        return 'address'
                var_name = arg.expression.name
                if var_name in self.var_types:
                    type_info = self.var_types[var_name]
                    if type_info.name and type_info.name in self.known_struct_fields:
                        struct_fields = self.known_struct_fields[type_info.name]
                        if arg.member in struct_fields:
                            field_info = struct_fields[arg.member]
                            if isinstance(field_info, tuple):
                                field_type, is_array = field_info
                            else:
                                field_type, is_array = field_info, False
                            return self._get_packed_type(field_type, is_array)
        if isinstance(arg, FunctionCall):
            if isinstance(arg.function, Identifier):
                func_name = arg.function.name
                if func_name == 'blockhash':
                    return 'bytes32'
                if func_name == 'keccak256':
                    return 'bytes32'
                if func_name == 'name':
                    return 'string'
            elif isinstance(arg.function, MemberAccess):
                if arg.function.member == 'name':
                    return 'string'
        return 'uint256'

    def _get_packed_type(self, type_name: str, is_array: bool = False) -> str:
        """Get packed type string for a Solidity type."""
        array_suffix = '[]' if is_array else ''
        if type_name == 'address':
            return f'address{array_suffix}'
        if type_name.startswith(('uint', 'int')):
            return f'{type_name}{array_suffix}'
        if type_name == 'bool':
            return f'bool{array_suffix}'
        if type_name.startswith('bytes'):
            return f'{type_name}{array_suffix}'
        if type_name == 'string':
            return f'string{array_suffix}'
        if type_name in self.known_enums:
            return f'uint8{array_suffix}'
        if type_name in self.known_contracts or type_name in self.known_interfaces:
            return f'address{array_suffix}'
        return f'uint256{array_suffix}'

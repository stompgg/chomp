"""
Type registry for discovered Solidity types.

The TypeRegistry performs a first pass over Solidity source files to discover
all types (structs, enums, contracts, interfaces, etc.) before code generation.
"""

from typing import Dict, Set, List, Optional
from pathlib import Path


class TypeRegistry:
    """
    Registry of discovered types from Solidity source files.

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
        self.known_public_state_vars: Set[str] = set()
        self.method_return_types: Dict[str, Dict[str, str]] = {}
        self.contract_paths: Dict[str, str] = {}
        self.contract_structs: Dict[str, Set[str]] = {}
        self.contract_bases: Dict[str, List[str]] = {}
        self.struct_paths: Dict[str, str] = {}
        self.struct_fields: Dict[str, Dict[str, str]] = {}

    def discover_from_source(self, source: str, rel_path: Optional[str] = None) -> None:
        """Discover types from a single Solidity source string."""
        # Import here to avoid circular imports
        from ..lexer import Lexer
        from ..parser import Parser

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
        base_dir = Path(directory)
        for sol_file in base_dir.glob(pattern):
            try:
                rel_path = sol_file.relative_to(base_dir).with_suffix('')
                self.discover_from_file(str(sol_file), str(rel_path))
            except Exception as e:
                print(f"Warning: Could not parse {sol_file} for type discovery: {e}")

    def discover_from_ast(self, ast: 'SourceUnit', rel_path: Optional[str] = None) -> None:
        """Extract type information from a parsed AST."""
        # Top-level structs
        for struct in ast.structs:
            self.structs.add(struct.name)
            if rel_path and rel_path != 'Structs':
                self.struct_paths[struct.name] = rel_path
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

            if rel_path:
                self.contract_paths[name] = rel_path

            self.contract_bases[name] = contract.base_contracts or []

            # Contract-local structs
            contract_local_structs: Set[str] = set()
            for struct in contract.structs:
                self.structs.add(struct.name)
                contract_local_structs.add(struct.name)
            self.contract_structs[name] = contract_local_structs

            # Contract-local enums
            for enum in contract.enums:
                self.enums.add(enum.name)

            # Methods and return types
            methods = set()
            return_types: Dict[str, str] = {}
            for func in contract.functions:
                if func.name:
                    methods.add(func.name)
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

            # State variables
            state_vars = set()
            for var in contract.state_variables:
                state_vars.add(var.name)
                if var.mutability == 'constant':
                    self.constants.add(var.name)
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

        for name, path in other.contract_paths.items():
            if name not in self.contract_paths:
                self.contract_paths[name] = path

        for name, structs in other.contract_structs.items():
            if name in self.contract_structs:
                self.contract_structs[name].update(structs)
            else:
                self.contract_structs[name] = structs.copy()

        for name, bases in other.contract_bases.items():
            if name not in self.contract_bases:
                self.contract_bases[name] = bases.copy()

        for struct_name, fields in other.struct_fields.items():
            if struct_name in self.struct_fields:
                self.struct_fields[struct_name].update(fields)
            else:
                self.struct_fields[struct_name] = fields.copy()

    def get_inherited_structs(self, contract_name: str) -> Dict[str, str]:
        """
        Get structs inherited from base contracts.

        Returns a dict mapping struct_name -> defining_contract_name.
        """
        inherited: Dict[str, str] = {}
        bases = self.contract_bases.get(contract_name, [])
        for base in bases:
            if base in self.contract_structs:
                for struct_name in self.contract_structs[base]:
                    if struct_name not in inherited:
                        inherited[struct_name] = base
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
            if base in self.contract_vars:
                inherited.update(self.contract_vars[base])
            inherited.update(self.get_all_inherited_vars(base))
        return inherited

    def get_all_inherited_methods(
        self,
        contract_name: str,
        exclude_interfaces: bool = True
    ) -> Set[str]:
        """
        Get all methods inherited from base contracts (transitively).

        Args:
            contract_name: The contract to get inherited methods for
            exclude_interfaces: If True, skip interfaces (for TypeScript override)
        """
        inherited: Set[str] = set()
        bases = self.contract_bases.get(contract_name, [])
        for base in bases:
            if exclude_interfaces:
                is_interface = (
                    (base.startswith('I') and len(base) > 1 and base[1].isupper())
                    or base in self.interfaces
                )
                if is_interface:
                    continue
            if base in self.contract_methods:
                inherited.update(self.contract_methods[base])
            inherited.update(self.get_all_inherited_methods(base, exclude_interfaces))
        return inherited

    def build_qualified_name_cache(self, current_file_type: str = '') -> Dict[str, str]:
        """
        Build a cached lookup dictionary for qualified names.

        This optimization avoids repeated set lookups in get_qualified_name().
        """
        cache: Dict[str, str] = {}

        if current_file_type != 'Structs':
            for name in self.structs:
                if name not in self.struct_paths:
                    cache[name] = f'Structs.{name}'

        if current_file_type != 'Enums':
            for name in self.enums:
                cache[name] = f'Enums.{name}'

        if current_file_type != 'Constants':
            for name in self.constants:
                cache[name] = f'Constants.{name}'

        return cache

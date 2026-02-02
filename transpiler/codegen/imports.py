"""
Import generation for Solidity to TypeScript transpilation.

This module handles the generation of TypeScript import statements based on
the types and contracts referenced during code generation.
"""

from pathlib import PurePosixPath
from typing import Dict, List, Set, TYPE_CHECKING

if TYPE_CHECKING:
    from .context import CodeGenerationContext


class ImportGenerator:
    """
    Generates TypeScript import statements.

    This class tracks referenced types and generates appropriate import
    statements for:
    - viem utilities (keccak256, encodePacked, etc.)
    - Runtime classes (Contract, Storage, set types)
    - Base contracts and libraries
    - Structs, Enums, and Constants modules
    - Referenced contracts
    """

    def __init__(self, ctx: 'CodeGenerationContext'):
        """
        Initialize the import generator.

        Args:
            ctx: The code generation context
        """
        self._ctx = ctx

    def generate(self, contract_name: str = '') -> str:
        """Generate import statements for a file.

        Args:
            contract_name: The name of the contract/module being generated

        Returns:
            The import statements as a string
        """
        prefix = self._get_prefix()

        lines = []

        # viem imports
        lines.append(
            "import { keccak256, encodePacked, encodeAbiParameters, "
            "decodeAbiParameters, parseAbiParameters } from 'viem';"
        )

        # Runtime imports
        runtime_imports = self._build_runtime_imports()
        lines.append(f"import {{ {', '.join(runtime_imports)} }} from '{prefix}runtime';")

        # Base contract imports
        lines.extend(self._generate_base_contract_imports(prefix))

        # Library imports
        lines.extend(self._generate_library_imports(prefix, runtime_imports))

        # Contract type imports
        lines.extend(self._generate_contract_type_imports(prefix, contract_name))

        # Inherited struct imports
        lines.extend(self._generate_inherited_struct_imports(prefix, contract_name))

        # External struct imports
        lines.extend(self._generate_external_struct_imports(prefix))

        # Module imports (Structs, Enums, Constants)
        lines.extend(self._generate_module_imports(prefix, contract_name))

        lines.append('')
        return '\n'.join(lines)

    def _get_prefix(self) -> str:
        """Get the relative path prefix based on file depth."""
        if self._ctx.file_depth > 0:
            return '../' * self._ctx.file_depth
        return './'

    def _build_runtime_imports(self) -> List[str]:
        """Build the list of runtime imports."""
        imports = [
            'Contract', 'Storage', 'ADDRESS_ZERO',
            'sha256', 'sha256String', 'addressToUint', 'blockhash'
        ]

        # Add set types if used
        if self._ctx.set_types_used:
            imports.extend(sorted(self._ctx.set_types_used))

        # Add runtime replacement classes needed as base contracts
        for base_contract in sorted(self._ctx.base_contracts_needed):
            if base_contract in self._ctx.runtime_replacement_classes:
                imports.append(base_contract)

        return imports

    def _generate_base_contract_imports(self, prefix: str) -> List[str]:
        """Generate import statements for base contracts."""
        lines = []
        for base_contract in sorted(self._ctx.base_contracts_needed):
            if base_contract in self._ctx.runtime_replacement_classes:
                continue  # Already imported from runtime
            import_path = self._get_relative_import_path(base_contract)
            lines.append(f"import {{ {base_contract} }} from '{import_path}';")
        return lines

    def _generate_library_imports(
        self,
        prefix: str,
        runtime_imports: List[str]
    ) -> List[str]:
        """Generate import statements for library contracts."""
        lines = []
        for library in sorted(self._ctx.libraries_referenced):
            if library in self._ctx.runtime_replacement_classes:
                # Will be handled by extending runtime imports
                continue
            import_path = self._get_relative_import_path(library)
            lines.append(f"import {{ {library} }} from '{import_path}';")
        return lines

    def _generate_contract_type_imports(
        self,
        prefix: str,
        contract_name: str
    ) -> List[str]:
        """Generate import statements for contracts used as types."""
        lines = []
        for contract in sorted(self._ctx.contracts_referenced):
            # Skip if already imported as base contract or if it's the current contract
            if contract not in self._ctx.base_contracts_needed and contract != contract_name:
                import_path = self._get_relative_import_path(contract)
                lines.append(f"import {{ {contract} }} from '{import_path}';")
        return lines

    def _generate_inherited_struct_imports(
        self,
        prefix: str,
        contract_name: str
    ) -> List[str]:
        """Generate import statements for inherited structs."""
        lines = []

        if not self._ctx.current_inherited_structs:
            return lines

        # Group by defining contract
        structs_by_contract: Dict[str, List[str]] = {}
        for struct_name, defining_contract in self._ctx.current_inherited_structs.items():
            if defining_contract not in structs_by_contract:
                structs_by_contract[defining_contract] = []
            structs_by_contract[defining_contract].append(struct_name)

        for defining_contract, struct_names in sorted(structs_by_contract.items()):
            if defining_contract != contract_name:
                import_path = self._get_relative_import_path(defining_contract)
                if defining_contract in self._ctx.base_contracts_needed:
                    # Struct import will be combined with base class import
                    # (handled during base contract import)
                    pass
                else:
                    structs_str = ', '.join(sorted(struct_names))
                    lines.append(f"import {{ {structs_str} }} from '{import_path}';")

        return lines

    def _generate_external_struct_imports(self, prefix: str) -> List[str]:
        """Generate import statements for external structs."""
        lines = []

        if not self._ctx.external_structs_used:
            return lines

        # Group by source file
        structs_by_file: Dict[str, List[str]] = {}
        for struct_name, rel_path in self._ctx.external_structs_used.items():
            if rel_path not in structs_by_file:
                structs_by_file[rel_path] = []
            structs_by_file[rel_path].append(struct_name)

        for rel_path, struct_names in sorted(structs_by_file.items()):
            if rel_path != self._ctx.current_file_path:
                import_path = f"{prefix}{rel_path}"
                structs_str = ', '.join(sorted(struct_names))
                lines.append(f"import {{ {structs_str} }} from '{import_path}';")

        return lines

    def _generate_module_imports(self, prefix: str, contract_name: str) -> List[str]:
        """Generate import statements for Structs/Enums/Constants modules."""
        lines = []

        if contract_name == 'Enums':
            pass  # Enums doesn't need to import anything
        elif contract_name == 'Structs':
            lines.append(f"import * as Enums from '{prefix}Enums';")
        elif contract_name == 'Constants':
            lines.append(f"import * as Structs from '{prefix}Structs';")
            lines.append(f"import * as Enums from '{prefix}Enums';")
        elif contract_name:
            lines.append(f"import * as Structs from '{prefix}Structs';")
            lines.append(f"import * as Enums from '{prefix}Enums';")
            lines.append(f"import * as Constants from '{prefix}Constants';")

        return lines

    def _get_relative_import_path(self, target_contract: str) -> str:
        """Compute the relative import path from current file to target contract.

        Args:
            target_contract: The name of the target contract

        Returns:
            The relative import path string
        """
        target_path = self._ctx.known_contract_paths.get(target_contract)

        if not target_path or not self._ctx.current_file_path:
            prefix = '../' * self._ctx.file_depth if self._ctx.file_depth > 0 else './'
            return f'{prefix}{target_contract}'

        current_dir = PurePosixPath(self._ctx.current_file_path).parent
        target = PurePosixPath(target_path)

        try:
            current_parts = current_dir.parts if str(current_dir) != '.' else ()
            target_parts = target.parts

            # Find common prefix length
            common_len = 0
            for i, (c, t) in enumerate(zip(current_parts, target_parts)):
                if c == t:
                    common_len = i + 1
                else:
                    break

            # Go up from current dir, then down to target
            ups = len(current_parts) - common_len
            downs = target_parts[common_len:]

            if ups == 0 and not downs:
                return f'./{target.name}'
            elif ups == 0:
                return './' + '/'.join(downs)
            else:
                return '../' * ups + '/'.join(downs)
        except Exception:
            prefix = '../' * self._ctx.file_depth if self._ctx.file_depth > 0 else './'
            return f'{prefix}{target_contract}'

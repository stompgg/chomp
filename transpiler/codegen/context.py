"""
Code generation context for the TypeScript code generator.

This module provides a context class that holds all state needed during
code generation, separating state management from the generation logic.
"""

from dataclasses import dataclass, field
from typing import Dict, Set, List, Optional

from ..parser.ast_nodes import TypeName
from ..type_system import TypeRegistry
from .diagnostics import TranspilerDiagnostics


# Reserved JavaScript method names that conflict with Object.prototype or other built-ins
# These need to be renamed when they appear as static methods in libraries
RESERVED_JS_METHODS: Dict[str, str] = {
    'toString': 'toStr',
    'valueOf': 'valueOf_',
    'hasOwnProperty': 'hasOwnProperty_',
    'isPrototypeOf': 'isPrototypeOf_',
    'propertyIsEnumerable': 'propertyIsEnumerable_',
    'toLocaleString': 'toLocaleStr',
    'constructor': 'constructor_',
}


@dataclass
class CodeGenerationContext:
    """
    Holds all state needed during TypeScript code generation.

    This class consolidates the numerous instance variables that were
    previously scattered throughout the TypeScriptCodeGenerator class.
    """

    # Indentation state
    indent_level: int = 0
    indent_str: str = '  '

    # File context
    file_depth: int = 0
    current_file_path: str = ''
    current_file_type: str = ''

    # Contract context
    current_class_name: str = ''
    current_contract_kind: str = ''  # 'contract', 'library', 'abstract', 'interface'
    current_base_classes: List[str] = field(default_factory=list)

    # Variable tracking
    current_state_vars: Set[str] = field(default_factory=set)
    current_static_vars: Set[str] = field(default_factory=set)
    current_methods: Set[str] = field(default_factory=set)
    current_local_vars: Set[str] = field(default_factory=set)
    var_types: Dict[str, TypeName] = field(default_factory=dict)
    current_method_return_types: Dict[str, str] = field(default_factory=dict)

    # Struct context
    current_local_structs: Set[str] = field(default_factory=set)
    current_inherited_structs: Dict[str, str] = field(default_factory=dict)

    # Import tracking
    base_contracts_needed: Set[str] = field(default_factory=set)
    libraries_referenced: Set[str] = field(default_factory=set)
    contracts_referenced: Set[str] = field(default_factory=set)
    set_types_used: Set[str] = field(default_factory=set)
    external_structs_used: Dict[str, str] = field(default_factory=dict)

    # Flags
    _in_base_constructor_args: bool = False

    # Caches
    _qualified_name_cache: Dict[str, str] = field(default_factory=dict)

    # Runtime replacements
    runtime_replacement_classes: Set[str] = field(default_factory=set)
    runtime_replacement_mixins: Dict[str, str] = field(default_factory=dict)
    runtime_replacement_methods: Dict[str, Set[str]] = field(default_factory=dict)

    # Type knowledge (from registry)
    known_structs: Set[str] = field(default_factory=set)
    known_enums: Set[str] = field(default_factory=set)
    known_constants: Set[str] = field(default_factory=set)
    known_interfaces: Set[str] = field(default_factory=set)
    known_contracts: Set[str] = field(default_factory=set)
    known_libraries: Set[str] = field(default_factory=set)
    known_contract_methods: Dict[str, Set[str]] = field(default_factory=dict)
    known_contract_vars: Dict[str, Set[str]] = field(default_factory=dict)
    known_public_state_vars: Set[str] = field(default_factory=set)
    known_public_mappings: Set[str] = field(default_factory=set)  # Public mappings needing getter methods
    known_method_return_types: Dict[str, Dict[str, str]] = field(default_factory=dict)
    known_contract_paths: Dict[str, str] = field(default_factory=dict)
    known_struct_fields: Dict[str, Dict[str, str]] = field(default_factory=dict)

    # Reference to the full registry (for complex queries)
    _registry: Optional[TypeRegistry] = None

    # Diagnostics collector
    _diagnostics: Optional[TranspilerDiagnostics] = None

    @property
    def diagnostics(self) -> TranspilerDiagnostics:
        """Get the diagnostics collector, creating one if needed."""
        if self._diagnostics is None:
            self._diagnostics = TranspilerDiagnostics()
        return self._diagnostics

    def indent(self) -> str:
        """Return the current indentation string."""
        return self.indent_str * self.indent_level

    def get_qualified_name(self, name: str) -> str:
        """
        Get the qualified name for a type.

        Uses cached lookup for performance optimization.
        """
        return self._qualified_name_cache.get(name, name)

    def reset_for_file(self) -> None:
        """Reset state for a new file."""
        self.base_contracts_needed = set()
        self.libraries_referenced = set()
        self.contracts_referenced = set()
        self.set_types_used = set()
        self.external_structs_used = {}

    def reset_for_contract(self) -> None:
        """Reset state for a new contract."""
        self.current_state_vars = set()
        self.current_static_vars = set()
        self.current_methods = set()
        self.current_local_vars = set()
        self.var_types = {}
        self.current_method_return_types = {}
        self.current_local_structs = set()
        self.current_inherited_structs = {}

    def reset_for_function(self) -> None:
        """Reset state for a new function."""
        self.current_local_vars = set()

    @classmethod
    def from_registry(
        cls,
        registry: Optional[TypeRegistry],
        file_depth: int = 0,
        current_file_path: str = '',
        runtime_replacement_classes: Optional[Set[str]] = None,
        runtime_replacement_mixins: Optional[Dict[str, str]] = None,
        runtime_replacement_methods: Optional[Dict[str, Set[str]]] = None,
    ) -> 'CodeGenerationContext':
        """
        Create a context from a TypeRegistry.

        Args:
            registry: The type registry containing discovered types
            file_depth: Depth of output file for relative imports
            current_file_path: Relative path of current file
            runtime_replacement_classes: Classes to import from runtime
            runtime_replacement_mixins: Mixin code for secondary inheritance
            runtime_replacement_methods: Method names for override detection

        Returns:
            A new CodeGenerationContext instance
        """
        ctx = cls(
            file_depth=file_depth,
            current_file_path=current_file_path,
            runtime_replacement_classes=runtime_replacement_classes or set(),
            runtime_replacement_mixins=runtime_replacement_mixins or {},
            runtime_replacement_methods=runtime_replacement_methods or {},
            _registry=registry,
        )

        if registry:
            ctx.known_structs = registry.structs
            ctx.known_enums = registry.enums
            ctx.known_constants = registry.constants
            ctx.known_interfaces = registry.interfaces
            ctx.known_contracts = registry.contracts
            ctx.known_libraries = registry.libraries
            ctx.known_contract_methods = registry.contract_methods
            ctx.known_contract_vars = registry.contract_vars
            ctx.known_public_state_vars = registry.known_public_state_vars
            ctx.known_public_mappings = registry.known_public_mappings
            ctx.known_method_return_types = registry.method_return_types
            ctx.known_contract_paths = registry.contract_paths
            ctx.known_struct_fields = registry.struct_fields

        return ctx

    def build_qualified_name_cache(self, current_file_type: str = '') -> None:
        """Build the qualified name cache for the current file."""
        self.current_file_type = current_file_type

        if self._registry:
            self._qualified_name_cache = self._registry.build_qualified_name_cache(
                current_file_type
            )
        else:
            self._qualified_name_cache = {}
            if current_file_type != 'Structs':
                for name in self.known_structs:
                    self._qualified_name_cache[name] = f'Structs.{name}'
            if current_file_type != 'Enums':
                for name in self.known_enums:
                    self._qualified_name_cache[name] = f'Enums.{name}'
            if current_file_type != 'Constants':
                for name in self.known_constants:
                    self._qualified_name_cache[name] = f'Constants.{name}'

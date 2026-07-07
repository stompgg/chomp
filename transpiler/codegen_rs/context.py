"""Mutable emission state for the Rust backend (analog of codegen.context)."""

from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set

from ..parser.ast_nodes import TypeName


@dataclass
class RustCodeGenerationContext:
    indent_level: int = 0
    indent_str: str = '    '

    # File / container context
    current_file_path: str = ''            # source-relative, no extension
    current_class_name: str = ''           # contract/library being emitted
    current_contract_kind: str = ''        # 'contract' | 'library' | 'interface' | 'abstract'

    # Variable tracking (name -> Solidity TypeName), mirrors the TS backend
    var_types: Dict[str, TypeName] = field(default_factory=dict)
    # Contract-level slice of var_types (state vars); reset_for_function
    # restores var_types from this so per-function locals never leak.
    contract_var_types: Dict[str, TypeName] = field(default_factory=dict)
    current_local_vars: Set[str] = field(default_factory=set)
    current_state_vars: Set[str] = field(default_factory=set)
    # Parameters passed as `&mut T` (Solidity memory reference types)
    ref_params: Set[str] = field(default_factory=set)
    # Parameters passed as `&mut dyn Trait` (callable interface handles)
    dyn_params: Set[str] = field(default_factory=set)
    # Memory-alias tracking: after `local = refParam` (whole array/struct),
    # Solidity's `refParam` and `local` are the SAME memory object. Reads and
    # writes of the param name are redirected to the owned local so intra-
    # function aliasing behaves like Solidity (see statement generator).
    alias_map: Dict[str, str] = field(default_factory=dict)

    # ---- Phase 2 (World model) ----
    # Storage locals bound to a DIRECT mapping index (`X storage y = m[k];`):
    # name -> {'place': substitution place text (re-derived per use, no held
    # borrows), 'key': key temp/expr text (for passing to key-lowered params),
    # 'root': (contract, state_var, key SolType) or None}.
    storage_locals: Dict[str, dict] = field(default_factory=dict)
    # Storage locals bound to helper calls / reference params of storage type:
    # plain `&mut T` bindings; uses read through `(*name)` like ref params.
    storage_ref_locals: Set[str] = field(default_factory=set)
    # Whether the function being emitted takes `world: &mut World`.
    current_fn_needs_world: bool = False
    # Whether it returns a storage reference (`-> &mut T`).
    current_fn_returns_storage: bool = False
    # Whether anything in this file referenced the World type.
    uses_world_type: bool = False
    # Whether the contract being emitted is stateful (state in World).
    current_contract_stateful: bool = False
    # Emitting a constructor body: state vars write to `self_` instead of world.
    in_constructor: bool = False
    # Contract that DEFINED the function currently being emitted (differs
    # from current_class_name inside flattened base functions); anchors
    # static super-dispatch resolution.
    current_defining_container: str = ''
    # Per-statement hoisted prelude lines (key temps, arg temps); the
    # statement generator drains these before the statement that caused them.
    pending_hoists: List[str] = field(default_factory=list)
    # Counter for unique temp names within a function.
    temp_counter: int = 0

    def fresh_temp(self, stem: str) -> str:
        self.temp_counter += 1
        return f'__{stem}{self.temp_counter}'

    # True inside `unchecked { ... }` blocks -> wrapping arithmetic
    unchecked_depth: int = 0

    # Enclosing-loop stack for break/continue emission. Each entry:
    # {'kind': 'for'|'while'|'dowhile', 'body_label': str|None,
    #  'loop_label': str|None}. for/do-while bodies containing `continue`
    # are wrapped in a labeled block (continue -> break 'body); the loop
    # itself is then labeled too because Rust rejects an UNLABELED `break`
    # that sits syntactically inside a labeled block (E0695), so Solidity
    # `break` becomes `break 'loop` there.
    loop_stack: List[dict] = field(default_factory=list)

    # Names referenced in this file that live in other modules -> use lines
    used_types: Set[str] = field(default_factory=set)       # enums/structs
    used_modules: Set[str] = field(default_factory=set)     # library modules (by type name)
    used_constants: Set[str] = field(default_factory=set)   # file-scope constants
    used_traits: Set[str] = field(default_factory=set)      # interface traits

    # Diagnostics: (severity, message) collected during emission
    notes: List[tuple] = field(default_factory=list)

    @property
    def unchecked(self) -> bool:
        return self.unchecked_depth > 0

    def indent(self) -> str:
        return self.indent_str * self.indent_level

    def warn(self, message: str) -> None:
        self.notes.append(('warning', f'{self.current_file_path}: {message}'))

    def info(self, message: str) -> None:
        self.notes.append(('info', f'{self.current_file_path}: {message}'))

    def reset_for_contract(self) -> None:
        self.var_types = {}
        self.contract_var_types = {}
        self.current_local_vars = set()
        self.current_state_vars = set()
        self.ref_params = set()
        self.dyn_params = set()
        self.unchecked_depth = 0
        self.loop_stack = []

    def reset_for_function(self) -> None:
        self.current_local_vars = set()
        self.ref_params = set()
        self.dyn_params = set()
        self.alias_map = {}
        self.storage_locals = {}
        self.storage_ref_locals = set()
        self.current_fn_needs_world = False
        self.current_defining_container = ''
        self.in_constructor = False
        self.pending_hoists = []
        self.temp_counter = 0
        self.unchecked_depth = 0
        self.loop_stack = []
        # Locals/params of the previous function must not leak into this
        # one's type inference: restore the contract-level view (state vars).
        self.var_types = dict(self.contract_var_types)

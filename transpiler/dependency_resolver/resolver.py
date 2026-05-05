"""
Main dependency resolver that orchestrates all resolution strategies.

Resolution order:
1. Manual overrides from transpiler-config.json
2. Parameter name inference (_FROSTBITE_STATUS -> FrostbiteStatus)
3. Interface aliases (IEngine -> Engine)

Unresolved dependencies are tracked and can be exported for user action.
"""

from typing import Dict, List, Optional, Set, Tuple, Union
from dataclasses import dataclass

from ..config import TranspilerConfig
from .name_inferrer import NameInferrer


@dataclass
class ResolvedDependency:
    """A dependency with resolution information."""
    name: str  # Parameter name (e.g., "_FROSTBITE_STATUS")
    type_name: str  # Interface type (e.g., "IEffect")
    is_interface: bool
    is_value_type: bool
    is_array: bool = False
    resolved_as: Optional[Union[str, List[str]]] = None  # Concrete class(es)
    resolution_source: Optional[str] = None  # How it was resolved



@dataclass
class UnresolvedDependency:
    """Tracks an unresolved dependency for user action."""
    contract_name: str
    param_name: str
    type_name: str
    is_array: bool = False

    def to_dict(self) -> dict:
        result = {
            "paramName": self.param_name,
            "typeName": self.type_name,
        }
        if self.is_array:
            result["isArray"] = True
        return result


class DependencyResolver:
    """
    Resolves interface dependencies to concrete implementations.

    Uses multiple strategies in order:
    1. Manual overrides (transpiler-config.json `dependencyOverrides`)
    2. Parameter name inference
    3. Interface aliases (transpiler-config.json `interfaceAliases`)
    4. Mechanical `I`-prefix strip (IFoo -> Foo, if Foo is known)

    The interface-alias map is entirely config-driven — no defaults are baked
    into the resolver. Consumers declare their own schema in their project's
    `transpiler-config.json`. `null` (JSON) / `None` (Python) means the type
    is self-referential or passed as `address(0)` at deploy time; the
    resolver uses the `"@self"` sentinel so factory generation can skip it.
    """

    def __init__(
        self,
        overrides_path: Optional[str] = None,
        known_classes: Optional[Set[str]] = None,
    ):
        """
        Initialize the resolver.

        Args:
            overrides_path: Path to transpiler-config.json
            known_classes: Set of known concrete class names
        """
        self.overrides: Dict[str, Dict[str, Union[str, List[str]]]] = {}
        self.interface_aliases: Dict[str, Optional[str]] = {}
        self.known_classes = known_classes or set()
        self.unresolved: List[UnresolvedDependency] = []

        if overrides_path:
            self._load_overrides(overrides_path)

        self.name_inferrer = NameInferrer(self.known_classes)

    def _load_overrides(self, path: str) -> None:
        """Load dependency overrides and interface aliases from JSON file.

        Expects the consolidated `transpiler-config.json` schema:

            {
              "dependencyOverrides": { "ContractName": { "_param": "Impl" } },
              "interfaceAliases":     { "IFoo": "FooImpl", "IBar": null }
            }

        Legacy `dependency-overrides.json` with a top-level `overrides` key
        is also accepted for backwards compatibility.
        """
        config = TranspilerConfig.load(path, warn_missing=False)
        self.overrides = config.dependency_overrides
        self.interface_aliases = config.interface_aliases

    def add_known_class(self, class_name: str) -> None:
        """Add a known concrete class."""
        self.known_classes.add(class_name)
        self.name_inferrer.add_known_class(class_name)

    def add_known_classes(self, class_names: Set[str]) -> None:
        """Add multiple known concrete classes."""
        self.known_classes.update(class_names)
        self.name_inferrer.add_known_classes(class_names)

    def add_aliases(
        self,
        aliases: Dict[str, Optional[str]],
        override: bool = False,
    ) -> None:
        """Layer interface→impl aliases on top of whatever was loaded from
        config. With `override=False` (default) existing entries win on
        conflict — matching the "manual config is authoritative" precedence."""
        for iface, impl in aliases.items():
            if override:
                self.interface_aliases[iface] = impl
            else:
                self.interface_aliases.setdefault(iface, impl)

    def resolve_constructor_params(
        self,
        contract_name: str,
        constructor_params: List[Tuple[str, str]],
        known_interfaces: Set[str],
        known_contracts: Optional[Set[str]] = None,
    ) -> List[Tuple[str, str, ResolvedDependency]]:
        """Walk one contract's constructor params, resolving each typed one.

        Returns a list of `(param_name, param_type, resolved)` tuples for
        params whose type is either an interface (always resolved via the
        `resolve()` chain) or a concrete contract (when `known_contracts`
        is passed — those don't need resolution, the type *is* the impl).

        Params whose type is neither (e.g., `uint256`) are skipped. Array
        suffixes (`IFoo[]`) are handled: the base type is used for interface
        classification, the full type for the resolution call.
        """
        out: List[Tuple[str, str, ResolvedDependency]] = []
        for idx, (param_name, param_type) in enumerate(constructor_params):
            base_type = param_type.rstrip('[]')
            is_interface = base_type in known_interfaces
            is_contract = known_contracts is not None and base_type in known_contracts
            if not (is_interface or is_contract):
                continue
            if is_interface:
                resolved = self.resolve(
                    contract_name=contract_name,
                    param_name=param_name,
                    type_name=param_type,
                    is_interface=True,
                    is_value_type=False,
                    param_index=idx,
                )
            else:
                resolved = ResolvedDependency(
                    name=param_name,
                    type_name=param_type,
                    is_interface=False,
                    is_value_type=False,
                    is_array=param_type.endswith('[]'),
                    resolved_as=base_type,
                )
            out.append((param_name, param_type, resolved))
        return out

    def resolve(
        self,
        contract_name: str,
        param_name: str,
        type_name: str,
        is_interface: bool,
        is_value_type: bool,
        param_index: int = 0,
    ) -> ResolvedDependency:
        """
        Resolve a single dependency.

        Args:
            contract_name: The contract that has this dependency
            param_name: The constructor parameter name
            type_name: The type (e.g., "IEffect" or "IEffect[]")
            is_interface: Whether the type is an interface
            is_value_type: Whether it's a value type (struct)
            param_index: Position in constructor (for script scanner)

        Returns:
            ResolvedDependency with resolution information
        """
        # Check if it's an array type
        is_array = type_name.endswith('[]')
        base_type = type_name.rstrip('[]') if is_array else type_name

        dep = ResolvedDependency(
            name=param_name,
            type_name=type_name,
            is_interface=is_interface,
            is_value_type=is_value_type,
            is_array=is_array,
        )

        # Don't resolve value types or non-interfaces
        if is_value_type or not is_interface:
            return dep

        # Try resolution strategies in order
        resolved = self._try_resolve(
            contract_name, param_name, base_type, is_array, param_index
        )

        if resolved is not None:
            dep.resolved_as = resolved
        else:
            # Track as unresolved
            self.unresolved.append(UnresolvedDependency(
                contract_name=contract_name,
                param_name=param_name,
                type_name=type_name,
                is_array=is_array,
            ))

        return dep

    def _try_resolve(
        self,
        contract_name: str,
        param_name: str,
        base_type: str,
        is_array: bool,
        param_index: int,
    ) -> Optional[Union[str, List[str]]]:
        """Try all resolution strategies in order."""

        # 1. Check manual overrides
        if contract_name in self.overrides:
            if param_name in self.overrides[contract_name]:
                override = self.overrides[contract_name][param_name]
                return override

        # 2. Try name inference (e.g., _FROSTBITE_STATUS -> FrostbiteStatus)
        inferred = self.name_inferrer.infer(param_name, validate=True)
        if inferred:
            return [inferred] if is_array else inferred

        # 3. Check configured interface aliases
        if base_type in self.interface_aliases:
            alias = self.interface_aliases[base_type]
            if alias is None:
                # None means self-referential/optional - use special marker
                return "@self"
            return [alias] if is_array else alias

        # 4. Try stripping 'I' prefix (IEffect -> Effect)
        if base_type.startswith('I') and len(base_type) > 1:
            stripped = base_type[1:]
            if stripped in self.known_classes:
                return [stripped] if is_array else stripped

        return None

    def get_unresolved(self) -> List[UnresolvedDependency]:
        """Get list of unresolved dependencies."""
        return list(self.unresolved)

    def has_unresolved(self) -> bool:
        """Check if there are any unresolved dependencies."""
        return len(self.unresolved) > 0

    def export_unresolved(self, output_path: str) -> None:
        """
        Export unresolved dependencies to JSON for user action.

        Creates a file like:
        {
            "unresolved": {
                "ContractName": {
                    "_param": { "typeName": "IEffect", "isArray": false }
                }
            },
            "template": {
                "ContractName": {
                    "_param": "ConcreteClassName"
                }
            }
        }
        """
        if not self.unresolved:
            return

        # Group by contract
        by_contract: Dict[str, Dict[str, dict]] = {}
        template: Dict[str, Dict[str, Union[str, List[str]]]] = {}

        for dep in self.unresolved:
            if dep.contract_name not in by_contract:
                by_contract[dep.contract_name] = {}
                template[dep.contract_name] = {}

            by_contract[dep.contract_name][dep.param_name] = dep.to_dict()
            template[dep.contract_name][dep.param_name] = (
                ["TODO"] if dep.is_array else "TODO"
            )

        output = {
            "$comment": "Copy entries from 'template' to dependency-overrides.json and fill in concrete class names",
            "unresolved": by_contract,
            "template": template,
        }

        with open(output_path, 'w') as f:
            json.dump(output, f, indent=2)

"""
Main dependency resolver that orchestrates all resolution strategies.

Resolution order:
1. Manual overrides from transpiler-config.json
2. Parameter name inference (_FROSTBITE_STATUS -> FrostbiteStatus)
3. Interface aliases (IEngine -> Engine)

Unresolved dependencies are tracked and can be exported for user action.
"""

import json
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple, Union
from dataclasses import dataclass, field

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
    1. Manual overrides (transpiler-config.json)
    2. Parameter name inference
    3. Interface aliases
    """

    # Standard interface -> implementation aliases
    # Use None to indicate optional/self-referential dependencies
    DEFAULT_ALIASES: Dict[str, Optional[str]] = {
        'IEngine': 'Engine',
        'ITypeCalculator': 'TypeCalculator',
        'ICommitManager': 'DefaultCommitManager',
        'IMatchmaker': 'DefaultMatchmaker',
        'IRandomnessOracle': 'DefaultRandomnessOracle',
        'IRuleset': 'DefaultRuleset',
        'IValidator': 'DefaultValidator',
        'IMonRegistry': 'DefaultMonRegistry',
        # IOwnableMon resolves to GachaRegistry
        'IOwnableMon': 'GachaRegistry',
        # ICPURNG is special: CPUs implement it themselves and use address(this)
        # when passed address(0). Mark as None to indicate self-referential.
        'ICPURNG': None,
        # IGachaRNG: GachaRegistry depends on this but deploy scripts pass address(0).
        # Mark as self-referential to avoid circular dependency.
        'IGachaRNG': None,
    }

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
        self.skip_contracts: Set[str] = set()
        self.known_classes = known_classes or set()
        self.unresolved: List[UnresolvedDependency] = []

        if overrides_path:
            self._load_overrides(overrides_path)

        self.name_inferrer = NameInferrer(self.known_classes)

    def _load_overrides(self, path: str) -> None:
        """Load manual overrides and skip list from JSON file.

        Supports both consolidated transpiler-config.json format
        (dependencyOverrides/skipContracts) and legacy dependency-overrides.json
        format (overrides/skipContracts).
        """
        try:
            with open(path, 'r') as f:
                data = json.load(f)
                self.overrides = data.get('dependencyOverrides', data.get('overrides', {}))
                self.skip_contracts = set(data.get('skipContracts', []))
        except FileNotFoundError:
            pass  # No overrides file is fine
        except json.JSONDecodeError as e:
            print(f"Warning: Failed to parse {path}: {e}")

    def add_known_class(self, class_name: str) -> None:
        """Add a known concrete class."""
        self.known_classes.add(class_name)
        self.name_inferrer.add_known_class(class_name)

    def add_known_classes(self, class_names: Set[str]) -> None:
        """Add multiple known concrete classes."""
        self.known_classes.update(class_names)
        self.name_inferrer.add_known_classes(class_names)

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

        # 3. Check default interface aliases
        if base_type in self.DEFAULT_ALIASES:
            alias = self.DEFAULT_ALIASES[base_type]
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


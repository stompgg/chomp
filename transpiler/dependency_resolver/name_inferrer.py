"""
Infers concrete class names from parameter names.

Converts parameter naming conventions to concrete class names:
- _FROSTBITE_STATUS -> FrostbiteStatus
- _effects -> Effects (may need override)
- _ENGINE -> Engine
"""

import re
from typing import Optional, Set


class NameInferrer:
    """Infers concrete class names from constructor parameter names."""

    def __init__(self, known_classes: Optional[Set[str]] = None):
        """
        Initialize the inferrer.

        Args:
            known_classes: Set of known concrete class names for validation.
                          If provided, inference will be validated against this set.
        """
        self.known_classes = known_classes or set()

    def infer(self, param_name: str, validate: bool = True) -> Optional[str]:
        """
        Infer a concrete class name from a parameter name.

        Args:
            param_name: The parameter name (e.g., "_FROSTBITE_STATUS")
            validate: If True and known_classes is set, only return if class exists

        Returns:
            The inferred class name, or None if inference failed/invalid
        """
        # Strip leading underscore(s)
        name = param_name.lstrip('_')

        if not name:
            return None

        # Convert to PascalCase
        inferred = self._to_pascal_case(name)

        # Validate against known classes if requested
        if validate and self.known_classes and inferred not in self.known_classes:
            return None

        return inferred

    def _to_pascal_case(self, name: str) -> str:
        """
        Convert a name to PascalCase.

        Handles:
        - SCREAMING_CASE: FROSTBITE_STATUS -> FrostbiteStatus
        - snake_case: frostbite_status -> FrostbiteStatus
        - camelCase: frostbiteStatus -> FrostbiteStatus
        - Already PascalCase: FrostbiteStatus -> FrostbiteStatus
        """
        # Check if it's SCREAMING_CASE or snake_case (contains underscores)
        if '_' in name:
            parts = name.split('_')
            return ''.join(self._capitalize_part(part) for part in parts if part)

        # Check if it's already PascalCase or camelCase
        if name[0].isupper():
            # Already PascalCase, return as-is
            return name

        # camelCase - capitalize first letter
        return name[0].upper() + name[1:]

    def _capitalize_part(self, part: str) -> str:
        """Capitalize a single part of a name."""
        if not part:
            return ''
        # Handle all-caps parts (from SCREAMING_CASE)
        if part.isupper():
            return part.capitalize()
        # Handle mixed case - just ensure first letter is upper
        return part[0].upper() + part[1:]

    def add_known_class(self, class_name: str) -> None:
        """Add a class to the known classes set."""
        self.known_classes.add(class_name)

    def add_known_classes(self, class_names: Set[str]) -> None:
        """Add multiple classes to the known classes set."""
        self.known_classes.update(class_names)

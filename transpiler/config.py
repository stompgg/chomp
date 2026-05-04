"""Shared loader for ``transpiler-config.json``.

The config file is consumed by code generation, dependency resolution, and
``extruder init``. This module keeps schema parsing and path normalization in
one place while preserving the existing public APIs that accept a config path.
"""

from dataclasses import dataclass, field
import json
from pathlib import Path
from typing import Dict, List, Optional, Set, Union


DependencyOverride = Union[str, List[str]]


def normalize_config_path(path: str) -> str:
    """Normalize config paths to POSIX-style relative strings."""
    return str(Path(path)).replace('\\', '/')


def merge_config_updates(
    existing: Optional[dict] = None,
    *,
    skip_files: Optional[List[str]] = None,
    interface_aliases: Optional[Dict[str, Optional[str]]] = None,
    dependency_overrides: Optional[Dict[str, Dict[str, DependencyOverride]]] = None,
    runtime_replacements: Optional[List[dict]] = None,
) -> dict:
    """Merge generated config updates without overwriting user choices.

    Existing aliases, dependency overrides, and replacement sources win on
    conflict. New skip paths are unioned and normalized for consistent writes.
    """
    existing = existing or {}
    merged = dict(existing)

    merged_skip_files = sorted({
        normalize_config_path(str(path))
        for path in existing.get('skipFiles', [])
    } | {
        normalize_config_path(str(path))
        for path in (skip_files or [])
    })

    merged_aliases = dict(existing.get('interfaceAliases', {}))
    for key, value in (interface_aliases or {}).items():
        merged_aliases.setdefault(key, value)

    merged_dep_overrides: Dict[str, Dict[str, DependencyOverride]] = {
        key: dict(value)
        for key, value in existing.get('dependencyOverrides', {}).items()
    }
    for contract_name, params in (dependency_overrides or {}).items():
        dest = merged_dep_overrides.setdefault(contract_name, {})
        for param_name, impl in params.items():
            dest.setdefault(param_name, impl)

    merged_replacements = list(existing.get('runtimeReplacements', []))
    existing_sources = {
        normalize_config_path(str(entry.get('source') or ''))
        for entry in merged_replacements
        if isinstance(entry, dict)
    }
    for replacement in runtime_replacements or []:
        source = normalize_config_path(str(replacement.get('source') or ''))
        if not source or source in existing_sources:
            continue
        merged_replacements.append(replacement)
        existing_sources.add(source)

    if merged_skip_files:
        merged['skipFiles'] = merged_skip_files
    if merged_aliases:
        merged['interfaceAliases'] = merged_aliases
    if merged_dep_overrides:
        merged['dependencyOverrides'] = merged_dep_overrides
    if merged_replacements:
        merged['runtimeReplacements'] = merged_replacements

    return merged


@dataclass
class TranspilerConfig:
    """Normalized representation of ``transpiler-config.json``."""

    runtime_replacements: Dict[str, dict] = field(default_factory=dict)
    runtime_replacement_classes: Set[str] = field(default_factory=set)
    runtime_replacement_mixins: Dict[str, str] = field(default_factory=dict)
    runtime_replacement_methods: Dict[str, Set[str]] = field(default_factory=dict)
    skip_files: Set[str] = field(default_factory=set)
    skip_dirs: Set[str] = field(default_factory=set)
    dependency_overrides: Dict[str, Dict[str, DependencyOverride]] = field(default_factory=dict)
    interface_aliases: Dict[str, Optional[str]] = field(default_factory=dict)
    raw: dict = field(default_factory=dict)

    @classmethod
    def default_path(cls) -> Path:
        return Path(__file__).parent / 'transpiler-config.json'

    @classmethod
    def load(
        cls,
        path: Optional[str | Path] = None,
        *,
        warn_missing: bool = False,
        label: str = 'transpiler-config.json',
    ) -> 'TranspilerConfig':
        """Load and normalize a config file.

        Missing files return an empty config. Invalid JSON also returns an empty
        config after printing a warning, matching the historical forgiving
        behavior.
        """
        config_path = Path(path) if path else cls.default_path()
        if not config_path.exists():
            if warn_missing:
                print(f"Warning: {label} not found at {config_path}")
            return cls()

        try:
            data = json.loads(config_path.read_text())
        except json.JSONDecodeError as e:
            print(f"Warning: Failed to parse {config_path}: {e}")
            return cls()

        return cls.from_dict(data)

    @classmethod
    def from_dict(cls, data: dict) -> 'TranspilerConfig':
        cfg = cls(raw=data)

        for replacement in data.get('runtimeReplacements', []):
            source_path = normalize_config_path(replacement.get('source', ''))
            if not source_path:
                continue

            cfg.runtime_replacements[source_path] = replacement

            for export in replacement.get('exports', []):
                cfg.runtime_replacement_classes.add(export)

            interface = replacement.get('interface', {})
            class_name = interface.get('class', '')
            mixin_code = interface.get('mixin', '')
            if class_name and mixin_code:
                cfg.runtime_replacement_mixins[class_name] = mixin_code

            methods = interface.get('methods', [])
            if class_name and methods:
                cfg.runtime_replacement_methods[class_name] = {
                    m.get('name', '') for m in methods if m.get('name')
                }

        cfg.skip_files = {
            normalize_config_path(path)
            for path in data.get('skipFiles', [])
        }
        cfg.skip_dirs = {
            normalize_config_path(path).rstrip('/')
            for path in data.get('skipDirs', [])
        }

        # Consolidated config uses dependencyOverrides; legacy
        # dependency-overrides.json used a top-level overrides key.
        cfg.dependency_overrides = data.get(
            'dependencyOverrides',
            data.get('overrides', {}),
        )
        cfg.interface_aliases = data.get('interfaceAliases', {})
        return cfg

    def should_skip_file(self, rel_path: str) -> bool:
        return normalize_config_path(rel_path) in self.skip_files

    def should_skip_dir(self, rel_path: str) -> bool:
        rel = normalize_config_path(rel_path)
        return any(rel == d or rel.startswith(d + '/') for d in self.skip_dirs)

    def runtime_replacement_for(self, rel_path: str) -> Optional[dict]:
        rel = normalize_config_path(rel_path)
        for source_pattern, replacement in self.runtime_replacements.items():
            if rel == source_pattern or rel.endswith(source_pattern):
                return replacement
        return None

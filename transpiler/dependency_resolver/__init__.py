"""
Dependency resolution module for sol2ts transpiler.

Resolves interface types to their concrete implementations using manual
overrides from transpiler-config.json and parameter-name inference.
"""

from .resolver import DependencyResolver
from .name_inferrer import NameInferrer

__all__ = ['DependencyResolver', 'NameInferrer']

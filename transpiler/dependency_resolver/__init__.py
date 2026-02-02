"""
Dependency resolution module for sol2ts transpiler.

This module handles resolving interface types to their concrete implementations
by scanning deploy scripts, inferring from parameter names, and using manual overrides.
"""

from .resolver import DependencyResolver
from .script_scanner import DeployScriptScanner
from .name_inferrer import NameInferrer

__all__ = ['DependencyResolver', 'DeployScriptScanner', 'NameInferrer']

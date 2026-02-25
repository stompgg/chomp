"""
Types module for the Solidity to TypeScript transpiler.

This module provides type registry and type conversion utilities.
"""

from .registry import TypeRegistry
from .mappings import (
    get_type_max,
    get_type_min,
    SOLIDITY_TO_TS_MAP,
)

__all__ = [
    'TypeRegistry',
    'get_type_max',
    'get_type_min',
    'SOLIDITY_TO_TS_MAP',
]

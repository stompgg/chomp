"""
Types module for the Solidity to TypeScript transpiler.

This module provides type registry and type conversion utilities.
"""

from .registry import TypeRegistry
from .mappings import (
    solidity_type_to_ts,
    get_default_value,
    get_type_max,
    get_type_min,
    SOLIDITY_TO_TS_MAP,
    DEFAULT_VALUES,
)

__all__ = [
    'TypeRegistry',
    'solidity_type_to_ts',
    'get_default_value',
    'get_type_max',
    'get_type_min',
    'SOLIDITY_TO_TS_MAP',
    'DEFAULT_VALUES',
]

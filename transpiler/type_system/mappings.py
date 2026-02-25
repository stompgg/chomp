"""
Type mappings and conversion utilities for Solidity to TypeScript.

This module contains the constant lookup tables and utility functions
for converting Solidity types to TypeScript equivalents.
"""


# =============================================================================
# TYPE MAPPING CONSTANTS
# =============================================================================

# Base Solidity to TypeScript type mapping
SOLIDITY_TO_TS_MAP = {
    # Integer types -> bigint
    'uint': 'bigint',
    'uint8': 'bigint',
    'uint16': 'bigint',
    'uint32': 'bigint',
    'uint64': 'bigint',
    'uint128': 'bigint',
    'uint256': 'bigint',
    'int': 'bigint',
    'int8': 'bigint',
    'int16': 'bigint',
    'int32': 'bigint',
    'int64': 'bigint',
    'int128': 'bigint',
    'int256': 'bigint',
    # Boolean
    'bool': 'boolean',
    # String and bytes
    'string': 'string',
    'bytes': 'string',
    'bytes1': 'string',
    'bytes2': 'string',
    'bytes3': 'string',
    'bytes4': 'string',
    'bytes8': 'string',
    'bytes16': 'string',
    'bytes20': 'string',
    'bytes32': 'string',
    # Address
    'address': 'string',
    # Special types
    'function': 'Function',
}


# =============================================================================
# TYPE UTILITY FUNCTIONS
# =============================================================================

def get_type_max(type_name: str) -> str:
    """
    Get the maximum value for a Solidity integer type.

    Args:
        type_name: The Solidity type name (e.g., 'uint8', 'int256')

    Returns:
        A TypeScript BigInt expression representing the max value
    """
    if type_name.startswith('uint'):
        bits = int(type_name[4:]) if len(type_name) > 4 else 256
        max_val = (2 ** bits) - 1
        return f'BigInt("{max_val}")'
    elif type_name.startswith('int'):
        bits = int(type_name[3:]) if len(type_name) > 3 else 256
        max_val = (2 ** (bits - 1)) - 1
        return f'BigInt("{max_val}")'
    return '0n'


def get_type_min(type_name: str) -> str:
    """
    Get the minimum value for a Solidity integer type.

    Args:
        type_name: The Solidity type name (e.g., 'uint8', 'int256')

    Returns:
        A TypeScript BigInt expression representing the min value
    """
    if type_name.startswith('uint'):
        return '0n'
    elif type_name.startswith('int'):
        bits = int(type_name[3:]) if len(type_name) > 3 else 256
        min_val = -(2 ** (bits - 1))
        return f'BigInt("{min_val}")'
    return '0n'

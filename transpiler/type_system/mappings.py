"""
Type mappings and conversion utilities for Solidity to TypeScript.

This module contains the mappings and functions for converting Solidity
types to their TypeScript equivalents, including default values and
numeric ranges.
"""

from typing import Optional


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

# Default values for TypeScript types
DEFAULT_VALUES = {
    'bigint': '0n',
    'boolean': 'false',
    'string': '""',
    'number': '0',
}


# =============================================================================
# TYPE CONVERSION FUNCTIONS
# =============================================================================

def solidity_type_to_ts(
    type_name: 'TypeName',
    known_structs: Optional[set] = None,
    known_enums: Optional[set] = None,
    known_contracts: Optional[set] = None,
    known_interfaces: Optional[set] = None,
    known_libraries: Optional[set] = None,
    current_local_structs: Optional[set] = None,
    qualified_name_cache: Optional[dict] = None,
) -> str:
    """
    Convert a Solidity TypeName to its TypeScript equivalent.

    Args:
        type_name: The TypeName AST node to convert
        known_structs: Set of known struct names
        known_enums: Set of known enum names
        known_contracts: Set of known contract names
        known_interfaces: Set of known interface names
        known_libraries: Set of known library names
        current_local_structs: Set of struct names defined in the current contract
        qualified_name_cache: Cache for qualified name lookups

    Returns:
        The TypeScript type string
    """
    known_structs = known_structs or set()
    known_enums = known_enums or set()
    known_contracts = known_contracts or set()
    known_interfaces = known_interfaces or set()
    known_libraries = known_libraries or set()
    current_local_structs = current_local_structs or set()
    qualified_name_cache = qualified_name_cache or {}

    if type_name.is_mapping:
        # Mapping type -> Record<KeyType, ValueType>
        key_type = solidity_type_to_ts(
            type_name.key_type, known_structs, known_enums, known_contracts,
            known_interfaces, known_libraries, current_local_structs, qualified_name_cache
        ) if type_name.key_type else 'string'
        value_type = solidity_type_to_ts(
            type_name.value_type, known_structs, known_enums, known_contracts,
            known_interfaces, known_libraries, current_local_structs, qualified_name_cache
        ) if type_name.value_type else 'any'

        # Use number keys for integer types (better TypeScript compatibility)
        if key_type == 'bigint':
            key_type = 'number'

        return f'Record<{key_type}, {value_type}>'

    base_name = type_name.name

    # Handle qualified names (Library.Type)
    if '.' in base_name:
        parts = base_name.split('.')
        # EnumerableSetLib types get special handling
        if parts[0] == 'EnumerableSetLib':
            set_type = parts[1]
            if set_type in ('AddressSet', 'Uint256Set', 'Bytes32Set', 'Int256Set'):
                return set_type

    # Check for known struct types
    if base_name in known_structs:
        qualified = qualified_name_cache.get(base_name, base_name)
        if type_name.is_array:
            return f'{qualified}[]'
        return qualified

    # Check for local structs (no prefix needed)
    if base_name in current_local_structs:
        if type_name.is_array:
            return f'{base_name}[]'
        return base_name

    # Check for known enum types
    if base_name in known_enums:
        qualified = qualified_name_cache.get(base_name, base_name)
        if type_name.is_array:
            return f'{qualified}[]'
        return qualified

    # Check for contract/interface types (map to the type name itself)
    if base_name in known_contracts or base_name in known_interfaces or base_name in known_libraries:
        if type_name.is_array:
            return f'{base_name}[]'
        return base_name

    # Handle EnumerableSetLib types
    if base_name in ('AddressSet', 'Uint256Set', 'Bytes32Set', 'Int256Set'):
        return base_name

    # Look up in base map
    ts_type = SOLIDITY_TO_TS_MAP.get(base_name, None)

    if ts_type:
        if type_name.is_array:
            return f'{ts_type}[]'
        return ts_type

    # Handle integer types with size suffix
    if base_name.startswith('uint') or base_name.startswith('int'):
        if type_name.is_array:
            return 'bigint[]'
        return 'bigint'

    # Handle bytes types with size suffix
    if base_name.startswith('bytes'):
        if type_name.is_array:
            return 'string[]'
        return 'string'

    # Unknown type - return as-is
    if type_name.is_array:
        return f'{base_name}[]'
    return base_name


def get_default_value(ts_type: str) -> str:
    """
    Get the default value for a TypeScript type.

    Args:
        ts_type: The TypeScript type string

    Returns:
        A string representing the default value in TypeScript
    """
    # Check direct mapping first
    if ts_type in DEFAULT_VALUES:
        return DEFAULT_VALUES[ts_type]

    # Handle array types
    if ts_type.endswith('[]'):
        return '[]'

    # Handle Record types
    if ts_type.startswith('Record<'):
        return '{}'

    # Handle struct types
    if ts_type.startswith('Structs.'):
        struct_name = ts_type[8:]
        return f'Structs.createDefault{struct_name}()'

    # Handle EnumerableSetLib types
    if ts_type in ('AddressSet', 'Uint256Set', 'Bytes32Set', 'Int256Set'):
        return f'new {ts_type}()'

    # Default fallback
    return '0n'


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

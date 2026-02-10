#!/usr/bin/env python3

import csv
import os
import re
import argparse
from typing import Dict, List, Tuple
import numpy as np


class MonData:
    """Represents a mon with its stats, moves, abilities, and sprite data"""
    def __init__(self, mon_id: int, name: str, hp: int, stamina: int, speed: int,
                 attack: int, defense: int, special_attack: int, special_defense: int,
                 type1: str, type2: str):
        self.mon_id = mon_id
        self.name = name
        self.hp = hp
        self.stamina = stamina
        self.speed = speed
        self.attack = attack
        self.defense = defense
        self.special_attack = special_attack
        self.special_defense = special_defense
        self.type1 = type1
        self.type2 = type2
        self.moves: List[str] = []
        self.abilities: List[str] = []
        self.sprite_data: List[int] = []  # uint256 values for compressed sprite data
        self.palette_data: List[int] = []  # uint256 values for compressed palette data


class ContractInfo:
    """Represents information about a contract to be deployed"""
    def __init__(self, name: str, contract_path: str, dependencies: List[Dict], import_paths: List[str] = None):
        self.name = name
        self.contract_path = contract_path
        self.dependencies = dependencies  # Now expects list of dicts with name, type, param_name
        self.import_paths = import_paths or []  # File paths of contracts that need to be imported
        self.variable_name = self._generate_variable_name()

    def _generate_variable_name(self) -> str:
        """Generate a valid Solidity variable name from contract name"""
        # Remove spaces and convert to camelCase
        words = self.name.replace(" ", "").split()
        if not words:
            return "contract"

        # First word lowercase, rest title case
        result = words[0].lower()
        for word in words[1:]:
            result += word.capitalize()

        # Remove any non-alphanumeric characters
        result = re.sub(r'\W+', '', result)

        return result


def read_mons_csv(file_path: str) -> Dict[str, MonData]:
    """Read mons.csv and return a dictionary of mon name -> MonData"""
    mons = {}
    with open(file_path, 'r', newline='', encoding='utf-8') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            mon = MonData(
                mon_id=int(row['Id']),
                name=row['Name'],
                hp=int(row['HP']),
                stamina=5,
                speed=int(row['Speed']),
                attack=int(row['Attack']),
                defense=int(row['Defense']),
                special_attack=int(row['SpecialAttack']),
                special_defense=int(row['SpecialDefense']),
                type1=row['Type1'],
                type2=row['Type2']
            )
            mons[mon.name] = mon
    return mons


def read_moves_csv(file_path: str, mons: Dict[str, MonData]) -> None:
    """Read moves.csv and populate move data for each mon"""
    with open(file_path, 'r', newline='', encoding='utf-8') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            move_name = row['Name'].strip()
            mon_name = row['Mon'].strip()
            if move_name and mon_name and mon_name in mons:
                mons[mon_name].moves.append(move_name)


def read_abilities_csv(file_path: str, mons: Dict[str, MonData]) -> None:
    """Read abilities.csv and populate ability data for each mon"""
    with open(file_path, 'r', newline='', encoding='utf-8') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            ability_name = row['Name'].strip()
            mon_name = row['Mon'].strip()

            if ability_name and mon_name and mon_name in mons:
                mons[mon_name].abilities.append(ability_name)


def convert_type_to_solidity(type_str: str) -> str:
    """Convert CSV type string to Solidity Type enum value"""
    if type_str == "NA" or type_str == "":
        return "Type.None"
    return "Type." + type_str


def contract_name_from_move_or_ability(name: str) -> str:
    """Convert move/ability name to contract name (remove spaces and -)"""
    name = re.sub(r'\W+', '', name.replace(" ", ""))
    return name


def get_mon_directory_name(mon_name: str) -> str:
    """Convert mon name to directory name (lowercase)"""
    return mon_name.lower()


def compress_to_uint256(indexed_frame, bits_per_pixel: int) -> List[int]:
    """Convert indexed frame to compressed uint256 values using simple bit packing."""
    height, width = indexed_frame.shape

    # Pack pixels into bits
    bit_string = ""
    for y in range(height):
        for x in range(width):
            pixel_value = indexed_frame[y, x]
            bit_string = format(pixel_value, f'0{bits_per_pixel}b') + bit_string

    # Split into 256-bit chunks (uint256)
    uint256_values = []
    for i in range(0, len(bit_string), 256):
        chunk = bit_string[i:i+256]
        # Pad with zeros if needed
        chunk = chunk.ljust(256, '0')
        # Convert to integer
        uint_value = int(chunk, 2)
        uint256_values.append(uint_value)

    return uint256_values



def analyze_contract_dependencies(contract_path: str, base_path: str) -> Tuple[List[str], List[str]]:
    """Analyze a contract file to determine its constructor dependencies and import paths

    Returns:
        tuple: (dependencies, import_paths) where dependencies is a list of dependency info
               and import_paths is a list of contract file paths that need to be imported
    """
    dependencies = []
    import_paths = []

    try:
        with open(contract_path, 'r', encoding='utf-8') as f:
            content = f.read()

        # Look for constructor parameters to determine deployment dependencies
        contracts_imported = set()
        constructor_match = re.search(r'constructor\s*\([^)]*\)', content, re.MULTILINE | re.DOTALL)
        if constructor_match:
            constructor_text = constructor_match.group(0)

            # Extract parameter names that start with underscore
            param_matches = re.findall(r'(\w+)\s+(\w+)', constructor_text)
            for param_type, param_name in param_matches:
                # Remove leading underscore for environment variable name
                env_name = param_name.upper()
                if env_name.startswith("_"):
                    env_name = env_name[1:]
                dependencies.append({
                    "name": env_name,
                    "type": param_type,
                    "param_name": param_name  # Keep original parameter name for intra-mon resolution
                })
                contracts_imported.add(param_type)

        # Parse import statements to get the contracts that need to be imported
        import_pattern = r'import\s+\{([^}]+)\}\s+from\s+"([^"]+)"'
        import_matches = re.findall(import_pattern, content)
        for contracts_str, import_path in import_matches:
            if contracts_str not in contracts_imported:
                continue
            # Convert relative import path to absolute file path
            if import_path.startswith("../../"):
                path = import_path.replace("../../", "src/")
                import_paths.append(path)
            elif not import_path.startswith("forge-std/"):
                # Handle relative imports without "../"
                abs_path = os.path.join(os.path.dirname(contract_path), import_path)
                import_paths.append(abs_path)

    except FileNotFoundError:
        print(f"Warning: Contract file not found: {contract_path}")
    except Exception as e:
        print(f"Warning: Error analyzing contract {contract_path}: {e}")

    return dependencies, import_paths


def analyze_intra_mon_dependencies(mon_contracts: Dict[str, ContractInfo]) -> Tuple[List[str], Dict[str, List[str]]]:
    """Analyze dependencies within a mon's contract set and determine deployment order

    Args:
        mon_contracts: Dictionary of contract_name -> ContractInfo for a specific mon

    Returns:
        tuple: (deployment_order, intra_dependencies) where:
            - deployment_order is a list of contract names in the order they should be deployed
            - intra_dependencies is a dict mapping contract_name -> list of intra-mon dependencies
    """
    # Build dependency graph for contracts within this mon
    intra_dependencies = {}
    all_contract_names = set(mon_contracts.keys())

    for contract_name, contract_info in mon_contracts.items():
        intra_deps = []
        for dep in contract_info.dependencies:
            dep_type = dep["type"]
            # Check if this dependency type matches any contract name in this mon's set
            if dep_type in all_contract_names:
                intra_deps.append(dep_type)
        intra_dependencies[contract_name] = intra_deps

    # Topological sort to determine deployment order
    deployment_order = []
    visited = set()
    temp_visited = set()

    def visit(contract_name: str):
        if contract_name in temp_visited:
            raise ValueError(f"Circular dependency detected involving {contract_name}")
        if contract_name in visited:
            return

        temp_visited.add(contract_name)

        # Visit all dependencies first
        for dep_contract in intra_dependencies.get(contract_name, []):
            visit(dep_contract)

        temp_visited.remove(contract_name)
        visited.add(contract_name)
        deployment_order.append(contract_name)

    # Visit all contracts
    for contract_name in mon_contracts.keys():
        if contract_name not in visited:
            visit(contract_name)

    return deployment_order, intra_dependencies


def get_contracts_for_mon(mon: MonData, base_path: str) -> Dict[str, ContractInfo]:
    """Get all contracts needed for a specific mon"""
    contracts = {}
    mon_dir = get_mon_directory_name(mon.name)

    # Collect move contracts
    for move_name in mon.moves:
        contract_name = contract_name_from_move_or_ability(move_name)
        contract_path = os.path.join(base_path, "src", "mons", mon_dir, f"{contract_name}.sol")

        if contract_name not in contracts:
            dependencies, import_paths = analyze_contract_dependencies(contract_path, base_path)
            contracts[contract_name] = ContractInfo(move_name, contract_path, dependencies, import_paths)

    # Collect ability contracts
    for ability_name in mon.abilities:
        contract_name = contract_name_from_move_or_ability(ability_name)
        contract_path = os.path.join(base_path, "src", "mons", mon_dir, f"{contract_name}.sol")

        if contract_name not in contracts:
            dependencies, import_paths = analyze_contract_dependencies(contract_path, base_path)
            contracts[contract_name] = ContractInfo(ability_name, contract_path, dependencies, import_paths)

    return contracts


def collect_all_contracts(mons: Dict[str, MonData], base_path: str) -> Dict[str, ContractInfo]:
    """Collect all unique contracts that need to be deployed"""
    contracts = {}

    for mon in mons.values():
        mon_contracts = get_contracts_for_mon(mon, base_path)
        contracts.update(mon_contracts)

    return contracts


def collect_env_addresses_for_mon(mon_contracts: Dict[str, ContractInfo], intra_dependencies: Dict[str, List[str]]) -> Dict[str, int]:
    """Collect all env addresses used by a mon's contracts and count their usage.

    Returns a dict of env_name -> usage_count for external dependencies only.
    """
    env_usage = {}

    for contract_name, contract_info in mon_contracts.items():
        for dep in contract_info.dependencies:
            contract_type = dep["type"]
            env_name = dep["name"]

            # Skip intra-mon dependencies (they use deployed addresses, not env)
            if contract_type in intra_dependencies.get(contract_name, []):
                continue

            # Track this env address usage with its type
            key = (env_name, contract_type)
            env_usage[key] = env_usage.get(key, 0) + 1

    return env_usage


def generate_deploy_function_for_mon(mon: MonData, base_path: str, include_color: bool = False) -> List[str]:
    """Generate the deploy function for a specific mon"""
    function_name = f"deploy{mon.name.replace(' ', '')}"
    lines = []

    lines.append(f"    function {function_name}(DefaultMonRegistry registry) internal returns (DeployData[] memory) {{")

    # Get contracts for this mon
    mon_contracts = get_contracts_for_mon(mon, base_path)

    # Create array to track deployed contracts
    num_contracts = len(mon_contracts) if mon_contracts else 0
    lines.append(f"        DeployData[] memory deployedContracts = new DeployData[]({num_contracts});")

    if mon_contracts:
        # Analyze intra-mon dependencies and get deployment order
        deployment_order, intra_dependencies = analyze_intra_mon_dependencies(mon_contracts)

        # Collect env addresses and find ones used multiple times to cache
        env_usage = collect_env_addresses_for_mon(mon_contracts, intra_dependencies)

        # Cache addresses used more than once (or always cache common ones for consistency)
        cached_addresses = {}
        for (env_name, contract_type), count in env_usage.items():
            if count > 1:
                var_name = env_name.lower().replace("_", "")
                cached_addresses[(env_name, contract_type)] = var_name

        # Emit cached address declarations
        if cached_addresses:
            lines.append("")
            lines.append("        // Cache commonly used addresses")
            for (env_name, contract_type), var_name in sorted(cached_addresses.items()):
                lines.append(f"        address {var_name} = vm.envAddress(\"{env_name}\");")

        # Create array to store deployed addresses for later use
        lines.append("")
        lines.append(f"        address[{num_contracts}] memory addrs;")
        lines.append("")

        # Track deployed contract addresses by index for intra-mon references
        deployed_indices = {}

        # Deploy contracts in dependency order, each in its own scope
        for idx, contract_name in enumerate(deployment_order):
            contract = mon_contracts[contract_name]

            # Build constructor arguments
            constructor_args = []
            for dep in contract.dependencies:
                contract_type = dep["type"]
                env_name = dep["name"]

                # Check if this is an intra-mon dependency
                if contract_type in intra_dependencies.get(contract_name, []):
                    # Use the deployed address from this mon
                    if contract_type in deployed_indices:
                        dep_idx = deployed_indices[contract_type]
                        constructor_args.append(f"{contract_type}(addrs[{dep_idx}])")
                    else:
                        raise ValueError(f"Intra-mon dependency {contract_type} not yet deployed for {contract_name}")
                else:
                    # Use cached address if available, otherwise inline envAddress call
                    key = (env_name, contract_type)
                    if key in cached_addresses:
                        var_name = cached_addresses[key]
                        constructor_args.append(f"{contract_type}({var_name})")
                    else:
                        constructor_args.append(f"{contract_type}(vm.envAddress(\"{env_name}\"))")

            args_str = ", ".join(constructor_args)

            # Use block scope to limit variable lifetime
            lines.append("        {")
            lines.append(f"            addrs[{idx}] = address(new {contract_name}({args_str}));")
            lines.append(f"            deployedContracts[{idx}] = DeployData({{name: \"{contract.name}\", contractAddress: addrs[{idx}]}});")
            lines.append("        }")

            # Track this deployed address index for future intra-mon references
            deployed_indices[contract_name] = idx

        # Call helper function to register the mon (reduces stack pressure)
        lines.append("")
        helper_name = f"_register{mon.name.replace(' ', '')}"
        lines.append(f"        {helper_name}(registry, addrs);")

    lines.append("")
    lines.append("        return deployedContracts;")
    lines.append("    }")
    lines.append("")

    # Generate the helper function for registering the mon
    if mon_contracts:
        deployment_order, intra_dependencies = analyze_intra_mon_dependencies(mon_contracts)
        deployed_indices = {name: idx for idx, name in enumerate(deployment_order)}

        helper_name = f"_register{mon.name.replace(' ', '')}"
        lines.append(f"    function {helper_name}(DefaultMonRegistry registry, address[{num_contracts}] memory addrs) internal {{")

        # Generate MonStats
        type1 = convert_type_to_solidity(mon.type1)
        type2 = convert_type_to_solidity(mon.type2)
        lines.extend([
            "        MonStats memory stats = MonStats({",
            f"            hp: {mon.hp},",
            f"            stamina: {mon.stamina},",
            f"            speed: {mon.speed},",
            f"            attack: {mon.attack},",
            f"            defense: {mon.defense},",
            f"            specialAttack: {mon.special_attack},",
            f"            specialDefense: {mon.special_defense},",
            f"            type1: {type1},",
            f"            type2: {type2}",
            "        });"
        ])

        # Generate moves array using addrs indices
        if mon.moves:
            lines.append(f"        IMoveSet[] memory moves = new IMoveSet[]({len(mon.moves)});")
            for i, move_name in enumerate(mon.moves):
                contract_name = contract_name_from_move_or_ability(move_name)
                if contract_name in deployed_indices:
                    idx = deployed_indices[contract_name]
                    lines.append(f"        moves[{i}] = IMoveSet(addrs[{idx}]);")
        else:
            lines.append("        IMoveSet[] memory moves = new IMoveSet[](0);")

        # Generate abilities array using addrs indices
        if mon.abilities:
            lines.append(f"        IAbility[] memory abilities = new IAbility[]({len(mon.abilities)});")
            for i, ability_name in enumerate(mon.abilities):
                contract_name = contract_name_from_move_or_ability(ability_name)
                if contract_name in deployed_indices:
                    idx = deployed_indices[contract_name]
                    lines.append(f"        abilities[{i}] = IAbility(addrs[{idx}]);")
        else:
            lines.append("        IAbility[] memory abilities = new IAbility[](0);")

        # Generate metadata arrays with sprite and palette data (if color flag is enabled)
        if include_color:
            total_metadata_count = len(mon.sprite_data) + len(mon.palette_data)

            if total_metadata_count > 0:
                lines.extend([
                    f"        bytes32[] memory keys = new bytes32[]({total_metadata_count});",
                    f"        bytes32[] memory values = new bytes32[]({total_metadata_count});"
                ])

                metadata_index = 0

                # Add sprite data as IMG_0, IMG_1, IMG_2, etc.
                for i, uint256_value in enumerate(mon.sprite_data):
                    lines.append(f"        keys[{metadata_index}] = bytes32(\"IMG_{i}\");")
                    lines.append(f"        values[{metadata_index}] = bytes32(uint256({uint256_value}));")
                    metadata_index += 1

                # Add palette data as PAL_0, PAL_1, PAL_2, etc.
                for i, uint256_value in enumerate(mon.palette_data):
                    lines.append(f"        keys[{metadata_index}] = bytes32(\"PAL_{i}\");")
                    lines.append(f"        values[{metadata_index}] = bytes32(uint256({uint256_value}));")
                    metadata_index += 1
            else:
                lines.extend([
                    "        bytes32[] memory keys = new bytes32[](0);",
                    "        bytes32[] memory values = new bytes32[](0);"
                ])
        else:
            # No color data - empty metadata arrays
            lines.extend([
                "        bytes32[] memory keys = new bytes32[](0);",
                "        bytes32[] memory values = new bytes32[](0);"
            ])

        # Generate createMon call
        lines.append(f"        registry.createMon({mon.mon_id}, stats, moves, abilities, keys, values);")
        lines.append("    }")
        lines.append("")

    return lines


def generate_solidity_script(mons: Dict[str, MonData], contracts: Dict[str, ContractInfo], base_path: str, include_color: bool = False) -> str:
    """Generate the complete Solidity deployment script"""

    # Generate imports
    imports = [
        "// SPDX-License-Identifier: AGPL-3.0",
        "// Created by mon_stats_to_sol.py",
        "pragma solidity ^0.8.0;",
        "",
        "import {Script} from \"forge-std/Script.sol\";",
        "import {DefaultMonRegistry} from \"../src/teams/DefaultMonRegistry.sol\";",
        "import {MonStats} from \"../src/Structs.sol\";",
        "import {Type} from \"../src/Enums.sol\";",
        "import {IMoveSet} from \"../src/moves/IMoveSet.sol\";",
        "import {IAbility} from \"../src/abilities/IAbility.sol\";",
        ""
    ]

    # Collect all import paths and deduplicate
    all_import_paths = set()

    # Add contract imports for main contracts (moves/abilities)
    for contract in contracts.values():
        mon_dir = None
        for mon in mons.values():
            if contract.name in mon.moves or contract.name in mon.abilities:
                mon_dir = get_mon_directory_name(mon.name)
                break

        if mon_dir:
            contract_name = contract_name_from_move_or_ability(contract.name)
            import_path = f"../src/mons/{mon_dir}/{contract_name}.sol"
            all_import_paths.add((contract_name, import_path))

            # Add imports for dependencies of this contract
            for dep_path in contract.import_paths:
                # Convert absolute path to relative import path
                rel_path = os.path.relpath(dep_path, base_path)
                rel_path = "../" + rel_path.replace("\\", "/")  # Convert to relative and use forward slashes

                # Extract contract name from file path
                dep_contract_name = os.path.splitext(os.path.basename(dep_path))[0]
                all_import_paths.add((dep_contract_name, rel_path))

    # Sort imports for consistent output
    sorted_imports = sorted(all_import_paths, key=lambda x: x[1])
    for contract_name, import_path in sorted_imports:
        imports.append(f"import {{{contract_name}}} from \"{import_path}\";")

    imports.append("")

    # Generate contract header and main run function
    contract_lines = [
        "struct DeployData {",
        "    string name;",
        "    address contractAddress;",
        "}",
        "contract SetupMons is Script {",
        "    function run() external returns (DeployData[] memory deployedContracts) {",
        "        vm.startBroadcast();",
        "",
        "        // Get the DefaultMonRegistry address",
        "        DefaultMonRegistry registry = DefaultMonRegistry(vm.envAddress(\"DEFAULT_MON_REGISTRY\"));",
        ""
    ]

    # Add calls to individual deploy functions and collect deployment data
    sorted_mons = sorted(mons.values(), key=lambda m: m.mon_id)
    num_mons = len(sorted_mons)

    contract_lines.extend([
        "        // Deploy all mons and collect deployment data",
        f"        DeployData[][] memory allDeployData = new DeployData[][]({num_mons});",
        ""
    ])

    # Generate calls to collect deployment data from each function
    for i, mon in enumerate(sorted_mons):
        function_name = f"deploy{mon.name.replace(' ', '')}"
        contract_lines.append(f"        allDeployData[{i}] = {function_name}(registry);")

    contract_lines.extend([
        "",
        "        // Calculate total length for flattened array",
        "        uint256 totalLength = 0;",
        "        for (uint256 i = 0; i < allDeployData.length; i++) {",
        "            totalLength += allDeployData[i].length;",
        "        }",
        "",
        "        // Create flattened array and copy all entries",
        "        deployedContracts = new DeployData[](totalLength);",
        "        uint256 currentIndex = 0;",
        "",
        "        // Copy all deployment data using nested loops",
        "        for (uint256 i = 0; i < allDeployData.length; i++) {",
        "            for (uint256 j = 0; j < allDeployData[i].length; j++) {",
        "                deployedContracts[currentIndex] = allDeployData[i][j];",
        "                currentIndex++;",
        "            }",
        "        }",
        "",
        "        vm.stopBroadcast();",
        "    }",
        ""
    ])

    # Generate individual deploy functions for each mon
    deploy_functions = []
    for mon in sorted(mons.values(), key=lambda m: m.mon_id):
        deploy_functions.extend(generate_deploy_function_for_mon(mon, base_path, include_color))

    # Generate contract footer
    contract_footer = ["}"]

    # Combine all parts
    all_lines = imports + contract_lines + deploy_functions + contract_footer
    return "\n".join(all_lines)


def run(include_color: bool = False, base_path: str = ".") -> bool:
    """
    Run Solidity generation. Returns True on success, False on failure.

    Args:
        include_color: Whether to include sprite and palette color data
        base_path: Base path to the repository root
    """
    try:
        # Read CSV data
        mons = read_mons_csv(os.path.join(base_path, "drool", "mons.csv"))
        read_moves_csv(os.path.join(base_path, "drool", "moves.csv"), mons)
        read_abilities_csv(os.path.join(base_path, "drool", "abilities.csv"), mons)
        print(f"Loaded {len(mons)} mons")

        # Collect all contracts
        contracts = collect_all_contracts(mons, base_path)
        print(f"Found {len(contracts)} unique contracts to deploy")

        # Generate Solidity script
        solidity_code = generate_solidity_script(mons, contracts, base_path, include_color)

        # Write to output file
        output_path = os.path.join(base_path, "script", "SetupMons.s.sol")
        os.makedirs(os.path.dirname(output_path), exist_ok=True)

        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(solidity_code)

        print(f"Generated deployment script: {output_path}")

        if include_color:
            print("Color data included in deployment script")
        else:
            print("Color data not included (use --color flag to include)")

        # Print summary
        print("\nSummary:")
        for mon in sorted(mons.values(), key=lambda m: m.mon_id):
            color_info = ""
            if include_color and (mon.sprite_data or mon.palette_data):
                color_info = f" (sprite: {len(mon.sprite_data)} uint256, palette: {len(mon.palette_data)} uint256)"
            print(f"  {mon.name}: {len(mon.moves)} moves, {len(mon.abilities)} abilities{color_info}")

        return True
    except Exception as e:
        print(f"Error generating Solidity: {e}")
        import traceback
        traceback.print_exc()
        return False


def main():
    """CLI entry point."""
    import sys

    # Parse command line arguments
    parser = argparse.ArgumentParser(description='Generate Solidity deployment script for mons')
    parser.add_argument('--color', action='store_true',
                       help='Include sprite and palette color data in the generated script')
    args = parser.parse_args()

    if not run(include_color=args.color):
        sys.exit(1)


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""
Script to convert address values from output.txt and update the Address object
in the munch and belch repositories' address.ts files.
Also extracts ABIs from the out folder and creates TypeScript ABI files.

Modes:
  --stdin: Read KEY=VALUE lines from stdin instead of output.txt
  (default): Read from processing/output.txt

Network flags (one required):
  --m, --mainnet: Update MAINNET addresses
  --t, --testnet: Update TESTNET addresses
"""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple


def parse_addresses_from_content(content: str) -> Dict[str, str]:
    """Parse addresses from content string with KEY=VALUE lines."""
    addresses = {}

    for line in content.splitlines():
        line = line.strip()
        if not line or '=' not in line:
            continue

        # Split the line into key and value
        key, value = line.split('=', 1)

        # Convert the key to uppercase and remove any non-alphanumeric characters
        key = re.sub(r'[^A-Z0-9_]', '', key.upper())

        # Convert the value to lowercase (for LowercaseHex type)
        value = value.lower()

        addresses[key] = value

    return addresses


def read_addresses(input_file: str) -> Dict[str, str]:
    """Read addresses from output.txt and return a dictionary."""
    addresses = {}

    with open(input_file, 'r') as infile:
        for line in infile:
            line = line.strip()
            if not line or '=' not in line:
                continue

            # Split the line into key and value
            key, value = line.split('=', 1)

            # Convert the key to uppercase and remove any non-alphanumeric characters
            key = re.sub(r'[^A-Z0-9_]', '', key.upper())

            # Convert the value to lowercase (for LowercaseHex type)
            value = value.lower()

            addresses[key] = value

    return addresses


def parse_existing_addresses(content: str) -> Dict[str, Dict[str, str]]:
    """Parse existing addresses from file content, handling both flat and nested formats.

    Returns a dict with 'MAINNET' and 'TESTNET' keys, each containing address dicts.
    For flat format (legacy), all addresses are placed under 'TESTNET'.
    """
    result = {'MAINNET': {}, 'TESTNET': {}}

    # Check if this is a nested format (has MAINNET: { or TESTNET: {)
    is_nested = bool(re.search(r'(MAINNET|TESTNET)\s*:\s*\{', content))

    if is_nested:
        # Parse nested format
        for network in ['MAINNET', 'TESTNET']:
            # Find the network block
            pattern = rf'{network}\s*:\s*\{{([^}}]*)\}}'
            match = re.search(pattern, content, re.DOTALL)
            if match:
                block = match.group(1)
                # Extract addresses from the block
                addr_pattern = r"(\w+):\s*'(0x[a-f0-9]+)'\s*as\s+LowercaseHex"
                matches = re.findall(addr_pattern, block, re.IGNORECASE)
                for key, value in matches:
                    result[network][key] = value.lower()
    else:
        # Flat format (legacy) - all addresses go to TESTNET
        addr_pattern = r"(\w+):\s*'(0x[a-f0-9]+)'\s*as\s+LowercaseHex"
        matches = re.findall(addr_pattern, content, re.IGNORECASE)
        for key, value in matches:
            result['TESTNET'][key] = value.lower()

    return result


def update_address_file(
    addresses: Dict[str, str],
    output_file: str,
    network: str,
    existing_addresses: Dict[str, Dict[str, str]],
    is_belch: bool = False
):
    """Update the address.ts file with new addresses for a specific network."""

    # Merge addresses for the target network (new addresses override existing ones)
    merged = {**existing_addresses.get(network, {}), **addresses}

    # Update the existing_addresses dict
    updated_addresses = {
        'MAINNET': existing_addresses.get('MAINNET', {}),
        'TESTNET': existing_addresses.get('TESTNET', {}),
    }
    updated_addresses[network] = merged

    # Sort addresses by key for consistent output
    sorted_mainnet = dict(sorted(updated_addresses['MAINNET'].items()))
    sorted_testnet = dict(sorted(updated_addresses['TESTNET'].items()))

    # Generate TypeScript content with different imports based on repository
    if is_belch:
        typescript_content = "import { Hex } from 'viem';\n"
        typescript_content += "type LowercaseHex = Lowercase<Hex>;\n\n"
    else:
        typescript_content = "import { LowercaseHex } from '../types/structs';\n\n"

    typescript_content += "export const Address = {\n"

    # Write MAINNET block
    typescript_content += "  MAINNET: {\n"
    for key, value in sorted_mainnet.items():
        typescript_content += f"    {key}: '{value}' as LowercaseHex,\n"
    typescript_content += "  },\n"

    # Write TESTNET block
    typescript_content += "  TESTNET: {\n"
    for key, value in sorted_testnet.items():
        typescript_content += f"    {key}: '{value}' as LowercaseHex,\n"
    typescript_content += "  },\n"

    typescript_content += "};\n"

    # Write to file
    with open(output_file, 'w') as f:
        f.write(typescript_content)


def extract_abi(contract_name: str, out_dir: Path) -> List:
    """Extract ABI from the out folder for a given contract."""
    json_file = out_dir / f"{contract_name}.sol" / f"{contract_name}.json"

    if not json_file.exists():
        raise FileNotFoundError(f"ABI file not found: {json_file}")

    with open(json_file, 'r') as f:
        contract_data = json.load(f)

    return contract_data.get('abi', [])


def create_abi_file(abi: List, abi_name: str, output_file: str):
    """Create a TypeScript ABI file."""

    # Convert ABI to formatted JSON string
    abi_json = json.dumps(abi, indent=2)

    # Create TypeScript content
    typescript_content = f"export const {abi_name} = {abi_json} as const;\n"

    # Ensure directory exists
    output_path = Path(output_file)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Write to file
    with open(output_file, 'w') as f:
        f.write(typescript_content)


def process_abis(out_dir: Path, game_dir: Path) -> List[Tuple[str, str]]:
    """Process ABIs for Engine, DefaultCommitManager, and DefaultMatchmaker."""

    # Define contracts to process: (contract_name, output_filename, abi_const_name)
    contracts = [
        ("Engine", "engine.ts", "EngineABI"),
        ("DefaultCommitManager", "commit.ts", "DefaultCommitManagerABI"),
        ("DefaultMatchmaker", "matchmaker.ts", "DefaultMatchmakerABI"),
    ]

    # Define output paths for both repositories
    munch_abi_dir = game_dir / "munch" / "src" / "app" / "types" / "abi"
    belch_abi_dir = game_dir / "belch" / "src" / "abi"

    updated_files = []

    for contract_name, output_filename, abi_const_name in contracts:
        try:
            # Extract ABI
            abi = extract_abi(contract_name, out_dir)

            # Create ABI file in munch repository
            if munch_abi_dir.parent.exists():
                munch_output = munch_abi_dir / output_filename
                create_abi_file(abi, abi_const_name, str(munch_output))
                updated_files.append(f"munch: {munch_output}")
                print(f"✅ Created {output_filename} in munch repository")

            # Create ABI file in belch repository
            if belch_abi_dir.parent.exists():
                belch_output = belch_abi_dir / output_filename
                create_abi_file(abi, abi_const_name, str(belch_output))
                updated_files.append(f"belch: {belch_output}")
                print(f"✅ Created {output_filename} in belch repository")

        except FileNotFoundError as e:
            print(f"⚠️  Error processing {contract_name}: {e}")

    return updated_files


def run_main_logic(addresses: Dict[str, str], network: str):
    """Run main logic with provided addresses."""
    base_path = Path(__file__).parent

    # base_path is /game/chomp/processing, so we need to go up 1 level to /game/chomp
    chomp_dir = base_path.parent
    # Then go up 1 more level to /game
    game_dir = chomp_dir.parent

    # out directory is in chomp
    out_dir = chomp_dir / "out"

    # Define output files for both munch and belch repositories
    munch_output_file = game_dir / "munch" / "src" / "app" / "data" / "address.ts"
    belch_output_file = game_dir / "belch" / "src" / "config" / "address.ts"
    fallback_output_file = base_path / "address.ts"

    print("=" * 60)
    print(f"PROCESSING ADDRESSES ({network})")
    print("=" * 60)

    print(f"Loaded {len(addresses)} addresses for {network}")

    # Read existing addresses from munch as source of truth
    existing_addresses = {'MAINNET': {}, 'TESTNET': {}}
    if munch_output_file.exists():
        with open(munch_output_file, 'r') as f:
            content = f.read()
        existing_addresses = parse_existing_addresses(content)
        print(f"📖 Read existing addresses from munch (MAINNET: {len(existing_addresses['MAINNET'])}, TESTNET: {len(existing_addresses['TESTNET'])})")
    else:
        print(f"⚠️  No existing munch address file found, starting fresh")

    # Track which files were updated
    updated_files = []

    # Update munch repository
    if munch_output_file.parent.exists():
        update_address_file(addresses, str(munch_output_file), network, existing_addresses, is_belch=False)
        updated_files.append(f"munch: {munch_output_file}")
        print(f"✅ Updated address.ts in munch repository")
    else:
        print(f"⚠️  Munch repository not found at {munch_output_file.parent}")

    # Update belch repository (using the same existing_addresses from munch)
    if belch_output_file.parent.exists():
        update_address_file(addresses, str(belch_output_file), network, existing_addresses, is_belch=True)
        updated_files.append(f"belch: {belch_output_file}")
        print(f"✅ Updated address.ts in belch repository")
    else:
        print(f"⚠️  Belch repository not found at {belch_output_file.parent}")

    # Fallback if neither repository was found
    if not updated_files:
        update_address_file(addresses, str(fallback_output_file), network, existing_addresses, is_belch=False)
        print(f"✅ Updated address.ts (fallback): {fallback_output_file}")

    print(f"\n✅ Address files updated: {len(updated_files)}")

    # Process ABIs
    print("\n" + "=" * 60)
    print("PROCESSING ABIs")
    print("=" * 60)

    if not out_dir.exists():
        print(f"⚠️  Out directory not found: {out_dir}")
        print("Skipping ABI extraction")
    else:
        abi_files = process_abis(out_dir, game_dir)
        print(f"\n✅ ABI files created: {len(abi_files)}")

    print("\n" + "=" * 60)
    print("DONE!")
    print("=" * 60)


def main():
    """Main function to orchestrate the address conversion and ABI extraction."""
    parser = argparse.ArgumentParser(
        description='Update address.ts files and extract ABIs'
    )
    parser.add_argument(
        '--stdin',
        action='store_true',
        help='Read KEY=VALUE lines from stdin instead of output.txt'
    )

    # Network flags (mutually exclusive, one required)
    network_group = parser.add_mutually_exclusive_group(required=True)
    network_group.add_argument(
        '-m', '--mainnet',
        action='store_true',
        help='Update MAINNET addresses'
    )
    network_group.add_argument(
        '-t', '--testnet',
        action='store_true',
        help='Update TESTNET addresses'
    )

    args = parser.parse_args()

    # Determine which network to update
    network = 'MAINNET' if args.mainnet else 'TESTNET'

    if args.stdin:
        # Read from stdin
        content = sys.stdin.read()
        addresses = parse_addresses_from_content(content)
        print(f"Reading addresses from stdin...")
    else:
        # Original file-based mode
        base_path = Path(__file__).parent
        input_file = base_path / "output.txt"

        if not input_file.exists():
            print(f"Error: {input_file} not found!")
            return

        print("Reading addresses from output.txt...")
        addresses = read_addresses(str(input_file))

    run_main_logic(addresses, network)


if __name__ == "__main__":
    main()
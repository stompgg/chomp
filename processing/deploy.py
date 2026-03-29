#!/usr/bin/env python3
"""
Meta-script to orchestrate the full deployment pipeline:
1. Validate move contracts against CSV data
2. Generate Solidity deployment script (SetupMons.s.sol)
3. Run EngineAndPeriphery.s.sol -> parse output -> update .env
4. Run SetupMons.s.sol -> parse output -> update .env
5. Run SetupCPU.s.sol
6. Run createAddressAndABIs.py and generateMonsTypescript.py
7. Run transpiler (sol2ts.py) to generate TypeScript from Solidity

Usage:
    python processing/deploy.py [--rpc-url <RPC_URL>] --testnet|--mainnet
"""

import argparse
import csv
import getpass
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# Add processing directory to path for local imports
sys.path.insert(0, str(Path(__file__).parent))

from packMoves import detect_inline_ability, pack_ability, pack_move
from generateSolidity import contract_name_from_move_or_ability, get_mon_directory_name


# Constants
SENDER = "0x4206957609f2936D166aF8E5d0870a11496302AD"
ACCOUNT = "defaultKey"

# Default RPC URLs
DEFAULT_RPC_MAINNET = "https://mainnet.megaeth.com/rpc"
DEFAULT_RPC_TESTNET = "https://carrot.megaeth.com/rpc"

# Script paths relative to chomp directory
SCRIPTS = [
    "script/EngineAndPeriphery.s.sol",
    "script/SetupMons.s.sol",
    "script/SetupCPU.s.sol",
]


def get_chomp_dir() -> Path:
    """Get the chomp directory (parent of processing/)."""
    return Path(__file__).parent.parent


def parse_deploy_data(output: str) -> list[tuple[str, str]]:
    """Parse DeployData output from forge script."""
    pattern = r'DeployData\(\{\s*name:\s*"([^"]+)",\s*contractAddress:\s*(0x[a-fA-F0-9]+)\s*\}\)'
    return re.findall(pattern, output)


def update_env_file(matches: list[tuple[str, str]], env_path: Path):
    """Update .env file with new addresses, merging with existing."""
    # Read existing .env
    existing = {}
    if env_path.exists():
        with open(env_path, 'r') as f:
            for line in f:
                line = line.strip()
                if line and '=' in line and not line.startswith('#'):
                    key, value = line.split('=', 1)
                    existing[key] = value

    # Add new addresses
    for name, address in matches:
        key = name.upper().replace(" ", "_").replace("-", "_")
        existing[key] = address

    # Write back sorted
    with open(env_path, 'w') as f:
        for key in sorted(existing.keys()):
            f.write(f"{key}={existing[key]}\n")


def run_forge_script(
    script_path: str,
    rpc_url: str,
    password: str,
    chomp_dir: Path,
    dry_run: bool = False
) -> str:
    """Run a forge script and return the output."""
    cmd = [
        "forge", "script", script_path,
        "--rpc-url", rpc_url,
        "--account", ACCOUNT,
        "--sender", SENDER,
        "--broadcast",
        "--skip-simulation",
        "--legacy",
        "--non-interactive",
        "-g", "105",
        "--password", password,
    ]

    print(f"\n{'='*60}")
    print(f"Running: {script_path}")
    print(f"{'='*60}")

    if dry_run:
        print(f"[DRY RUN] Would execute: {' '.join(cmd)}")
        return ""

    result = subprocess.run(
        cmd,
        cwd=chomp_dir,
        capture_output=True,
        text=True,
    )

    # Print stdout for visibility
    if result.stdout:
        print(result.stdout)

    # Print stderr (forge often outputs here too)
    if result.stderr:
        print(result.stderr, file=sys.stderr)

    if result.returncode != 0:
        print(f"ERROR: Script {script_path} failed with return code {result.returncode}")
        sys.exit(1)

    # Return combined output for parsing
    return result.stdout + result.stderr


def collect_inline_move_addresses(chomp_dir: Path) -> list[tuple[str, str]]:
    """Find all JSON inline moves, pack them, and return as (move_display_name, hex_value) tuples.

    Uses CSV move names (e.g. "Pound Ground") so the Address keys match what
    generateMonsTypeScript.py expects.
    """
    src_dir = chomp_dir / "src"
    moves_csv = chomp_dir / "drool" / "moves.csv"

    results = []
    with open(moves_csv, "r", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            move_name = row["Name"].strip()
            mon_name = row["Mon"].strip()
            contract_name = contract_name_from_move_or_ability(move_name)
            json_path = src_dir / "mons" / get_mon_directory_name(mon_name) / f"{contract_name}.json"
            if not json_path.exists():
                continue
            with open(json_path, "r", encoding="utf-8") as jf:
                move_data = json.load(jf)
            # Pack with effect_address=0 — the client only needs the move params
            packed = pack_move(move_data, effect_address=0)
            results.append((move_name, f"0x{packed:064x}"))

    return results


def find_ability_sol_path(ability_name: str, chomp_dir: Path) -> Path | None:
    """Find the .sol file for an ability by searching src/mons/*/.

    Args:
        ability_name: The ability name (e.g., "Rise From The Grave")
        chomp_dir: Path to the chomp directory

    Returns:
        Path to the .sol file, or None if not found
    """
    contract_name = contract_name_from_move_or_ability(ability_name)

    mons_dir = chomp_dir / "src" / "mons"
    if not mons_dir.exists():
        return None

    for mon_dir in mons_dir.iterdir():
        if mon_dir.is_dir():
            sol_path = mon_dir / f"{contract_name}.sol"
            if sol_path.exists():
                return sol_path
    return None


def pack_inline_ability_addresses(
    deployed_addresses: list[tuple[str, str]],
    chomp_dir: Path
) -> list[tuple[str, str]]:
    """For each deployed ability, check if inline and pack if needed.

    Uses the @inline-ability magic comment in .sol files to detect inline abilities.
    For inline abilities, packs as (type_id << 248) | address.
    For external abilities, returns the raw address.

    Args:
        deployed_addresses: List of (name, address) tuples from forge output
        chomp_dir: Path to the chomp directory

    Returns:
        List of (name, hex_value) tuples with packed values for inline abilities
    """
    results = []
    packed_count = 0

    for name, address in deployed_addresses:
        sol_path = find_ability_sol_path(name, chomp_dir)
        if sol_path:
            ability_type_id = detect_inline_ability(str(sol_path))
            if ability_type_id is not None:
                addr_int = int(address, 16)
                packed = pack_ability(ability_type_id, addr_int)
                results.append((name, f"0x{packed:064x}"))
                packed_count += 1
                continue

        # Not inline or not found - use raw address as-is
        results.append((name, address))

    if packed_count > 0:
        print(f"Packed {packed_count} inline abilities")

    return results


def run_typescript_scripts(
    network: str,
    chomp_dir: Path,
    all_addresses: list[tuple[str, str]],
    dry_run: bool = False
):
    """Run createAddressAndABIs.py and generateMonsTypescript.py."""
    processing_dir = chomp_dir / "processing"

    # Pack inline ability addresses (must happen before adding inline moves)
    all_addresses = pack_inline_ability_addresses(list(all_addresses), chomp_dir)

    # Add packed inline move values to the address list
    inline_moves = collect_inline_move_addresses(chomp_dir)
    if inline_moves:
        print(f"Adding {len(inline_moves)} inline move packed values to addresses")
        all_addresses = list(all_addresses) + inline_moves

    # Run createAddressAndABIs.py
    print(f"\n{'='*60}")
    print("Running createAddressAndABIs.py")
    print(f"{'='*60}")

    network_flag = "--mainnet" if network == "mainnet" else "--testnet"
    cmd = [sys.executable, str(processing_dir / "createAddressAndABIs.py"), "--stdin", network_flag]

    # Prepare stdin content from collected addresses
    stdin_content = "\n".join(f"{name}={address}" for name, address in all_addresses)

    if dry_run:
        print(f"[DRY RUN] Would execute: {' '.join(cmd)}")
        print(f"[DRY RUN] With stdin:\n{stdin_content}")
    else:
        result = subprocess.run(cmd, cwd=chomp_dir, input=stdin_content, text=True)
        if result.returncode != 0:
            print("ERROR: createAddressAndABIs.py failed")
            sys.exit(1)

    # Run generateMonsTypescript.py
    print(f"\n{'='*60}")
    print("Running generateMonsTypescript.py")
    print(f"{'='*60}")

    cmd = [sys.executable, str(processing_dir / "generateMonsTypescript.py")]

    if dry_run:
        print(f"[DRY RUN] Would execute: {' '.join(cmd)}")
    else:
        result = subprocess.run(cmd, cwd=chomp_dir)
        if result.returncode != 0:
            print("ERROR: generateMonsTypescript.py failed")
            sys.exit(1)


def run_transpiler(chomp_dir: Path, dry_run: bool = False):
    """Run the Solidity to TypeScript transpiler."""
    print(f"\n{'='*60}")
    print("Running transpiler (sol2ts.py)")
    print(f"{'='*60}")

    # Run as module to support relative imports
    cmd = [
        sys.executable,
        "-m", "transpiler",
        "src",
        "-o", "transpiler/ts-output",
        "-d", "src",
        "--emit-metadata",
    ]

    if dry_run:
        print(f"[DRY RUN] Would execute: {' '.join(cmd)}")
    else:
        result = subprocess.run(cmd, cwd=chomp_dir)
        if result.returncode != 0:
            print("ERROR: Transpiler failed")
            sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description='Orchestrate full deployment pipeline'
    )
    parser.add_argument(
        '--rpc-url',
        help='RPC URL for the target network (defaults to MegaETH RPC based on network)'
    )

    network_group = parser.add_mutually_exclusive_group(required=True)
    network_group.add_argument(
        '-m', '--mainnet',
        action='store_true',
        help='Deploy to mainnet'
    )
    network_group.add_argument(
        '-t', '--testnet',
        action='store_true',
        help='Deploy to testnet'
    )

    parser.add_argument(
        '--dry-run',
        action='store_true',
        help='Print commands without executing'
    )
    parser.add_argument(
        '--skip-forge',
        action='store_true',
        help='Skip forge scripts, only run TypeScript generation'
    )
    parser.add_argument(
        '--skip-build',
        action='store_true',
        help='Skip validation and Solidity generation (assume already up to date)'
    )

    args = parser.parse_args()
    network = "mainnet" if args.mainnet else "testnet"

    # Use default RPC URL if not provided
    rpc_url = args.rpc_url
    if not rpc_url:
        rpc_url = DEFAULT_RPC_MAINNET if args.mainnet else DEFAULT_RPC_TESTNET

    chomp_dir = get_chomp_dir()
    env_path = chomp_dir / ".env"

    print(f"Deploying to {network.upper()}")
    print(f"RPC URL: {rpc_url}")
    print(f"Sender: {SENDER}")
    print(f"Chomp directory: {chomp_dir}")

    # Prompt for password once (only if running forge scripts)
    password = None
    if not args.skip_forge and not args.dry_run:
        password = getpass.getpass("Enter keystore password: ")

    # Run validation and Solidity generation
    if not args.skip_build:
        os.chdir(chomp_dir)

        print(f"\n{'='*60}")
        print("Validating move contracts against CSV data")
        print(f"{'='*60}")
        from validateMoves import run as run_validate
        if not run_validate():
            print("ERROR: Move validation failed. Fix issues before deploying.")
            sys.exit(1)

        print(f"\n{'='*60}")
        print("Generating Solidity deployment script (SetupMons.s.sol)")
        print(f"{'='*60}")
        from generateSolidity import run as run_solidity
        if not run_solidity():
            print("ERROR: Solidity generation failed.")
            sys.exit(1)

    # Collect all addresses across forge scripts
    all_addresses: list[tuple[str, str]] = []

    if not args.skip_forge:
        # Run forge scripts and update .env after each
        for script_path in SCRIPTS:
            output = run_forge_script(
                script_path,
                rpc_url,
                password,
                chomp_dir,
                dry_run=args.dry_run
            )

            # Parse and update .env (skip for SetupCPU which doesn't deploy new contracts)
            if "SetupCPU" not in script_path:
                matches = parse_deploy_data(output)
                if matches:
                    print(f"\nParsed {len(matches)} contract addresses")
                    all_addresses.extend(matches)
                    if not args.dry_run:
                        update_env_file(matches, env_path)
                        print(f"Updated .env with {len(matches)} addresses")
                else:
                    print("No DeployData found in output")

    # Run TypeScript generation scripts
    run_typescript_scripts(network, chomp_dir, all_addresses, dry_run=args.dry_run)

    # Run transpiler to generate TypeScript from Solidity
    run_transpiler(chomp_dir, dry_run=args.dry_run)

    print(f"\n{'='*60}")
    print("DEPLOYMENT COMPLETE!")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()

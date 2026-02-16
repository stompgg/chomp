#!/usr/bin/env python3
"""
Meta-script to orchestrate the full deployment pipeline:
1. Run EngineAndPeriphery.s.sol -> parse output -> update .env
2. Run SetupMons.s.sol -> parse output -> update .env
3. Run SetupCPU.s.sol
4. Run createAddressAndABIs.py and generateMonsTypescript.py

Usage:
    python processing/deploy.py [--rpc-url <RPC_URL>] --testnet|--mainnet
"""

import argparse
import getpass
import re
import subprocess
import sys
from pathlib import Path


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


def run_typescript_scripts(
    network: str,
    chomp_dir: Path,
    all_addresses: list[tuple[str, str]],
    dry_run: bool = False
):
    """Run createAddressAndABIs.py and generateMonsTypescript.py."""
    processing_dir = chomp_dir / "processing"

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

    print(f"\n{'='*60}")
    print("DEPLOYMENT COMPLETE!")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()

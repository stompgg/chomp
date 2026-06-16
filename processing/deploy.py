#!/usr/bin/env python3
"""
Meta-script to orchestrate the full deployment pipeline:
1. Validate move contracts against CSV data
2. Generate Solidity deploy scripts (SetupMons.s.sol, SetupCPU.s.sol)
3. Run the forge scripts -> parse output -> update .env + deployments.json
4. Run the TypeScript generators (addresses/ABIs, mon data, event layouts, EIP-712 meta)
5. Run the transpiler (sol2ts.py) to generate TypeScript from Solidity

Usage:
    python processing/deploy.py [--rpc-url <RPC_URL>] --testnet|--mainnet
"""

import argparse
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Add processing directory to path for local imports
sys.path.insert(0, str(Path(__file__).parent))

from addressPacking import collect_inline_move_addresses, pack_inline_ability_addresses


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


def print_banner(text: str) -> None:
    """Print a section banner."""
    print(f"\n{'='*60}")
    print(text)
    print(f"{'='*60}")


def run_step(label: str, fn, dry_run: bool = False) -> None:
    """Run one in-process pipeline step. `fn` is a callable that returns falsy or
    raises on failure. Raises RuntimeError so main()'s handler exits non-zero."""
    print_banner(f"Running {label}")
    if dry_run:
        print(f"[DRY RUN] Would run {label}")
        return
    if fn() is False:
        raise RuntimeError(f"{label} failed")


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


# Bookkeeping key in .env recording which network the current address record belongs to.
ENV_NETWORK_KEY = "DEPLOY_NETWORK"


def set_env_network(env_path: Path, network: str) -> None:
    """Stamp .env with the network its addresses belong to, so a later --skip-forge
    regeneration can refuse to emit the wrong network's addresses from it."""
    lines: list[str] = []
    found = False
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if line.strip().startswith(f"{ENV_NETWORK_KEY}="):
                lines.append(f"{ENV_NETWORK_KEY}={network}")
                found = True
            else:
                lines.append(line)
    if not found:
        lines.insert(0, f"{ENV_NETWORK_KEY}={network}")
    env_path.write_text("\n".join(lines) + "\n")


def read_env_network(env_path: Path) -> str | None:
    """Which network .env's address record belongs to (last broadcast), or None if untagged."""
    if not env_path.exists():
        return None
    for line in env_path.read_text().splitlines():
        if line.strip().startswith(f"{ENV_NETWORK_KEY}="):
            return line.split('=', 1)[1].strip().lower() or None
    return None


def read_env_addresses(env_path: Path) -> list[tuple[str, str]]:
    """Read the (NAME, raw-address) pairs from .env — the durable record of the latest
    broadcast. Only 20-byte 0x-addresses are returned; bookkeeping keys are skipped."""
    if not env_path.exists():
        return []
    pairs: list[tuple[str, str]] = []
    for line in env_path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        value = value.strip()
        if re.fullmatch(r'0x[0-9a-fA-F]{40}', value):
            pairs.append((key.strip(), value))
    return pairs


def get_prev_gacha_registry(network: str, chomp_dir: Path) -> str | None:
    """Read the currently-deployed GachaTeamRegistry address from deployments.json.

    The newly-deployed registry takes this as its PREVIOUS_REGISTRY so players can
    self-migrate their progression. deployments.json is chomp's own canonical record
    (network-specific), so we read whichever of MAINNET/TESTNET matches this deploy.

    Returns None (→ migration disabled, address(0)) if the record or the key is missing.
    """
    deployments_file = chomp_dir / "deployments.json"
    if not deployments_file.exists():
        print(f"⚠️  {deployments_file} not found; "
              "PREVIOUS_REGISTRY defaults to address(0) (migration disabled)")
        return None

    record = json.loads(deployments_file.read_text())
    addr = record.get(network.upper(), {}).get("GACHA_TEAM_REGISTRY")
    if not addr:
        print(f"⚠️  GACHA_TEAM_REGISTRY not found for {network.upper()} in deployments.json; "
              "PREVIOUS_REGISTRY defaults to address(0) (migration disabled)")
        return None
    return addr


def run_forge_script(
    script_path: str,
    rpc_url: str,
    password: str,
    chomp_dir: Path,
    dry_run: bool = False,
    extra_env: dict | None = None,
) -> str:
    """Run a forge script and return the output. Raises RuntimeError on failure."""
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
        "--slow",
    ]
    # password is None on dry runs (never prompted); only pass it when present.
    if password is not None:
        cmd += ["--password", password]

    print_banner(f"Running: {script_path}")

    if dry_run:
        if extra_env:
            print(f"[DRY RUN] With env: {extra_env}")
        print(f"[DRY RUN] Would execute: {' '.join(cmd)}")
        return ""

    # Forge reads PREV_GACHA_TEAM_REGISTRY (and friends) via vm.envOr; merge over the
    # inherited environment so explicitly-passed values win over any .env entry.
    env = {**os.environ, **extra_env} if extra_env else None

    result = subprocess.run(
        cmd,
        cwd=chomp_dir,
        capture_output=True,
        text=True,
        env=env,
    )

    # Print stdout for visibility
    if result.stdout:
        print(result.stdout)

    # Print stderr (forge often outputs here too)
    if result.stderr:
        print(result.stderr, file=sys.stderr)

    if result.returncode != 0:
        raise RuntimeError(f"Script {script_path} failed with return code {result.returncode}")

    # Return combined output for parsing
    return result.stdout + result.stderr


def run_typescript_scripts(
    network: str,
    chomp_dir: Path,
    all_addresses: list[tuple[str, str]],
    dry_run: bool = False
):
    """Pack inline ability/move values into the address list, then run the TypeScript
    generators in-process (addresses/ABIs, mon data, event layouts, EIP-712 meta)."""
    from createAddressAndABIs import parse_addresses_from_content, run_main_logic
    from generateMonsTypeScript import run as run_mons_ts
    from generate_type_chart import run as run_type_chart
    from generateTypeMetadata import run as run_type_metadata
    from generateEventLayouts import main as run_event_layouts
    from generateEip712Meta import main as run_eip712_meta

    # Pack inline ability addresses (must happen before adding inline moves).
    all_addresses = pack_inline_ability_addresses(list(all_addresses), chomp_dir)

    # Add packed inline move values to the address list.
    inline_moves = collect_inline_move_addresses(chomp_dir, all_addresses)
    if inline_moves:
        print(f"Adding {len(inline_moves)} inline move packed values to addresses")
        all_addresses = list(all_addresses) + inline_moves

    # createAddressAndABIs consumes `name=address` lines; reuse its parser for identical
    # key normalization, then drive its main logic in-process.
    addresses = parse_addresses_from_content(
        "\n".join(f"{name}={address}" for name, address in all_addresses)
    )

    run_step("createAddressAndABIs", lambda: run_main_logic(addresses, network), dry_run)
    run_step("generateMonsTypeScript", run_mons_ts, dry_run)
    run_step("generateTypeChart", run_type_chart, dry_run)
    run_step("generateTypeMetadata", run_type_metadata, dry_run)
    run_step("generateEventLayouts", run_event_layouts, dry_run)
    run_step("generateEip712Meta", run_eip712_meta, dry_run)


def run_transpiler(chomp_dir: Path, dry_run: bool = False):
    """Run the Solidity to TypeScript transpiler and sync output to munch."""
    print_banner("Running transpiler (sol2ts.py)")

    # Wipe transpiler/ts-output entirely before regenerating so renamed/removed/skipped
    # Solidity files don't leave stale .ts files behind. The transpiler re-copies
    # transpiler/runtime/ into ts-output/runtime/ as part of its run, so nothing
    # here needs to be preserved. The subsequent rsync --delete propagates the clean
    # state to munch.
    ts_output = chomp_dir / "transpiler" / "ts-output"
    if ts_output.exists():
        if dry_run:
            print(f"[DRY RUN] Would remove {ts_output}")
        else:
            shutil.rmtree(ts_output)
            print(f"Cleaned {ts_output}")

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
            raise RuntimeError("Transpiler failed")

    # Sync transpiled output to munch's quarantined generated/sim dir. runtime/ is excluded:
    # munch owns its own runtime/ (including the simulator's battle-harness.ts, which chomp no
    # longer carries). Chomp still copies transpiler/runtime/ into its own ts-output/runtime/
    # for vitest, but that copy is not propagated to munch.
    munch_ts_output = chomp_dir.parent / "munch" / "src" / "app" / "generated" / "sim"
    chomp_ts_output = chomp_dir / "transpiler" / "ts-output"

    if munch_ts_output.exists():
        print(f"\nSyncing transpiled output to {munch_ts_output}")
        if dry_run:
            print(f"[DRY RUN] Would rsync {chomp_ts_output}/ → {munch_ts_output}/ (excluding runtime/)")
        else:
            result = subprocess.run(
                ["rsync", "-a", "--delete", "--exclude=runtime/",
                 f"{chomp_ts_output}/", f"{munch_ts_output}/"],
            )
            if result.returncode != 0:
                print("WARNING: Failed to sync transpiled output to munch")
            else:
                print("Synced transpiled output to munch")
    else:
        print(f"Skipping munch sync: {munch_ts_output} does not exist")


def run_deploy(args, network, rpc_url, password, chomp_dir, env_path):
    """Run the full deploy pipeline. Raises RuntimeError on any step failure."""
    # Run validation and Solidity generation.
    if not args.skip_build:
        # validateMoves / generateSolidity resolve CSV + src paths relative to CWD.
        os.chdir(chomp_dir)

        print_banner("Validating move contracts against CSV data")
        from validateMoves import run as run_validate
        if not run_validate():
            raise RuntimeError("Move validation failed. Fix issues before deploying.")

        print_banner("Generating Solidity deployment script (SetupMons.s.sol)")
        from generateSolidity import run as run_solidity
        if not run_solidity():
            raise RuntimeError("Solidity generation failed.")

        print_banner("Generating SetupCPU.s.sol + munch cpu-teams.ts from cpu-teams.json")
        from generateSetupCPU import run as run_setup_cpu
        if not run_setup_cpu():
            raise RuntimeError("SetupCPU generation failed.")

    # Collect all addresses across forge scripts.
    all_addresses: list[tuple[str, str]] = []

    if not args.skip_forge:
        # Tag .env with this network up front so a later --skip-forge regen sourcing from it
        # can detect (and refuse) a cross-network mismatch.
        if not args.dry_run:
            set_env_network(env_path, network)

        # Run forge scripts and update .env after each.
        for script_path in SCRIPTS:
            # EngineAndPeriphery deploys a new GachaTeamRegistry; point it at the prior
            # one (from the canonical deployments record for this network) so players can migrate.
            extra_env = None
            if "EngineAndPeriphery" in script_path:
                prev_gacha = get_prev_gacha_registry(network, chomp_dir)
                if prev_gacha:
                    extra_env = {"PREV_GACHA_TEAM_REGISTRY": prev_gacha}
                    print(f"PREVIOUS_REGISTRY for new GachaTeamRegistry = {prev_gacha} ({network})")

            output = run_forge_script(
                script_path,
                rpc_url,
                password,
                chomp_dir,
                dry_run=args.dry_run,
                extra_env=extra_env,
            )

            # Parse and update .env (skip for SetupCPU which doesn't deploy new contracts).
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
    elif not args.dry_run:
        # No fresh broadcast this run: regenerate consumers from .env, the durable record of
        # the latest broadcast's RAW addresses. Without this, a --skip-forge regen feeds
        # createAddressAndABIs an empty set, which re-emits whatever stale addresses already
        # sit in deployments.json — pairing a freshly regenerated ABI with an old contract.
        env_network = read_env_network(env_path)
        if env_network and env_network != network:
            raise RuntimeError(
                f"{env_path} holds {env_network.upper()} addresses (last broadcast), but this is a "
                f"{network.upper()} --skip-forge run. Re-broadcast for {network.upper()} first."
            )
        all_addresses = read_env_addresses(env_path)
        if not all_addresses:
            raise RuntimeError(
                f"--skip-forge but no deployed addresses found in {env_path}; nothing to generate."
            )
        print(f"Loaded {len(all_addresses)} addresses from {env_path} (no forge broadcast this run)")

    # Run TypeScript generation scripts.
    run_typescript_scripts(network, chomp_dir, all_addresses, dry_run=args.dry_run)

    # Run transpiler to generate TypeScript from Solidity.
    run_transpiler(chomp_dir, dry_run=args.dry_run)


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
    rpc_url = args.rpc_url or (DEFAULT_RPC_MAINNET if args.mainnet else DEFAULT_RPC_TESTNET)

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

    try:
        run_deploy(args, network, rpc_url, password, chomp_dir, env_path)
    except RuntimeError as e:
        print(f"\nERROR: {e}", file=sys.stderr)
        sys.exit(1)

    print_banner("DEPLOYMENT COMPLETE!")


if __name__ == "__main__":
    main()

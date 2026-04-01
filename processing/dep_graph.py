#!/usr/bin/env python3
"""
Dependency graph resolution and change detection for incremental mon deployment.

Resolves transitive Solidity imports per contract, computes content hashes,
and classifies contracts against a deploy manifest as NEW/DIRTY/CLEAN/REMOVED.
"""

import hashlib
import json
import os
import re
from enum import Enum
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

from generateSolidity import (
    MonData,
    contract_name_from_move_or_ability,
    get_contracts_for_mon,
    get_mon_directory_name,
    is_json_move,
    load_json_move,
    read_abilities_csv,
    read_mons_csv,
    read_moves_csv,
)
from packMoves import pack_move


class ChangeStatus(Enum):
    NEW = "new"
    DIRTY = "dirty"
    CLEAN = "clean"
    REMOVED = "removed"


# ---------------------------------------------------------------------------
# Import parsing & transitive resolution
# ---------------------------------------------------------------------------

# Matches: import "../../Foo.sol";
_BARE_IMPORT_RE = re.compile(r'^import\s+"([^"]+)"\s*;', re.MULTILINE)
# Matches: import {Foo} from "../../Foo.sol";
_NAMED_IMPORT_RE = re.compile(r'^import\s+\{[^}]*\}\s+from\s+"([^"]+)"\s*;', re.MULTILINE)


def parse_imports(sol_path: str) -> List[str]:
    """Extract all import paths from a Solidity file."""
    try:
        content = Path(sol_path).read_text(encoding="utf-8")
    except FileNotFoundError:
        return []
    paths = _BARE_IMPORT_RE.findall(content) + _NAMED_IMPORT_RE.findall(content)
    return paths


def resolve_import_path(import_path: str, importing_file: str, base_path: str) -> Optional[str]:
    """Resolve a relative import to an absolute, normalized file path.

    Handles:
      - Relative paths like "../../Foo.sol" or "./Bar.sol"
      - forge-std imports (skipped — not user code)
    """
    if import_path.startswith("forge-std/"):
        return None

    dir_of_importer = os.path.dirname(importing_file)
    resolved = os.path.normpath(os.path.join(dir_of_importer, import_path))
    if os.path.isfile(resolved):
        return resolved
    return None


def resolve_transitive_deps(sol_path: str, base_path: str) -> Set[str]:
    """Return all files transitively imported by ``sol_path`` (including itself)."""
    visited: Set[str] = set()
    queue = [os.path.normpath(sol_path)]
    while queue:
        current = queue.pop()
        if current in visited:
            continue
        visited.add(current)
        for imp in parse_imports(current):
            resolved = resolve_import_path(imp, current, base_path)
            if resolved and resolved not in visited:
                queue.append(resolved)
    return visited


# ---------------------------------------------------------------------------
# Hashing helpers
# ---------------------------------------------------------------------------

def hash_file(path: str) -> str:
    """SHA-256 of a single file's contents."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def hash_file_set(file_paths: Set[str]) -> str:
    """Deterministic SHA-256 over a set of files (sorted, concatenated)."""
    h = hashlib.sha256()
    for p in sorted(file_paths):
        try:
            h.update(Path(p).read_bytes())
        except FileNotFoundError:
            # File disappeared between scan and hash — treat as content change
            h.update(b"__missing__" + p.encode())
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Per-contract fingerprinting
# ---------------------------------------------------------------------------

def _mon_dir_abs(mon_name: str, base_path: str) -> str:
    return os.path.normpath(os.path.join(base_path, "src", "mons", get_mon_directory_name(mon_name)))


def fingerprint_sol_contract(
    sol_path: str,
    mon_dir: str,
    base_path: str,
) -> Tuple[str, str]:
    """Compute (source_hash, deps_hash) for a single .sol contract.

    source_hash: hash of the .sol file itself + any intra-mon local deps
                 (e.g. HeatBeaconLib.sol).
    deps_hash:   hash of all transitive imports *outside* this mon's directory.
    """
    all_deps = resolve_transitive_deps(sol_path, base_path)
    norm_mon_dir = os.path.normpath(mon_dir)

    local_files: Set[str] = set()
    external_files: Set[str] = set()
    for dep in all_deps:
        if os.path.normpath(dep).startswith(norm_mon_dir + os.sep) or os.path.normpath(dep) == os.path.normpath(sol_path):
            local_files.add(dep)
        else:
            external_files.add(dep)

    # Always include the contract itself in local
    local_files.add(os.path.normpath(sol_path))

    return hash_file_set(local_files), hash_file_set(external_files)


def fingerprint_json_move(json_path: str) -> str:
    """Hash a JSON inline move definition."""
    return hash_file(json_path)


# ---------------------------------------------------------------------------
# Scanning current state
# ---------------------------------------------------------------------------

def scan_current_state(
    mons: Dict[str, MonData],
    base_path: str,
) -> Dict[str, dict]:
    """Scan all mon contracts and compute fingerprints.

    Returns a dict keyed by "mondir/ContractName" with:
      {type, source, source_hash, deps_hash, mon_name, mon_id, contract_name, is_inline}
    """
    state: Dict[str, dict] = {}

    for mon in mons.values():
        mon_dir = _mon_dir_abs(mon.name, base_path)
        mon_dir_rel = os.path.join("src", "mons", get_mon_directory_name(mon.name))

        # Deployed .sol moves
        for move_name in mon.moves:
            contract_name = contract_name_from_move_or_ability(move_name)

            if is_json_move(mon.name, move_name, base_path):
                json_path = os.path.join(mon_dir, f"{contract_name}.json")
                key = f"{get_mon_directory_name(mon.name)}/{contract_name}"
                state[key] = {
                    "type": "move",
                    "source": os.path.join(mon_dir_rel, f"{contract_name}.json"),
                    "source_hash": fingerprint_json_move(json_path),
                    "deps_hash": "",  # inline moves have no external deps
                    "mon_name": mon.name,
                    "mon_id": mon.mon_id,
                    "contract_name": contract_name,
                    "display_name": move_name,
                    "is_inline": True,
                }
                continue

            sol_path = os.path.join(mon_dir, f"{contract_name}.sol")
            key = f"{get_mon_directory_name(mon.name)}/{contract_name}"
            source_hash, deps_hash = fingerprint_sol_contract(sol_path, mon_dir, base_path)
            state[key] = {
                "type": "move",
                "source": os.path.join(mon_dir_rel, f"{contract_name}.sol"),
                "source_hash": source_hash,
                "deps_hash": deps_hash,
                "mon_name": mon.name,
                "mon_id": mon.mon_id,
                "contract_name": contract_name,
                "display_name": move_name,
                "is_inline": False,
            }

        # Abilities
        for ability_name in mon.abilities:
            contract_name = contract_name_from_move_or_ability(ability_name)
            sol_path = os.path.join(mon_dir, f"{contract_name}.sol")
            key = f"{get_mon_directory_name(mon.name)}/{contract_name}"
            source_hash, deps_hash = fingerprint_sol_contract(sol_path, mon_dir, base_path)
            state[key] = {
                "type": "ability",
                "source": os.path.join(mon_dir_rel, f"{contract_name}.sol"),
                "source_hash": source_hash,
                "deps_hash": deps_hash,
                "mon_name": mon.name,
                "mon_id": mon.mon_id,
                "contract_name": contract_name,
                "display_name": ability_name,
                "is_inline": False,
            }

    return state


# ---------------------------------------------------------------------------
# Change classification
# ---------------------------------------------------------------------------

def classify_changes(
    manifest: dict,
    current_state: Dict[str, dict],
) -> Dict[str, Tuple[ChangeStatus, dict]]:
    """Compare current state against manifest and classify each contract.

    Returns dict of key -> (status, data) where data is the current_state entry
    (or the manifest entry for REMOVED contracts).
    """
    prev_contracts = manifest.get("contracts", {})
    results: Dict[str, Tuple[ChangeStatus, dict]] = {}

    for key, data in current_state.items():
        if key not in prev_contracts:
            results[key] = (ChangeStatus.NEW, data)
        else:
            prev = prev_contracts[key]
            if (data["source_hash"] != prev.get("source_hash")
                    or data["deps_hash"] != prev.get("deps_hash")):
                results[key] = (ChangeStatus.DIRTY, data)
            else:
                results[key] = (ChangeStatus.CLEAN, data)

    for key, prev_data in prev_contracts.items():
        if key not in current_state:
            results[key] = (ChangeStatus.REMOVED, prev_data)

    return results


def get_dirty_mons(
    changes: Dict[str, Tuple[ChangeStatus, dict]],
) -> Dict[str, List[Tuple[ChangeStatus, dict]]]:
    """Group non-CLEAN changes by mon directory name.

    Returns dict of mon_dir -> list of (status, data) for contracts that need action.
    """
    dirty: Dict[str, List[Tuple[ChangeStatus, dict]]] = {}
    for key, (status, data) in changes.items():
        if status == ChangeStatus.CLEAN:
            continue
        mon_dir = key.split("/")[0]
        dirty.setdefault(mon_dir, []).append((status, data))
    return dirty


# ---------------------------------------------------------------------------
# Manifest I/O
# ---------------------------------------------------------------------------

def load_manifest(deploys_dir: str, network: str) -> dict:
    """Load a deploy manifest, returning empty dict if not found."""
    path = os.path.join(deploys_dir, f"{network}.json")
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_manifest(deploys_dir: str, network: str, manifest: dict) -> None:
    """Write a deploy manifest to disk."""
    os.makedirs(deploys_dir, exist_ok=True)
    path = os.path.join(deploys_dir, f"{network}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)
    print(f"Manifest saved to {path}")


def build_manifest_from_state(
    current_state: Dict[str, dict],
    deployed_addresses: Dict[str, str],
    commit_hash: str,
) -> dict:
    """Build a fresh manifest from current state + deployed addresses.

    ``deployed_addresses`` maps SCREAMING_SNAKE env key -> address string.
    """
    from datetime import datetime, timezone

    contracts: Dict[str, dict] = {}
    for key, data in current_state.items():
        display_name = data["display_name"]
        env_key = display_name.upper().replace(" ", "_").replace("-", "_")
        address = deployed_addresses.get(env_key, "")
        contracts[key] = {
            "type": data["type"],
            "source": data["source"],
            "source_hash": data["source_hash"],
            "deps_hash": data["deps_hash"],
            "address": address,
        }

    return {
        "last_deploy_commit": commit_hash,
        "deployed_at": datetime.now(timezone.utc).isoformat(),
        "contracts": contracts,
    }


def update_manifest_after_incremental(
    manifest: dict,
    current_state: Dict[str, dict],
    changes: Dict[str, Tuple[ChangeStatus, dict]],
    new_addresses: Dict[str, str],
    commit_hash: str,
) -> dict:
    """Update an existing manifest after an incremental deploy.

    - CLEAN contracts keep their existing manifest entry.
    - NEW/DIRTY contracts get updated hashes + new addresses.
    - REMOVED contracts are pruned.
    """
    from datetime import datetime, timezone

    contracts = dict(manifest.get("contracts", {}))

    for key, (status, data) in changes.items():
        if status == ChangeStatus.REMOVED:
            contracts.pop(key, None)
            continue

        if status == ChangeStatus.CLEAN:
            # Keep existing entry unchanged
            continue

        # NEW or DIRTY — update hashes and address
        display_name = data["display_name"]
        env_key = display_name.upper().replace(" ", "_").replace("-", "_")
        address = new_addresses.get(env_key, contracts.get(key, {}).get("address", ""))
        contracts[key] = {
            "type": data["type"],
            "source": data["source"],
            "source_hash": data["source_hash"],
            "deps_hash": data["deps_hash"],
            "address": address,
        }

    manifest["contracts"] = contracts
    manifest["last_deploy_commit"] = commit_hash
    manifest["deployed_at"] = datetime.now(timezone.utc).isoformat()
    return manifest


# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

def get_current_commit(chomp_dir: str) -> str:
    """Return the short git commit hash for HEAD."""
    import subprocess
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=chomp_dir,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()
    except Exception:
        return "unknown"


def load_mons(base_path: str) -> Dict[str, MonData]:
    """Load mon data from CSV files."""
    mons = read_mons_csv(os.path.join(base_path, "drool", "mons.csv"))
    read_moves_csv(os.path.join(base_path, "drool", "moves.csv"), mons)
    read_abilities_csv(os.path.join(base_path, "drool", "abilities.csv"), mons)
    return mons


def load_env_addresses(env_path: str) -> Dict[str, str]:
    """Load address mappings from a .env file."""
    addresses: Dict[str, str] = {}
    if not os.path.isfile(env_path):
        return addresses
    with open(env_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                addresses[k] = v
    return addresses


# ---------------------------------------------------------------------------
# CLI for debugging / standalone use
# ---------------------------------------------------------------------------

def main():
    """Print change summary against a manifest (useful for debugging)."""
    import argparse

    parser = argparse.ArgumentParser(description="Inspect incremental deploy status")
    parser.add_argument("--network", required=True, choices=["testnet", "mainnet"])
    parser.add_argument("--base-path", default=".")
    args = parser.parse_args()

    base_path = args.base_path
    deploys_dir = os.path.join(base_path, ".deploys")
    manifest = load_manifest(deploys_dir, args.network)

    if not manifest:
        print(f"No manifest found at {deploys_dir}/{args.network}.json")
        print("Run a full deploy first to create the manifest.")
        return

    mons = load_mons(base_path)
    current_state = scan_current_state(mons, base_path)
    changes = classify_changes(manifest, current_state)

    dirty_mons = get_dirty_mons(changes)

    if not dirty_mons:
        print("All contracts are up to date. Nothing to deploy.")
        return

    clean_count = sum(1 for _, (s, _) in changes.items() if s == ChangeStatus.CLEAN)
    print(f"\n{clean_count} contracts unchanged, {len(changes) - clean_count} need action:\n")

    for mon_dir, contract_changes in sorted(dirty_mons.items()):
        print(f"  {mon_dir}/")
        for status, data in contract_changes:
            name = data.get("contract_name", data.get("source", "?"))
            reason = ""
            if status == ChangeStatus.DIRTY:
                prev = manifest.get("contracts", {}).get(f"{mon_dir}/{name}", {})
                if data.get("source_hash") != prev.get("source_hash"):
                    reason = " (source changed)"
                elif data.get("deps_hash") != prev.get("deps_hash"):
                    reason = " (dependency changed)"
            print(f"    {status.value:>7}  {name}{reason}")

    print()


if __name__ == "__main__":
    main()

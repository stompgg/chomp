#!/usr/bin/env python3
"""
Generate IncrementalSetupMons.s.sol — a Solidity script that only deploys
contracts that have changed and surgically updates the on-chain MonRegistry.
"""

import os
import re
from typing import Dict, List, Set, Tuple

from dep_graph import ChangeStatus, load_mons, scan_current_state
from generateSolidity import (
    MonData,
    analyze_intra_mon_dependencies,
    collect_env_addresses_for_mon,
    contract_name_from_move_or_ability,
    convert_type_to_solidity,
    get_contracts_for_mon,
    get_mon_directory_name,
    is_json_move,
    load_json_move,
    effect_name_to_env_var,
)
from packMoves import detect_inline_ability, pack_move


def _env_key(display_name: str) -> str:
    """Convert a human-readable name to a SCREAMING_SNAKE .env key."""
    return display_name.upper().replace(" ", "_").replace("-", "_")


def _expand_dirty_for_intra_deps(
    mon: MonData,
    dirty_contract_names: Set[str],
    base_path: str,
) -> Set[str]:
    """If a dirty contract is a constructor dep for another contract in the same
    mon, that dependent must also be redeployed (it bakes in the address).

    Returns the expanded set of contract names that need redeployment.
    """
    contracts = get_contracts_for_mon(mon, base_path)
    if not contracts:
        return dirty_contract_names

    _, intra_deps = analyze_intra_mon_dependencies(contracts)

    expanded = set(dirty_contract_names)
    changed = True
    while changed:
        changed = False
        for cname, deps in intra_deps.items():
            if cname not in expanded:
                # If any of this contract's deps are dirty, it must also redeploy
                if any(d in expanded for d in deps):
                    expanded.add(cname)
                    changed = True
    return expanded


def _collect_mon_changes(
    mon: MonData,
    changes: Dict[str, Tuple[ChangeStatus, dict]],
    base_path: str,
) -> dict:
    """Analyze a single mon's changes and produce a structured diff.

    Returns:
        {
            "is_new_mon": bool,
            "deploy": [contract_name, ...],    # contracts to deploy
            "add_moves": [display_name, ...],   # move names to add to registry
            "remove_moves": [env_key, ...],     # .env keys for old move addresses to remove
            "add_abilities": [display_name, ...],
            "remove_abilities": [env_key, ...],
            "unchanged_moves": [(display_name, contract_name), ...],
            "unchanged_abilities": [(display_name, contract_name), ...],
        }
    """
    mon_dir = get_mon_directory_name(mon.name)
    prefix = f"{mon_dir}/"

    # Gather this mon's changes
    mon_changes: Dict[str, Tuple[ChangeStatus, dict]] = {}
    for key, (status, data) in changes.items():
        if key.startswith(prefix):
            mon_changes[key] = (status, data)

    # Check if this is a brand-new mon (all contracts are NEW)
    statuses = {s for s, _ in mon_changes.values()}
    is_new = statuses == {ChangeStatus.NEW}

    # Identify which contracts are dirty/new
    dirty_names: Set[str] = set()
    for key, (status, data) in mon_changes.items():
        if status in (ChangeStatus.NEW, ChangeStatus.DIRTY):
            dirty_names.add(data.get("contract_name", key.split("/")[1]))

    # Expand for intra-mon constructor deps
    dirty_names = _expand_dirty_for_intra_deps(mon, dirty_names, base_path)

    # Categorize moves and abilities
    deploy = []
    add_moves = []
    remove_moves = []
    add_abilities = []
    remove_abilities = []
    unchanged_moves = []
    unchanged_abilities = []

    for key, (status, data) in mon_changes.items():
        cname = data.get("contract_name", key.split("/")[1])
        display = data.get("display_name", cname)
        ctype = data.get("type", "move")
        is_inline = data.get("is_inline", False)
        env_key = _env_key(display)

        if status == ChangeStatus.REMOVED:
            if ctype == "move":
                remove_moves.append(env_key)
            else:
                remove_abilities.append(env_key)
            continue

        # Check if this contract needs deployment (dirty, new, or cascaded from intra-deps)
        needs_deploy = cname in dirty_names

        if needs_deploy and not is_inline:
            deploy.append(cname)

        if needs_deploy or status == ChangeStatus.NEW:
            if ctype == "move":
                add_moves.append(display)
                # If replacing an existing contract (not brand-new), remove old address
                if status != ChangeStatus.NEW:
                    remove_moves.append(env_key)
            else:
                add_abilities.append(display)
                if status != ChangeStatus.NEW:
                    remove_abilities.append(env_key)
        else:
            # Contract unchanged and not cascaded
            if ctype == "move":
                unchanged_moves.append((display, cname))
            else:
                unchanged_abilities.append((display, cname))

    return {
        "is_new_mon": is_new,
        "deploy": deploy,
        "add_moves": add_moves,
        "remove_moves": remove_moves,
        "add_abilities": add_abilities,
        "remove_abilities": remove_abilities,
        "unchanged_moves": unchanged_moves,
        "unchanged_abilities": unchanged_abilities,
    }


# ---------------------------------------------------------------------------
# Solidity code generation
# ---------------------------------------------------------------------------

def _generate_update_function(
    mon: MonData,
    diff: dict,
    base_path: str,
) -> Tuple[List[str], Set[Tuple[str, str]]]:
    """Generate the incremental deploy+update function for one mon.

    Returns (lines, import_set) where import_set is {(contract_name, import_path)}.
    """
    imports: Set[Tuple[str, str]] = set()
    mon_dir = get_mon_directory_name(mon.name)
    fn_name = f"update{mon.name.replace(' ', '')}"
    deploy_contracts = diff["deploy"]
    num_deploy = len(deploy_contracts)

    lines = []
    lines.append(f"    function {fn_name}(DefaultMonRegistry registry) internal returns (DeployData[] memory) {{")
    lines.append(f"        DeployData[] memory deployedContracts = new DeployData[]({num_deploy});")

    if not deploy_contracts:
        # Nothing to deploy but still need to update registry (e.g., inline-only changes)
        lines.append("")
        _append_registry_update(lines, mon, diff, base_path, {}, imports)
        lines.append("")
        lines.append("        return deployedContracts;")
        lines.append("    }")
        lines.append("")
        return lines, imports

    # Get ContractInfo for deployment ordering
    all_contracts = get_contracts_for_mon(mon, base_path)

    # Filter to only contracts being deployed
    deploy_set = set(deploy_contracts)
    deploy_only = {k: v for k, v in all_contracts.items() if k in deploy_set}

    if not deploy_only:
        lines.append("")
        lines.append("        return deployedContracts;")
        lines.append("    }")
        lines.append("")
        return lines, imports

    order, intra_deps = analyze_intra_mon_dependencies(deploy_only)
    env_usage = collect_env_addresses_for_mon(deploy_only, intra_deps)

    # Cache addresses used more than once
    cached = {}
    for (env_name, contract_type), count in env_usage.items():
        if count > 1:
            var_name = env_name.lower().replace("_", "")
            cached[(env_name, contract_type)] = var_name

    if cached:
        lines.append("")
        lines.append("        // Cache commonly used addresses")
        for (env_name, contract_type), var_name in sorted(cached.items()):
            lines.append(f"        address {var_name} = vm.envAddress(\"{env_name}\");")

    lines.append("")
    lines.append(f"        address[{num_deploy}] memory addrs;")
    lines.append("")

    deployed_indices = {}
    for idx, cname in enumerate(order):
        contract = deploy_only[cname]
        # Add import
        import_path = f"../src/mons/{mon_dir}/{cname}.sol"
        imports.add((cname, import_path))
        # Add imports for constructor dep types
        for dep_path in contract.import_paths:
            rel = os.path.relpath(dep_path, base_path)
            rel = "../" + rel.replace("\\", "/")
            dep_name = os.path.splitext(os.path.basename(dep_path))[0]
            imports.add((dep_name, rel))

        # Build constructor args
        args = []
        for dep in contract.dependencies:
            dep_type = dep["type"]
            env_name = dep["name"]
            if dep_type in intra_deps.get(cname, []):
                if dep_type in deployed_indices:
                    args.append(f"{dep_type}(addrs[{deployed_indices[dep_type]}])")
                else:
                    # Dep is clean and already deployed — use env address
                    args.append(f"{dep_type}(vm.envAddress(\"{env_name}\"))")
            else:
                key = (env_name, dep_type)
                if key in cached:
                    args.append(f"{dep_type}({cached[key]})")
                else:
                    args.append(f"{dep_type}(vm.envAddress(\"{env_name}\"))")

        args_str = ", ".join(args)
        lines.append("        {")
        lines.append(f"            addrs[{idx}] = address(new {cname}({args_str}));")
        lines.append(f"            deployedContracts[{idx}] = DeployData({{name: \"{contract.name}\", contractAddress: addrs[{idx}]}});")
        lines.append("        }")
        deployed_indices[cname] = idx

    # Generate registry update in a helper function to reduce stack pressure
    lines.append("")
    helper_name = f"_update{mon.name.replace(' ', '')}"
    lines.append(f"        {helper_name}(registry, addrs);")
    lines.append("")
    lines.append("        return deployedContracts;")
    lines.append("    }")
    lines.append("")

    # Helper function
    lines.append(f"    function {helper_name}(DefaultMonRegistry registry, address[{num_deploy}] memory addrs) internal {{")
    _append_registry_update(lines, mon, diff, base_path, deployed_indices, imports)
    lines.append("    }")
    lines.append("")

    return lines, imports


def _generate_create_function(
    mon: MonData,
    diff: dict,
    base_path: str,
) -> Tuple[List[str], Set[Tuple[str, str]]]:
    """Generate a full create function for a brand-new mon.

    Reuses the same pattern as generateSolidity.py's generate_deploy_function_for_mon
    but adapted for IncrementalSetupMons context.
    """
    # For new mons, delegate to the same codegen used by the full deploy.
    # We import and call generate_deploy_function_for_mon directly.
    from generateSolidity import generate_deploy_function_for_mon as _gen_full

    raw_lines = _gen_full(mon, base_path, include_color=False)

    # Collect imports for this mon's contracts
    imports: Set[Tuple[str, str]] = set()
    mon_dir = get_mon_directory_name(mon.name)
    all_contracts = get_contracts_for_mon(mon, base_path)
    for cname, contract in all_contracts.items():
        import_path = f"../src/mons/{mon_dir}/{cname}.sol"
        imports.add((cname, import_path))
        for dep_path in contract.import_paths:
            rel = os.path.relpath(dep_path, base_path)
            rel = "../" + rel.replace("\\", "/")
            dep_name = os.path.splitext(os.path.basename(dep_path))[0]
            imports.add((dep_name, rel))

    return raw_lines, imports


def _append_registry_update(
    lines: List[str],
    mon: MonData,
    diff: dict,
    base_path: str,
    deployed_indices: Dict[str, int],
    imports: Set[Tuple[str, str]],
) -> None:
    """Append modifyMon() call lines for an existing (dirty) mon."""
    mon_dir = get_mon_directory_name(mon.name)

    # MonStats (always pass current)
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
        "        });",
    ])

    # movesToAdd
    add_moves = diff["add_moves"]
    lines.append(f"        uint256[] memory movesToAdd = new uint256[]({len(add_moves)});")
    for i, move_name in enumerate(add_moves):
        cname = contract_name_from_move_or_ability(move_name)
        json_data = load_json_move(mon.name, move_name, base_path)
        if json_data is not None:
            packed = pack_move(json_data, effect_address=0)
            effect_name = json_data.get("effect")
            if effect_name:
                env_var = effect_name_to_env_var(effect_name)
                lines.append(f"        movesToAdd[{i}] = 0x{packed:064x} | uint256(uint160(vm.envAddress(\"{env_var}\")));")
            else:
                lines.append(f"        movesToAdd[{i}] = 0x{packed:064x};")
        elif cname in deployed_indices:
            idx = deployed_indices[cname]
            lines.append(f"        movesToAdd[{i}] = uint256(uint160(addrs[{idx}]));")
        else:
            # Clean contract being re-added — shouldn't happen in normal flow
            env_key = _env_key(move_name)
            lines.append(f"        movesToAdd[{i}] = uint256(uint160(vm.envAddress(\"{env_key}\")));")

    # movesToRemove
    rm_moves = diff["remove_moves"]
    lines.append(f"        uint256[] memory movesToRemove = new uint256[]({len(rm_moves)});")
    for i, env_key in enumerate(rm_moves):
        lines.append(f"        movesToRemove[{i}] = uint256(uint160(vm.envAddress(\"{env_key}\")));")

    # abilitiesToAdd
    add_abs = diff["add_abilities"]
    lines.append(f"        uint256[] memory abilitiesToAdd = new uint256[]({len(add_abs)});")
    for i, ab_name in enumerate(add_abs):
        cname = contract_name_from_move_or_ability(ab_name)
        if cname in deployed_indices:
            idx = deployed_indices[cname]
            sol_path = os.path.join(base_path, "src", "mons", mon_dir, f"{cname}.sol")
            ability_type_id = detect_inline_ability(sol_path)
            if ability_type_id is not None:
                lines.append(f"        abilitiesToAdd[{i}] = (uint256({ability_type_id}) << 248) | uint256(uint160(addrs[{idx}]));")
            else:
                lines.append(f"        abilitiesToAdd[{i}] = uint256(uint160(addrs[{idx}]));")
        else:
            env_key = _env_key(ab_name)
            lines.append(f"        abilitiesToAdd[{i}] = uint256(uint160(vm.envAddress(\"{env_key}\")));")

    # abilitiesToRemove
    rm_abs = diff["remove_abilities"]
    lines.append(f"        uint256[] memory abilitiesToRemove = new uint256[]({len(rm_abs)});")
    for i, env_key in enumerate(rm_abs):
        lines.append(f"        abilitiesToRemove[{i}] = uint256(uint160(vm.envAddress(\"{env_key}\")));")

    lines.append(f"        registry.modifyMon({mon.mon_id}, stats, movesToAdd, movesToRemove, abilitiesToAdd, abilitiesToRemove);")


# ---------------------------------------------------------------------------
# Top-level script generation
# ---------------------------------------------------------------------------

def generate_incremental_script(
    mons: Dict[str, MonData],
    changes: Dict[str, Tuple[ChangeStatus, dict]],
    base_path: str,
) -> str:
    """Generate the complete IncrementalSetupMons.s.sol script."""
    from dep_graph import get_dirty_mons

    dirty_mons = get_dirty_mons(changes)
    if not dirty_mons:
        return ""

    # Collect per-mon diffs and generate functions
    all_imports: Set[Tuple[str, str]] = set()
    all_functions: List[str] = []
    mon_fn_names: List[str] = []

    for mon_dir in sorted(dirty_mons.keys()):
        # Find the MonData for this dir
        mon = None
        for m in mons.values():
            if get_mon_directory_name(m.name) == mon_dir:
                mon = m
                break
        if not mon:
            continue

        diff = _collect_mon_changes(mon, changes, base_path)

        if diff["is_new_mon"]:
            fn_lines, fn_imports = _generate_create_function(mon, diff, base_path)
            fn_name = f"deploy{mon.name.replace(' ', '')}"
        else:
            fn_lines, fn_imports = _generate_update_function(mon, diff, base_path)
            fn_name = f"update{mon.name.replace(' ', '')}"

        all_functions.extend(fn_lines)
        all_imports.update(fn_imports)
        mon_fn_names.append(fn_name)

    # Build the full script
    header = [
        "// SPDX-License-Identifier: AGPL-3.0",
        "// Generated by generate_incremental.py",
        "pragma solidity ^0.8.0;",
        "",
        'import {Script} from "forge-std/Script.sol";',
        'import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";',
        'import {MonStats} from "../src/Structs.sol";',
        'import {Type} from "../src/Enums.sol";',
        "",
    ]

    # Sort and deduplicate imports
    sorted_imports = sorted(all_imports, key=lambda x: x[1])
    for cname, ipath in sorted_imports:
        header.append(f'import {{{cname}}} from "{ipath}";')
    header.append("")

    # Contract body
    body = [
        "struct DeployData {",
        "    string name;",
        "    address contractAddress;",
        "}",
        "contract IncrementalSetupMons is Script {",
        "    function run() external returns (DeployData[] memory deployedContracts) {",
        "        vm.startBroadcast();",
        "",
        "        DefaultMonRegistry registry = DefaultMonRegistry(vm.envAddress(\"DEFAULT_MON_REGISTRY\"));",
        "",
        f"        DeployData[][] memory allDeployData = new DeployData[][]({len(mon_fn_names)});",
        "",
    ]

    for i, fn_name in enumerate(mon_fn_names):
        body.append(f"        allDeployData[{i}] = {fn_name}(registry);")

    body.extend([
        "",
        "        uint256 totalLength = 0;",
        "        for (uint256 i = 0; i < allDeployData.length; i++) {",
        "            totalLength += allDeployData[i].length;",
        "        }",
        "",
        "        deployedContracts = new DeployData[](totalLength);",
        "        uint256 currentIndex = 0;",
        "        for (uint256 i = 0; i < allDeployData.length; i++) {",
        "            for (uint256 j = 0; j < allDeployData[i].length; j++) {",
        "                deployedContracts[currentIndex] = allDeployData[i][j];",
        "                currentIndex++;",
        "            }",
        "        }",
        "",
        "        vm.stopBroadcast();",
        "    }",
        "",
    ])

    footer = ["}"]

    return "\n".join(header + body + all_functions + footer)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def run(
    network: str,
    base_path: str = ".",
    manifest: dict = None,
) -> Tuple[str, Dict[str, Tuple[ChangeStatus, dict]]]:
    """Generate the incremental script and return (solidity_source, changes).

    Raises SystemExit if no manifest exists or nothing to deploy.
    """
    import sys
    from dep_graph import (
        classify_changes,
        get_dirty_mons,
        load_manifest,
        load_mons,
        scan_current_state,
    )

    deploys_dir = os.path.join(base_path, ".deploys")
    if manifest is None:
        manifest = load_manifest(deploys_dir, network)
    if not manifest:
        print(f"No manifest found at {deploys_dir}/{network}.json")
        print("Run a full deploy first to create the manifest.")
        sys.exit(1)

    mons = load_mons(base_path)
    current_state = scan_current_state(mons, base_path)
    changes = classify_changes(manifest, current_state)
    dirty = get_dirty_mons(changes)

    if not dirty:
        print("All contracts are up to date. Nothing to deploy.")
        sys.exit(0)

    # Print summary
    for mon_dir, contract_changes in sorted(dirty.items()):
        print(f"  {mon_dir}/")
        for status, data in contract_changes:
            name = data.get("contract_name", "?")
            print(f"    {status.value:>7}  {name}")

    sol_source = generate_incremental_script(mons, changes, base_path)

    output_path = os.path.join(base_path, "script", "IncrementalSetupMons.s.sol")
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(sol_source)
    print(f"\nGenerated {output_path}")

    return sol_source, changes


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Generate incremental deploy script")
    parser.add_argument("--network", required=True, choices=["testnet", "mainnet"])
    parser.add_argument("--base-path", default=".")
    args = parser.parse_args()

    run(args.network, args.base_path)

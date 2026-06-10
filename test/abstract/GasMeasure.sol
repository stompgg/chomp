// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CommonBase} from "../../lib/forge-std/src/Base.sol";
import {Vm} from "../../lib/forge-std/src/Vm.sol";

/// @notice Shared production-faithful gas measurement: a deterministic storage/account access
///         tally per measured window (one prod-tx-equivalent unit), plus a synthetic
///         `prodStorageGas` that prices the tally at EIP-2929/2200 production rates.
///
///         WHY the synthetic metric is the headline number (and the measured scalar is only
///         directional): a foundry test function is ONE transaction, so EVM warm/cold and
///         dirty-slot pricing never reset between in-test "turns". `vm.cool` only half-fixes
///         this — measured on forge 1.5.1: a re-cooled slot does re-price cold (2,100), but the
///         account access stays warm (100 vs 2,600), and per-slot resets show scale limits on
///         large contracts. On top of that, recompiles shift via-IR code layout by a few k of
///         pure compute (non-semantic), polluting cross-version scalar diffs. The tally is
///         immune to all three: opcode counts are warmth- and layout-independent.
abstract contract GasMeasure is CommonBase {
    struct Tally {
        uint256 totalSload;
        uint256 coldSload; // slot's first touch in the window is this READ
        uint256 warmSload;
        uint256 totalSstore;
        uint256 zToNz; // zero -> nonzero (SSTORE_SET, 20k + cold surcharge)
        uint256 nzToNz; // nonzero -> different nonzero (SSTORE_RESET, 2.9k)
        uint256 nzToZ; // nonzero -> zero (SSTORE_RESET 2.9k; EIP-3529 refund ignored)
        uint256 noop; // value unchanged (~100)
        uint256 coldWriteTouch; // slot's first touch in the window is a WRITE (cold surcharge lands there)
        uint256 extraAccounts; // unique non-precompile accounts beyond the call target (2,600 cold each in prod)
    }

    /// @dev Classify a state-diff window as ONE transaction: first touch of a slot is cold,
    ///      subsequent touches warm. Call once per prod-tx-equivalent unit (e.g. once per turn)
    ///      so cold/warm reflects a fresh cold-start access list.
    function _tally(Vm.AccountAccess[] memory accesses) internal view returns (Tally memory t) {
        // Size the dedup scratch to the actual access count in THIS window (not a fixed large
        // array), so calling _tally once per turn doesn't blow up cumulative memory across a battle.
        uint256 cap;
        for (uint256 i; i < accesses.length; i++) cap += accesses[i].storageAccesses.length;
        bytes32[] memory keys = new bytes32[](cap);
        uint16[] memory writes = new uint16[](cap);
        bool[] memory reads = new bool[](cap);
        uint256 keyCount;

        // Account dedup: every unique account beyond the window's call target pays a cold-account
        // surcharge in a real tx (the target itself is pre-warmed as tx.to). Precompiles are
        // always warm; the VM/cheatcode address and the test contract are harness artifacts.
        address target = accesses.length > 0 ? accesses[0].account : address(0);
        address[] memory accts = new address[](accesses.length);
        uint256 acctCount;

        for (uint256 i; i < accesses.length; i++) {
            address acct = accesses[i].account;
            if (acct != target && acct != VM_ADDRESS && acct != address(this) && uint160(acct) > 0xff) {
                bool seen;
                for (uint256 k; k < acctCount; k++) {
                    if (accts[k] == acct) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    accts[acctCount++] = acct;
                    t.extraAccounts++;
                }
            }

            Vm.StorageAccess[] memory sa = accesses[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                bytes32 key = keccak256(abi.encode(a.account, a.slot));
                uint256 idx = keyCount;
                for (uint256 k; k < keyCount; k++) {
                    if (keys[k] == key) { idx = k; break; }
                }
                if (idx == keyCount) { keys[idx] = key; keyCount++; }
                if (a.isWrite) {
                    t.totalSstore++;
                    if (!reads[idx] && writes[idx] == 0) t.coldWriteTouch++;
                    if (a.previousValue == bytes32(0) && a.newValue != bytes32(0)) t.zToNz++;
                    else if (a.previousValue != bytes32(0) && a.newValue == bytes32(0)) t.nzToZ++;
                    else if (a.previousValue != a.newValue) t.nzToNz++;
                    else t.noop++;
                    writes[idx]++;
                } else {
                    t.totalSload++;
                    if (!reads[idx] && writes[idx] == 0) { t.coldSload++; reads[idx] = true; }
                    else t.warmSload++;
                }
            }
        }
    }

    function _addTally(Tally memory a, Tally memory b) internal pure returns (Tally memory o) {
        o.totalSload = a.totalSload + b.totalSload;
        o.coldSload = a.coldSload + b.coldSload;
        o.warmSload = a.warmSload + b.warmSload;
        o.totalSstore = a.totalSstore + b.totalSstore;
        o.zToNz = a.zToNz + b.zToNz;
        o.nzToNz = a.nzToNz + b.nzToNz;
        o.nzToZ = a.nzToZ + b.nzToZ;
        o.noop = a.noop + b.noop;
        o.coldWriteTouch = a.coldWriteTouch + b.coldWriteTouch;
        o.extraAccounts = a.extraAccounts + b.extraAccounts;
    }

    /// @notice Conservative production storage+account cost for a window, priced from the tally
    ///         as if the window were ONE fresh production transaction. Assumptions, all chosen so
    ///         a code change's benefit is never overstated:
    ///         - tx.to is pre-warm (like a prod tx); every other touched account pays one 2,600
    ///           cold-account surcharge;
    ///         - the 2,100 cold-slot surcharge is charged once per slot regardless of whether its
    ///           first touch is a read or a write — so eliminating a REDUNDANT access to a slot
    ///           the window still touches elsewhere is credited at warm (100), not cold (2,100);
    ///         - EIP-3529 refunds are ignored (clears price at full 2,900);
    ///         - tx intrinsic (21k) + calldata are excluded (constant across code versions);
    ///         - compute/memory/event gas is excluded — use the measured scalar for
    ///           compute-shaped changes; this metric is the guard for storage-shaped ones.
    function _prodStorageGas(Tally memory t) internal pure returns (uint256 g) {
        g = t.coldSload * 2100 + (t.totalSload - t.coldSload) * 100;
        g += t.coldWriteTouch * 2100;
        g += t.zToNz * 20000 + (t.nzToNz + t.nzToZ) * 2900 + t.noop * 100;
        g += t.extraAccounts * 2600;
    }

    /// @dev Cool every listed account's storage (resets the EIP-2929 access list to cold), so the
    ///      next access pays cold prices — modeling a fresh production transaction. NOTE: measured
    ///      on forge 1.5.1 this re-prices slots but NOT the account access itself; treat the
    ///      resulting scalar as directional and `prodStorageGas` as the grounded number.
    function _coolAll(address[] memory addrs) internal {
        for (uint256 i; i < addrs.length; i++) vm.cool(addrs[i]);
    }

    /// @notice Snapshot one scenario: the deterministic access tally, the conservative synthetic
    ///         production storage cost, and the measured (directional) cold-per-tx gas scalar.
    function _snapScenario(string memory name, Tally memory t, uint256 coldGas) internal {
        vm.snapshotValue(string.concat(name, "_prodStorageGas"), _prodStorageGas(t));
        vm.snapshotValue(string.concat(name, "_coldGas"), coldGas);
        vm.snapshotValue(string.concat(name, "_totalSload"), t.totalSload);
        vm.snapshotValue(string.concat(name, "_coldSload"), t.coldSload);
        vm.snapshotValue(string.concat(name, "_totalSstore"), t.totalSstore);
        vm.snapshotValue(string.concat(name, "_zToNz"), t.zToNz);
        vm.snapshotValue(string.concat(name, "_nzToNz"), t.nzToNz);
        vm.snapshotValue(string.concat(name, "_noop"), t.noop);
        vm.snapshotValue(string.concat(name, "_extraAccounts"), t.extraAccounts);
    }
}

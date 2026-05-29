// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CommonBase} from "../../lib/forge-std/src/Base.sol";
import {Vm} from "../../lib/forge-std/src/Vm.sol";

/// @notice Shared production-faithful gas measurement: per-tx cold-access accounting (via `vm.cool`
///         between measured units) + a deterministic storage-access tally. Replaces the all-warm
///         `vm.startSnapshotGas` span, which (a) doesn't reflect production (each turn is its own
///         cold-start tx) and (b) MASKS storage-access regressions — a new cold SLOAD is invisible
///         once the slot is warm within a single foundry tx.
///
///         The tally counts are regime-INDEPENDENT (a new SLOAD is +1 totalSload regardless of
///         warmth), so they are the robust regression guard; cold/warm split + cold-gas add the
///         production-cost picture. Snapshot one scenario with `_snapScenario(name, tally, coldGas)`.
abstract contract GasMeasure is CommonBase {
    struct Tally {
        uint256 totalSload;
        uint256 coldSload;
        uint256 warmSload;
        uint256 totalSstore;
        uint256 zToNz; // zero -> nonzero (SSTORE_SET, ~20k)
        uint256 nzToNz; // nonzero -> different nonzero (SSTORE_RESET, ~2.9k)
        uint256 noop; // value unchanged (~100)
    }

    /// @dev Classify a state-diff window as ONE transaction: first touch of a slot is cold,
    ///      subsequent touches warm. Call once per prod-tx-equivalent unit (e.g. once per turn)
    ///      so cold/warm reflects a fresh cold-start access list.
    function _tally(Vm.AccountAccess[] memory accesses) internal pure returns (Tally memory t) {
        bytes32[] memory keys = new bytes32[](8192);
        uint16[] memory writes = new uint16[](8192);
        bool[] memory reads = new bool[](8192);
        uint256 keyCount;
        for (uint256 i; i < accesses.length; i++) {
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
                    if (a.previousValue == bytes32(0) && a.newValue != bytes32(0)) t.zToNz++;
                    else if (a.previousValue != bytes32(0) && a.newValue != bytes32(0) && a.previousValue != a.newValue) t.nzToNz++;
                    else if (a.previousValue == a.newValue) t.noop++;
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
        o.noop = a.noop + b.noop;
    }

    /// @dev Cool every listed account's storage (resets the EIP-2929 access list to cold), so the
    ///      next access pays cold prices — modeling a fresh production transaction.
    function _coolAll(address[] memory addrs) internal {
        for (uint256 i; i < addrs.length; i++) vm.cool(addrs[i]);
    }

    /// @notice Snapshot one scenario: the deterministic access tally + the cold-per-tx total gas.
    function _snapScenario(string memory name, Tally memory t, uint256 coldGas) internal {
        vm.snapshotValue(string.concat(name, "_coldGas"), coldGas);
        vm.snapshotValue(string.concat(name, "_totalSload"), t.totalSload);
        vm.snapshotValue(string.concat(name, "_coldSload"), t.coldSload);
        vm.snapshotValue(string.concat(name, "_totalSstore"), t.totalSstore);
        vm.snapshotValue(string.concat(name, "_zToNz"), t.zToNz);
        vm.snapshotValue(string.concat(name, "_nzToNz"), t.nzToNz);
        vm.snapshotValue(string.concat(name, "_noop"), t.noop);
    }
}

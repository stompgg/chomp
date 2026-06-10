// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngineHook} from "../../src/IEngineHook.sol";

/// @notice Minimal OnBattleEnd-only engine hook mirroring GachaTeamRegistry's hook shape
///         (stepsBitmap = OnBattleEnd). Handler bodies are no-ops on purpose: benchmarks use this
///         to measure the per-round hook-bitmap probing cost that ANY attached hook imposes on
///         every turn, independent of the work the real hook does at battle end.
contract MockOnBattleEndHook is IEngineHook {
    function getStepsBitmap() external pure returns (uint16) {
        return 0x08; // OnBattleEnd only — same as the gacha registry hook
    }

    function onBattleStart(bytes32) external {}

    function onRoundStart(bytes32) external {}

    function onRoundEnd(bytes32) external {}

    function onBattleEnd(bytes32) external {}
}

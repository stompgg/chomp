// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {HeatBeaconLib} from "./HeatBeaconLib.sol";

contract HeatBeacon is IMoveSet {
    IEngine immutable ENGINE;
    IEffect immutable BURN_STATUS;

    constructor(IEngine _ENGINE, IEffect _BURN_STATUS) {
        ENGINE = _ENGINE;
        BURN_STATUS = _BURN_STATUS;
    }

    function name() public pure override returns (string memory) {
        return "Heat Beacon";
    }

    function move(bytes32, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Apply burn to opposing mon
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 defenderMonIndex =
            ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[defenderPlayerIndex];
        ENGINE.addEffect(defenderPlayerIndex, defenderMonIndex, BURN_STATUS, "");

        // Clear the priority boost
        if (HeatBeaconLib._getPriorityBoost(ENGINE, attackerPlayerIndex) == 1) {
            HeatBeaconLib._clearPriorityBoost(ENGINE, attackerPlayerIndex);
        }

        // Set a new priority boost
        HeatBeaconLib._setPriorityBoost(ENGINE, attackerPlayerIndex);
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(bytes32, uint256 attackerPlayerIndex) external view returns (uint32) {
        return DEFAULT_PRIORITY + HeatBeaconLib._getPriorityBoost(ENGINE, attackerPlayerIndex);
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Fire;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

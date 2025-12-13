// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract ContagiousSlumber is IMoveSet {
    IEngine immutable ENGINE;
    IEffect immutable SLEEP_STATUS;

    constructor(IEngine _ENGINE, IEffect _SLEEP_STATUS) {
        ENGINE = _ENGINE;
        SLEEP_STATUS = _SLEEP_STATUS;
    }

    function name() public pure override returns (string memory) {
        return "Contagious Slumber";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Apply sleep to self
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        ENGINE.addEffect(attackerPlayerIndex, activeMonIndex, SLEEP_STATUS, "");

        // Apply sleep to opponent
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 defenderMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[defenderPlayerIndex];
        ENGINE.addEffect(defenderPlayerIndex, defenderMonIndex, SLEEP_STATUS, "");
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Cosmic;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}


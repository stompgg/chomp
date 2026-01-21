// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {Type, MoveClass} from "../../Enums.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IEngine} from "../../IEngine.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract PreemptiveShock is IAbility {

    IEngine immutable ENGINE;
    ITypeCalculator immutable TYPE_CALCULATOR;

    uint32 public constant BASE_POWER = 15;
    uint32 public constant DEFAULT_VOL = 10;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }
    
    function name() public pure override returns (string memory) {
        return "Preemptive Shock";
    }

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256) external override {
        // Singles uses slot 0
        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            playerIndex,
            0, // attackerSlotIndex
            0, // defenderSlotIndex
            BASE_POWER,
            100,
            DEFAULT_VOL,
            Type.Lightning,
            MoveClass.Physical,
            ENGINE.tempRNG(),
            0
        );
    }
}

// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {Type, MoveClass} from "../../Enums.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IEngine} from "../../IEngine.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract PreemptiveShock is IAbility {

    ITypeCalculator immutable TYPE_CALCULATOR;

    uint32 public constant BASE_POWER = 15;
    uint32 public constant DEFAULT_VOL = 10;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override returns (string memory) {
        return "Preemptive Shock";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256) external override {
        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            playerIndex,
            BASE_POWER,
            100,
            DEFAULT_VOL,
            Type.Lightning,
            MoveClass.Physical,
            engine.tempRNG(),
            0
        );
    }
}

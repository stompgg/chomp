// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import "../../Structs.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

import {Baselight} from "./Baselight.sol";

contract FirstResort is IMoveSet {
    uint32 public constant BASE_POWER = 40;
    uint256 public constant BASELIGHT_THRESHOLD = 2;

    IEngine immutable ENGINE;
    ITypeCalculator immutable TYPE_CALCULATOR;
    Baselight immutable BASELIGHT;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR, Baselight _BASELIGHT) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        BASELIGHT = _BASELIGHT;
    }

    function name() public pure override returns (string memory) {
        return "First Resort";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256 rng) external {
        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            BASE_POWER,
            DEFAULT_ACCURACY, // 100%
            DEFAULT_VOL,
            moveType(battleKey),
            moveClass(battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(bytes32 battleKey, uint256 attackerPlayerIndex) external view returns (uint32) {
        if (
            BASELIGHT.getBaselightLevel(
                    battleKey,
                    attackerPlayerIndex,
                    ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex]
                ) >= BASELIGHT_THRESHOLD
        ) {
            return DEFAULT_PRIORITY + 1;
        } else {
            return DEFAULT_PRIORITY;
        }
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Water;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

import {Baselight} from "./Baselight.sol";

/**
 * Unbounded Strike Move for Iblivion
 * - Type: Yin, Class: Physical
 * - If at 3 Baselight stacks: Power 130, Stamina 1, consumes all 3 stacks
 * - Otherwise: Power 80, Stamina 2, consumes nothing
 */
contract UnboundedStrike is IMoveSet {
    uint32 public constant BASE_POWER = 80;
    uint32 public constant EMPOWERED_POWER = 130;
    uint32 public constant BASE_STAMINA = 2;
    uint32 public constant EMPOWERED_STAMINA = 1;
    uint256 public constant REQUIRED_STACKS = 3;

    IEngine immutable ENGINE;
    ITypeCalculator immutable TYPE_CALCULATOR;
    Baselight immutable BASELIGHT;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR, Baselight _BASELIGHT) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        BASELIGHT = _BASELIGHT;
    }

    function name() public pure override returns (string memory) {
        return "Unbounded Strike";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256 rng) external {
        uint256 monIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        uint256 baselightLevel = BASELIGHT.getBaselightLevel(battleKey, attackerPlayerIndex, monIndex);

        uint32 power;
        if (baselightLevel >= REQUIRED_STACKS) {
            // Empowered version: consume all 3 stacks
            power = EMPOWERED_POWER;
            BASELIGHT.setBaselightLevel(battleKey, attackerPlayerIndex, monIndex, 0);
        } else {
            // Normal version: no stacks consumed
            power = BASE_POWER;
        }

        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            power,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(battleKey),
            moveClass(battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
    }

    function stamina(bytes32 battleKey, uint256 attackerPlayerIndex, uint256 monIndex) external view returns (uint32) {
        uint256 baselightLevel = BASELIGHT.getBaselightLevel(battleKey, attackerPlayerIndex, monIndex);
        if (baselightLevel >= REQUIRED_STACKS) {
            return EMPOWERED_STAMINA;
        }
        return BASE_STAMINA;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Air;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

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
import {MoveMeta} from "../../Structs.sol";

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

    ITypeCalculator immutable TYPE_CALCULATOR;
    Baselight immutable BASELIGHT;

    constructor(ITypeCalculator _TYPE_CALCULATOR, Baselight _BASELIGHT) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        BASELIGHT = _BASELIGHT;
    }

    function name() public pure override returns (string memory) {
        return "Unbounded Strike";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint240,
        uint256 rng
    ) external {
        uint256 baselightLevel = BASELIGHT.getBaselightLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex);

        uint32 power;
        if (baselightLevel >= REQUIRED_STACKS) {
            // Empowered version: consume all 3 stacks
            power = EMPOWERED_POWER;
            BASELIGHT.setBaselightLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex, 0);
        } else {
            // Normal version: no stacks consumed
            power = BASE_POWER;
        }

        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            power,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
    }

    function stamina(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 monIndex) public view returns (uint32) {
        uint256 baselightLevel = BASELIGHT.getBaselightLevel(engine, battleKey, attackerPlayerIndex, monIndex);
        if (baselightLevel >= REQUIRED_STACKS) {
            return EMPOWERED_STAMINA;
        }
        return BASE_STAMINA;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Air;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }

}

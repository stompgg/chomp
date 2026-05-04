// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {MoveMeta} from "../../Structs.sol";

contract Gachachacha is IMoveSet {
    uint256 public constant MIN_BASE_POWER = 1;
    uint256 public constant MAX_BASE_POWER = 200;
    uint256 public constant SELF_KO_CHANCE = 5;
    uint256 public constant OPP_KO_CHANCE = 5;

    // RNG table
    // Damage      | Self KO damage | Opp KO damage
    // [0 ... 200] | [201 ... 205]  | [206 ... 210]
    uint256 public constant SELF_KO_THRESHOLD_L = MAX_BASE_POWER;
    uint256 public constant SELF_KO_THRESHOLD_R = MAX_BASE_POWER + SELF_KO_CHANCE;
    // uint256 constant public OPP_KO_THRESHOLD_L = SELF_KO_THRESHOLD_R;
    uint256 public constant OPP_KO_THRESHOLD_R = SELF_KO_THRESHOLD_R + OPP_KO_CHANCE;

    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override returns (string memory) {
        return "Gachachacha";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderMonIndex,
        uint16,
        uint256 rng
    ) external {
        uint256 chance = rng % OPP_KO_THRESHOLD_R;
        uint32 basePower;
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 playerForCalculator = attackerPlayerIndex;
        if (chance <= SELF_KO_THRESHOLD_L) {
            basePower = uint32(chance);
        } else if (chance > SELF_KO_THRESHOLD_L && chance <= SELF_KO_THRESHOLD_R) {
            basePower = engine.getMonValueForBattle(
                battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp
            );
            playerForCalculator = defenderPlayerIndex;
        } else {
            basePower = engine.getMonValueForBattle(
                battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Hp
            );
        }
        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            playerForCalculator,
            basePower,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 3;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Cyber;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
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

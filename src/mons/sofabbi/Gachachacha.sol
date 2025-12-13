// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

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

    IEngine immutable ENGINE;
    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override returns (string memory) {
        return "Gachachacha";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256 rng) external {
        uint256 chance = rng % OPP_KO_THRESHOLD_R;
        uint32 basePower;
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 playerForCalculator = attackerPlayerIndex;
        uint256[] memory activeMon = ENGINE.getActiveMonIndexForBattleState(battleKey);
        if (chance <= SELF_KO_THRESHOLD_L) {
            basePower = uint32(chance);
        } else if (chance > SELF_KO_THRESHOLD_L && chance <= SELF_KO_THRESHOLD_R) {
            basePower = ENGINE.getMonValueForBattle(
                battleKey, attackerPlayerIndex, activeMon[attackerPlayerIndex], MonStateIndexName.Hp
            );
            playerForCalculator = defenderPlayerIndex;
        } else {
            basePower = ENGINE.getMonValueForBattle(
                battleKey, defenderPlayerIndex, activeMon[defenderPlayerIndex], MonStateIndexName.Hp
            );
        }
        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            playerForCalculator,
            basePower,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(battleKey),
            moveClass(battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 3;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Cyber;
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Structs.sol";
import "../../src/Enums.sol";
import "../../src/Constants.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {AttackCalculator} from "../../src/moves/AttackCalculator.sol";

/**
 * @title DoublesSlotAttack
 * @notice A mock attack for doubles battles that uses AttackCalculator
 */
contract DoublesSlotAttack is IMoveSet {
    IEngine public immutable ENGINE;
    ITypeCalculator public immutable TYPE_CALCULATOR;

    uint32 public constant BASE_POWER = 100;
    uint32 public constant STAMINA_COST = 1;
    uint32 public constant ACCURACY = 100;
    uint32 public constant PRIORITY = 0;

    constructor(IEngine engine, ITypeCalculator typeCalc) {
        ENGINE = engine;
        TYPE_CALCULATOR = typeCalc;
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint256, uint256, uint240 extraData, uint256 rng) external {
        // Extract slot indices from extraData: lower 4 bits = attacker slot, next 4 bits = defender slot
        uint256 attackerSlotIndex = uint256(extraData) & 0x0F;
        uint256 defenderSlotIndex = (uint256(extraData) >> 4) & 0x0F;

        // Use slot-aware AttackCalculator overload for correct doubles targeting
        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            attackerSlotIndex,
            defenderSlotIndex,
            BASE_POWER,
            ACCURACY,
            DEFAULT_VOL,
            moveType(battleKey),
            moveClass(battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return PRIORITY;
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return STAMINA_COST;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Fire;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function name() external pure returns (string memory) {
        return "DoublesSlotAttack";
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

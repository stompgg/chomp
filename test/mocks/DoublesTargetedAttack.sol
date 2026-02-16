// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Structs.sol";
import "../../src/Enums.sol";
import "../../src/Constants.sol";
import "../../src/Engine.sol";
import "../../src/moves/IMoveSet.sol";
import "../../src/types/ITypeCalculator.sol";

/**
 * @title DoublesTargetedAttack
 * @notice A mock attack for doubles battles that uses extraData for target slot selection
 * @dev extraData is interpreted as the target slot index (0 or 1) on the opponent's side
 */
contract DoublesTargetedAttack is IMoveSet {
    Engine public immutable ENGINE;
    ITypeCalculator public immutable TYPE_CALCULATOR;

    uint32 private _basePower;
    uint32 private _stamina;
    uint32 private _accuracy;
    uint32 private _priority;
    Type private _moveType;

    struct Args {
        Type TYPE;
        uint32 BASE_POWER;
        uint32 ACCURACY;
        uint32 STAMINA_COST;
        uint32 PRIORITY;
    }

    constructor(Engine engine, ITypeCalculator typeCalc, Args memory args) {
        ENGINE = engine;
        TYPE_CALCULATOR = typeCalc;
        _basePower = args.BASE_POWER;
        _stamina = args.STAMINA_COST;
        _accuracy = args.ACCURACY;
        _priority = args.PRIORITY;
        _moveType = args.TYPE;
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256 rng) external {
        // Parse target slot from extraData (0 or 1)
        uint256 targetSlot = uint256(extraData) & 0x01;
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Get the target mon index from the specified slot
        uint256 defenderMonIndex = ENGINE.getActiveMonIndexForSlot(battleKey, defenderPlayerIndex, targetSlot);

        // Check accuracy
        if (rng % 100 >= _accuracy) {
            return; // Miss
        }

        // Get attacker mon index (slot 0 for simplicity - in a real implementation would need slot info)
        uint256 attackerMonIndex = ENGINE.getActiveMonIndexForSlot(battleKey, attackerPlayerIndex, 0);

        // Calculate damage using a simplified formula
        // Get attacker's attack stat
        int32 attackDelta = ENGINE.getMonStateForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Attack);
        uint32 baseAttack = ENGINE.getMonValueForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Attack);
        uint32 attack = uint32(int32(baseAttack) + attackDelta);

        // Get defender's defense stat
        int32 defDelta = ENGINE.getMonStateForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Defense);
        uint32 baseDef = ENGINE.getMonValueForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Defense);
        uint32 defense = uint32(int32(baseDef) + defDelta);

        // Simple damage formula: (attack / defense) * basePower
        uint32 damage = (_basePower * attack) / (defense > 0 ? defense : 1);

        // Apply type effectiveness
        Type defType1 = Type(ENGINE.getMonValueForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Type1));
        Type defType2 = Type(ENGINE.getMonValueForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Type2));
        damage = TYPE_CALCULATOR.getTypeEffectiveness(_moveType, defType1, damage);
        damage = TYPE_CALCULATOR.getTypeEffectiveness(_moveType, defType2, damage);

        // Deal damage to the targeted mon
        if (damage > 0) {
            ENGINE.dealDamage(defenderPlayerIndex, defenderMonIndex, int32(damage));
        }
    }

    function isValidTarget(bytes32, uint240 extraData) external pure returns (bool) {
        // extraData should be 0 or 1 for slot targeting
        return (uint256(extraData) & 0x01) <= 1;
    }

    function priority(bytes32, uint256) external view returns (uint32) {
        return _priority;
    }

    function stamina(bytes32, uint256, uint256) external view returns (uint32) {
        return _stamina;
    }

    function moveType(bytes32) external view returns (Type) {
        return _moveType;
    }

    function moveClass(bytes32) external pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function basePower(bytes32) external view returns (uint32) {
        return _basePower;
    }

    function accuracy(bytes32) external view returns (uint32) {
        return _accuracy;
    }

    function name() external pure returns (string memory) {
        return "DoublesTargetedAttack";
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None; // Custom targeting logic in this mock
    }
}

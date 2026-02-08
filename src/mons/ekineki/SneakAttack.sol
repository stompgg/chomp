// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {NineNineNineLib} from "./999Lib.sol";

contract SneakAttack is IMoveSet, BasicEffect {
    uint32 public constant BASE_POWER = 60;
    uint32 public constant STAMINA_COST = 2;

    IEngine immutable ENGINE;
    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Sneak Attack";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256 rng) external {
        // Check if already used this switch-in (effect present = already used)
        uint256 attackerMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        (EffectInstance[] memory effects,) = ENGINE.getEffects(battleKey, attackerPlayerIndex, attackerMonIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }

        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 targetMonIndex = uint256(extraData);

        // Get effective crit rate (checks 999 buff)
        uint32 effectiveCritRate = NineNineNineLib._getEffectiveCritRate(ENGINE, battleKey, attackerPlayerIndex);

        // Build DamageCalcContext manually to target any opponent mon (not just active)
        MonStats memory attackerStats = ENGINE.getMonStatsForBattle(battleKey, attackerPlayerIndex, attackerMonIndex);
        MonStats memory defenderStats = ENGINE.getMonStatsForBattle(battleKey, defenderPlayerIndex, targetMonIndex);

        DamageCalcContext memory ctx = DamageCalcContext({
            attackerMonIndex: uint8(attackerMonIndex),
            defenderMonIndex: uint8(targetMonIndex),
            attackerAttack: attackerStats.attack,
            attackerAttackDelta: ENGINE.getMonStateForBattle(
                battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Attack
            ),
            attackerSpAtk: attackerStats.specialAttack,
            attackerSpAtkDelta: ENGINE.getMonStateForBattle(
                battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.SpecialAttack
            ),
            defenderDef: defenderStats.defense,
            defenderDefDelta: ENGINE.getMonStateForBattle(
                battleKey, defenderPlayerIndex, targetMonIndex, MonStateIndexName.Defense
            ),
            defenderSpDef: defenderStats.specialDefense,
            defenderSpDefDelta: ENGINE.getMonStateForBattle(
                battleKey, defenderPlayerIndex, targetMonIndex, MonStateIndexName.SpecialDefense
            ),
            defenderType1: defenderStats.type1,
            defenderType2: defenderStats.type2
        });

        (int32 damage, bytes32 eventType) = AttackCalculator._calculateDamageFromContext(
            TYPE_CALCULATOR, ctx, BASE_POWER, DEFAULT_ACCURACY, DEFAULT_VOL, Type.Liquid, MoveClass.Special, rng, effectiveCritRate
        );

        if (damage != 0) {
            ENGINE.dealDamage(defenderPlayerIndex, targetMonIndex, damage);
        }
        if (eventType != bytes32(0)) {
            ENGINE.emitEngineEvent(eventType, "");
        }

        // Mark as used by adding local effect on the attacker's mon
        ENGINE.addEffect(attackerPlayerIndex, attackerMonIndex, IEffect(address(this)), bytes32(0));
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return STAMINA_COST;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) external pure returns (Type) {
        return Type.Liquid;
    }

    function moveClass(bytes32) external pure returns (MoveClass) {
        return MoveClass.Special;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.OpponentNonKOTeamIndex;
    }

    // IEffect implementation — local effect that cleans up on switch-out
    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return step == EffectStep.OnMonSwitchOut;
    }

    function onMonSwitchOut(uint256, bytes32, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (bytes32(0), true);
    }
}

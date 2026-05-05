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
import {NineNineNineLib} from "./NineNineNineLib.sol";
import {MoveMeta} from "../../Structs.sol";

contract SneakAttack is IMoveSet, BasicEffect {
    uint32 public constant BASE_POWER = 60;
    uint32 public constant STAMINA_COST = 2;

    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Sneak Attack";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint16 extraData,
        uint256 rng
    ) external {
        // Check if already used this switch-in (effect present = already used)
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, attackerPlayerIndex, attackerMonIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }

        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 targetMonIndex = uint256(extraData);

        // Get effective crit rate (checks 999 buff)
        uint32 effectiveCritRate = NineNineNineLib._getEffectiveCritRate(engine, battleKey, attackerPlayerIndex);

        // Build DamageCalcContext manually to target any opponent mon (not just active)
        MonStats memory attackerStats = engine.getMonStatsForBattle(battleKey, attackerPlayerIndex, attackerMonIndex);
        MonStats memory defenderStats = engine.getMonStatsForBattle(battleKey, defenderPlayerIndex, targetMonIndex);

        DamageCalcContext memory ctx = DamageCalcContext({
            attackerMonIndex: uint8(attackerMonIndex),
            defenderMonIndex: uint8(targetMonIndex),
            attackerAttack: attackerStats.attack,
            attackerAttackDelta: engine.getMonStateForBattle(
                battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Attack
            ),
            attackerSpAtk: attackerStats.specialAttack,
            attackerSpAtkDelta: engine.getMonStateForBattle(
                battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.SpecialAttack
            ),
            defenderDef: defenderStats.defense,
            defenderDefDelta: engine.getMonStateForBattle(
                battleKey, defenderPlayerIndex, targetMonIndex, MonStateIndexName.Defense
            ),
            defenderSpDef: defenderStats.specialDefense,
            defenderSpDefDelta: engine.getMonStateForBattle(
                battleKey, defenderPlayerIndex, targetMonIndex, MonStateIndexName.SpecialDefense
            ),
            defenderType1: defenderStats.type1,
            defenderType2: defenderStats.type2
        });

        (int32 damage, bytes32 eventType) = AttackCalculator._calculateDamageFromContext(
            TYPE_CALCULATOR, ctx, BASE_POWER, DEFAULT_ACCURACY, DEFAULT_VOL, Type.Liquid, MoveClass.Special, rng, effectiveCritRate
        );

        if (damage != 0) {
            engine.dealDamage(defenderPlayerIndex, targetMonIndex, damage);
        }

        // Mark as used by adding local effect on the attacker's mon
        engine.addEffect(attackerPlayerIndex, attackerMonIndex, IEffect(address(this)), bytes32(0));
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return STAMINA_COST;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Liquid;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    function isValidTarget(IEngine, bytes32, uint16) external pure returns (bool) {
        return true;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.OpponentNonKOTeamIndex;
    }

    // IEffect implementation — local effect that cleans up on switch-out
    // Steps: OnMonSwitchOut
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8020;
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (bytes32(0), true);
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

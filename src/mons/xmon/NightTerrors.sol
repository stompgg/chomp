// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {DEFAULT_ACCURACY, DEFAULT_CRIT_RATE, DEFAULT_PRIORITY, DEFAULT_VOL} from "../../Constants.sol";
import {ExtraDataType, MonStateIndexName, MoveClass, Type, TargetSpec} from "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract NightTerrors is IMoveSet, BasicEffect {
    uint32 public constant BASE_DAMAGE_PER_STACK = 20;
    uint32 public constant ASLEEP_DAMAGE_PER_STACK = 30;

    ITypeCalculator immutable TYPE_CALCULATOR;
    IEffect immutable SLEEP_STATUS;

    constructor(ITypeCalculator _TYPE_CALCULATOR, IEffect _SLEEP_STATUS) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        SLEEP_STATUS = _SLEEP_STATUS;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Night Terrors";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Check if the effect is already applied to the attacker (targeted lookup, no full-array build)
        (bool found, uint256 effectIndex, bytes32 effectData) =
            engine.getEffectData(battleKey, attackerPlayerIndex, attackerMonIndex, address(this));
        uint64 currentTerrorCount = 0;
        if (found) {
            (, currentTerrorCount) = _unpackExtraData(effectData);
        }

        // Increment terror count
        uint64 newTerrorCount = currentTerrorCount + 1;
        bytes32 newExtraData = _packExtraData(uint64(defenderPlayerIndex), newTerrorCount);

        if (found) {
            // Edit existing effect
            engine.editEffect(attackerPlayerIndex, effectIndex, newExtraData);
        } else {
            // Add new effect
            engine.addEffect(attackerPlayerIndex, attackerMonIndex, this, newExtraData);
        }
    }

    function _packExtraData(uint64 defenderPlayerIndex, uint64 terrorCount) internal pure returns (bytes32) {
        return bytes32((uint256(defenderPlayerIndex) << 64) | terrorCount);
    }

    function _unpackExtraData(bytes32 data) internal pure returns (uint64 defenderPlayerIndex, uint64 terrorCount) {
        defenderPlayerIndex = uint64(uint256(data) >> 64);
        terrorCount = uint64(uint256(data) & type(uint64).max);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Cosmic;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    // Steps: RoundEnd, OnMonSwitchOut
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8024;
    }

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32, bool) {
        uint256 p0ActiveMonIndex = TargetLib.sideActive(activesPacked, 0);
        uint256 p1ActiveMonIndex = TargetLib.sideActive(activesPacked, 1);
        // targetIndex/monIndex is the attacker (who has the effect)
        // defenderPlayerIndex is stored in extraData (who should take damage)
        (uint64 defenderPlayerIndex, uint64 terrorCount) = _unpackExtraData(extraData);

        // Check current stamina of the attacker (who has the effect)
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Stamina);
        int32 staminaLeft = int32(engine.getMonStatsForBattle(battleKey, targetIndex, monIndex).stamina) + staminaDelta;

        // If not enough stamina to pay for all stacks, nothing happens
        if (staminaLeft < int32(uint32(terrorCount))) {
            return (extraData, false);
        }

        // Pay stamina cost from the attacker
        engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, -int32(uint32(terrorCount)));

        // Get the defender's active mon index
        uint256 defenderMonIndex = defenderPlayerIndex == 0 ? p0ActiveMonIndex : p1ActiveMonIndex;

        // Check if opponent (defender) is asleep (targeted lookup, no full-array build)
        (bool isAsleep,,) =
            engine.getEffectData(battleKey, defenderPlayerIndex, defenderMonIndex, address(SLEEP_STATUS));

        // Determine damage per stack based on sleep status
        uint32 damagePerStack = isAsleep ? ASLEEP_DAMAGE_PER_STACK : BASE_DAMAGE_PER_STACK;

        // Calculate total base power
        uint32 totalBasePower = damagePerStack * uint32(terrorCount);

        // Deal damage using AttackCalculator (attacker damages defender)
        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            targetIndex, TargetLib.impliedSinglesTargetBits(targetIndex), // attacker player index
            totalBasePower,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            // The hook's rng parameter IS tempRNG on every RoundEnd path — the engine sets
            // tempRNG = rng then threads the same value into every effect hook; the external
            // tempRNG() read-back was a duplicate round-trip.
            rng,
            DEFAULT_CRIT_RATE
        );

        return (extraData, false);
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Clear effect on switch out
        return (extraData, true);
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            targetSpec: TargetSpec.AnyOtherSlot,
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}

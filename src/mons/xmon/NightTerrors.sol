// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {DEFAULT_PRIORITY, DEFAULT_ACCURACY, DEFAULT_VOL, DEFAULT_CRIT_RATE} from "../../Constants.sol";
import {EffectStep, ExtraDataType, MoveClass, Type, MonStateIndexName} from "../../Enums.sol";
import {EffectInstance} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract NightTerrors is IMoveSet, BasicEffect {

    uint32 public constant BASE_DAMAGE_PER_STACK = 20;
    uint32 public constant ASLEEP_DAMAGE_PER_STACK = 30;

    IEngine immutable ENGINE;
    ITypeCalculator immutable TYPE_CALCULATOR;
    IEffect immutable SLEEP_STATUS;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR, IEffect _SLEEP_STATUS) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        SLEEP_STATUS = _SLEEP_STATUS;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Night Terrors";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256) external {
        uint256 attackerMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;

        // Check if the effect is already applied to the attacker
        (EffectInstance[] memory effects, uint256[] memory indices) = ENGINE.getEffects(battleKey, attackerPlayerIndex, attackerMonIndex);
        bool found = false;
        uint256 effectIndex = 0;
        uint64 currentTerrorCount = 0;

        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                found = true;
                effectIndex = indices[i];
                // Decode existing extraData
                (, uint64 storedTerrorCount) = _unpackExtraData(effects[i].data);
                currentTerrorCount = storedTerrorCount;
                break;
            }
        }

        // Increment terror count
        uint64 newTerrorCount = currentTerrorCount + 1;
        bytes32 newExtraData = _packExtraData(uint64(defenderPlayerIndex), newTerrorCount);

        if (found) {
            // Edit existing effect
            ENGINE.editEffect(attackerPlayerIndex, attackerMonIndex, effectIndex, newExtraData);
        } else {
            // Add new effect
            ENGINE.addEffect(attackerPlayerIndex, attackerMonIndex, this, newExtraData);
        }
    }

    function _packExtraData(uint64 defenderPlayerIndex, uint64 terrorCount) internal pure returns (bytes32) {
        return bytes32((uint256(defenderPlayerIndex) << 64) | terrorCount);
    }

    function _unpackExtraData(bytes32 data) internal pure returns (uint64 defenderPlayerIndex, uint64 terrorCount) {
        defenderPlayerIndex = uint64(uint256(data) >> 64);
        terrorCount = uint64(uint256(data) & type(uint64).max);
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 0;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Cosmic;
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

    // Effect implementation
    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return (step == EffectStep.RoundEnd || step == EffectStep.OnMonSwitchOut);
    }

    function onRoundEnd(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32, bool)
    {
        // targetIndex/monIndex is the attacker (who has the effect)
        // defenderPlayerIndex is stored in extraData (who should take damage)
        (uint64 defenderPlayerIndex, uint64 terrorCount) = _unpackExtraData(extraData);

        bytes32 battleKey = ENGINE.battleKeyForWrite();

        // Check current stamina of the attacker (who has the effect)
        int32 staminaDelta = ENGINE.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Stamina);
        int32 staminaLeft = int32(ENGINE.getMonStatsForBattle(battleKey, targetIndex, monIndex).stamina) + staminaDelta;

        // If not enough stamina to pay for all stacks, nothing happens
        if (staminaLeft < int32(uint32(terrorCount))) {
            return (extraData, false);
        }

        // Pay stamina cost from the attacker
        ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Stamina, -int32(uint32(terrorCount)));

        // Get the defender's active mon index
        uint256 defenderMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[defenderPlayerIndex];

        // Check if opponent (defender) is asleep by iterating through their effects
        (EffectInstance[] memory defenderEffects, ) = ENGINE.getEffects(battleKey, defenderPlayerIndex, defenderMonIndex);
        bool isAsleep = false;
        for (uint256 i = 0; i < defenderEffects.length; i++) {
            if (address(defenderEffects[i].effect) == address(SLEEP_STATUS)) {
                isAsleep = true;
                break;
            }
        }

        // Determine damage per stack based on sleep status
        uint32 damagePerStack = isAsleep ? ASLEEP_DAMAGE_PER_STACK : BASE_DAMAGE_PER_STACK;

        // Calculate total base power
        uint32 totalBasePower = damagePerStack * uint32(terrorCount);

        // Deal damage using AttackCalculator (attacker damages defender)
        AttackCalculator._calculateDamage(
            ENGINE,
            TYPE_CALCULATOR,
            battleKey,
            targetIndex, // attacker player index
            totalBasePower,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(battleKey),
            moveClass(battleKey),
            ENGINE.tempRNG(),
            DEFAULT_CRIT_RATE
        );

        return (extraData, false);
    }

    function onMonSwitchOut(uint256, bytes32 extraData, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Clear effect on switch out
        return (extraData, true);
    }
}

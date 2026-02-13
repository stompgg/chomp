// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {DEFAULT_PRIORITY} from "../../Constants.sol";
import {EffectStep, ExtraDataType, MoveClass, Type, MonStateIndexName} from "../../Enums.sol";
import {EffectInstance} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract IronWall is IMoveSet, BasicEffect {
    
    int32 public constant HEAL_PERCENT = 50;
    int32 public constant INITIAL_HEAL_PERCENT = 20;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Iron Wall";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Get the active mon index
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];

        // Check to see if the effect is already active
        (EffectInstance[] memory effects, ) = ENGINE.getEffects(battleKey, attackerPlayerIndex, activeMonIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }

        // The effect will last until Aurox switches out
        ENGINE.addEffect(attackerPlayerIndex, activeMonIndex, IEffect(address(this)), bytes32(0));

        // Also, heal for INITIAL_HEAL_PERCENT
        int32 maxHp =
            int32(ENGINE.getMonValueForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp));
        int32 healAmount = (maxHp * INITIAL_HEAL_PERCENT) / 100;
        // Prevent overhealing
        int32 currentHpDelta =
            ENGINE.getMonStateForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp);
        if (currentHpDelta + healAmount > 0) {
            healAmount = -currentHpDelta;
        }
        ENGINE.updateMonState(attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp, healAmount);
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 3;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Metal;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    // IEffect implementation
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x60;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](2);
        steps[0] = EffectStep.AfterDamage;
        steps[1] = EffectStep.OnMonSwitchOut;
        return steps;
    }

    function onAfterDamage(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, int32 damageDealt)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Calculate 50% of the damage taken
        int32 healAmount = (damageDealt * HEAL_PERCENT) / 100;
        // Heal only if not KO'ed
        if (
            healAmount > 0
                && ENGINE.getMonStateForBattle(
                        ENGINE.battleKeyForWrite(), targetIndex, monIndex, MonStateIndexName.IsKnockedOut
                    ) == 0
        ) {
            ENGINE.updateMonState(targetIndex, monIndex, MonStateIndexName.Hp, healAmount);
        }
        return (extraData, false);
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
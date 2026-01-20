// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {EffectStep} from "../../Enums.sol";

import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

contract RiseFromTheGrave is IAbility, BasicEffect {
    uint64 public constant REVIVAL_DELAY = 3;
    uint64 constant MON_EFFECT_IDENTIFIER = 17;

    IEngine immutable ENGINE;

    constructor(IEngine _ENGINE) {
        ENGINE = _ENGINE;
    }

    // IAbility implementation
    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Rise From The Grave";
    }

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Check if the effect has already been set for this mon (can only be set once)
        bytes32 monEffectId = keccak256(abi.encode(playerIndex, monIndex, name()));
        if (ENGINE.getGlobalKV(battleKey, monEffectId) != 0) {
            return;
        }
        // Otherwise, add this effect to the mon when it switches in
        else {
            ENGINE.setGlobalKV(monEffectId, 1);
            uint64 v1 = MON_EFFECT_IDENTIFIER; // turns left, or sentinel value
            uint64 v2 = uint64(playerIndex) & 0x3F; // player index (masked to 6 bits)
            uint64 v3 = uint64(monIndex) & 0x3F; // mon index (masked to 6 bits)
            uint256 packedValue = (v1 << 12) | (v2 << 6) | v3;
            ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(packedValue));
        }
    }

    // IEffect implementation
    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return (step == EffectStep.RoundEnd || step == EffectStep.AfterDamage);
    }

    function onAfterDamage(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, int32)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        /*
        On damage, if the mon is KO'd, add this effect to the global effects list (so we can hook into onRoundEnd)
        and remove this effect (so we stop hooking into it on future applications)
        */
        // If the mon is KO'd, add this effect to the global effects list and remove the mon effect
        if (
            ENGINE.getMonStateForBattle(
                    ENGINE.battleKeyForWrite(), targetIndex, monIndex, MonStateIndexName.IsKnockedOut
                ) == 1
        ) {
            uint64 v1 = REVIVAL_DELAY;
            uint64 v2 = uint64(targetIndex) & 0x3F; // player index (masked to 6 bits)
            uint64 v3 = uint64(monIndex) & 0x3F; // mon index (masked to 6 bits)
            uint256 packedValue = (v1 << 12) | (v2 << 6) | v3;
            ENGINE.addEffect(2, targetIndex, IEffect(address(this)), bytes32(packedValue));
            return (extraData, true);
        }
        return (extraData, false);
    }

    // Regain stamina on round end, this can overheal stamina
    function onRoundEnd(uint256, bytes32 extraData, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Decode the packed magic value
        uint256 packedValue = uint256(extraData);
        uint64 turnsLeft = uint64(packedValue >> 12);
        uint64 playerIndex = uint64((packedValue >> 6) & 0x3F); // Extract 6 bits for player index
        uint64 monIndex = uint64(packedValue & 0x3F); // Extract 6 bits for mon index

        // If the effect is applied to the mon (and not globally), then we just end early
        if (turnsLeft == MON_EFFECT_IDENTIFIER) {
            return (extraData, false);
        }
        // Otherwise, we are applied as a global effect and we should check if we should revive the mon
        else if (turnsLeft == 1) {
            // Revive the mon and set HP to 1
            ENGINE.updateMonState(playerIndex, monIndex, MonStateIndexName.IsKnockedOut, 0);
            bytes32 battleKey = ENGINE.battleKeyForWrite();
            int32 currentDamage = ENGINE.getMonStateForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Hp);
            uint32 maxHp = ENGINE.getMonValueForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.Hp);
            int32 hpShiftAmount = 1 - currentDamage - int32(maxHp);
            ENGINE.updateMonState(playerIndex, monIndex, MonStateIndexName.Hp, hpShiftAmount);

            // Clear the effect after running
            return (extraData, true);
        } else {
            uint256 newPackedValue = ((turnsLeft - 1) << 12) | ((playerIndex & 0x3F) << 6) | (monIndex & 0x3F);
            return (bytes32(newPackedValue), false);
        }
    }
}

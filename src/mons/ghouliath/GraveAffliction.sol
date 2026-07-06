// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {StatusEffectLib} from "../../effects/status/StatusEffectLib.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract GraveAffliction is IMoveSet {
    // Both mons lose 1/FRACTION_DENOM of their current HP.
    int32 public constant FRACTION_DENOM = 2;

    function name() public pure override returns (string memory) {
        return "Grave Affliction";
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
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) return; // no chosen target (defensive; the engine fizzles first)
        uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);

        // Only fires if the opposing mon currently has a status condition. The StatusEffect base sets
        // this per-mon flag in onApply for every status (Sleep/Panic/Burn/Frostbite/Zap/Blessed).
        uint64 statusKey = StatusEffectLib.getKeyForMonIndex(defenderPlayerIndex, defenderMonIndex);
        if (engine.getGlobalKV(battleKey, statusKey) == 0) {
            return;
        }

        // Both mons lose half their *current* HP (max HP + signed delta).
        int32 attackerCurrentHp = int32(
            engine.getMonValueForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp)
        ) + engine.getMonStateForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
        int32 defenderCurrentHp = int32(
            engine.getMonValueForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Hp)
        ) + engine.getMonStateForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Hp);

        engine.dealDamage(attackerPlayerIndex, attackerMonIndex, attackerCurrentHp / FRACTION_DENOM);
        engine.dealDamage(defenderPlayerIndex, defenderMonIndex, defenderCurrentHp / FRACTION_DENOM);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Yin;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
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
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}

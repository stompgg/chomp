// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, STATUS_CLASS_SHIFT} from "../../Constants.sol";
import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract BlessedStatus is StatusEffect {
    uint256 constant STATUS_CLASS = 6;

    // Healed on removal, as a fraction of max HP.
    int32 public constant HEAL_DENOM = 16;

    function name() public pure override returns (string memory) {
        return "Blessed";
    }

    // Steps: OnApply (0x01), OnRemove (0x08), PreDamage (0x200)
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x209 | uint16(STATUS_CLASS << STATUS_CLASS_SHIFT) | ALWAYS_APPLIES_BIT;
    }

    // Absorb the next incoming damage source entirely, then remove (which grants the heal).
    function onPreDamage(IEngine engine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool removeAfterRun)
    {
        if (engine.getPreDamage() > 0) {
            engine.setPreDamage(0);
            return (extraData, true);
        }
        return (extraData, false);
    }

    // On removal, grant the heal (the engine clears the status lane).
    function onRemove(IEngine engine, bytes32 battleKey, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        public
        override
    {
        _heal(engine, battleKey, targetIndex, monIndex);
    }

    // Heal maxHp/HEAL_DENOM, clamped so we never overheal (copy of the ChainExpansion clamp).
    function _heal(IEngine engine, bytes32 battleKey, uint256 targetIndex, uint256 monIndex) internal {
        int32 amtToHeal =
            int32(engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp)) / HEAL_DENOM;
        int32 hpDelta = engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
        // hpDelta is negative when damaged; cap the heal to the damage taken so we can't exceed max HP.
        if (amtToHeal > (-1 * hpDelta)) {
            amtToHeal = -1 * hpDelta;
        }
        if (amtToHeal != 0) {
            engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Hp, amtToHeal);
        }
    }
}

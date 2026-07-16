// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, STATUS_CLASS_SHIFT} from "../../Constants.sol";
import "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {StatBoostToApply} from "../../Structs.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract FrostbiteStatus is StatusEffect {
    uint256 constant STATUS_CLASS = 2;

    int32 constant DAMAGE_DENOM = 16;
    uint8 constant SP_ATTACK_PERCENT = 50;

    function name() public pure override returns (string memory) {
        return "Frostbite";
    }

    // Steps: OnApply, RoundEnd, OnRemove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0D | uint16(STATUS_CLASS << STATUS_CLASS_SHIFT) | ALWAYS_APPLIES_BIT;
    }

    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        // Reduce special attack by half
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack, boostPercent: SP_ATTACK_PERCENT, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);

        // Cache max HP (bits 32-63; fixed for the battle) so each tick skips the engine read.
        uint256 maxHp = uint256(engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp));
        return (bytes32(maxHp << 32), false);
    }

    function onRemove(IEngine engine, bytes32, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        public
        override
    {
        // Reset the special attack reduction
        engine.removeStatBoost(targetIndex, monIndex, StatBoostFlag.Perm);
    }

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) public override returns (bytes32, bool) {
        // Damage from the max HP cached at apply
        int32 damage = int32(uint32(uint256(extraData) >> 32)) / DAMAGE_DENOM;
        engine.dealDamage(targetIndex, monIndex, damage);

        // Do not update data
        return (extraData, false);
    }
}

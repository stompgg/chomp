// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, HAS_REAPPLY_BIT, STATUS_CLASS_SHIFT} from "../../Constants.sol";
import "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {StatBoostToApply} from "../../Structs.sol";

import {IStatusEffect} from "./IStatusEffect.sol";
import {StatusEffect} from "./StatusEffect.sol";

contract BurnStatus is StatusEffect, IStatusEffect {
    uint256 constant STATUS_CLASS = 1;

    uint256 public constant MAX_BURN_DEGREE = 3;

    uint8 public constant ATTACK_PERCENT = 50;

    int32 public constant DEG1_DAMAGE_DENOM = 16;
    int32 public constant DEG2_DAMAGE_DENOM = 8;
    int32 public constant DEG3_DAMAGE_DENOM = 4;

    function name() public pure override returns (string memory) {
        return "Burn";
    }

    // Steps: OnApply, RoundEnd, OnRemove (no RoundStart behavior — the bit would only buy a
    // no-op external call per burned turn). HAS_REAPPLY routes same-class re-applies to the
    // degree escalation in onReapply.
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0D | uint16(STATUS_CLASS << STATUS_CLASS_SHIFT) | HAS_REAPPLY_BIT | ALWAYS_APPLIES_BIT;
    }

    // extraData layout: [burn degree: bits 0-7 | cached max HP: bits 32-63]. Base HP is fixed
    // for the battle, so caching it at apply saves the per-tick engine read.

    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        // Fresh apply only — the Engine routes same-class re-applies to onReapply instead.
        // Reduce attack by 1/ATTACK_DENOM of base attack stat
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack, boostPercent: ATTACK_PERCENT, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);

        uint256 maxHp = uint256(engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp));
        return (bytes32(uint256(1) | (maxHp << 32)), false);
    }

    // Same-class re-apply (IStatusEffect): escalate the degree in place, preserving the cached
    // max HP in the upper bits.
    function onReapply(IEngine, bytes32, uint256, bytes32 existingData, uint256, uint256, uint256)
        external
        pure
        returns (bytes32 newData, bool removeAfterRun)
    {
        uint256 burnDegree = uint256(existingData) & 0xFF;
        if (burnDegree < MAX_BURN_DEGREE) {
            existingData = bytes32((uint256(existingData) & ~uint256(0xFF)) | (burnDegree + 1));
        }
        return (existingData, false);
    }

    function onRemove(IEngine engine, bytes32, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        public
        override
    {
        // Lane clear is engine-owned (_removeEffectAtSlot); only the attack debuff is ours.
        engine.removeStatBoost(targetIndex, monIndex, StatBoostFlag.Perm);
    }

    // Deal damage over time
    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) external override returns (bytes32, bool) {
        uint256 burnDegree = uint256(extraData) & 0xFF;
        int32 damageDenom = DEG1_DAMAGE_DENOM;
        if (burnDegree == 2) {
            damageDenom = DEG2_DAMAGE_DENOM;
        }
        if (burnDegree == 3) {
            damageDenom = DEG3_DAMAGE_DENOM;
        }
        int32 damage = int32(uint32(uint256(extraData) >> 32)) / damageDenom;
        engine.dealDamage(targetIndex, monIndex, damage);
        return (extraData, false);
    }
}

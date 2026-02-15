// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MonStateIndexName, StatBoostFlag, StatBoostType} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {StatBoostToApply} from "../../src/Structs.sol";

import {StatusEffect} from "../../src/effects/status/StatusEffect.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";

contract SpAtkDebuffEffect is StatusEffect {
    uint8 constant SP_ATTACK_PERCENT = 50;

    StatBoosts immutable STAT_BOOST;

    constructor(IEngine engine, StatBoosts _STAT_BOOSTS) StatusEffect(engine) {
        STAT_BOOST = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "SpAtk Debuff";
    }

    // Steps: OnApply, OnRemove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x09;
    }

    function onApply(
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    )
        public
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Call parent to set status flag
        super.onApply(battleKey, rng, extraData, targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);

        // Reduce special attack by half
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: SP_ATTACK_PERCENT,
            boostType: StatBoostType.Divide
        });
        STAT_BOOST.addStatBoosts(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);

        // Do not update data
        return (extraData, false);
    }

    function onRemove(
        bytes32 battleKey,
        bytes32 data,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) public override {
        super.onRemove(battleKey, data, targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);

        // Reset the special attack reduction
        STAT_BOOST.removeStatBoosts(targetIndex, monIndex, StatBoostFlag.Perm);
    }
}

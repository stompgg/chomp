// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {EffectStep, MonStateIndexName, StatBoostFlag, StatBoostType} from "../../src/Enums.sol";
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

    function getStepsBitmap() external pure override returns (uint16) {
        return 0x09;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](2);
        steps[0] = EffectStep.OnApply;
        steps[1] = EffectStep.OnRemove;
        return steps;
    }

    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return (r == EffectStep.OnApply || r == EffectStep.OnRemove);
    }

    function onApply(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        public
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
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

    function onRemove(bytes32 data, uint256 targetIndex, uint256 monIndex) public override {
        super.onRemove(data, targetIndex, monIndex);

        // Reset the special attack reduction
        STAT_BOOST.removeStatBoosts(targetIndex, monIndex, StatBoostFlag.Perm);
    }
}


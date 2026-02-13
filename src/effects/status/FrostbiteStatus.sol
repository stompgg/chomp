// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../Enums.sol";
import {StatBoostToApply} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {StatBoosts} from "../StatBoosts.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract FrostbiteStatus is StatusEffect {

    int32 constant DAMAGE_DENOM = 16;
    uint8 constant SP_ATTACK_PERCENT = 50;

    StatBoosts immutable STAT_BOOST;

    constructor(IEngine engine, StatBoosts _STAT_BOOSTS) StatusEffect(engine) {
        STAT_BOOST = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Frostbite";
    }

    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0D;
    }

    function getStepsToRun() external pure override returns (EffectStep[] memory) {
        EffectStep[] memory steps = new EffectStep[](3);
        steps[0] = EffectStep.OnApply;
        steps[1] = EffectStep.RoundEnd;
        steps[2] = EffectStep.OnRemove;
        return steps;
    }

    function onApply(uint256 rng, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        public
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {

        super.onApply(rng, extraData, targetIndex, monIndex);

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

    function onRoundEnd(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        public
        override
        returns (bytes32, bool)
    {
        // Calculate damage to deal
        uint32 maxHealth =
            ENGINE.getMonValueForBattle(ENGINE.battleKeyForWrite(), targetIndex, monIndex, MonStateIndexName.Hp);
        int32 damage = int32(maxHealth) / DAMAGE_DENOM;
        ENGINE.dealDamage(targetIndex, monIndex, damage);

        // Do not update data
        return (extraData, false);
    }
}

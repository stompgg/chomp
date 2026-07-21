// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, STATUS_CLASS_SHIFT} from "../../src/Constants.sol";
import {MonStateIndexName, StatBoostFlag, StatBoostType} from "../../src/Enums.sol";
import {IEngine} from "../../src/IEngine.sol";
import {StatBoostToApply} from "../../src/Structs.sol";

import {StatusEffect} from "../../src/effects/status/StatusEffect.sol";
import {TEST_STATUS_CLASS} from "./TestStatusClass.sol";

contract SpAtkDebuffEffect is StatusEffect {
    uint256 constant STATUS_CLASS = TEST_STATUS_CLASS;

    uint8 constant SP_ATTACK_PERCENT = 50;

    function name() public pure override returns (string memory) {
        return "SpAtk Debuff";
    }

    // Steps: OnApply, OnRemove
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x09 | uint16(STATUS_CLASS << STATUS_CLASS_SHIFT) | ALWAYS_APPLIES_BIT;
    }

    function onApply(
        IEngine engine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        // Reduce special attack by half
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack, boostPercent: SP_ATTACK_PERCENT, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);

        // Do not update data
        return (extraData, false);
    }

    function onRemove(IEngine engine, bytes32, bytes32, uint256 targetIndex, uint256 monIndex, uint256)
        public
        override
    {
        // Reset the special attack reduction
        engine.removeStatBoost(targetIndex, monIndex, StatBoostFlag.Perm);
    }
}

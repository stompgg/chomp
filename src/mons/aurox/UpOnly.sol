// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {EffectStep} from "../../Enums.sol";
import {MonStateIndexName, StatBoostType, StatBoostFlag} from "../../Enums.sol";
import {EffectInstance, StatBoostToApply} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";

contract UpOnly is IAbility, BasicEffect {

    uint8 public constant ATTACK_BOOST_PERCENT = 10; // 10% attack boost per hit

    IEngine immutable ENGINE;
    StatBoosts immutable STAT_BOOSTS;

    constructor(IEngine _ENGINE, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    // IAbility implementation
    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Up Only";
    }

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Check if the effect has already been set for this mon
        (EffectInstance[] memory effects, ) = ENGINE.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }
        ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // IEffect implementation
    // Steps: AfterDamage
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x40;
    }

    function onAfterDamage(bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256, uint256, int32)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Add 5% attack boost every time damage is taken
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack,
            boostPercent: ATTACK_BOOST_PERCENT,
            boostType: StatBoostType.Multiply
        });
        STAT_BOOSTS.addStatBoosts(targetIndex, monIndex, statBoosts, StatBoostFlag.Perm);

        return (extraData, false);
    }
}

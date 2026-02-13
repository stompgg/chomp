// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Enums.sol";
import {EffectInstance, StatBoostToApply} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";

contract Interweaving is IAbility, BasicEffect {
    uint8 constant DECREASE_PERCENTAGE = 10;
    IEngine immutable ENGINE;
    StatBoosts immutable STAT_BOOST;

    constructor(IEngine _ENGINE, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        STAT_BOOST = _STAT_BOOSTS;
    }

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Interweaving";
    }

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Lower opposing mon Attack stat
        uint256 otherPlayerIndex = (playerIndex + 1) % 2;
        uint256 otherPlayerActiveMonIndex =
            ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[otherPlayerIndex];
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack,
            boostPercent: DECREASE_PERCENTAGE,
            boostType: StatBoostType.Divide
        });
        STAT_BOOST.addStatBoosts(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);

        // Check if the effect has already been set for this mon
        (EffectInstance[] memory effects, ) = ENGINE.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length;) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
            unchecked { ++i; }
        }
        // Otherwise, add this effect to the mon when it switches in
        // This way we can trigger on switch out
        ENGINE.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: OnApply, OnMonSwitchOut
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x21;
    }

    function onMonSwitchOut(uint256, bytes32, uint256 targetIndex, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        uint256 otherPlayerIndex = (targetIndex + 1) % 2;
        uint256 otherPlayerActiveMonIndex =
            ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[otherPlayerIndex];
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: DECREASE_PERCENTAGE,
            boostType: StatBoostType.Divide
        });
        STAT_BOOST.addStatBoosts(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);
        return (bytes32(0), false);
    }
}

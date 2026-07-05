// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {EffectInstance, StatBoostToApply} from "../../Structs.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";

contract Interweaving is IAbility, BasicEffect {
    uint8 public constant DECREASE_PERCENTAGE = 15;

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Interweaving";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Lower opposing mon Attack stat
        uint256 otherPlayerIndex = (playerIndex + 1) % 2;
        uint256 otherPlayerActiveMonIndex = engine.getActiveMonIndexForBattleState(battleKey)[otherPlayerIndex];
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack, boostPercent: DECREASE_PERCENTAGE, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);

        // Check if the effect has already been set for this mon
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }
        // Otherwise, add this effect to the mon when it switches in
        // This way we can trigger on switch out
        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: OnApply, OnMonSwitchOut
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8021;
    }

    function onMonSwitchOut(
        IEngine engine,
        bytes32,
        uint256,
        bytes32,
        uint256 targetIndex,
        uint256,
        uint256 activesPacked
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        uint256 p0ActiveMonIndex = TargetLib.sideActive(activesPacked, 0);
        uint256 p1ActiveMonIndex = TargetLib.sideActive(activesPacked, 1);
        uint256 otherPlayerIndex = (targetIndex + 1) % 2;
        uint256 otherPlayerActiveMonIndex = otherPlayerIndex == 0 ? p0ActiveMonIndex : p1ActiveMonIndex;
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack, boostPercent: DECREASE_PERCENTAGE, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);
        return (bytes32(0), false);
    }
}

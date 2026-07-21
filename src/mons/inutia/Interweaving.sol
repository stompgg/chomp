// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {EMPTY_ACTIVE_LANE, NO_SLOT} from "../../Constants.sol";
import "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {StatBoostToApply} from "../../Structs.sol";
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
        // Lower opposing mon Attack stat (mirror-slot ruling; slot 0 in singles)
        uint256[4] memory lanes = engine.getActiveSlots(battleKey);
        uint256 ownSlot = lanes[playerIndex << 1] == monIndex ? (playerIndex << 1) : ((playerIndex << 1) | 1);
        uint256 oppSlot = ownSlot ^ 2;
        if (lanes[oppSlot] == EMPTY_ACTIVE_LANE) {
            oppSlot ^= 1;
            if (lanes[oppSlot] == EMPTY_ACTIVE_LANE) {
                return;
            }
        }
        uint256 otherPlayerIndex = oppSlot >> 1;
        uint256 otherPlayerActiveMonIndex = lanes[oppSlot];
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack, boostPercent: DECREASE_PERCENTAGE, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);

        // Skip if the switch-out effect is already registered on this mon
        (bool exists,,) = engine.getEffectData(battleKey, playerIndex, monIndex, address(this));
        if (exists) {
            return;
        }
        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: OnApply, OnMonSwitchOut
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x8021;
    }

    function onMonSwitchOut(
        IEngine engine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 activesPacked
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        // Mirror-slot ruling: the debuff lands opposite Inutia's own slot.
        uint256 ownSlot = TargetLib.slotOfMon(activesPacked, targetIndex, monIndex);
        uint256 oppSlot = TargetLib.mirrorOpposingSlot(activesPacked, ownSlot);
        if (oppSlot == NO_SLOT) {
            return (extraData, false);
        }
        uint256 otherPlayerIndex = oppSlot >> 1;
        uint256 otherPlayerActiveMonIndex = TargetLib.activeAt(activesPacked, oppSlot);
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack, boostPercent: DECREASE_PERCENTAGE, boostType: StatBoostType.Divide
        });
        engine.addStatBoost(otherPlayerIndex, otherPlayerActiveMonIndex, statBoosts, StatBoostFlag.Temp);
        return (bytes32(0), false);
    }
}

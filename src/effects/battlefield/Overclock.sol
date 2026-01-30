// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../BasicEffect.sol";
import {IEffect} from "../IEffect.sol";
import {StatBoosts} from "../StatBoosts.sol";

contract Overclock is BasicEffect {
    uint256 public constant DEFAULT_DURATION = 3;

    uint8 public constant SPEED_PERCENT = 25;
    uint8 public constant SP_DEF_PERCENT = 25;

    IEngine immutable ENGINE;
    StatBoosts immutable STAT_BOOST;

    constructor(IEngine _ENGINE, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        STAT_BOOST = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Overclock";
    }

    function shouldRunAtStep(EffectStep r) external pure override returns (bool) {
        return
            (r == EffectStep.OnApply || r == EffectStep.RoundEnd || r == EffectStep.OnMonSwitchIn
                    || r == EffectStep.OnRemove);
    }

    function _effectKey(uint256 playerIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, name()));
    }

    function applyOverclock(uint256 playerIndex) public {
        // Check if we have an active Overclock effect
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        uint256 duration = getDuration(battleKey, playerIndex);
        if (duration == 0) {
            // If not, add the effect to the global effects array
            ENGINE.addEffect(2, playerIndex, IEffect(address(this)), bytes32(playerIndex));
        } else {
            // Otherwise, reset the duration
            setDuration(DEFAULT_DURATION, playerIndex);
        }
    }

    function getDuration(bytes32 battleKey, uint256 playerIndex) public view returns (uint256) {
        return uint256(ENGINE.getGlobalKV(battleKey, _effectKey(playerIndex)));
    }

    function setDuration(uint256 newDuration, uint256 playerIndex) public {
        ENGINE.setGlobalKV(_effectKey(playerIndex), uint192(newDuration));
    }

    function _applyStatChange(uint256 playerIndex, uint256 monIndex) internal {
        // Apply stat boosts (speed buff / sp def debuff)
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](2);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Speed,
            boostPercent: SPEED_PERCENT,
            boostType: StatBoostType.Multiply
        });
        statBoosts[1] = StatBoostToApply({
            stat: MonStateIndexName.SpecialDefense,
            boostPercent: SP_DEF_PERCENT,
            boostType: StatBoostType.Divide
        });
        STAT_BOOST.addStatBoosts(playerIndex, monIndex, statBoosts, StatBoostFlag.Temp);
    }

    function _removeStatChange(uint256 playerIndex, uint256 monIndex) internal {
        // Reset stat boosts (speed buff / sp def debuff)
        STAT_BOOST.removeStatBoosts(playerIndex, monIndex, StatBoostFlag.Temp);
    }

    function onApply(EffectContext calldata ctx, uint256, bytes32 extraData, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        uint256 playerIndex = uint256(extraData);

        // Set default duration
        setDuration(DEFAULT_DURATION, playerIndex);

        // Apply stat change to the team of the player who summoned Overclock
        uint256 activeMonIndex = playerIndex == 0 ? ctx.p0ActiveMonIndex : ctx.p1ActiveMonIndex;
        _applyStatChange(playerIndex, activeMonIndex);

        return (extraData, false);
    }

    function onRoundEnd(EffectContext calldata ctx, uint256, bytes32 extraData, uint256, uint256)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        uint256 playerIndex = uint256(extraData);
        uint256 duration = getDuration(ctx.battleKey, playerIndex);
        if (duration == 1) {
            return (extraData, true);
        } else {
            setDuration(duration - 1, playerIndex);
            return (extraData, false);
        }
    }

    function onMonSwitchIn(EffectContext calldata, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        uint256 playerIndex = uint256(extraData);
        // Apply stat change to the mon on the team of the player who summoned Overclock
        if (targetIndex == playerIndex) {
            _applyStatChange(targetIndex, monIndex);
        }
        return (extraData, false);
    }

    function onRemove(bytes32 extraData, uint256, uint256) external override {
        uint256 playerIndex = uint256(extraData);
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[playerIndex];
        // Reset stat changes from the mon on the team of the player who summoned Overclock
        _removeStatChange(playerIndex, activeMonIndex);
        // Clear the duration when we clear the effect
        setDuration(0, playerIndex);
    }
}


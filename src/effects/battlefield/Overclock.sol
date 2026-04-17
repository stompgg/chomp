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

    StatBoosts immutable STAT_BOOST;

    constructor(StatBoosts _STAT_BOOSTS) {
        STAT_BOOST = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Overclock";
    }

    // Steps: OnApply, RoundEnd, OnRemove, OnMonSwitchIn
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x801D;
    }

    function _effectKey(uint256 playerIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, name()))));
    }

    function applyOverclock(IEngine engine, bytes32 battleKey, uint256 playerIndex) public {
        // Check if we have an active Overclock effect
        uint256 duration = getDuration(engine, battleKey, playerIndex);
        if (duration == 0) {
            // If not, add the effect to the global effects array
            engine.addEffect(2, playerIndex, IEffect(address(this)), bytes32(playerIndex));
        } else {
            // Otherwise, reset the duration
            setDuration(engine, DEFAULT_DURATION, playerIndex);
        }
    }

    function getDuration(IEngine engine, bytes32 battleKey, uint256 playerIndex) public view returns (uint256) {
        return uint256(engine.getGlobalKV(battleKey, _effectKey(playerIndex)));
    }

    function setDuration(IEngine engine, uint256 newDuration, uint256 playerIndex) public {
        engine.setGlobalKV(_effectKey(playerIndex), uint192(newDuration));
    }

    function _applyStatChange(IEngine engine, uint256 playerIndex, uint256 monIndex) internal {
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
        STAT_BOOST.addStatBoosts(engine, playerIndex, monIndex, statBoosts, StatBoostFlag.Temp);
    }

    function _removeStatChange(IEngine engine, uint256 playerIndex, uint256 monIndex) internal {
        // Reset stat boosts (speed buff / sp def debuff)
        STAT_BOOST.removeStatBoosts(engine, playerIndex, monIndex, StatBoostFlag.Temp);
    }

    function onApply(
        IEngine engine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256,
        uint256,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        uint256 playerIndex = uint256(extraData);

        // Set default duration
        setDuration(engine, DEFAULT_DURATION, playerIndex);

        // Apply stat change to the team of the player who summoned Overclock
        uint256 activeMonIndex = playerIndex == 0 ? p0ActiveMonIndex : p1ActiveMonIndex;
        _applyStatChange(engine, playerIndex, activeMonIndex);

        return (extraData, false);
    }

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256,
        uint256,
        uint256,
        uint256
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        uint256 playerIndex = uint256(extraData);
        uint256 duration = getDuration(engine, battleKey, playerIndex);
        if (duration == 1) {
            return (extraData, true);
        } else {
            setDuration(engine, duration - 1, playerIndex);
            return (extraData, false);
        }
    }

    function onMonSwitchIn(
        IEngine engine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    ) external override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        uint256 playerIndex = uint256(extraData);
        // Apply stat change to the mon on the team of the player who summoned Overclock
        if (targetIndex == playerIndex) {
            _applyStatChange(engine, targetIndex, monIndex);
        }
        return (extraData, false);
    }

    function onRoundStart(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        return (extraData, false);
    }

    function onRemove(
        IEngine engine,
        bytes32,
        bytes32 extraData,
        uint256,
        uint256,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) external override {
        uint256 playerIndex = uint256(extraData);
        uint256 activeMonIndex = playerIndex == 0 ? p0ActiveMonIndex : p1ActiveMonIndex;
        // Reset stat changes from the mon on the team of the player who summoned Overclock
        _removeStatChange(engine, playerIndex, activeMonIndex);
        // Clear the duration when we clear the effect
        setDuration(engine, 0, playerIndex);
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";
import {IEffect} from "../../src/effects/IEffect.sol";

/// @notice Test journal for 2-slot ordering: attach as every mon's ability; it self-registers
///         as a per-mon effect and appends (step, side, mon) to `entries` at RoundStart,
///         RoundEnd, and AfterMove — so tests can assert exact action / effect-pass order.
contract OrderRecorderAbility is IAbility, BasicEffect {
    // entry = (uint8(step) << 16) | (side << 8) | monIndex
    uint256[] public entries;

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Order Recorder";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        (bool exists,,) = engine.getEffectData(battleKey, playerIndex, monIndex, address(this));
        if (!exists) {
            engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
        }
    }

    function getStepsBitmap() external pure override returns (uint32) {
        return uint16(
            ALWAYS_APPLIES_BIT | (1 << uint8(EffectStep.RoundStart)) | (1 << uint8(EffectStep.RoundEnd))
                | (1 << uint8(EffectStep.AfterMove))
        );
    }

    function _record(EffectStep step, uint256 targetIndex, uint256 monIndex) private {
        entries.push((uint256(uint8(step)) << 16) | (targetIndex << 8) | monIndex);
    }

    function onRoundStart(IEngine, bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256)
        external
        override
        returns (bytes32, bool)
    {
        _record(EffectStep.RoundStart, targetIndex, monIndex);
        return (extraData, false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256)
        external
        override
        returns (bytes32, bool)
    {
        _record(EffectStep.RoundEnd, targetIndex, monIndex);
        return (extraData, false);
    }

    function onAfterMove(IEngine, bytes32, uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex, uint256)
        external
        override
        returns (bytes32, bool)
    {
        _record(EffectStep.AfterMove, targetIndex, monIndex);
        return (extraData, false);
    }

    function count() external view returns (uint256) {
        return entries.length;
    }

    function entryAt(uint256 i) external view returns (EffectStep step, uint256 side, uint256 monIndex) {
        uint256 e = entries[i];
        return (EffectStep(uint8(e >> 16)), (e >> 8) & 0xFF, e & 0xFF);
    }

    function clear() external {
        delete entries;
    }
}

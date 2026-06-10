// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../BasicEffect.sol";
import {IEffect} from "../IEffect.sol";

contract Overclock is BasicEffect {
    uint256 public constant DEFAULT_DURATION = 3;

    uint8 public constant SPEED_PERCENT = 25;
    uint8 public constant SP_DEF_PERCENT = 25;

    function name() public pure override returns (string memory) {
        return "Overclock";
    }

    // Steps: OnApply, RoundEnd, OnRemove, OnMonSwitchIn
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x801D;
    }

    // ----- extraData layout -----
    // The countdown lives in the effect's OWN extraData — which the engine already threads
    // through every hook and persists for free via _updateOrRemoveEffect — instead of a globalKV
    // entry (whose first write per battle costs a key-buffer append + a fresh nonzero word,
    // ~13-48k, plus a getDuration/setDuration round-trip pair every active round).
    //   bits 0-7  playerIndex (the side that summoned Overclock)
    //   bits 8-15 remaining duration in rounds
    // NOTE: MegaStarBlast._checkForOverclock reads this layout raw (masks the player byte) —
    // the two contracts must ship together.
    uint256 private constant DURATION_SHIFT = 8;

    function _pack(uint256 playerIndex, uint256 duration) internal pure returns (bytes32) {
        return bytes32(playerIndex | (duration << DURATION_SHIFT));
    }

    function _playerOf(bytes32 data) internal pure returns (uint256) {
        return uint256(data) & 0xFF;
    }

    function _durationOf(bytes32 data) internal pure returns (uint256) {
        return uint256(data) >> DURATION_SHIFT;
    }

    function applyOverclock(IEngine engine, bytes32 battleKey, uint256 playerIndex) public {
        // Two instances can coexist (one per player), so the already-active check scans for
        // address AND player — the address-keyed getEffectData getter would be ambiguous here.
        (EffectInstance[] memory effects, uint256[] memory indices) = engine.getEffects(battleKey, 2, 2);
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this) && _playerOf(effects[i].data) == playerIndex) {
                // Already active: reset the countdown in place.
                engine.editEffect(2, indices[i], _pack(playerIndex, DEFAULT_DURATION));
                return;
            }
        }
        engine.addEffect(2, playerIndex, IEffect(address(this)), bytes32(playerIndex));
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
        engine.addStatBoost(playerIndex, monIndex, statBoosts, StatBoostFlag.Temp);
    }

    function _removeStatChange(IEngine engine, uint256 playerIndex, uint256 monIndex) internal {
        // Reset stat boosts (speed buff / sp def debuff)
        engine.removeStatBoost(playerIndex, monIndex, StatBoostFlag.Temp);
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

        // Apply stat change to the team of the player who summoned Overclock
        uint256 activeMonIndex = playerIndex == 0 ? p0ActiveMonIndex : p1ActiveMonIndex;
        _applyStatChange(engine, playerIndex, activeMonIndex);

        // The returned extraData is what the engine stores: countdown starts here.
        return (_pack(playerIndex, DEFAULT_DURATION), false);
    }

    function onRoundEnd(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Tick the countdown in extraData — zero engine calls; the engine persists the returned
        // value (or runs onRemove when we signal removal).
        uint256 duration = _durationOf(extraData);
        if (duration <= 1) {
            return (extraData, true);
        }
        return (_pack(_playerOf(extraData), duration - 1), false);
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
        uint256 playerIndex = _playerOf(extraData);
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
        uint256 playerIndex = _playerOf(extraData);
        uint256 activeMonIndex = playerIndex == 0 ? p0ActiveMonIndex : p1ActiveMonIndex;
        // Reset stat changes from the mon on the team of the player who summoned Overclock.
        // (No KV cleanup — the countdown lives in this effect's extraData, which dies with it.)
        _removeStatChange(engine, playerIndex, activeMonIndex);
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../Enums.sol";
import "../../Structs.sol";

import {DEFAULT_ACCURACY, DEFAULT_VOL} from "../../Constants.sol";
import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../BasicEffect.sol";
import {IEffect} from "../IEffect.sol";

/// @notice Battlefield storm: damages every active at end of round for a fixed number of rounds.
///         Damage runs the normal formula off the summoner's stats, so it tracks their buffs and
///         debuffs and keeps resolving after they leave the field.
contract Storm is BasicEffect {
    uint256 public constant DEFAULT_DURATION = 7;
    uint32 public constant BASE_POWER = 50;

    // Every absolute slot; the engine skips empty lanes and KO'd mons.
    uint256 private constant ALL_SLOTS = 0xF;

    // extraData: [duration 0-7 | casterPlayerIndex 8-15 | casterMonIndex 16-23]
    uint256 private constant CASTER_SIDE_SHIFT = 8;
    uint256 private constant CASTER_MON_SHIFT = 16;

    // Steps: RoundEnd. No OnApply — applyStorm packs the initial extraData itself, and addEffect
    // stores it verbatim when the bit is clear.
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x8004;
    }

    function _pack(uint256 duration, uint256 casterSide, uint256 casterMon) internal pure returns (bytes32) {
        return bytes32(duration | (casterSide << CASTER_SIDE_SHIFT) | (casterMon << CASTER_MON_SHIFT));
    }

    function _durationOf(bytes32 data) internal pure returns (uint256) {
        return uint256(data) & 0xFF;
    }

    function _casterSideOf(bytes32 data) internal pure returns (uint256) {
        return (uint256(data) >> CASTER_SIDE_SHIFT) & 0xFF;
    }

    function _casterMonOf(bytes32 data) internal pure returns (uint256) {
        return (uint256(data) >> CASTER_MON_SHIFT) & 0xFF;
    }

    /// @notice Summons the storm, or re-latches it to this caster and resets the clock if one is
    ///         already up. Exactly one storm and one latched caster exist at a time.
    function applyStorm(IEngine engine, bytes32 battleKey, uint256 casterSide, uint256 casterMon) external {
        bytes32 packed = _pack(DEFAULT_DURATION, casterSide, casterMon);
        (bool exists, uint256 effectIndex,) = engine.getEffectData(battleKey, 2, 2, address(this));
        if (exists) {
            engine.editEffect(2, effectIndex, packed);
            return;
        }
        engine.addEffect(2, 0, IEffect(address(this)), packed);
    }

    function onRoundEnd(IEngine engine, bytes32, uint256 rng, bytes32 extraData, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        engine.dispatchCustomAttackMulti(
            _casterSideOf(extraData),
            _casterMonOf(extraData),
            ALL_SLOTS,
            BASE_POWER,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            Type.Lightning,
            MoveClass.Special,
            rng,
            0
        );

        uint256 duration = _durationOf(extraData);
        if (duration <= 1) {
            return (extraData, true);
        }
        return (_pack(duration - 1, _casterSideOf(extraData), _casterMonOf(extraData)), false);
    }
}

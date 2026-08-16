// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {MoveMeta} from "../../Structs.sol";
import {Storm} from "../../effects/battlefield/Storm.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

/// @notice Hits harder and chills more reliably while a Storm is on the field.
contract CloudStrike is IMoveSet {
    uint32 public constant BASE_POWER = 70;
    uint32 public constant STORM_BASE_POWER = 100;
    uint8 public constant EFFECT_ACCURACY = 10;
    uint8 public constant STORM_EFFECT_ACCURACY = 30;

    Storm immutable STORM;
    IEffect immutable FROSTBITE_STATUS;

    constructor(Storm _STORM, IEffect _FROSTBITE_STATUS) {
        STORM = _STORM;
        FROSTBITE_STATUS = _FROSTBITE_STATUS;
    }

    /// @dev Storm is battle-unique, so the address-keyed lookup is unambiguous — no scan of the
    ///      global list needed.
    function _stormIsUp(IEngine engine, bytes32 battleKey) internal view returns (bool) {
        (bool exists,,) = engine.getEffectData(battleKey, 2, 2, address(STORM));
        return exists;
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256,
        uint16,
        uint256 rng
    ) external {
        bool stormIsUp = _stormIsUp(engine, battleKey);
        engine.dispatchStandardAttack(
            attackerPlayerIndex,
            attackerMonIndex,
            targetBits,
            stormIsUp ? STORM_BASE_POWER : BASE_POWER,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            Type.Ice,
            MoveClass.Special,
            DEFAULT_CRIT_RATE,
            stormIsUp ? STORM_EFFECT_ACCURACY : EFFECT_ACCURACY,
            FROSTBITE_STATUS,
            rng
        );
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Ice;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: _stormIsUp(engine, battleKey) ? STORM_BASE_POWER : BASE_POWER
        });
    }
}

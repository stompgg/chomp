// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {DEFAULT_ACCURACY, DEFAULT_CRIT_RATE, DEFAULT_PRIORITY, DEFAULT_VOL} from "../../Constants.sol";
import {ExtraDataType, MoveClass, Type} from "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract ModalBolt is IMoveSet {
    uint32 public constant BASE_POWER = 90;
    uint8 public constant EFFECT_ACCURACY = 20;

    uint16 public constant MODE_FIRE = 0;
    uint16 public constant MODE_ICE = 1;
    uint16 public constant MODE_LIGHTNING = 2;

    IEffect immutable BURN_STATUS;
    IEffect immutable FROSTBITE_STATUS;
    IEffect immutable ZAP_STATUS;

    constructor(IEffect _BURN_STATUS, IEffect _FROSTBITE_STATUS, IEffect _ZAP_STATUS) {
        BURN_STATUS = _BURN_STATUS;
        FROSTBITE_STATUS = _FROSTBITE_STATUS;
        ZAP_STATUS = _ZAP_STATUS;
    }

    function name() public pure returns (string memory) {
        return "Modal Bolt";
    }

    function _modalKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode("ModalBolt", playerIndex, monIndex))));
    }

    function getUsedModes(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        external
        view
        returns (uint8)
    {
        return uint8(uint256(engine.getGlobalKV(battleKey, _modalKey(playerIndex, monIndex))) & 0x7);
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderMonIndex,
        uint16 extraData,
        uint256 rng
    ) external {
        if (extraData > MODE_LIGHTNING) {
            return;
        }
        uint64 key = _modalKey(attackerPlayerIndex, attackerMonIndex);
        uint256 used = uint256(engine.getGlobalKV(battleKey, key));
        uint256 mask = 1 << extraData;
        if ((used & mask) != 0) {
            return;
        }

        Type t;
        IEffect status;
        if (extraData == MODE_FIRE) {
            t = Type.Fire;
            status = BURN_STATUS;
        } else if (extraData == MODE_ICE) {
            t = Type.Ice;
            status = FROSTBITE_STATUS;
        } else {
            t = Type.Lightning;
            status = ZAP_STATUS;
        }

        engine.dispatchStandardAttack(
            attackerPlayerIndex,
            defenderMonIndex,
            BASE_POWER,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            t,
            MoveClass.Special,
            DEFAULT_CRIT_RATE,
            EFFECT_ACCURACY,
            status,
            rng
        );

        engine.setGlobalKV(key, uint192(used | mask));
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 3;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    /// @dev Validator-time type. Actual dispatched attack uses the picked mode's type.
    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Math;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function isValidTarget(IEngine, bytes32, uint16 extraData) external pure returns (bool) {
        return extraData <= MODE_LIGHTNING;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: BASE_POWER
        });
    }
}

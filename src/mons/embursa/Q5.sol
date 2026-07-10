// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {MoveMeta} from "../../Structs.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {HeatBeaconLib} from "./HeatBeaconLib.sol";

contract Q5 is IMoveSet, BasicEffect {
    uint256 public constant DELAY = 5;
    uint32 public constant BASE_POWER = 150;

    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(ITypeCalculator _TYPE_CALCULATOR) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Q5";
    }

    function _packExtraData(
        uint256 turnCount,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetSlot
    ) internal pure returns (bytes32) {
        return bytes32((turnCount << 128) | (attackerMonIndex << 72) | (targetSlot << 64) | attackerPlayerIndex);
    }

    function _unpackExtraData(bytes32 data)
        internal
        pure
        returns (uint256 turnCount, uint256 attackerPlayerIndex, uint256 attackerMonIndex, uint256 targetSlot)
    {
        turnCount = uint256(data) >> 128;
        attackerMonIndex = (uint256(data) >> 72) & 0xFF;
        targetSlot = (uint256(data) >> 64) & 0xFF;
        attackerPlayerIndex = uint256(data) & type(uint64).max;
    }

    // Per-side (no monIndex) so only one Q5 can be queued per side at a time, unique across mons.
    function _q5GuardKey(uint256 attackerPlayerIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(attackerPlayerIndex, "Q5_ACTIVE"))));
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        // Arm against the slot this cast aimed at (slot-bound, D3: a later switch redirects
        // the blast onto the occupant, never onto a different slot).
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return;
        }
        // One active Q5 bomb per side at a time (recastable once the previous one detonates).
        uint64 guardKey = _q5GuardKey(attackerPlayerIndex);
        if (engine.getGlobalKV(battleKey, guardKey) != 0) {
            return;
        }
        engine.setGlobalKV(guardKey, 1);
        // The bomb detonates with the casting mon's stats, even if it has since left the field.
        engine.addEffect(
            2, attackerPlayerIndex, this, _packExtraData(1, attackerPlayerIndex, attackerMonIndex, targetSlot)
        );

        // Clear the priority boost
        if (HeatBeaconLib._getPriorityBoost(engine, battleKey, attackerPlayerIndex) == 1) {
            HeatBeaconLib._clearPriorityBoost(engine, attackerPlayerIndex);
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex) public view returns (uint32) {
        return DEFAULT_PRIORITY + HeatBeaconLib._getPriorityBoost(engine, battleKey, attackerPlayerIndex);
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Fire;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    // Effect implementation
    // Steps: RoundStart
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8002;
    }

    function onRoundStart(IEngine engine, bytes32 battleKey, uint256 rng, bytes32 extraData, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        (uint256 turnCount, uint256 attackerPlayerIndex, uint256 attackerMonIndex, uint256 targetSlot) =
            _unpackExtraData(extraData);
        if (turnCount == DELAY) {
            // Deal damage
            AttackCalculator._calculateDamage(
                engine,
                TYPE_CALCULATOR,
                battleKey,
                attackerPlayerIndex,
                attackerMonIndex,
                uint256(1) << targetSlot,
                BASE_POWER,
                DEFAULT_ACCURACY,
                DEFAULT_VOL,
                moveType(engine, battleKey),
                moveClass(engine, battleKey),
                rng,
                DEFAULT_CRIT_RATE
            );
            // Free the side's Q5 slot so a new bomb can be queued.
            engine.setGlobalKV(_q5GuardKey(attackerPlayerIndex), 0);
            return (extraData, true);
        } else {
            return (_packExtraData(turnCount + 1, attackerPlayerIndex, attackerMonIndex, targetSlot), false);
        }
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
            basePower: 0
        });
    }
}

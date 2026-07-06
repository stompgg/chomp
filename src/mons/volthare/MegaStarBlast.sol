// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {EffectInstance, MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract MegaStarBlast is IMoveSet {
    uint32 public constant BASE_ACCURACY = 60;
    uint32 public constant ZAP_ACCURACY = 30;
    uint32 public constant BASE_POWER = 150;

    ITypeCalculator immutable TYPE_CALCULATOR;
    IEffect immutable ZAP_STATUS;
    IEffect immutable OVERCLOCK;

    constructor(ITypeCalculator _TYPE_CALCULATOR, IEffect _ZAP_STATUS, IEffect _OVERCLOCK) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        ZAP_STATUS = _ZAP_STATUS;
        OVERCLOCK = _OVERCLOCK;
    }

    function name() public pure override returns (string memory) {
        return "Mega Star Blast";
    }

    function _checkForOverclock(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex)
        internal
        view
        returns (int32)
    {
        // Check all global effects to see if Overclock is active and the player index matches
        (EffectInstance[] memory effects, uint256[] memory indices) = engine.getEffects(battleKey, 2, 2);
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == address(OVERCLOCK)) {
                bytes32 effectData = effects[i].data;
                // Overclock packs [duration << 8 | playerIndex] into its extraData — mask the
                // player byte (raw equality would never match once the countdown is nonzero).
                if ((uint256(effectData) & 0xFF) == attackerPlayerIndex) {
                    return int32(int256(indices[i]));
                }
            }
        }
        return -1;
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256 rng
    ) external {
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) return; // no chosen target (defensive; the engine fizzles first)
        uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
        // Check if Overclock is active
        uint32 acc = BASE_ACCURACY;
        int32 overclockIndex = _checkForOverclock(engine, battleKey, attackerPlayerIndex);
        if (overclockIndex >= 0) {
            // Remove Overclock
            engine.removeEffect(2, 2, uint256(uint32(overclockIndex)));
            // Upgrade accuracy
            acc = 100;
        }
        // Deal damage
        (int32 damage,) = AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            targetBits,
            BASE_POWER,
            acc,
            DEFAULT_VOL,
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
        // Apply Zap if rng allows. Mix in attacker player index to break symmetry on mirror matchups.
        if (damage > 0) {
            uint256 rng2 = uint256(keccak256(abi.encode(rng, attackerPlayerIndex, "ZAP")));
            if (rng2 % 100 < ZAP_ACCURACY) {
                engine.addEffect(defenderPlayerIndex, defenderMonIndex, ZAP_STATUS, "");
            }
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 3;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY + 2;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Lightning;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            targetSpec: TargetSpec.AnyOtherSlot,
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}

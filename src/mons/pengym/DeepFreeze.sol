// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import { EffectInstance, MoveMeta } from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract DeepFreeze is IMoveSet {
    uint32 public constant BASE_POWER = 90;

    IEffect immutable FROSTBITE;
    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(ITypeCalculator _TYPE_CALCULATOR, IEffect _FROSTBITE_STATUS) {
        FROSTBITE = _FROSTBITE_STATUS;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override returns (string memory) {
        return "Deep Freeze";
    }

    function _frostbiteExists(IEngine engine, bytes32 battleKey, uint256 targetIndex, uint256 monIndex) internal view returns (int32) {
        (EffectInstance[] memory effects, uint256[] memory indices) = engine.getEffects(battleKey, targetIndex, monIndex);
        uint256 numEffects = effects.length;
        for (uint256 i; i < numEffects;) {
            if (address(effects[i].effect) == address(FROSTBITE)) {
                return int32(int256(indices[i]));
            }
            unchecked {
                ++i;
            }
        }
        return -1;
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 defenderMonIndex,
        uint240,
        uint256 rng
    ) external {
        uint256 otherPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint32 damageToDeal = BASE_POWER;
        int32 frostbiteIndex = _frostbiteExists(engine, battleKey, otherPlayerIndex, defenderMonIndex);
        // Remove frostbite if it exists, and double the damage dealt
        if (frostbiteIndex != -1) {
            engine.removeEffect(otherPlayerIndex, defenderMonIndex, uint256(uint32(frostbiteIndex)));
            damageToDeal = damageToDeal * 2;
        }
        // Deal damage
        AttackCalculator._calculateDamage(
            engine,
            TYPE_CALCULATOR,
            battleKey,
            attackerPlayerIndex,
            damageToDeal,
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            rng,
            DEFAULT_CRIT_RATE
        );
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 3;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Ice;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
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
            basePower: 0
        });
    }

}

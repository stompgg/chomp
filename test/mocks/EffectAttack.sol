// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {TargetLib} from "../../src/lib/TargetLib.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

contract EffectAttack is IMoveSet {
    struct Args {
        Type TYPE;
        uint32 STAMINA_COST;
        uint32 PRIORITY;
    }

    IEffect immutable EFFECT;
    Type immutable TYPE;
    uint32 immutable STAMINA_COST;
    uint32 immutable PRIORITY;

    constructor(IEffect _EFFECT, Args memory args) {
        EFFECT = _EFFECT;
        TYPE = args.TYPE;
        STAMINA_COST = args.STAMINA_COST;
        PRIORITY = args.PRIORITY;
    }

    function name() external pure returns (string memory) {
        return "Effect Attack";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, TargetLib.lowestSlot(targetBits));
        uint256 targetIndex = (attackerPlayerIndex + 1) % 2;
        engine.addEffect(targetIndex, defenderMonIndex, EFFECT, bytes32(0));
    }

    function priority(IEngine, bytes32, uint256) public view returns (uint32) {
        return PRIORITY;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public view returns (uint32) {
        return STAMINA_COST;
    }

    function moveType(IEngine, bytes32) public view returns (Type) {
        return TYPE;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function basePower(bytes32) external pure returns (uint32) {
        return 0;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
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

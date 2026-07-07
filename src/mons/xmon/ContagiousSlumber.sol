// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {MoveMeta} from "../../Structs.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract ContagiousSlumber is IMoveSet {
    IEffect immutable SLEEP_STATUS;

    constructor(IEffect _SLEEP_STATUS) {
        SLEEP_STATUS = _SLEEP_STATUS;
    }

    function name() public pure override returns (string memory) {
        return "Contagious Slumber";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256 activesPacked,
        uint16,
        uint256
    ) external {
        uint256 targetSlot = TargetLib.lowestSlot(targetBits);
        if (targetSlot == NO_SLOT) {
            return; // no chosen target (defensive; the engine fizzles first)
        }
        uint256 defenderPlayerIndex = TargetLib.sideOf(targetSlot);
        uint256 defenderMonIndex = TargetLib.activeAt(activesPacked, targetSlot);
        // Apply sleep to self
        engine.addEffect(attackerPlayerIndex, attackerMonIndex, SLEEP_STATUS, "");

        // Apply sleep to opponent
        engine.addEffect(defenderPlayerIndex, defenderMonIndex, SLEEP_STATUS, "");
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Cosmic;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Other;
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

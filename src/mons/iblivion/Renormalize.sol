// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

import {MoveMeta} from "../../Structs.sol";
import {Baselight} from "./Baselight.sol";
import {Loop} from "./Loop.sol";

contract Renormalize is IMoveSet {
    Baselight immutable BASELIGHT;
    Loop immutable LOOP;

    constructor(Baselight _BASELIGHT, Loop _LOOP) {
        BASELIGHT = _BASELIGHT;
        LOOP = _LOOP;
    }

    function name() public pure override returns (string memory) {
        return "Renormalize";
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
        // Set Baselight level to 3
        BASELIGHT.setBaselightLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex, 3);

        // Clear Loop active flag so Loop can be used again
        LOOP.clearLoopActive(engine, battleKey, attackerPlayerIndex, attackerMonIndex);

        // Clear all StatBoost effects and reset stats to base values
        engine.clearAllStatBoosts(attackerPlayerIndex, attackerMonIndex);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY - 1;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Yang;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
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

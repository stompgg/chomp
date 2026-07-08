// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {MoveMeta} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract Sanctify is IMoveSet {
    // Deployed BlessedStatus singleton, injected at deploy time (env BLESSED_STATUS).
    IEffect immutable BLESSED_STATUS;

    constructor(IEffect _BLESSED_STATUS) {
        BLESSED_STATUS = _BLESSED_STATUS;
    }

    function name() public pure override returns (string memory) {
        return "Sanctify";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 targetBits,
        uint256 activesPacked,
        uint16 extraData,
        uint256
    ) external {
        // extraData contains the target team index as raw uint16.
        uint256 targetMonIndex = uint256(extraData);

        // Bless the targeted team member. addEffect runs BlessedStatus.shouldApply, which no-ops if
        // that mon already carries a status condition (one status per mon).
        engine.addEffect(attackerPlayerIndex, targetMonIndex, BLESSED_STATUS, bytes32(0));
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Faith;
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
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}

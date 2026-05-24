// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";

import {BasicEffect} from "../../src/effects/BasicEffect.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {MoveMeta} from "../../src/Structs.sol";

/// @notice Test move + effect hybrid that drives the new write-side APIs from inside an Engine
///         execute() so the write context is active. Encodes the action it should take in
///         `extraData` so a single mon's "move" can be reused across multiple test cases:
///
///         bits 0..1 = op
///           0: noop
///           1: addEffectIfNotPresent(player=self, mon=self, IEffect(this), data=0)
///              → writes returned `added` bool into globalKV key OP_ADD_RESULT
///           2: getAndInitGlobalKV(key=KV_KEY, valueIfZero=42)
///              → writes returned previousValue into globalKV key OP_KV_RESULT
///         bits 2..15 = unused
contract MockNewAPIMove is IMoveSet, BasicEffect {
    uint64 internal constant OP_ADD_RESULT = 2001;
    uint64 internal constant OP_KV_RESULT = 2002;
    uint64 internal constant KV_KEY = 2003;

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "MockNewAPI";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256 attackerMonIndex, uint256, uint16 extraData, uint256)
        external
    {
        uint8 op = uint8(extraData & 0x3);
        if (op == 1) {
            bool added = engine.addEffectIfNotPresent(
                attackerPlayerIndex, attackerMonIndex, IEffect(address(this)), bytes32(0)
            );
            engine.setGlobalKV(OP_ADD_RESULT, added ? uint192(1) : uint192(0));
        } else if (op == 2) {
            uint192 prev = engine.getAndInitGlobalKV(KV_KEY, 42);
            engine.setGlobalKV(OP_KV_RESULT, prev);
        }
    }

    // -------- IMoveSet boilerplate --------

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.None;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
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

    // -------- BasicEffect: needs to be addable as an effect by the move above --------

    function getStepsBitmap() external pure override returns (uint16) {
        return 0; // No active steps; only existence matters for the dedup test.
    }
}

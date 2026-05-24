// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";

import {BasicEffect} from "../../src/effects/BasicEffect.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {MoveMeta} from "../../src/Structs.sol";

/// @notice Test move + effect hybrid that drives the new write-side API from inside an Engine
///         execute() so the write context is active. extraData==1 triggers an
///         addEffectIfNotPresent call against self, and the returned `added` bool is
///         written into globalKV key OP_ADD_RESULT for the test to read back.
contract MockNewAPIMove is IMoveSet, BasicEffect {
    uint64 internal constant OP_ADD_RESULT = 2001;

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "MockNewAPI";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256 attackerMonIndex, uint256, uint16 extraData, uint256)
        external
    {
        if (extraData == 1) {
            bool added = engine.addEffectIfNotPresent(
                attackerPlayerIndex, attackerMonIndex, IEffect(address(this)), bytes32(0)
            );
            engine.setGlobalKV(OP_ADD_RESULT, added ? uint192(1) : uint192(0));
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

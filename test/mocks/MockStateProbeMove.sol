// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {MoveMeta} from "../../src/Structs.sol";

/// @notice Test-only move that probes the opponent's MonState mid-flow and records what it
///         reads into `globalKV`. Used by the batched shadow-correctness tests: if mid-batch
///         shadow routing breaks, the probe will record a stale storage value instead of the
///         post-prior-sub-turn shadow value.
///
///         extraData layout (16 bits):
///           bits 0..7  = which field to probe (matches MonStateIndexName enum value)
///           bits 8..15 = unused
///
///         The probe always targets the opponent's active mon (player index = 1 - attacker).
///         Reads `getMonStateForBattle(...)` (which routes through the shadow stack just like
///         the internal helpers do), casts to int192, and writes to `setGlobalKV(PROBE_KEY, ...)`.
contract MockStateProbeMove is IMoveSet {
    uint64 internal constant PROBE_KEY = 9001;

    function name() external pure returns (string memory) {
        return "MockStateProbe";
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 defenderMonIndex,
        uint16 extraData,
        uint256
    ) external {
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        MonStateIndexName field = MonStateIndexName(uint8(extraData & 0xFF));
        int32 value = engine.getMonStateForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, field);
        // Cast to int192 then uint192 (preserves negative values bit-for-bit in two's complement)
        engine.setGlobalKV(PROBE_KEY, uint192(int192(value)));
    }

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
}

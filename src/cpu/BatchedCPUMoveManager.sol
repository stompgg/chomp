// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {IMatchmaker} from "../matchmaker/IMatchmaker.sol";

/// @title BatchedCPUMoveManager
/// @notice Single-player batched commit-and-execute manager for CPU-style battles.
///         The "CPU" is a phantom opponent address; ALL decision logic lives off-chain
///         (the player runs the engine locally via the transpiler to pick the CPU's
///         response). On-chain the contract just buffers `(playerMove, cpuMove)` tuples
///         and drains them into `engine.executeBatchedTurns` on demand.
///
/// @dev OPT_PLAN §7 trust model: this works because there's no counterparty to cheat.
///      The player can submit any CPU move she wants; misrepresenting the CPU's "ideal"
///      response just produces a worse experience for the player herself. Since the
///      CPU has no stake, no balance, no opinion, there's nothing to defend against.
///      This eliminates the per-submit `ICPU.calculateMove` STATICCALL, `CPUContext`
///      calldata overhead, salt derivation, and per-turn event that earlier designs
///      paid for — getting per-submit cost to roughly `2 × SSTORE + 1 × getSubmitContext`.
abstract contract BatchedCPUMoveManager is IMatchmaker {
    IEngine internal immutable ENGINE;

    /// @notice Buffer layout matches `SignedCommitManager.moveBuffer` exactly so the engine's
    ///         `executeBatchedTurns` consumes either interchangeably.
    /// @dev [ p0Move (8) | p0Extra (16) | p0Salt (104) | p1Move (8) | p1Extra (16) | p1Salt (104) ]
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) public moveBuffer;

    /// @notice [ numExecuted (64) | numBuffered (64) | lastSubmitTimestamp (64) ]
    mapping(bytes32 storageKey => uint256) public bufferCounters;

    event TurnsExecuted(bytes32 indexed battleKey, uint64 startTurn, uint64 count, address winner);

    error NotP0();
    error BattleAlreadyComplete();
    error EmptyBuffer();

    constructor(IEngine engine) {
        ENGINE = engine;

        // Self-register as an approved matchmaker so subclasses' `startBattle` can pass `this`.
        address[] memory self = new address[](1);
        self[0] = address(this);
        address[] memory empty = new address[](0);
        engine.updateMatchmakers(self, empty);
    }

    /// @notice Append one turn to the buffer. The player supplies both her own move AND the
    ///         CPU's move (computed off-chain via the transpiled engine + any strategy she
    ///         wants). See OPT_PLAN §7 for the trust model.
    function submitTurn(
        bytes32 battleKey,
        uint8 playerMove,
        uint16 playerExtra,
        uint104 playerSalt,
        uint8 cpuMove,
        uint16 cpuExtra,
        uint104 cpuSalt
    ) external {
        (address ctxP0,, uint64 ctxTurnId, uint8 ctxWinnerIndex, bytes32 storageKey) =
            ENGINE.getSubmitContext(battleKey);

        if (msg.sender != ctxP0) {
            revert NotP0();
        }
        if (ctxWinnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        // First-of-batch sync: mirror engine's `turnId` into `numExecuted` so a battle that
        // alternates between any single-turn manager and this batched flow stays consistent.
        uint256 packedCounters = bufferCounters[storageKey];
        uint64 numExecuted = uint64(packedCounters);
        uint64 numBuffered = uint64(packedCounters >> 64);
        if (numBuffered == 0) {
            numExecuted = ctxTurnId;
        }
        uint64 nextTurnId = numExecuted + numBuffered;

        moveBuffer[storageKey][nextTurnId] = _packBufferedTurn(
            playerMove, playerExtra, playerSalt, cpuMove, cpuExtra, cpuSalt
        );

        unchecked {
            bufferCounters[storageKey] =
                uint256(numExecuted) | (uint256(numBuffered + 1) << 64) | (uint256(uint64(block.timestamp)) << 128);
        }
    }

    /// @notice Drain the buffer in one tx via `engine.executeBatchedTurns`. Anyone can call —
    ///         the engine's `msg.sender == config.moveManager` check is the only authorization,
    ///         and this contract IS the moveManager for battles started through it.
    function executeBuffered(bytes32 battleKey) external {
        bytes32 storageKey = ENGINE.getStorageKey(battleKey);
        uint256 packedCounters = bufferCounters[storageKey];
        uint64 numExecuted = uint64(packedCounters);
        uint64 numBuffered = uint64(packedCounters >> 64);

        if (numBuffered == 0) {
            revert EmptyBuffer();
        }

        uint256[] memory entries = new uint256[](numBuffered);
        for (uint64 i = 0; i < numBuffered; i++) {
            entries[i] = moveBuffer[storageKey][numExecuted + i];
        }
        (uint64 executedThisBatch, address winner) = ENGINE.executeBatchedTurns(battleKey, entries);

        unchecked {
            bufferCounters[storageKey] =
                uint256(numExecuted + executedThisBatch) | (uint256(0) << 64) | (uint256(uint64(block.timestamp)) << 128);
        }

        emit TurnsExecuted(battleKey, numExecuted, executedThisBatch, winner);

        if (winner != address(0)) {
            _afterBattle(battleKey, ENGINE.getPlayersForBattle(battleKey)[0], winner);
        }
    }

    function getBufferStatus(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint64 numBuffered, uint64 lastSubmitTimestamp)
    {
        uint256 packed = bufferCounters[ENGINE.getStorageKey(battleKey)];
        numExecuted = uint64(packed);
        numBuffered = uint64(packed >> 64);
        lastSubmitTimestamp = uint64(packed >> 128);
    }

    function getBufferedTurn(bytes32 battleKey, uint64 turnId)
        external
        view
        returns (
            uint8 playerMove,
            uint16 playerExtra,
            uint104 playerSalt,
            uint8 cpuMove,
            uint16 cpuExtra,
            uint104 cpuSalt
        )
    {
        return _unpackBufferedTurn(moveBuffer[ENGINE.getStorageKey(battleKey)][turnId]);
    }

    /// @notice IMatchmaker — open match policy. The CPU phantom is whoever the player names
    ///         when starting the battle; no off-chain matching needed.
    function validateMatch(bytes32, address) external pure returns (bool) {
        return true;
    }

    /// @notice Post-execute hook. Fires once at end-of-batch when the battle ends.
    ///         Subclasses override to react (e.g. award points, emit summary events).
    function _afterBattle(bytes32 battleKey, address p0, address winner) internal virtual {}

    // ---------------------------------------------------------------------
    // Packing helpers — bit layout matches `SignedCommitManager` exactly so the engine's
    // `executeBatchedTurns` consumes either buffer interchangeably.
    // ---------------------------------------------------------------------

    function _packBufferedTurn(
        uint8 p0Move,
        uint16 p0Extra,
        uint104 p0Salt,
        uint8 p1Move,
        uint16 p1Extra,
        uint104 p1Salt
    ) internal pure returns (uint256 packed) {
        packed = uint256(p0Move)
            | (uint256(p0Extra) << 8)
            | (uint256(p0Salt) << 24)
            | (uint256(p1Move) << 128)
            | (uint256(p1Extra) << 136)
            | (uint256(p1Salt) << 152);
    }

    function _unpackBufferedTurn(uint256 packed)
        internal
        pure
        returns (
            uint8 p0Move,
            uint16 p0Extra,
            uint104 p0Salt,
            uint8 p1Move,
            uint16 p1Extra,
            uint104 p1Salt
        )
    {
        p0Move = uint8(packed);
        p0Extra = uint16(packed >> 8);
        p0Salt = uint104(packed >> 24);
        p1Move = uint8(packed >> 128);
        p1Extra = uint16(packed >> 136);
        p1Salt = uint104(packed >> 152);
    }
}

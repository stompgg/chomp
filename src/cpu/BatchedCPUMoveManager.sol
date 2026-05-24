// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {IMatchmaker} from "../matchmaker/IMatchmaker.sol";

/// @title BatchedCPUMoveManager
/// @notice Single-player batched commit-and-execute for CPU battles. The "CPU" is a
///         phantom opponent; the player computes its move off-chain (via the transpiled
///         engine) and submits `(playerMove, cpuMove)` tuples to a buffer drained by
///         `engine.executeBatchedTurns`.
/// @dev Works because there's no counterparty to cheat — misrepresenting the CPU's
///      response just gives the player a worse experience. See OPT_PLAN §7. Per-submit
///      cost: ~1 SLOAD + 2 SSTORE (no STATICCALL, no salt, no event).
abstract contract BatchedCPUMoveManager is IMatchmaker {
    IEngine internal immutable ENGINE;

    /// @notice Buffer layout matches `SignedCommitManager.moveBuffer` exactly so the engine's
    ///         `executeBatchedTurns` consumes either interchangeably.
    /// @dev [ p0Move (8) | p0Extra (16) | p0Salt (104) | p1Move (8) | p1Extra (16) | p1Salt (104) ]
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) public moveBuffer;

    /// @notice Per-battle counters + cached `p0` + observed `gameOverFlag` packed into one slot.
    ///         Keyed by `storageKey` so `MappingAllocator` slot reuse keeps writes warm.
    /// @dev Layout (256 bits):
    ///   [0..30]   numExecuted     (uint31)
    ///   [31]      gameOverFlag    (set by `executeBuffered` on game-end)
    ///   [32..63]  numBuffered     (uint32)
    ///   [64..95]  lastSubmitTs    (uint32, year 2106 overflow)
    ///   [96..255] p0              (cached on first submit)
    mapping(bytes32 storageKey => uint256 packed) public bufferState;

    /// @notice battleKey → storageKey cache so subsequent submits skip the engine STATICCALL.
    mapping(bytes32 battleKey => bytes32 storageKey) public storageKeyOf;

    event TurnsExecuted(bytes32 indexed battleKey, uint64 startTurn, uint64 count, address winner);

    error NotP0();
    error BattleAlreadyComplete();
    error EmptyBuffer();

    // Packed-slot bit layout constants
    uint256 private constant NUM_EXECUTED_MASK = (1 << 31) - 1;             // bits [0..30]
    uint256 private constant GAME_OVER_BIT = 1 << 31;                       // bit  [31]
    uint256 private constant NUM_BUFFERED_SHIFT = 32;
    uint256 private constant NUM_BUFFERED_MASK = uint256(type(uint32).max); // 32-bit
    uint256 private constant LAST_TS_SHIFT = 64;
    uint256 private constant LAST_TS_MASK = uint256(type(uint32).max);      // 32-bit
    uint256 private constant P0_SHIFT = 96;
    uint256 private constant P0_MASK = uint256(type(uint160).max);          // 160-bit

    constructor(IEngine engine) {
        ENGINE = engine;

        // Self-register as an approved matchmaker so subclasses' `startBattle` can pass `this`.
        address[] memory self = new address[](1);
        self[0] = address(this);
        address[] memory empty = new address[](0);
        engine.updateMatchmakers(self, empty);
    }

    /// @notice Append one turn to the buffer. Player supplies both her own move AND the CPU's
    ///         (computed off-chain). See OPT_PLAN §7 for the trust model.
    function submitTurn(
        bytes32 battleKey,
        uint8 playerMove,
        uint16 playerExtra,
        uint104 playerSalt,
        uint8 cpuMove,
        uint16 cpuExtra,
        uint104 cpuSalt
    ) external {
        bytes32 storageKey = storageKeyOf[battleKey];
        uint256 packed;
        address ctxP0;
        if (storageKey != bytes32(0)) {
            packed = bufferState[storageKey];
            if (packed & GAME_OVER_BIT != 0) revert BattleAlreadyComplete();
            ctxP0 = address(uint160(packed >> P0_SHIFT));
            if (msg.sender != ctxP0) revert NotP0();
        } else {
            // First submit per battle: one-time STATICCALL to populate caches. Any prior
            // battle's leftover state at this storageKey is intentionally overwritten below.
            uint64 ctxTurnId;
            uint8 ctxWinnerIndex;
            (ctxP0,, ctxTurnId, ctxWinnerIndex, storageKey) = ENGINE.getSubmitContext(battleKey);
            if (msg.sender != ctxP0) revert NotP0();
            if (ctxWinnerIndex != 2) revert BattleAlreadyComplete();
            storageKeyOf[battleKey] = storageKey;
            packed = uint256(ctxTurnId) | (uint256(uint160(ctxP0)) << P0_SHIFT);
        }

        uint64 numExecuted = uint64(packed & NUM_EXECUTED_MASK);
        uint64 numBuffered = uint64((packed >> NUM_BUFFERED_SHIFT) & NUM_BUFFERED_MASK);
        uint64 nextTurnId = numExecuted + numBuffered;

        moveBuffer[storageKey][nextTurnId] = _packBufferedTurn(
            playerMove, playerExtra, playerSalt, cpuMove, cpuExtra, cpuSalt
        );

        unchecked {
            bufferState[storageKey] = uint256(numExecuted)
                | (uint256(numBuffered + 1) << NUM_BUFFERED_SHIFT)
                | (uint256(uint32(block.timestamp)) << LAST_TS_SHIFT)
                | (uint256(uint160(ctxP0)) << P0_SHIFT);
        }
    }

    /// @notice Drain the buffer in one tx via `engine.executeBatchedTurns`. Anyone can call —
    ///         the engine's `msg.sender == config.moveManager` check is the only authorization,
    ///         and this contract IS the moveManager for battles started through it.
    function executeBuffered(bytes32 battleKey) external {
        bytes32 storageKey = storageKeyOf[battleKey];
        if (storageKey == bytes32(0)) storageKey = ENGINE.getStorageKey(battleKey);
        uint256 packed = bufferState[storageKey];
        uint64 numExecuted = uint64(packed & NUM_EXECUTED_MASK);
        uint64 numBuffered = uint64((packed >> NUM_BUFFERED_SHIFT) & NUM_BUFFERED_MASK);

        if (numBuffered == 0) {
            revert EmptyBuffer();
        }

        uint256[] memory entries = new uint256[](numBuffered);
        for (uint64 i = 0; i < numBuffered; i++) {
            entries[i] = moveBuffer[storageKey][numExecuted + i];
        }
        (uint64 executedThisBatch, address winner) = ENGINE.executeBatchedTurns(battleKey, entries);

        unchecked {
            bufferState[storageKey] = uint256(numExecuted + executedThisBatch)
                | (winner != address(0) ? GAME_OVER_BIT : 0)
                | (uint256(uint32(block.timestamp)) << LAST_TS_SHIFT)
                | (packed & (P0_MASK << P0_SHIFT));
        }

        emit TurnsExecuted(battleKey, numExecuted, executedThisBatch, winner);

        if (winner != address(0)) {
            // Cached p0 from the SLOAD above; avoids an extra getPlayersForBattle STATICCALL.
            _afterBattle(battleKey, address(uint160(packed >> P0_SHIFT)), winner);
        }
    }

    function getBufferStatus(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint64 numBuffered, uint64 lastSubmitTimestamp)
    {
        bytes32 storageKey = storageKeyOf[battleKey];
        if (storageKey == bytes32(0)) storageKey = ENGINE.getStorageKey(battleKey);
        uint256 packed = bufferState[storageKey];
        numExecuted = uint64(packed & NUM_EXECUTED_MASK);
        numBuffered = uint64((packed >> NUM_BUFFERED_SHIFT) & NUM_BUFFERED_MASK);
        lastSubmitTimestamp = uint64((packed >> LAST_TS_SHIFT) & LAST_TS_MASK);
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
        bytes32 storageKey = storageKeyOf[battleKey];
        if (storageKey == bytes32(0)) storageKey = ENGINE.getStorageKey(battleKey);
        return _unpackBufferedTurn(moveBuffer[storageKey][turnId]);
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

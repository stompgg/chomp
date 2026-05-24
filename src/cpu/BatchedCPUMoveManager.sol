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
///      paid for — getting per-submit cost to roughly `1 × SLOAD + 2 × SSTORE`.
abstract contract BatchedCPUMoveManager is IMatchmaker {
    IEngine internal immutable ENGINE;

    /// @notice Buffer layout matches `SignedCommitManager.moveBuffer` exactly so the engine's
    ///         `executeBatchedTurns` consumes either interchangeably.
    /// @dev [ p0Move (8) | p0Extra (16) | p0Salt (104) | p1Move (8) | p1Extra (16) | p1Salt (104) ]
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) public moveBuffer;

    /// @notice Combined per-battle slot keyed by `storageKey` (so it benefits from the engine's
    ///         MappingAllocator reuse pattern in steady state). Carries both the counters and a
    ///         cache of the immutable `p0` + an observed `gameOverFlag` — folding what was
    ///         previously a separate `engine.getSubmitContext` STATICCALL per `submitTurn` into
    ///         a single SLOAD of this slot.
    /// @dev Layout (256 bits):
    ///   [0..30]   numExecuted     (uint31, ~2B turns max — plenty)
    ///   [31]      gameOverFlag    (1 bit — set by `executeBuffered` on game-end)
    ///   [32..63]  numBuffered     (uint32)
    ///   [64..95]  lastSubmitTs    (uint32, year 2106 overflow)
    ///   [96..255] p0              (address, 160 bits — cached on first submit)
    mapping(bytes32 storageKey => uint256 packed) public bufferState;

    /// @notice Per-battle storageKey cache. Saves the engine STATICCALL on subsequent submits.
    ///         Keyed by battleKey (storageKey isn't known yet at the start of submit). Cold
    ///         first-touch in production, but the value is immutable per battle so subsequent
    ///         submits in the same tx (impossible today, but logically) would be warm.
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
        // Cache hit path: single SLOAD of bufferState + storageKeyOf gives us p0, gameOver,
        // counters, and storageKey — no engine STATICCALL needed.
        bytes32 storageKey = storageKeyOf[battleKey];
        uint256 packed;
        address ctxP0;
        if (storageKey != bytes32(0)) {
            packed = bufferState[storageKey];
            if (packed & GAME_OVER_BIT != 0) revert BattleAlreadyComplete();
            ctxP0 = address(uint160(packed >> P0_SHIFT));
            if (msg.sender != ctxP0) revert NotP0();
        } else {
            // Cache miss (first submit per battle): one-time STATICCALL to populate caches.
            // Engine's winnerIndex == 2 guard still runs here.
            uint64 ctxTurnId;
            uint8 ctxWinnerIndex;
            (ctxP0,, ctxTurnId, ctxWinnerIndex, storageKey) = ENGINE.getSubmitContext(battleKey);
            if (msg.sender != ctxP0) revert NotP0();
            if (ctxWinnerIndex != 2) revert BattleAlreadyComplete();
            storageKeyOf[battleKey] = storageKey;
            packed = bufferState[storageKey];
            // First-of-batch sync: mirror engine's `turnId` into `numExecuted`. Only happens on
            // cache miss (first submit) so we lazily pick up the engine's current state.
            if ((packed >> NUM_BUFFERED_SHIFT) & NUM_BUFFERED_MASK == 0) {
                // Reset counters carrying the new p0 + clear stale gameOver.
                packed = uint256(ctxTurnId) | (uint256(uint160(ctxP0)) << P0_SHIFT);
            }
        }

        uint64 numExecuted = uint64(packed & NUM_EXECUTED_MASK);
        uint64 numBuffered = uint64((packed >> NUM_BUFFERED_SHIFT) & NUM_BUFFERED_MASK);
        uint64 nextTurnId = numExecuted + numBuffered;

        moveBuffer[storageKey][nextTurnId] = _packBufferedTurn(
            playerMove, playerExtra, playerSalt, cpuMove, cpuExtra, cpuSalt
        );

        unchecked {
            // Update counters: numBuffered++, lastTs=now, keep gameOver=0 (it stays 0 in the
            // submit path), keep p0 from the cached/freshly-set value.
            uint256 newPacked = uint256(numExecuted)
                | (uint256(numBuffered + 1) << NUM_BUFFERED_SHIFT)
                | (uint256(uint32(block.timestamp)) << LAST_TS_SHIFT)
                | (uint256(uint160(ctxP0)) << P0_SHIFT);
            bufferState[storageKey] = newPacked;
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
            // Preserve p0, set gameOver if game ended, advance numExecuted, clear numBuffered.
            uint256 p0Bits = packed & (P0_MASK << P0_SHIFT);
            uint256 newPacked = uint256(numExecuted + executedThisBatch)
                | (winner != address(0) ? GAME_OVER_BIT : 0)
                | (uint256(uint32(block.timestamp)) << LAST_TS_SHIFT)
                | p0Bits;
            bufferState[storageKey] = newPacked;
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

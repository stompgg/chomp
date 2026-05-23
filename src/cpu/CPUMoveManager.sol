// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {ICPU} from "./ICPU.sol";

abstract contract CPUMoveManager {
    IEngine internal immutable ENGINE;

    /// @notice Per-turn buffer slot: same layout as `SignedCommitManager.moveBuffer`. Engine's
    ///         `executeBatchedTurns` consumes this layout via `_unpackBufferedTurn`.
    /// @dev [ p0Move (8) | p0Extra (16) | p0Salt (104) | p1Move (8) | p1Extra (16) | p1Salt (104) ]
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) public moveBuffer;

    /// @notice Packed counters per storageKey: [numExecuted (64) | numBuffered (64) | lastSubmitTs (64)].
    mapping(bytes32 storageKey => uint256) public bufferCounters;

    /// @notice Emitted per `selectMoveWithStateHint` call that triggers a CPU move (flag != 0).
    /// Off-chain replay reconstructs the CPU salt as
    /// `uint104(uint256(keccak256(abi.encode(timestamp, aliceSalt, turnId))))`.
    event CPUTurnSalt(bytes32 indexed battleKey, uint64 indexed turnId, uint40 timestamp);

    /// @notice Emitted at the end of `executeBuffered`. `winner == address(0)` means the battle
    ///         is still ongoing; otherwise it's the winning player's address.
    event TurnsExecuted(bytes32 indexed battleKey, uint64 startTurn, uint64 count, address winner);

    error NotP0();
    error BattleAlreadyComplete();
    error EmptyBuffer();

    constructor(IEngine engine) {
        ENGINE = engine;

        // Self-register as an approved matchmaker
        address[] memory self = new address[](1);
        self[0] = address(this);
        address[] memory empty = new address[](0);
        engine.updateMatchmakers(self, empty);
    }

    // -----------------------------------------------------------------------
    // Legacy single-turn flow (unchanged).
    // -----------------------------------------------------------------------

    function selectMove(bytes32 battleKey, uint8 moveIndex, uint104 salt, uint16 extraData) external {
        // Cheap routing staticcall: one SLOAD for p0 / winnerIndex / playerSwitchForTurnFlag.
        // When the turn is "p0 forced switch" (flag == 0) or the game is already over we return
        // without ever paying for the full CPUContext (which would load team sizes, KO bitmaps,
        // p1's active mon state, and all four move slots — none of which we'd use).
        (address p0, uint8 winnerIndex, uint8 playerSwitchForTurnFlag) = ENGINE.getCPURouteContext(battleKey);

        if (msg.sender != p0) {
            revert NotP0();
        }

        if (winnerIndex != 2) {
            return;
        }

        address winner;
        if (playerSwitchForTurnFlag == 0) {
            winner = ENGINE.executeWithSingleMove(battleKey, moveIndex, salt, extraData);
        } else {
            // P1's turn or both players move: CPU calculates its move. Fetch the full context now.
            CPUContext memory ctx = ENGINE.getCPUContext(battleKey);
            (uint128 cpuMoveIndex, uint16 cpuExtraData) =
                ICPU(address(this)).calculateMove(ctx, moveIndex, extraData);
            // Salt narrows to 104 bits to match the engine's storage; ample for an unpredictable
            // RNG source within the seconds-to-minutes commit-reveal window.
            uint104 p1Salt = uint104(uint256(keccak256(abi.encode(battleKey, msg.sender, block.timestamp))));

            if (playerSwitchForTurnFlag == 1) {
                winner = ENGINE.executeWithSingleMove(battleKey, uint8(cpuMoveIndex), p1Salt, cpuExtraData);
            } else {
                winner = ENGINE.executeWithMoves(
                    battleKey, moveIndex, salt, extraData, uint8(cpuMoveIndex), p1Salt, cpuExtraData
                );
            }
        }

        _afterTurn(battleKey, p0, winner);
    }

    // -----------------------------------------------------------------------
    // Batched flow (OPT_PLAN §7) — trusted-state hint + executeBuffered.
    // -----------------------------------------------------------------------

    /// @notice Append a CPU turn to the buffer. `projectedState` is the post-prior-turn snapshot
    ///         Alice produced locally; the CPU consumes it (calldata only) to pick its move.
    ///         The hint is NOT verified — lying just makes the CPU suboptimal against Alice
    ///         (see OPT_PLAN §7.1), so there's no incentive to cheat.
    /// @dev Mirrors `SignedCommitManager.submitTurnMoves`: writes one packed `uint256` slot to
    ///      `moveBuffer[storageKey][nextTurnId]` and bumps counters. `executeBuffered` later
    ///      drains the buffer via `engine.executeBatchedTurns`.
    function selectMoveWithStateHint(
        bytes32 battleKey,
        uint8 aliceMoveIndex,
        uint16 aliceExtraData,
        uint104 aliceSalt,
        CPUContext calldata projectedState
    ) external {
        (address ctxP0,, uint64 ctxTurnId, uint8 ctxWinnerIndex, bytes32 storageKey) =
            ENGINE.getSubmitContext(battleKey);

        if (msg.sender != ctxP0) {
            revert NotP0();
        }
        if (ctxWinnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        // First-of-batch sync: mirror engine `turnId` into `numExecuted` so legacy↔batched
        // alternation works seamlessly (matches `SignedCommitManager.submitTurnMoves`).
        uint256 packedCounters = bufferCounters[storageKey];
        uint64 numExecuted = uint64(packedCounters);
        uint64 numBuffered = uint64(packedCounters >> 64);
        if (numBuffered == 0) {
            numExecuted = ctxTurnId;
        }
        uint64 nextTurnId = numExecuted + numBuffered;

        // Route on the projected flag. Three cases:
        //   flag == 0: Alice solo (forced switch); CPU side is NO_OP.
        //   flag == 1: CPU solo (forced switch); Alice side is NO_OP, CPU picks via calculateMove.
        //   flag == 2: both move; both halves populated.
        uint8 flag = projectedState.playerSwitchForTurnFlag;
        uint8 cpuMove;
        uint16 cpuExtra;
        uint104 cpuSalt;

        if (flag != 0) {
            (uint128 cpuMoveIdx, uint16 cpuExtraData) =
                ICPU(address(this)).calculateMove(projectedState, aliceMoveIndex, aliceExtraData);
            cpuMove = uint8(cpuMoveIdx);
            cpuExtra = cpuExtraData;
            // Salt formula per OPT_PLAN §7.4. turnId in the hash defends against in-block
            // collisions if Alice submits multiple CPU turns in one tx (rare but possible).
            cpuSalt = uint104(uint256(keccak256(abi.encode(block.timestamp, aliceSalt, nextTurnId))));
            emit CPUTurnSalt(battleKey, nextTurnId, uint40(block.timestamp));
        } else {
            cpuMove = NO_OP_MOVE_INDEX;
        }

        uint256 packed;
        if (flag == 1) {
            // CPU solo: Alice's slot is NO_OP.
            packed = _packBufferedTurn(NO_OP_MOVE_INDEX, 0, 0, cpuMove, cpuExtra, cpuSalt);
        } else {
            packed = _packBufferedTurn(aliceMoveIndex, aliceExtraData, aliceSalt, cpuMove, cpuExtra, cpuSalt);
        }

        moveBuffer[storageKey][nextTurnId] = packed;

        unchecked {
            bufferCounters[storageKey] =
                uint256(numExecuted) | (uint256(numBuffered + 1) << 64) | (uint256(uint64(block.timestamp)) << 128);
        }
    }

    /// @notice Drain the buffer in one tx via `engine.executeBatchedTurns`. Anyone can call —
    ///         the only authorization is the engine's `msg.sender == config.moveManager` check,
    ///         and this contract IS the moveManager for battles started via it.
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

        // Fire _afterTurn on game-over so subclasses can react. Legacy mode fires it per turn;
        // batched mode only has a meaningful state transition at end-of-batch. Subclasses that
        // need per-turn callbacks should stay on legacy `selectMove`.
        if (winner != address(0)) {
            _afterTurn(battleKey, ENGINE.getPlayersForBattle(battleKey)[0], winner);
        }
    }

    /// @notice External view: pending vs cumulatively executed counts.
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

    /// @notice Read a single buffered turn. Returns zero for unset slots.
    function getBufferedTurn(bytes32 battleKey, uint64 turnId)
        external
        view
        returns (
            uint8 p0Move,
            uint16 p0Extra,
            uint104 p0Salt,
            uint8 p1Move,
            uint16 p1Extra,
            uint104 p1Salt
        )
    {
        return _unpackBufferedTurn(moveBuffer[ENGINE.getStorageKey(battleKey)][turnId]);
    }

    /// @notice Post-execute hook. `winner == address(0)` means the battle is still ongoing;
    ///         otherwise it's the winning player's address. Subclasses override to react.
    function _afterTurn(bytes32 battleKey, address p0, address winner) internal virtual {}

    // -----------------------------------------------------------------------
    // Packing helpers — bit layout matches `SignedCommitManager` exactly so the engine's
    // `executeBatchedTurns` can consume either buffer interchangeably.
    // -----------------------------------------------------------------------

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

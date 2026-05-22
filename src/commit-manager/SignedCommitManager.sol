// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {IValidator} from "../IValidator.sol";
import {CommitContext, PlayerDecisionData, TurnSubmission} from "../Structs.sol";
import {ECDSA} from "../lib/ECDSA.sol";
import {EIP712} from "../lib/EIP712.sol";
import {DefaultCommitManager} from "./DefaultCommitManager.sol";
import {SignedCommitLib} from "./SignedCommitLib.sol";

/// @title SignedCommitManager
/// @notice Extends DefaultCommitManager with optimistic dual-signed commit flow
/// @dev Allows both players to sign their moves off-chain, enabling the committer
///      to submit both moves and execute in a single transaction.
///
///      Normal flow (3 transactions):
///        1. Alice commits (TX 1)
///        2. Bob reveals (TX 2)
///        3. Alice reveals (TX 3)
///
///      Dual-signed flow (1 transaction):
///        1. Alice signs her move hash off-chain (SignedCommit), sends to Bob
///        2. Bob signs his move + Alice's hash off-chain (DualSignedReveal), sends back
///        3. Anyone (Alice, Bob, or a relayer) calls executeWithDualSignedMoves with
///           both signatures + Alice's preimage (TX 1)
///
///      Security: Alice commits to her hash before seeing Bob's move (binding Alice
///      cryptographically via her SignedCommit). Bob signs over Alice's hash (binding
///      Bob via his DualSignedReveal). Both signatures together prove both players'
///      intent without trusting msg.sender — submission can be relayed without
///      reopening any unilateral-revealer attack.
///
///      Fallback if Alice stalls: Bob can use commitWithSignature() to publish Alice's
///      signed commitment on-chain, then continue with the normal reveal flow.
///
///      Fallback if Bob doesn't cooperate: Alice can use the normal commitMove() flow.
contract SignedCommitManager is DefaultCommitManager, EIP712 {
    /// @notice Thrown when the signature verification fails
    error InvalidSignature();

    /// @notice Thrown when trying to use dual-signed flow on a single-player turn
    error NotTwoPlayerTurn();

    /// @notice Thrown when trying to use single-player flow on a two-player turn
    error NotSinglePlayerTurn();

    /// @notice Thrown when `submitTurnMoves` is called with the wrong append-position turnId.
    error WrongTurnId();

    /// @notice Thrown when `executeBuffered` is called with nothing pending.
    error EmptyBuffer();

    // ---------------------------------------------------------------------
    // Per-turn batched submission state (OPT_PLAN §3 / §4)
    // ---------------------------------------------------------------------

    /// @notice Packed per-turn move buffer keyed by the engine's `storageKey` (NOT battleKey).
    ///         Slots are reused across battles via the engine's `MappingAllocator`, so the
    ///         steady-state (second-and-later game) submission cost is a warm nonzero→nonzero
    ///         SSTORE (~5k) instead of a cold zero→nonzero SSTORE (~22k). This closes most of
    ///         the per-turn submission overhead vs the legacy `executeWithDualSignedMoves` path.
    /// @dev Layout per OPT_PLAN §3 (one 256-bit slot per turn):
    ///        bits   0-  7 : p0 stored move index (including IS_REAL_TURN_BIT + +1 offset rules)
    ///        bits   8- 23 : p0 extra data (uint16)
    ///        bits  24-127 : p0 salt (uint104)
    ///        bits 128-135 : p1 stored move index
    ///        bits 136-151 : p1 extra data
    ///        bits 152-255 : p1 salt
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) public moveBuffer;

    /// @notice Packed counters per storageKey (mirrors moveBuffer's keying so the counter slot
    ///         also benefits from cross-battle slot reuse):
    ///         bits   0- 63 : numTurnsExecuted (cumulative across the current battle's lifetime;
    ///                        reset at startBattle via engine — managers should sync on first submit
    ///                        of a new battle by mirroring engine's `turnId`)
    ///         bits  64-127 : numTurnsBuffered (current pending count, reset to 0 after executeBuffered)
    ///         bits 128-191 : lastSubmitTimestamp (for timeout tracking; see OPT_PLAN §2.3)
    mapping(bytes32 storageKey => uint256) public bufferCounters;

    /// @notice Emitted on `executeBuffered` so off-chain observers can see how many turns drained.
    /// @dev We don't emit a per-submission event — the SSTORE to `moveBuffer[storageKey][turnId]`
    ///      is itself observable on-chain (anyone tracing storage diffs sees the new entry).
    ///      Skipping the LOG3 saves ~2k gas per submission (~28k for a 14-turn game).
    event TurnsExecuted(bytes32 indexed battleKey, uint64 startTurnId, uint64 executedCount, address winner);

    constructor(IEngine engine) DefaultCommitManager(engine) {}

    /// @inheritdoc EIP712
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "SignedCommitManager";
        version = "1";
    }

    /// @notice Executes a turn using dual-signed moves from both players (gas-optimized)
    /// @dev Both players sign off-chain — committer over `SignedCommit{committerMoveHash, …}`
    ///      and revealer over `DualSignedReveal{committerMoveHash, …, revealerMove…}`. Anyone
    ///      can submit (relayer-friendly) since both signatures are required and bind each
    ///      player independently. Without the explicit committer signature, a malicious
    ///      revealer could pick any preimage `P*`, sign `DualSignedReveal{keccak(P*), …}`
    ///      and play `P*` as the committer's move — the committer signature closes that.
    /// @param battleKey The battle identifier
    /// @param committerMoveIndex The committer's move index
    /// @param committerSalt The committer's salt
    /// @param committerExtraData The committer's extra data
    /// @param revealerMoveIndex The revealer's move index
    /// @param revealerSalt The revealer's salt
    /// @param revealerExtraData The revealer's extra data
    /// @param committerSignature EIP-712 signature from the committer over
    ///        SignedCommit(committerMoveHash, battleKey, turnId)
    /// @param revealerSignature EIP-712 signature from the revealer over
    ///        DualSignedReveal(battleKey, turnId, committerMoveHash, revealerMove…)
    function executeWithDualSignedMoves(
        bytes32 battleKey,
        uint8 committerMoveIndex,
        uint104 committerSalt,
        uint16 committerExtraData,
        uint8 revealerMoveIndex,
        uint104 revealerSalt,
        uint16 revealerExtraData,
        bytes calldata committerSignature,
        bytes calldata revealerSignature
    ) external {
        (address committer, address revealer, uint64 turnId) = ENGINE.getCommitAuthForDualSigned(battleKey);

        bytes32 committerMoveHash = keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));

        // Scoped to keep `commit`/`reveal` structs from sharing stack space across recoveries.
        {
            SignedCommitLib.SignedCommit memory commit = SignedCommitLib.SignedCommit({
                moveHash: committerMoveHash,
                battleKey: battleKey,
                turnId: turnId
            });
            bytes32 commitDigest = _hashTypedData(SignedCommitLib.hashSignedCommit(commit));
            if (ECDSA.recoverCalldata(commitDigest, committerSignature) != committer) {
                revert InvalidSignature();
            }
        }

        {
            SignedCommitLib.DualSignedReveal memory reveal = SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: revealerMoveIndex,
                revealerSalt: revealerSalt,
                revealerExtraData: revealerExtraData
            });
            bytes32 revealDigest = _hashTypedData(SignedCommitLib.hashDualSignedReveal(reveal));
            if (ECDSA.recoverCalldata(revealDigest, revealerSignature) != revealer) {
                revert InvalidSignature();
            }
        }

        if (turnId % 2 == 0) {
            ENGINE.executeWithMoves(
                battleKey,
                committerMoveIndex,
                committerSalt,
                committerExtraData,
                revealerMoveIndex,
                revealerSalt,
                revealerExtraData
            );
        } else {
            ENGINE.executeWithMoves(
                battleKey,
                revealerMoveIndex,
                revealerSalt,
                revealerExtraData,
                committerMoveIndex,
                committerSalt,
                committerExtraData
            );
        }
    }

    /// @notice Executes a forced single-player move, usually a switch after a KO, in one transaction.
    /// @dev The acting player is inferred from the engine's switch flag and must be msg.sender.
    function executeSinglePlayerMove(bytes32 battleKey, uint8 moveIndex, uint104 salt, uint16 extraData) external {
        CommitContext memory ctx = ENGINE.getCommitContext(battleKey);

        if (ctx.startTimestamp == 0) {
            revert BattleNotYetStarted();
        }
        if (ctx.winnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        uint8 playerSwitchForTurnFlag = ctx.playerSwitchForTurnFlag;
        if (playerSwitchForTurnFlag > 1) {
            revert NotSinglePlayerTurn();
        }

        uint256 playerIndex = playerSwitchForTurnFlag;
        address player = playerIndex == 0 ? ctx.p0 : ctx.p1;
        if (msg.sender != player) {
            revert PlayerNotAllowed();
        }

        if (ctx.validator != address(0)) {
            if (!IValidator(ctx.validator).validatePlayerMove(battleKey, moveIndex, playerIndex, extraData)) {
                revert InvalidMove(msg.sender);
            }
        }

        ENGINE.executeWithSingleMove(battleKey, moveIndex, salt, extraData);
    }

    /// @notice Allows anyone to publish the committer's signed commitment on-chain
    /// @dev This is a fallback mechanism if the committer (A) doesn't submit via
    ///      executeWithDualSignedMoves. The revealer (B) can use this to force A's
    ///      commitment on-chain, then proceed with the normal reveal flow.
    /// @param battleKey The battle identifier
    /// @param moveHash The committer's move hash
    /// @param committerSignature EIP-712 signature from the committer over
    ///        SignedCommit(moveHash, battleKey, turnId)
    function commitWithSignature(bytes32 battleKey, bytes32 moveHash, bytes calldata committerSignature) external {
        // Get battle context
        CommitContext memory ctx = ENGINE.getCommitContext(battleKey);

        // Validate battle state
        if (ctx.startTimestamp == 0) {
            revert BattleNotYetStarted();
        }
        if (ctx.winnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        // This function only works for two-player turns
        if (ctx.playerSwitchForTurnFlag != 2) {
            revert NotTwoPlayerTurn();
        }

        // Determine who is the committer based on turn parity
        uint64 turnId = ctx.turnId;
        address committer;
        uint256 committerIndex;

        if (turnId % 2 == 0) {
            committer = ctx.p0;
            committerIndex = 0;
        } else {
            committer = ctx.p1;
            committerIndex = 1;
        }

        // Check if already committed (same logic as commitMove)
        PlayerDecisionData storage pd = playerData[battleKey][committerIndex];
        if (turnId == 0) {
            if (pd.moveHash != bytes32(0)) {
                revert AlreadyCommited();
            }
        } else if (pd.lastCommitmentTurnId == turnId) {
            revert AlreadyCommited();
        }

        // Verify the committer's signature
        SignedCommitLib.SignedCommit memory commit =
            SignedCommitLib.SignedCommit({moveHash: moveHash, battleKey: battleKey, turnId: turnId});

        bytes32 structHash = SignedCommitLib.hashSignedCommit(commit);
        bytes32 digest = _hashTypedData(structHash);
        address signer = ECDSA.recoverCalldata(digest, committerSignature);

        if (signer != committer) {
            revert InvalidSignature();
        }

        // Store the commitment
        _storeCommitment(battleKey, committerIndex, moveHash, turnId);

        emit MoveCommit(battleKey, committer);
    }

    // ---------------------------------------------------------------------
    // Batched per-turn submission (OPT_PLAN §4.1, §4.2, §6.1)
    // ---------------------------------------------------------------------

    /// @notice Append a per-turn entry to the buffered move stream. No engine execution happens
    ///         in this call — `executeBuffered` later drains every currently buffered turn in
    ///         one transaction.
    /// @dev Anyone can call: both player signatures are required so submission is relayer-friendly,
    ///      matching the dual-signed security model in `executeWithDualSignedMoves`. Each call
    ///      verifies (committer EIP-712 sig over `SignedCommit`, revealer EIP-712 sig over
    ///      `DualSignedReveal`) and append-position equality (`entry.turnId == executed + buffered`).
    ///      Switch-turn entries follow the same shape: the non-acting player signs a NO_OP move,
    ///      which `executeBuffered` ignores by routing via the engine's live `playerSwitchForTurnFlag`.
    function submitTurnMoves(bytes32 battleKey, TurnSubmission calldata entry) external {
        // Single combined getter: returns p0/p1/turnId/winnerIndex/storageKey in one call.
        // Skips startTimestamp/validator/flag — none needed at submission time in the async flow.
        (address ctxP0, address ctxP1, uint64 ctxTurnId, uint8 ctxWinnerIndex, bytes32 storageKey) =
            ENGINE.getSubmitContext(battleKey);

        if (ctxWinnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        // First-of-batch sync: if the buffer is empty, mirror engine's `turnId` into
        // `numTurnsExecuted` so a legacy single-turn execute → batched-submit transition is seamless.
        // Also reset on first submission of a new battle so leftover counters from a prior battle's
        // storageKey don't desync the append position.
        uint256 packedCounters = bufferCounters[storageKey];
        uint64 numExecuted = uint64(packedCounters);
        uint64 numBuffered = uint64(packedCounters >> 64);
        if (numBuffered == 0) {
            numExecuted = ctxTurnId;
        }

        if (entry.turnId != numExecuted + numBuffered) {
            revert WrongTurnId();
        }

        // Per OPT_PLAN §6.1, both halves are signed every turn. Committer/revealer roles derive
        // from parity; the engine reads the live `playerSwitchForTurnFlag` at execute time and
        // skips the non-acting player's half.
        (address committer, address revealer) =
            entry.turnId % 2 == 0 ? (ctxP0, ctxP1) : (ctxP1, ctxP0);

        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(entry.committerMoveIndex, entry.committerSalt, entry.committerExtraData));

        {
            SignedCommitLib.SignedCommit memory commit = SignedCommitLib.SignedCommit({
                moveHash: committerMoveHash,
                battleKey: battleKey,
                turnId: entry.turnId
            });
            bytes32 digest = _hashTypedData(SignedCommitLib.hashSignedCommit(commit));
            if (ECDSA.recoverCalldata(digest, entry.committerSig) != committer) {
                revert InvalidSignature();
            }
        }

        {
            SignedCommitLib.DualSignedReveal memory reveal = SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: entry.turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: entry.revealerMoveIndex,
                revealerSalt: entry.revealerSalt,
                revealerExtraData: entry.revealerExtraData
            });
            bytes32 digest = _hashTypedData(SignedCommitLib.hashDualSignedReveal(reveal));
            if (ECDSA.recoverCalldata(digest, entry.revealerSig) != revealer) {
                revert InvalidSignature();
            }
        }

        // Map (committer, revealer) → (p0, p1) by parity and pack into a single 256-bit slot.
        uint256 packed;
        if (entry.turnId % 2 == 0) {
            packed = _packBufferedTurn(
                entry.committerMoveIndex,
                entry.committerExtraData,
                entry.committerSalt,
                entry.revealerMoveIndex,
                entry.revealerExtraData,
                entry.revealerSalt
            );
        } else {
            packed = _packBufferedTurn(
                entry.revealerMoveIndex,
                entry.revealerExtraData,
                entry.revealerSalt,
                entry.committerMoveIndex,
                entry.committerExtraData,
                entry.committerSalt
            );
        }

        moveBuffer[storageKey][entry.turnId] = packed;

        unchecked {
            bufferCounters[storageKey] =
                uint256(numExecuted) | (uint256(numBuffered + 1) << 64) | (uint256(uint64(block.timestamp)) << 128);
        }
    }

    /// @notice Drain every currently buffered turn in one transaction.
    /// @dev Loops `executeWithMoves` (two-player turn) and `executeWithSingleMove` (single-player
    ///      switch turn, per §6.1) based on the engine's live `playerSwitchForTurnFlag`. Stops
    ///      early on game-over; any remaining buffered entries become dead once `numTurnsBuffered`
    ///      resets to 0 at the end of this call.
    ///
    ///      Anyone can call — signatures were checked at submission time. The shared-tx loop
    ///      relies on the EVM's warm-storage discount across sub-turns for cold-SLOAD amortization
    ///      (this is the v1 substitute for §5's transient shadow layer; see §12 Decision Log).
    function executeBuffered(bytes32 battleKey) external {
        bytes32 storageKey = ENGINE.getStorageKey(battleKey);
        uint256 packedCounters = bufferCounters[storageKey];
        uint64 numExecuted = uint64(packedCounters);
        uint64 numBuffered = uint64(packedCounters >> 64);

        if (numBuffered == 0) {
            revert EmptyBuffer();
        }

        uint64 executedThisBatch;
        address winner;

        for (uint64 i = 0; i < numBuffered; i++) {
            uint64 turnId = numExecuted + i;
            uint256 entry = moveBuffer[storageKey][turnId];

            (
                uint8 p0Move,
                uint16 p0Extra,
                uint104 p0Salt,
                uint8 p1Move,
                uint16 p1Extra,
                uint104 p1Salt
            ) = _unpackBufferedTurn(entry);

            // Live flag read: the engine updated `playerSwitchForTurnFlag` at the end of the
            // previous sub-turn (or it's the snapshot from before the batch started). Cheap SLOAD
            // since this slot was just warmed.
            uint8 flag = uint8(ENGINE.getPlayerSwitchForTurnFlagForBattleState(battleKey));

            if (flag == 2) {
                winner = ENGINE.executeWithMoves(battleKey, p0Move, p0Salt, p0Extra, p1Move, p1Salt, p1Extra);
            } else if (flag == 0) {
                winner = ENGINE.executeWithSingleMove(battleKey, p0Move, p0Salt, p0Extra);
            } else {
                winner = ENGINE.executeWithSingleMove(battleKey, p1Move, p1Salt, p1Extra);
            }

            executedThisBatch++;

            if (winner != address(0)) {
                break;
            }

            // Reset per-turn transients so leaky slots (tempRNG, koOccurredFlag, tempPreDamage,
            // effectsDirtyBitmap, _turnP*MoveEncoded, _turnP*Salt) don't carry into the next
            // sub-turn within this tx. `executeWithMoves` / `executeWithSingleMove` re-set
            // `battleKeyForWrite` / `storageKeyForWrite` at entry, so the cleared values here
            // get repopulated next iteration. Skipped after the final iteration since the tx
            // is about to end. See OPT_PLAN §12 Decision Log on transient resets.
            if (i + 1 < numBuffered) {
                ENGINE.resetCallContext();
            }
        }

        // Flush counters: `numTurnsExecuted` advances by the actually-executed count;
        // `numTurnsBuffered` resets to 0 regardless (post-game-over entries become dead).
        unchecked {
            bufferCounters[storageKey] =
                uint256(numExecuted + executedThisBatch) | (uint256(0) << 64) | (uint256(uint64(block.timestamp)) << 128);
        }

        emit TurnsExecuted(battleKey, numExecuted, executedThisBatch, winner);
    }

    /// @notice External view: how many turns are currently pending vs cumulatively executed.
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

    // ---------------------------------------------------------------------
    // Internal packing helpers (OPT_PLAN §3)
    // ---------------------------------------------------------------------

    /// @dev Bit layout matches §3 exactly: [p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104].
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

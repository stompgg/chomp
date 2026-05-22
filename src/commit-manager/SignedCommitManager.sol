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
    ///        bits  24-127 : p0 salt (uint96)
    ///        bits 128-135 : p1 stored move index
    ///        bits 136-151 : p1 extra data
    ///        bits 152-255 : p1 salt
    /// @notice Packed buffered turn entries per (storageKey, turnId).
    /// @dev Bit layout in each entry (per `_packBufferedTurn`):
    ///        [p0Move 8 | p0Extra 16 | p0Salt 96 | p1Move 8 | p1Extra 16 | p1Salt 96 | epoch 16]
    ///      The top-16-bit epoch tag is `_battleEpoch(battleKey)` = low 16 bits of battleKey OR 1.
    ///      A stale leftover from a prior battle has the prior battle's epoch — `executeBuffered`
    ///      walks slots and stops at the first epoch mismatch, so abandoned-buffer slots are
    ///      naturally invisible to the next battle. Replaces the old `bufferCounters` SSTORE
    ///      per submit (saves ~5k gas per submission, ~70k per 14-turn game in production).
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) public moveBuffer;

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
        uint96 committerSalt,
        uint16 committerExtraData,
        uint8 revealerMoveIndex,
        uint96 revealerSalt,
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
    function executeSinglePlayerMove(bytes32 battleKey, uint8 moveIndex, uint96 salt, uint16 extraData) external {
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
        (address ctxP0, address ctxP1, uint64 ctxTurnId, uint8 ctxWinnerIndex, bytes32 storageKey) =
            ENGINE.getSubmitContext(battleKey);

        if (ctxWinnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        // Can't submit for a turn that's already been executed.
        if (entry.turnId < ctxTurnId) {
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

        // Map (committer, revealer) → (p0, p1) by parity and pack into a single 256-bit slot,
        // tagged with this battle's epoch in the top 16 bits. Epoch = low 16 bits of battleKey
        // OR'd with 1 to guarantee non-zero (so a freshly-zeroed slot stays distinguishable
        // from a live entry). `executeBuffered` uses the epoch tag to detect "live for this
        // battle" vs "stale from a prior battle that reused this storageKey but never drained
        // its buffer" — removing the need for a separate `bufferCounters` SSTORE per submit.
        uint16 epoch = _battleEpoch(battleKey);
        uint256 packed;
        if (entry.turnId % 2 == 0) {
            packed = _packBufferedTurn(
                entry.committerMoveIndex,
                entry.committerExtraData,
                entry.committerSalt,
                entry.revealerMoveIndex,
                entry.revealerExtraData,
                entry.revealerSalt,
                epoch
            );
        } else {
            packed = _packBufferedTurn(
                entry.revealerMoveIndex,
                entry.revealerExtraData,
                entry.revealerSalt,
                entry.committerMoveIndex,
                entry.committerExtraData,
                entry.committerSalt,
                epoch
            );
        }

        moveBuffer[storageKey][entry.turnId] = packed;
    }

    /// @dev Battle-unique 16-bit epoch tag derived from the low 16 bits of `battleKey`, OR'd
    /// with 1 so the tag is always non-zero (a zero packed slot is the "no entry" sentinel).
    /// Collision probability between two battles ever using the same storageKey is ~1/32768.
    function _battleEpoch(bytes32 battleKey) internal pure returns (uint16) {
        return uint16(uint256(battleKey)) | uint16(1);
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
        uint64 numExecuted = uint64(ENGINE.getTurnIdForBattleState(battleKey));
        uint16 epoch = _battleEpoch(battleKey);

        // Walk forward from the engine's current turnId, collecting contiguous slots whose
        // top-16-bit epoch tag matches THIS battle. First mismatch (stale entry from a prior
        // battle that reused this storageKey, or a never-written zero slot) ends the buffer.
        // Hard-bound the walk so a malformed buffer can't grief the gas; in practice every
        // battle is well under this cap.
        uint256 MAX_BUFFERED = 256;
        uint256[] memory tmp = new uint256[](MAX_BUFFERED);
        uint256 numBuffered;
        unchecked {
            for (uint256 i = 0; i < MAX_BUFFERED; i++) {
                uint256 packed = moveBuffer[storageKey][numExecuted + i];
                if (uint16(packed >> 240) != epoch) break;
                tmp[i] = packed;
                numBuffered = i + 1;
            }
        }

        if (numBuffered == 0) {
            revert EmptyBuffer();
        }

        // Shrink to the actual buffered length before passing to the engine.
        uint256[] memory entries = new uint256[](numBuffered);
        for (uint256 i; i < numBuffered; i++) {
            entries[i] = tmp[i];
        }
        (uint64 executedThisBatch, address winner) = ENGINE.executeBatchedTurns(battleKey, entries);

        emit TurnsExecuted(battleKey, numExecuted, executedThisBatch, winner);
    }

    /// @notice External view: how many turns are currently buffered vs cumulatively executed.
    /// @dev `numBuffered` is now computed live by walking the epoch-tagged slots; the timestamp
    /// is no longer tracked (was a side-effect of the old counter SSTORE that we eliminated).
    function getBufferStatus(bytes32 battleKey)
        external
        view
        returns (uint64 numExecuted, uint64 numBuffered, uint64 lastSubmitTimestamp)
    {
        bytes32 storageKey = ENGINE.getStorageKey(battleKey);
        numExecuted = uint64(ENGINE.getTurnIdForBattleState(battleKey));
        uint16 epoch = _battleEpoch(battleKey);
        // Walk slots until we find one whose epoch doesn't match (stale or empty). Bound at 256
        // to mirror executeBuffered's cap.
        unchecked {
            for (uint256 i = 0; i < 256; i++) {
                uint256 packed = moveBuffer[storageKey][numExecuted + i];
                if (uint16(packed >> 240) != epoch) break;
                numBuffered = uint64(i + 1);
            }
        }
        lastSubmitTimestamp = 0;
    }

    /// @notice Read a single buffered turn. Returns zero for unset slots.
    /// @dev `epoch` is the per-battle tag baked into the slot; it's exposed so callers can
    /// confirm the entry belongs to the live battle (vs a stale leftover from a prior battle
    /// that abandoned its buffer at this storageKey).
    function getBufferedTurn(bytes32 battleKey, uint64 turnId)
        external
        view
        returns (
            uint8 p0Move,
            uint16 p0Extra,
            uint96 p0Salt,
            uint8 p1Move,
            uint16 p1Extra,
            uint96 p1Salt,
            uint16 epoch
        )
    {
        return _unpackBufferedTurn(moveBuffer[ENGINE.getStorageKey(battleKey)][turnId]);
    }

    // ---------------------------------------------------------------------
    // Internal packing helpers (OPT_PLAN §3)
    // ---------------------------------------------------------------------

    /// @dev Bit layout (tight pack, 256 bits total):
    ///        [p0Move 8 | p0Extra 16 | p0Salt 96 | p1Move 8 | p1Extra 16 | p1Salt 96 | epoch 16]
    /// The 16-bit epoch is the low 16 bits of the battleKey — every battle has a distinct
    /// battleKey (computed from p0/p1/pairHashNonce), so the chance of two battles ever using
    /// the SAME storageKey with the SAME low-16-bit battleKey value is ~1/65k. Used by
    /// `submitTurnMoves` to detect duplicates and `executeBuffered` to detect "stale entries
    /// from a prior battle that abandoned its buffer."
    function _packBufferedTurn(
        uint8 p0Move,
        uint16 p0Extra,
        uint96 p0Salt,
        uint8 p1Move,
        uint16 p1Extra,
        uint96 p1Salt,
        uint16 epoch
    ) internal pure returns (uint256 packed) {
        packed = uint256(p0Move)
            | (uint256(p0Extra) << 8)
            | (uint256(p0Salt) << 24)
            | (uint256(p1Move) << 120)
            | (uint256(p1Extra) << 128)
            | (uint256(p1Salt) << 144)
            | (uint256(epoch) << 240);
    }

    function _unpackBufferedTurn(uint256 packed)
        internal
        pure
        returns (
            uint8 p0Move,
            uint16 p0Extra,
            uint96 p0Salt,
            uint8 p1Move,
            uint16 p1Extra,
            uint96 p1Salt,
            uint16 epoch
        )
    {
        p0Move = uint8(packed);
        p0Extra = uint16(packed >> 8);
        p0Salt = uint96(packed >> 24);
        p1Move = uint8(packed >> 120);
        p1Extra = uint16(packed >> 128);
        p1Salt = uint96(packed >> 144);
        epoch = uint16(packed >> 240);
    }
}

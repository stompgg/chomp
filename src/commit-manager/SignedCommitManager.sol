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

    constructor(IEngine engine) DefaultCommitManager(engine) {}

    /// @inheritdoc EIP712
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "SignedCommitManager";
        version = "1";
    }

    /// @notice Executes a turn in one transaction (gas-optimized, SINGLE-SIG): the committer is
    ///         `msg.sender` and the revealer's signature carries their move.
    /// @dev No committer signature — the committer is bound by `msg.sender == committer`. The
    ///      revealer signs `DualSignedReveal{committerMoveHash, …}`, which pins the committer's move
    ///      hash, so the committer is locked to this exact move (a different preimage would break the
    ///      revealer's signature) and a malicious revealer cannot play a forged committer move (they
    ///      are not `msg.sender == committer`). Saves one ecrecover + one 65-byte signature vs the
    ///      dual-sig variant. Trade-off: NOT relayer-friendly — the committer must send their own tx.
    /// @param battleKey The battle identifier
    /// @param committerMoveIndex The committer's move index
    /// @param committerSalt The committer's salt
    /// @param committerExtraData The committer's extra data
    /// @param revealerMoveIndex The revealer's move index
    /// @param revealerSalt The revealer's salt
    /// @param revealerExtraData The revealer's extra data
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
        bytes calldata revealerSignature
    ) external {
        (address committer, address revealer, uint64 turnId) = ENGINE.getCommitAuthForDualSigned(battleKey);

        if (msg.sender != committer) {
            revert NotCommitter();
        }

        bytes32 committerMoveHash = keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));

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
    // Batched per-turn submission (single-sig: msg.sender == committer)
    // ---------------------------------------------------------------------

    error WrongTurnId();
    error EmptyBuffer();
    error NotCommitter();

    /// @notice Packed per-turn move buffer keyed by the engine's `storageKey` (slot reuse across
    ///         battles → steady-state warm nz->nz SSTOREs). Layout per slot:
    ///   [p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104]
    mapping(bytes32 storageKey => mapping(uint64 turnId => uint256 packed)) public moveBuffer;

    /// @notice Packed counters per storageKey:
    ///   bits 0-63 numTurnsExecuted | bits 64-127 numTurnsBuffered | bits 128-191 lastSubmitTimestamp
    mapping(bytes32 storageKey => uint256) public bufferCounters;

    /// @notice Append a per-turn entry to the buffer. The committer (msg.sender) supplies their
    ///         preimage directly; the revealer's signature pins the committer's move hash. No
    ///         engine execution — `executeBuffered` later drains the whole buffer in one tx.
    function submitTurnMoves(bytes32 battleKey, TurnSubmission calldata entry) external {
        _submitTurnMoves(battleKey, entry);
    }

    /// @notice Append a per-turn entry and drain the whole buffer in the same transaction.
    /// @dev Convenience for the final submission of a batch: the committer (msg.sender) submits
    ///      their entry and pays for execution in one call, saving a standalone `executeBuffered`
    ///      transaction (one fewer 21k base cost + one fewer engine context lookup).
    function submitTurnMovesAndExecute(bytes32 battleKey, TurnSubmission calldata entry) external {
        bytes32 storageKey = _submitTurnMoves(battleKey, entry);
        _executeBuffered(battleKey, storageKey);
    }

    function _submitTurnMoves(bytes32 battleKey, TurnSubmission calldata entry) internal returns (bytes32 storageKey) {
        address ctxP0;
        address ctxP1;
        uint64 ctxTurnId;
        uint8 ctxWinnerIndex;
        (ctxP0, ctxP1, ctxTurnId, ctxWinnerIndex, storageKey) = ENGINE.getSubmitContext(battleKey);

        if (ctxWinnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        uint256 packedCounters = bufferCounters[storageKey];
        uint64 numExecuted = uint64(packedCounters);
        uint64 numBuffered = uint64(packedCounters >> 64);
        if (numBuffered == 0) {
            // First of a new batch: sync to the engine's live turnId (seamless legacy<->batched).
            numExecuted = ctxTurnId;
        }
        if (entry.turnId != numExecuted + numBuffered) {
            revert WrongTurnId();
        }

        (address committer, address revealer) = entry.turnId % 2 == 0 ? (ctxP0, ctxP1) : (ctxP1, ctxP0);

        // SINGLE-SIG: committer is msg.sender (no committer signature). Cheaper than dual-sig by
        // one ecrecover + one 65-byte sig; the revealer sig below still pins committerMoveHash so
        // the committer cannot change their move and cannot be impersonated.
        if (msg.sender != committer) {
            revert NotCommitter();
        }

        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(entry.committerMoveIndex, entry.committerSalt, entry.committerExtraData));

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

        uint256 packed;
        if (entry.turnId % 2 == 0) {
            packed = _packBufferedTurn(
                entry.committerMoveIndex, entry.committerExtraData, entry.committerSalt,
                entry.revealerMoveIndex, entry.revealerExtraData, entry.revealerSalt
            );
        } else {
            packed = _packBufferedTurn(
                entry.revealerMoveIndex, entry.revealerExtraData, entry.revealerSalt,
                entry.committerMoveIndex, entry.committerExtraData, entry.committerSalt
            );
        }

        moveBuffer[storageKey][entry.turnId] = packed;
        unchecked {
            bufferCounters[storageKey] =
                uint256(numExecuted) | (uint256(numBuffered + 1) << 64) | (uint256(uint64(block.timestamp)) << 128);
        }
    }

    /// @notice Drain every currently buffered turn in one transaction. Anyone can call.
    function executeBuffered(bytes32 battleKey) external {
        _executeBuffered(battleKey, ENGINE.getStorageKey(battleKey));
    }

    function _executeBuffered(bytes32 battleKey, bytes32 storageKey) internal {
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
        (uint64 executedThisBatch,) = ENGINE.executeBatchedTurns(battleKey, entries);

        unchecked {
            bufferCounters[storageKey] =
                uint256(numExecuted + executedThisBatch) | (uint256(uint64(block.timestamp)) << 128);
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
        returns (uint8 p0Move, uint16 p0Extra, uint104 p0Salt, uint8 p1Move, uint16 p1Extra, uint104 p1Salt)
    {
        return _unpackBufferedTurn(moveBuffer[ENGINE.getStorageKey(battleKey)][turnId]);
    }

    function _packBufferedTurn(
        uint8 p0Move, uint16 p0Extra, uint104 p0Salt, uint8 p1Move, uint16 p1Extra, uint104 p1Salt
    ) internal pure returns (uint256 packed) {
        packed = uint256(p0Move) | (uint256(p0Extra) << 8) | (uint256(p0Salt) << 24)
            | (uint256(p1Move) << 128) | (uint256(p1Extra) << 136) | (uint256(p1Salt) << 152);
    }

    function _unpackBufferedTurn(uint256 packed)
        internal
        pure
        returns (uint8 p0Move, uint16 p0Extra, uint104 p0Salt, uint8 p1Move, uint16 p1Extra, uint104 p1Salt)
    {
        p0Move = uint8(packed);
        p0Extra = uint16(packed >> 8);
        p0Salt = uint104(packed >> 24);
        p1Move = uint8(packed >> 128);
        p1Extra = uint16(packed >> 136);
        p1Salt = uint104(packed >> 152);
    }
}

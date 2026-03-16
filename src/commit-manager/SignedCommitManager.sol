// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {DefaultCommitManager} from "./DefaultCommitManager.sol";
import {EIP712} from "../lib/EIP712.sol";
import {ECDSA} from "../lib/ECDSA.sol";
import {SignedCommitLib} from "./SignedCommitLib.sol";
import {IEngine} from "../IEngine.sol";
import {CommitContext, PlayerDecisionData} from "../Structs.sol";
import {GameMode} from "../Enums.sol";

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
///        1. Alice signs her move hash off-chain, sends to Bob
///        2. Bob signs his move + Alice's hash off-chain, sends to Alice
///        3. Alice calls executeWithDualSignedMoves with both moves + Bob's signature (TX 1)
///
///      Security: Alice commits to her hash before seeing Bob's move. Bob signs over
///      Alice's hash, so even though Alice sees Bob's move before submitting, Alice
///      cannot change her move (must provide valid preimage for the hash Bob signed).
///
///      Fallback if Alice stalls: Bob can use commitWithSignature() to publish Alice's
///      signed commitment on-chain, then continue with the normal reveal flow.
///
///      Fallback if Bob doesn't cooperate: Alice can use the normal commitMove() flow.
contract SignedCommitManager is DefaultCommitManager, EIP712 {
    /// @notice Thrown when the signature verification fails
    error InvalidSignature();

    /// @notice Thrown when caller is not the committing player for this turn
    error CallerNotCommitter();

    /// @notice Thrown when trying to use dual-signed flow on a single-player turn
    error NotTwoPlayerTurn();

    /// @notice Thrown when using singles function for a doubles battle or vice versa
    error WrongGameMode();

    constructor(IEngine engine) DefaultCommitManager(engine) {}

    /// @inheritdoc EIP712
    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name, string memory version)
    {
        name = "SignedCommitManager";
        version = "1";
    }

    /// @notice Executes a turn using dual-signed moves from both players (singles only)
    /// @dev The committer (A) submits both moves. The revealer (B) has signed over
    ///      their move and A's move hash, binding both players to their moves.
    /// @param battleKey The battle identifier
    /// @param committerMoveIndex The committer's move index
    /// @param committerSalt The committer's salt
    /// @param committerExtraData The committer's extra data
    /// @param revealerMoveIndex The revealer's move index
    /// @param revealerSalt The revealer's salt
    /// @param revealerExtraData The revealer's extra data
    /// @param revealerSignature EIP-712 signature from the revealer over
    ///        DualSignedReveal(battleKey, turnId, committerMoveHash, revealerMove...)
    function executeWithDualSignedMoves(
        bytes32 battleKey,
        uint8 committerMoveIndex,
        bytes32 committerSalt,
        uint240 committerExtraData,
        uint8 revealerMoveIndex,
        bytes32 revealerSalt,
        uint240 revealerExtraData,
        bytes memory revealerSignature
    ) external {
        // Use lightweight getter (validates internally, reverts on bad state)
        (address committer, address revealer, uint64 turnId, GameMode gameMode) =
            ENGINE.getCommitAuthForDualSigned(battleKey);

        if (gameMode != GameMode.Singles) revert WrongGameMode();

        // Caller must be the committing player
        if (msg.sender != committer) {
            revert CallerNotCommitter();
        }

        // Compute the committer's move hash
        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));

        // Verify the revealer's signature over DualSignedReveal
        SignedCommitLib.DualSignedReveal memory reveal = SignedCommitLib.DualSignedReveal({
            battleKey: battleKey,
            turnId: turnId,
            committerMoveHash: committerMoveHash,
            revealerMoveIndex: revealerMoveIndex,
            revealerSalt: revealerSalt,
            revealerExtraData: revealerExtraData
        });

        bytes32 digest = _hashTypedData(SignedCommitLib.hashDualSignedReveal(reveal));
        if (ECDSA.recover(digest, revealerSignature) != revealer) {
            revert InvalidSignature();
        }

        // Execute with moves in a single call (engine validates during execution)
        // No playerData updates needed - engine tracks lastExecuteTimestamp for timeouts
        if (turnId % 2 == 0) {
            // Committer is p0
            ENGINE.executeWithMoves(
                battleKey,
                committerMoveIndex, committerSalt, committerExtraData,
                revealerMoveIndex, revealerSalt, revealerExtraData
            );
        } else {
            // Committer is p1
            ENGINE.executeWithMoves(
                battleKey,
                revealerMoveIndex, revealerSalt, revealerExtraData,
                committerMoveIndex, committerSalt, committerExtraData
            );
        }
    }

    /// @notice Executes a turn using dual-signed moves for doubles battles
    /// @dev Same security model as executeWithDualSignedMoves but each player has 2 slot moves.
    ///      The committer's hash covers both slot moves: keccak256(moveIndex0, moveIndex1, salt, extraData0, extraData1)
    ///      matching the revealMovePair preimage format.
    /// @param battleKey The battle identifier
    /// @param committerMoveIndex0 The committer's slot 0 move index
    /// @param committerExtraData0 The committer's slot 0 extra data
    /// @param committerMoveIndex1 The committer's slot 1 move index
    /// @param committerExtraData1 The committer's slot 1 extra data
    /// @param committerSalt The committer's salt (shared across both slots)
    /// @param revealerMoveIndex0 The revealer's slot 0 move index
    /// @param revealerExtraData0 The revealer's slot 0 extra data
    /// @param revealerMoveIndex1 The revealer's slot 1 move index
    /// @param revealerExtraData1 The revealer's slot 1 extra data
    /// @param revealerSalt The revealer's salt (shared across both slots)
    /// @param revealerSignature EIP-712 signature from the revealer over DualSignedRevealDoubles
    function executeWithDualSignedMovesForDoubles(
        bytes32 battleKey,
        uint8 committerMoveIndex0,
        uint240 committerExtraData0,
        uint8 committerMoveIndex1,
        uint240 committerExtraData1,
        bytes32 committerSalt,
        uint8 revealerMoveIndex0,
        uint240 revealerExtraData0,
        uint8 revealerMoveIndex1,
        uint240 revealerExtraData1,
        bytes32 revealerSalt,
        bytes memory revealerSignature
    ) external {
        // Use lightweight getter (validates internally, reverts on bad state)
        (address committer, address revealer, uint64 turnId, GameMode gameMode) =
            ENGINE.getCommitAuthForDualSigned(battleKey);

        if (gameMode != GameMode.Doubles) revert WrongGameMode();

        // Caller must be the committing player
        if (msg.sender != committer) {
            revert CallerNotCommitter();
        }

        // Compute the committer's move hash (matches revealMovePair preimage format)
        bytes32 committerMoveHash = keccak256(
            abi.encodePacked(
                committerMoveIndex0, committerMoveIndex1, committerSalt, committerExtraData0, committerExtraData1
            )
        );

        // Verify the revealer's signature over DualSignedRevealDoubles
        SignedCommitLib.DualSignedRevealDoubles memory reveal = SignedCommitLib.DualSignedRevealDoubles({
            battleKey: battleKey,
            turnId: turnId,
            committerMoveHash: committerMoveHash,
            revealerMoveIndex0: revealerMoveIndex0,
            revealerMoveIndex1: revealerMoveIndex1,
            revealerSalt: revealerSalt,
            revealerExtraData0: revealerExtraData0,
            revealerExtraData1: revealerExtraData1
        });

        bytes32 digest = _hashTypedData(SignedCommitLib.hashDualSignedRevealDoubles(reveal));
        if (ECDSA.recover(digest, revealerSignature) != revealer) {
            revert InvalidSignature();
        }

        // Execute with all 4 slot moves in a single call
        if (turnId % 2 == 0) {
            // Committer is p0
            ENGINE.executeWithMovesForDoubles(
                battleKey,
                committerMoveIndex0, committerExtraData0,
                committerMoveIndex1, committerExtraData1,
                committerSalt,
                revealerMoveIndex0, revealerExtraData0,
                revealerMoveIndex1, revealerExtraData1,
                revealerSalt
            );
        } else {
            // Committer is p1
            ENGINE.executeWithMovesForDoubles(
                battleKey,
                revealerMoveIndex0, revealerExtraData0,
                revealerMoveIndex1, revealerExtraData1,
                revealerSalt,
                committerMoveIndex0, committerExtraData0,
                committerMoveIndex1, committerExtraData1,
                committerSalt
            );
        }
    }

    /// @notice Allows anyone to publish the committer's signed commitment on-chain
    /// @dev This is a fallback mechanism if the committer (A) doesn't submit via
    ///      executeWithDualSignedMoves. The revealer (B) can use this to force A's
    ///      commitment on-chain, then proceed with the normal reveal flow.
    ///      Works for both singles and doubles - the moveHash is format-agnostic.
    /// @param battleKey The battle identifier
    /// @param moveHash The committer's move hash
    /// @param committerSignature EIP-712 signature from the committer over
    ///        SignedCommit(moveHash, battleKey, turnId)
    function commitWithSignature(
        bytes32 battleKey,
        bytes32 moveHash,
        bytes memory committerSignature
    ) external {
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
        SignedCommitLib.SignedCommit memory commit = SignedCommitLib.SignedCommit({
            moveHash: moveHash,
            battleKey: battleKey,
            turnId: turnId
        });

        bytes32 structHash = SignedCommitLib.hashSignedCommit(commit);
        bytes32 digest = _hashTypedData(structHash);
        address signer = ECDSA.recover(digest, committerSignature);

        if (signer != committer) {
            revert InvalidSignature();
        }

        // Store the commitment
        _storeCommitment(battleKey, committerIndex, moveHash, turnId);

        emit MoveCommit(battleKey, committer);
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {DefaultCommitManager} from "./DefaultCommitManager.sol";
import {EIP712} from "../lib/EIP712.sol";
import {ECDSA} from "../lib/ECDSA.sol";
import {SignedCommitLib} from "./SignedCommitLib.sol";
import {IEngine} from "../IEngine.sol";
import {IValidator} from "../IValidator.sol";
import {CommitContext, PlayerDecisionData} from "../Structs.sol";

/// @title SignedCommitManager
/// @notice Extends DefaultCommitManager with optimistic commit flow using signed commitments
/// @dev Allows the revealing player to submit the committing player's signed commitment
///      along with their own reveal in a single transaction, removing the need for the
///      committing player to make an on-chain commit transaction.
///
///      Normal flow (3 transactions):
///        1. Alice commits (TX 1)
///        2. Bob reveals (TX 2)
///        3. Alice reveals (TX 3)
///
///      Signed commit flow (2 transactions):
///        1. Alice signs commitment off-chain
///        2. Bob calls revealMoveWithOtherPlayerSignedCommit with Alice's signature (TX 1)
///        3. Alice reveals (TX 2)
///
///      Fallback: If Bob doesn't publish Alice's signed commit, Alice can still use
///      the normal commitMove() flow.
contract SignedCommitManager is DefaultCommitManager, EIP712 {
    /// @notice Thrown when the signature verification fails
    error InvalidCommitSignature();

    /// @notice Thrown when caller is not the revealing player for this turn
    error CallerNotRevealer();

    /// @notice Thrown when trying to use signed commit on a single-player turn
    error NotTwoPlayerTurn();

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

    /// @notice Allows the revealing player to submit the committing player's signed commitment
    ///         along with their own reveal in a single transaction.
    /// @dev If an on-chain commit already exists for the committer, this function falls back
    ///      to normal reveal behavior (ignoring the signature).
    /// @param battleKey The battle identifier
    /// @param committerMoveHash The committing player's move hash
    /// @param committerSignature EIP-712 signature from the committing player over
    ///        SignedCommit(moveHash, battleKey, turnId)
    /// @param moveIndex The revealing player's move index
    /// @param salt The revealing player's salt (can be empty for revealer)
    /// @param extraData The revealing player's extra data
    /// @param autoExecute Whether to auto-execute after reveal (will be false since committer
    ///        hasn't revealed yet in the signed commit flow)
    function revealMoveWithOtherPlayerSignedCommit(
        bytes32 battleKey,
        bytes32 committerMoveHash,
        bytes memory committerSignature,
        uint8 moveIndex,
        bytes32 salt,
        uint240 extraData,
        bool autoExecute
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

        // Determine who is the committer vs revealer based on turn parity
        uint64 turnId = ctx.turnId;
        address committer;
        address revealer;
        uint256 committerIndex;
        uint256 revealerIndex;

        if (turnId % 2 == 0) {
            committer = ctx.p0;
            revealer = ctx.p1;
            committerIndex = 0;
            revealerIndex = 1;
        } else {
            committer = ctx.p1;
            revealer = ctx.p0;
            committerIndex = 1;
            revealerIndex = 0;
        }

        // Caller must be the revealing player
        if (msg.sender != revealer) {
            revert CallerNotRevealer();
        }

        // Check if committer already committed on-chain
        PlayerDecisionData storage committerPd = playerData[battleKey][committerIndex];
        bool alreadyCommitted;
        if (turnId == 0) {
            alreadyCommitted = (committerPd.moveHash != bytes32(0));
        } else {
            alreadyCommitted = (committerPd.lastCommitmentTurnId == turnId && committerPd.moveHash != bytes32(0));
        }

        // If already committed on-chain, the signature is ignored - just do normal reveal
        if (!alreadyCommitted) {
            // Verify the signature from the committer
            SignedCommitLib.SignedCommit memory commit = SignedCommitLib.SignedCommit({
                moveHash: committerMoveHash,
                battleKey: battleKey,
                turnId: turnId
            });

            bytes32 structHash = SignedCommitLib.hashSignedCommit(commit);
            bytes32 digest = _hashTypedData(structHash);
            address signer = ECDSA.recover(digest, committerSignature);

            if (signer != committer) {
                revert InvalidCommitSignature();
            }

            // Store the commitment for the committer
            _storeCommitment(battleKey, committerIndex, committerMoveHash, turnId);

            // Emit MoveCommit event (same as normal commit flow)
            emit MoveCommit(battleKey, committer);
        }

        // Now perform the reveal for the caller (revealer)
        // We inline the reveal logic here to avoid external call overhead
        PlayerDecisionData storage revealerPd = playerData[battleKey][revealerIndex];

        // Check no prior reveal (prevents double revealing)
        if (revealerPd.numMovesRevealed > turnId) {
            revert AlreadyRevealed();
        }

        // Validate that the move is legal
        if (!IValidator(ctx.validator).validatePlayerMove(battleKey, moveIndex, revealerIndex, extraData)) {
            revert InvalidMove(msg.sender);
        }

        // Store revealed move and update state
        ENGINE.setMove(battleKey, revealerIndex, moveIndex, salt, extraData);
        revealerPd.lastMoveTimestamp = uint96(block.timestamp);
        revealerPd.numMovesRevealed += 1;

        // Emit reveal event
        emit MoveReveal(battleKey, msg.sender, moveIndex);

        // Auto-execute is not possible here since committer hasn't revealed yet
        // (the revealer in a 2-player turn cannot trigger execute)
        // We ignore the autoExecute parameter for correctness
        (autoExecute);
    }
}

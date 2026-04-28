// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";
import {IValidator} from "../IValidator.sol";
import {CommitContext, PlayerDecisionData} from "../Structs.sol";
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
}

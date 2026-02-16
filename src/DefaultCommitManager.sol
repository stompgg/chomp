// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";
import "./Structs.sol";

import {BaseCommitManager} from "./BaseCommitManager.sol";
import {ICommitManager} from "./ICommitManager.sol";
import {IEngine} from "./IEngine.sol";
import {IValidator} from "./IValidator.sol";

/**
 * @title DefaultCommitManager
 * @notice Commit/reveal manager for singles battles (one move per player per turn)
 */
contract DefaultCommitManager is BaseCommitManager, ICommitManager {
    error InvalidMove(address player);

    event MoveReveal(bytes32 indexed battleKey, address player, uint256 moveIndex);

    constructor(IEngine engine) BaseCommitManager(engine) {}

    // Override view functions to satisfy both base class and interface
    function getCommitment(bytes32 battleKey, address player)
        public view override(BaseCommitManager, ICommitManager) returns (bytes32 moveHash, uint256 turnId)
    {
        return BaseCommitManager.getCommitment(battleKey, player);
    }

    function getMoveCountForBattleState(bytes32 battleKey, address player)
        public view override(BaseCommitManager, ICommitManager) returns (uint256)
    {
        return BaseCommitManager.getMoveCountForBattleState(battleKey, player);
    }

    function getLastMoveTimestampForPlayer(bytes32 battleKey, address player)
        public view override(BaseCommitManager, ICommitManager) returns (uint256)
    {
        return BaseCommitManager.getLastMoveTimestampForPlayer(battleKey, player);
    }

    /**
     * @notice Commit a move hash for a singles battle
     * @param battleKey The battle identifier
     * @param moveHash Hash of (moveIndex, salt, extraData)
     */
    function commitMove(bytes32 battleKey, bytes32 moveHash) external {
        _validateCommit(battleKey, moveHash);
    }

    /**
     * @notice Reveal a move for a singles battle
     * @param battleKey The battle identifier
     * @param moveIndex The move index
     * @param salt Salt used in the commitment hash
     * @param extraData Extra data for the move
     * @param autoExecute Whether to auto-execute after both players reveal
     */
    function revealMove(bytes32 battleKey, uint8 moveIndex, bytes32 salt, uint240 extraData, bool autoExecute)
        external
    {
        // Validate preconditions
        (
            CommitContext memory ctx,
            uint256 currentPlayerIndex,
            ,
            PlayerDecisionData storage currentPd,
            PlayerDecisionData storage otherPd,
            bool playerSkipsPreimageCheck
        ) = _validateRevealPreconditions(battleKey);

        // Validate timing and preimage
        bytes32 expectedHash = keccak256(abi.encodePacked(moveIndex, salt, extraData));
        _validateRevealTiming(ctx, currentPd, otherPd, playerSkipsPreimageCheck, expectedHash);

        // Validate move is legal
        if (!IValidator(ctx.validator).validatePlayerMove(battleKey, moveIndex, currentPlayerIndex, extraData)) {
            revert InvalidMove(msg.sender);
        }

        // Store revealed move
        ENGINE.setMove(battleKey, currentPlayerIndex, moveIndex, salt, extraData);

        // Update player data
        _updateAfterReveal(battleKey, currentPlayerIndex, ctx.playerSwitchForTurnFlag);

        emit MoveReveal(battleKey, msg.sender, moveIndex);

        // Auto execute if desired
        if (autoExecute && _shouldAutoExecute(currentPlayerIndex, ctx.playerSwitchForTurnFlag, playerSkipsPreimageCheck)) {
            ENGINE.execute(battleKey);
        }
    }
}

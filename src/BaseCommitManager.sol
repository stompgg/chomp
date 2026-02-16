// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";
import "./Enums.sol";
import "./Structs.sol";

import {IEngine} from "./IEngine.sol";

/**
 * @title BaseCommitManager
 * @notice Abstract base contract with shared commit/reveal logic for singles and doubles
 * @dev Subclasses implement mode-specific validation and move storage
 */
abstract contract BaseCommitManager {
    IEngine internal immutable ENGINE;

    mapping(bytes32 battleKey => mapping(uint256 playerIndex => PlayerDecisionData)) internal playerData;

    error NotP0OrP1();
    error AlreadyCommited();
    error AlreadyRevealed();
    error NotYetRevealed();
    error RevealBeforeOtherCommit();
    error RevealBeforeSelfCommit();
    error WrongPreimage();
    error PlayerNotAllowed();
    error BattleNotYetStarted();
    error BattleAlreadyComplete();

    event MoveCommit(bytes32 indexed battleKey, address player);

    constructor(IEngine engine) {
        ENGINE = engine;
    }

    /**
     * @dev Validates common commit preconditions
     * @return ctx The commit context
     * @return playerIndex The caller's player index
     * @return pd Storage reference to player's decision data
     */
    function _validateCommit(bytes32 battleKey, bytes32 moveHash)
        internal
        returns (CommitContext memory ctx, uint256 playerIndex, PlayerDecisionData storage pd)
    {
        ctx = ENGINE.getCommitContext(battleKey);

        if (ctx.startTimestamp == 0) {
            revert BattleNotYetStarted();
        }

        address caller = msg.sender;
        playerIndex = (caller == ctx.p0) ? 0 : 1;

        if (caller != ctx.p0 && caller != ctx.p1) {
            revert NotP0OrP1();
        }

        if (ctx.winnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        pd = playerData[battleKey][playerIndex];
        uint64 turnId = ctx.turnId;

        // Check no commitment exists for this turn
        if (turnId == 0) {
            if (pd.moveHash != bytes32(0)) {
                revert AlreadyCommited();
            }
        } else if (pd.lastCommitmentTurnId == turnId) {
            revert AlreadyCommited();
        }

        // Cannot commit if it's a single-player switch turn
        if (ctx.playerSwitchForTurnFlag != 2) {
            revert PlayerNotAllowed();
        }

        // Alternating commit: p0 on even turns, p1 on odd turns
        if (caller == ctx.p0 && turnId % 2 == 1) {
            revert PlayerNotAllowed();
        } else if (caller == ctx.p1 && turnId % 2 == 0) {
            revert PlayerNotAllowed();
        }

        // Store commitment
        pd.lastCommitmentTurnId = uint16(turnId);
        pd.moveHash = moveHash;
        pd.lastMoveTimestamp = uint96(block.timestamp);

        emit MoveCommit(battleKey, caller);
    }

    /**
     * @dev Validates common reveal preconditions
     * @return ctx The commit context
     * @return currentPlayerIndex The caller's player index
     * @return otherPlayerIndex The other player's index
     * @return currentPd Storage reference to caller's decision data
     * @return otherPd Storage reference to other player's decision data
     * @return playerSkipsPreimageCheck Whether the caller skips preimage verification
     */
    function _validateRevealPreconditions(bytes32 battleKey)
        internal
        view
        returns (
            CommitContext memory ctx,
            uint256 currentPlayerIndex,
            uint256 otherPlayerIndex,
            PlayerDecisionData storage currentPd,
            PlayerDecisionData storage otherPd,
            bool playerSkipsPreimageCheck
        )
    {
        ctx = ENGINE.getCommitContext(battleKey);

        if (ctx.startTimestamp == 0) {
            revert BattleNotYetStarted();
        }
        if (msg.sender != ctx.p0 && msg.sender != ctx.p1) {
            revert NotP0OrP1();
        }
        if (ctx.winnerIndex != 2) {
            revert BattleAlreadyComplete();
        }

        currentPlayerIndex = msg.sender == ctx.p0 ? 0 : 1;
        otherPlayerIndex = 1 - currentPlayerIndex;

        currentPd = playerData[battleKey][currentPlayerIndex];
        otherPd = playerData[battleKey][otherPlayerIndex];

        uint64 turnId = ctx.turnId;
        uint8 playerSwitchForTurnFlag = ctx.playerSwitchForTurnFlag;

        // Determine if player skips preimage check
        if (playerSwitchForTurnFlag == 2) {
            playerSkipsPreimageCheck =
                (((turnId % 2 == 1) && (currentPlayerIndex == 0)) || ((turnId % 2 == 0) && (currentPlayerIndex == 1)));
        } else {
            playerSkipsPreimageCheck = (playerSwitchForTurnFlag == currentPlayerIndex);
            if (!playerSkipsPreimageCheck) {
                revert PlayerNotAllowed();
            }
        }
    }

    /**
     * @dev Validates reveal timing (commitment order, preimage if needed)
     */
    function _validateRevealTiming(
        CommitContext memory ctx,
        PlayerDecisionData storage currentPd,
        PlayerDecisionData storage otherPd,
        bool playerSkipsPreimageCheck,
        bytes32 expectedHash
    ) internal view {
        uint64 turnId = ctx.turnId;
        uint8 playerSwitchForTurnFlag = ctx.playerSwitchForTurnFlag;

        if (playerSkipsPreimageCheck) {
            // Must wait for other player's commitment (if 2-player turn)
            if (playerSwitchForTurnFlag == 2) {
                if (turnId != 0) {
                    if (otherPd.lastCommitmentTurnId != turnId) {
                        revert RevealBeforeOtherCommit();
                    }
                } else {
                    if (otherPd.moveHash == bytes32(0)) {
                        revert RevealBeforeOtherCommit();
                    }
                }
            }
        } else {
            // Validate preimage
            if (expectedHash != currentPd.moveHash) {
                revert WrongPreimage();
            }

            // Ensure reveal happens after caller commits
            if (currentPd.lastCommitmentTurnId != turnId) {
                revert RevealBeforeSelfCommit();
            }

            // Check that other player has already revealed
            if (otherPd.numMovesRevealed < turnId || otherPd.lastMoveTimestamp == 0) {
                revert NotYetRevealed();
            }
        }

        // Prevent double revealing
        if (currentPd.numMovesRevealed > turnId) {
            revert AlreadyRevealed();
        }
    }

    /**
     * @dev Updates player data after successful reveal
     */
    function _updateAfterReveal(
        bytes32 battleKey,
        uint256 currentPlayerIndex,
        uint8 playerSwitchForTurnFlag
    ) internal {
        PlayerDecisionData storage currentPd = playerData[battleKey][currentPlayerIndex];
        PlayerDecisionData storage otherPd = playerData[battleKey][1 - currentPlayerIndex];

        currentPd.lastMoveTimestamp = uint96(block.timestamp);
        currentPd.numMovesRevealed += 1;

        // Handle single-player turns
        if (playerSwitchForTurnFlag == 0 || playerSwitchForTurnFlag == 1) {
            otherPd.lastMoveTimestamp = uint96(block.timestamp);
            otherPd.numMovesRevealed += 1;
        }
    }

    /**
     * @dev Determines if auto-execute should run
     */
    function _shouldAutoExecute(
        uint256 currentPlayerIndex,
        uint8 playerSwitchForTurnFlag,
        bool playerSkipsPreimageCheck
    ) internal pure returns (bool) {
        return (playerSwitchForTurnFlag == currentPlayerIndex) || (!playerSkipsPreimageCheck);
    }

    // View functions

    function getCommitment(bytes32 battleKey, address player) public view virtual returns (bytes32 moveHash, uint256 turnId) {
        address[] memory players = ENGINE.getPlayersForBattle(battleKey);
        uint256 playerIndex = (player == players[0]) ? 0 : 1;
        PlayerDecisionData storage pd = playerData[battleKey][playerIndex];
        return (pd.moveHash, pd.lastCommitmentTurnId);
    }

    function getMoveCountForBattleState(bytes32 battleKey, address player) public view virtual returns (uint256) {
        address[] memory players = ENGINE.getPlayersForBattle(battleKey);
        uint256 playerIndex = (player == players[0]) ? 0 : 1;
        return playerData[battleKey][playerIndex].numMovesRevealed;
    }

    function getLastMoveTimestampForPlayer(bytes32 battleKey, address player) public view virtual returns (uint256) {
        address[] memory players = ENGINE.getPlayersForBattle(battleKey);
        uint256 playerIndex = (player == players[0]) ? 0 : 1;
        return playerData[battleKey][playerIndex].lastMoveTimestamp;
    }
}

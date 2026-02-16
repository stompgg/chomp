// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";
import "./Enums.sol";
import "./Structs.sol";

import {BaseCommitManager} from "./BaseCommitManager.sol";
import {ICommitManager} from "./ICommitManager.sol";
import {IEngine} from "./IEngine.sol";
import {IValidator} from "./IValidator.sol";

/**
 * @title DoublesCommitManager
 * @notice Commit/reveal manager for double battles where each player commits 2 moves per turn
 * @dev Follows same alternating commit scheme as DefaultCommitManager:
 *      - p0 commits on even turns, p1 commits on odd turns
 *      - Non-committing player reveals first, then committing player reveals
 *      - Each commit/reveal handles both slot 0 and slot 1 moves together
 */
contract DoublesCommitManager is BaseCommitManager, ICommitManager {
    error InvalidMove(address player, uint256 slotIndex);
    error BothSlotsSwitchToSameMon();
    error NotDoublesMode();

    event MoveReveal(bytes32 indexed battleKey, address player, uint256 moveIndex0, uint256 moveIndex1);

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
     * @notice Commit a hash of both moves for a doubles battle
     * @param battleKey The battle identifier
     * @param moveHash Hash of (moveIndex0, extraData0, moveIndex1, extraData1, salt)
     */
    function commitMove(bytes32 battleKey, bytes32 moveHash) external {
        (CommitContext memory ctx,,) = _validateCommit(battleKey, moveHash);

        // Doubles-specific validation
        if (ctx.gameMode != GameMode.Doubles) {
            revert NotDoublesMode();
        }
    }

    /**
     * @notice Commit moves - alias for commitMove to match expected pattern
     */
    function commitMoves(bytes32 battleKey, bytes32 moveHash) external {
        (CommitContext memory ctx,,) = _validateCommit(battleKey, moveHash);

        if (ctx.gameMode != GameMode.Doubles) {
            revert NotDoublesMode();
        }
    }

    /**
     * @notice Reveal both moves for a doubles battle
     * @param battleKey The battle identifier
     * @param moveIndex0 Move index for slot 0 mon
     * @param extraData0 Extra data for slot 0 move (includes target)
     * @param moveIndex1 Move index for slot 1 mon
     * @param extraData1 Extra data for slot 1 move (includes target)
     * @param salt Salt used in the commitment hash
     * @param autoExecute Whether to auto-execute after both players reveal
     */
    function revealMoves(
        bytes32 battleKey,
        uint8 moveIndex0,
        uint240 extraData0,
        uint8 moveIndex1,
        uint240 extraData1,
        bytes32 salt,
        bool autoExecute
    ) external {
        // Validate preconditions
        (
            CommitContext memory ctx,
            uint256 currentPlayerIndex,
            ,
            PlayerDecisionData storage currentPd,
            PlayerDecisionData storage otherPd,
            bool playerSkipsPreimageCheck
        ) = _validateRevealPreconditions(battleKey);

        // Doubles-specific validation
        if (ctx.gameMode != GameMode.Doubles) {
            revert NotDoublesMode();
        }

        // Validate timing and preimage (hash covers both moves)
        bytes32 expectedHash = keccak256(abi.encodePacked(moveIndex0, extraData0, moveIndex1, extraData1, salt));
        _validateRevealTiming(ctx, currentPd, otherPd, playerSkipsPreimageCheck, expectedHash);

        // Validate both moves are legal for their respective slots
        IValidator validator = IValidator(ctx.validator);
        if (!validator.validatePlayerMoveForSlot(battleKey, moveIndex0, currentPlayerIndex, 0, extraData0)) {
            revert InvalidMove(msg.sender, 0);
        }
        // For slot 1, if slot 0 is switching, we need to account for the mon being claimed
        // This allows slot 1 to NO_OP if slot 0 is taking the last available reserve
        if (moveIndex0 == SWITCH_MOVE_INDEX) {
            if (!validator.validatePlayerMoveForSlotWithClaimed(
                battleKey, moveIndex1, currentPlayerIndex, 1, extraData1, uint256(extraData0)
            )) {
                revert InvalidMove(msg.sender, 1);
            }
        } else {
            if (!validator.validatePlayerMoveForSlot(battleKey, moveIndex1, currentPlayerIndex, 1, extraData1)) {
                revert InvalidMove(msg.sender, 1);
            }
        }

        // Prevent both slots from switching to the same mon
        if (moveIndex0 == SWITCH_MOVE_INDEX && moveIndex1 == SWITCH_MOVE_INDEX) {
            if (extraData0 == extraData1) {
                revert BothSlotsSwitchToSameMon();
            }
        }

        // Store both revealed moves using slot-aware setters
        ENGINE.setMoveForSlot(battleKey, currentPlayerIndex, 0, moveIndex0, salt, extraData0);
        ENGINE.setMoveForSlot(battleKey, currentPlayerIndex, 1, moveIndex1, salt, extraData1);

        // Update player data
        _updateAfterReveal(battleKey, currentPlayerIndex, ctx.playerSwitchForTurnFlag);

        emit MoveReveal(battleKey, msg.sender, moveIndex0, moveIndex1);

        // Auto execute if desired
        if (autoExecute && _shouldAutoExecute(currentPlayerIndex, ctx.playerSwitchForTurnFlag, playerSkipsPreimageCheck)) {
            ENGINE.execute(battleKey);
        }
    }

    /**
     * @notice Reveal a single move - required by ICommitManager but not used for doubles
     * @dev Reverts as doubles requires revealMoves with both slot moves
     */
    function revealMove(bytes32, uint8, bytes32, uint240, bool) external pure {
        revert NotDoublesMode();
    }
}

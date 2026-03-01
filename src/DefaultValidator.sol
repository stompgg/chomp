// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "./Constants.sol";
import "./Structs.sol";
import "./moves/IMoveSet.sol";

import {IEngine} from "./IEngine.sol";
import {IValidator} from "./IValidator.sol";
import {ValidatorLogic, TimeoutCheckParams} from "./lib/ValidatorLogic.sol";

import {ICommitManager} from "./commit-manager/ICommitManager.sol";
import {IMonRegistry} from "./teams/IMonRegistry.sol";

contract DefaultValidator is IValidator {
    struct Args {
        uint256 MONS_PER_TEAM;
        uint256 MOVES_PER_MON;
        uint256 TIMEOUT_DURATION;
    }

    uint256 public constant PREV_TURN_MULTIPLIER = 2;

    uint256 immutable MONS_PER_TEAM;
    uint256 immutable BITMAP_VALUE_FOR_MONS_PER_TEAM;
    uint256 immutable MOVES_PER_MON;
    uint256 public immutable TIMEOUT_DURATION;
    IEngine immutable ENGINE;

    mapping(address => mapping(bytes32 => uint256)) proposalTimestampForProposer;

    constructor(IEngine _ENGINE, Args memory args) {
        ENGINE = _ENGINE;
        MONS_PER_TEAM = args.MONS_PER_TEAM;
        BITMAP_VALUE_FOR_MONS_PER_TEAM = (uint256(1) << args.MONS_PER_TEAM) - 1;
        MOVES_PER_MON = args.MOVES_PER_MON;
        TIMEOUT_DURATION = args.TIMEOUT_DURATION;
    }

    // Validates that there are MONS_PER_TEAM mons per team w/ MOVES_PER_MON moves each
    function validateGameStart(address p0, address p1, Mon[][] calldata teams, ITeamRegistry teamRegistry, uint256 p0TeamIndex, uint256 p1TeamIndex
    ) external returns (bool) {
        IMonRegistry monRegistry = teamRegistry.getMonRegistry();

        // p0 and p1 each have 6 mons, each mon has 4 moves
        uint256[2] memory playerIndices = [uint256(0), uint256(1)];
        address[2] memory players = [p0, p1];
        uint256[2] memory teamIndex = [uint256(p0TeamIndex), uint256(p1TeamIndex)];

        // If either player has a team count of zero, then it's invalid
        {
            uint256 p0teamCount = teamRegistry.getTeamCount(p0);
            uint256 p1TeamCount = teamRegistry.getTeamCount(p1);
            if (p0teamCount == 0 || p1TeamCount == 0) {
                return false;
            }
        }
        // Otherwise, we check team and move length
        for (uint256 i; i < playerIndices.length; ++i) {
            if (teams[i].length != MONS_PER_TEAM) {
                return false;
            }

            // Check moves length for each mon
            for (uint256 j; j < MONS_PER_TEAM; ++j) {
                if (teams[i][j].moves.length != MOVES_PER_MON) {
                    return false;
                }
            }

            // Batch validate all mons against registry (1 external call instead of MONS_PER_TEAM)
            if (address(monRegistry) != address(0)) {
                uint256[] memory teamIndices = teamRegistry.getMonRegistryIndicesForTeam(players[i], teamIndex[i]);
                if (!monRegistry.validateMonBatch(teams[i], teamIndices)) {
                    return false;
                }
            }
        }
        return true;
    }

    // A switch is valid if the new mon isn't knocked out and the index is valid (not out of range or the same one)
    // For doubles, also checks that the mon isn't already active in either slot
    function validateSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monToSwitchIndex)
        public
        view
        returns (bool)
    {
        BattleContext memory ctx = ENGINE.getBattleContext(battleKey);
        uint256 activeMonIndex = (playerIndex == 0) ? ctx.p0ActiveMonIndex : ctx.p1ActiveMonIndex;

        if (monToSwitchIndex >= MONS_PER_TEAM) {
            return false;
        }
        bool isNewMonKnockedOut =
            ENGINE.getMonStateForBattle(battleKey, playerIndex, monToSwitchIndex, MonStateIndexName.IsKnockedOut) == 1;
        if (isNewMonKnockedOut) {
            return false;
        }
        if (ctx.turnId != 0) {
            if (monToSwitchIndex == activeMonIndex) {
                return false;
            }
            // For doubles, also check the second slot
            if (ctx.gameMode == GameMode.Doubles) {
                uint256 activeMonIndex2 = (playerIndex == 0) ? ctx.p0ActiveMonIndex1 : ctx.p1ActiveMonIndex1;
                if (monToSwitchIndex == activeMonIndex2) {
                    return false;
                }
            }
        }
        return true;
    }

    // A slot-aware switch validation for doubles
    // Uses the slot index to determine which active mon is the "current" vs "other" slot
    function validateSwitchForSlot(bytes32 battleKey, uint256 playerIndex, uint256 slotIndex, uint256 monToSwitchIndex)
        public
        view
        returns (bool)
    {
        BattleContext memory ctx = ENGINE.getBattleContext(battleKey);
        uint256 activeMonIndex = _getActiveMonForSlot(ctx, playerIndex, slotIndex);
        uint256 otherSlotActiveMonIndex = _getActiveMonForSlot(ctx, playerIndex, 1 - slotIndex);

        bool isTargetKnockedOut = ENGINE.getMonStateForBattle(
            battleKey, playerIndex, monToSwitchIndex, MonStateIndexName.IsKnockedOut
        ) == 1;

        return ValidatorLogic.validateSwitchForSlot(
            ctx.turnId, monToSwitchIndex, activeMonIndex, otherSlotActiveMonIndex, type(uint256).max, isTargetKnockedOut, MONS_PER_TEAM
        );
    }

    function validateSpecificMoveSelection(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint240 extraData
    ) public view returns (bool) {
        BattleContext memory ctx = ENGINE.getBattleContext(battleKey);
        uint256 activeMonIndex = (playerIndex == 0) ? ctx.p0ActiveMonIndex : ctx.p1ActiveMonIndex;

        IMoveSet moveSet = ENGINE.getMoveForMonForBattle(battleKey, playerIndex, activeMonIndex, moveIndex);
        int32 staminaDelta =
            ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Stamina);
        uint32 baseStamina =
            ENGINE.getMonValueForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Stamina);

        return ValidatorLogic.validateSpecificMoveSelection(
            battleKey,
            moveSet,
            playerIndex,
            activeMonIndex,
            extraData,
            baseStamina,
            staminaDelta
        );
    }

    // Validates that you can't switch to the same mon, you have enough stamina, the move isn't disabled, etc.
    function validatePlayerMove(bytes32 battleKey, uint256 moveIndex, uint256 playerIndex, uint240 extraData)
        external
        view
        returns (bool)
    {
        // Use batch context to minimize external calls (reduces SLOADs significantly)
        ValidationContext memory vctx = ENGINE.getValidationContext(battleKey);
        uint256 activeMonIndex = (playerIndex == 0) ? vctx.p0ActiveMonIndex : vctx.p1ActiveMonIndex;
        bool isActiveMonKnockedOut = (playerIndex == 0) ? vctx.p0ActiveMonKnockedOut : vctx.p1ActiveMonKnockedOut;

        // Use library for basic validation
        (, bool isNoOp, bool isSwitch, bool isRegularMove, bool basicValid) =
            ValidatorLogic.validatePlayerMoveBasics(moveIndex, vctx.turnId, isActiveMonKnockedOut, MOVES_PER_MON);

        if (!basicValid) {
            return false;
        }

        // No-op is always valid (if basic validation passed)
        if (isNoOp) {
            return true;
        }

        // Switch validation
        if (isSwitch) {
            uint256 monToSwitchIndex = uint256(extraData);
            return _validateSwitchInternalWithContext(battleKey, playerIndex, monToSwitchIndex, vctx);
        }

        // Regular move validation
        if (isRegularMove) {
            return _validateSpecificMoveSelectionWithContext(battleKey, moveIndex, playerIndex, extraData, activeMonIndex, vctx);
        }

        return true;
    }

    // Internal version using ValidationContext to avoid redundant SLOADs
    function _validateSwitchInternalWithContext(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 monToSwitchIndex,
        ValidationContext memory vctx
    ) internal view returns (bool) {
        uint256 activeMonIndex = (playerIndex == 0) ? vctx.p0ActiveMonIndex : vctx.p1ActiveMonIndex;

        // Still need external call to check if switch target is KO'd (not in context)
        bool isTargetKnockedOut =
            ENGINE.getMonStateForBattle(battleKey, playerIndex, monToSwitchIndex, MonStateIndexName.IsKnockedOut) == 1;

        return ValidatorLogic.validateSwitch(
            vctx.turnId,
            activeMonIndex,
            monToSwitchIndex,
            isTargetKnockedOut,
            MONS_PER_TEAM
        );
    }

    // Internal version using ValidationContext for stamina check
    function _validateSpecificMoveSelectionWithContext(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint240 extraData,
        uint256 activeMonIndex,
        ValidationContext memory vctx
    ) internal view returns (bool) {
        // Use pre-fetched stamina values from context
        uint32 baseStamina = (playerIndex == 0) ? vctx.p0ActiveMonBaseStamina : vctx.p1ActiveMonBaseStamina;
        int32 staminaDelta = (playerIndex == 0) ? vctx.p0ActiveMonStaminaDelta : vctx.p1ActiveMonStaminaDelta;

        // Still need external call to get the move (can't batch all moves)
        IMoveSet moveSet = ENGINE.getMoveForMonForBattle(battleKey, playerIndex, activeMonIndex, moveIndex);

        return ValidatorLogic.validateSpecificMoveSelection(
            battleKey,
            moveSet,
            playerIndex,
            activeMonIndex,
            extraData,
            baseStamina,
            staminaDelta
        );
    }

    // Validates a move for a specific slot in doubles mode
    function validatePlayerMoveForSlot(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint256 slotIndex,
        uint240 extraData
    ) external view returns (bool) {
        return _validatePlayerMoveForSlotImpl(battleKey, moveIndex, playerIndex, slotIndex, extraData, type(uint256).max);
    }

    // Validates a move for a specific slot, preventing the same mon from being claimed by both slots
    function validatePlayerMoveForSlotWithClaimed(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint256 slotIndex,
        uint240 extraData,
        uint256 claimedByOtherSlot
    ) external view returns (bool) {
        return _validatePlayerMoveForSlotImpl(battleKey, moveIndex, playerIndex, slotIndex, extraData, claimedByOtherSlot);
    }

    // Shared implementation for slot move validation
    function _validatePlayerMoveForSlotImpl(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint256 slotIndex,
        uint240 extraData,
        uint256 claimedByOtherSlot
    ) internal view returns (bool) {
        BattleContext memory ctx = ENGINE.getBattleContext(battleKey);

        uint256 activeMonIndex = _getActiveMonForSlot(ctx, playerIndex, slotIndex);
        uint256 otherSlotActiveMonIndex = _getActiveMonForSlot(ctx, playerIndex, 1 - slotIndex);

        bool isActiveMonKnockedOut = ENGINE.getMonStateForBattle(
            battleKey, playerIndex, activeMonIndex, MonStateIndexName.IsKnockedOut
        ) == 1;

        // Only compute hasValidSwitchTarget when needed (forced switch + non-switch move)
        bool hasValidSwitchTarget = true;
        if ((ctx.turnId == 0 || isActiveMonKnockedOut) && moveIndex != SWITCH_MOVE_INDEX) {
            hasValidSwitchTarget = _hasValidSwitchTargetForSlot(battleKey, playerIndex, otherSlotActiveMonIndex, claimedByOtherSlot);
        }

        // Use library for basic validation
        (, bool isNoOp, bool isSwitch, bool isRegularMove, bool basicValid) =
            ValidatorLogic.validatePlayerMoveBasicsForSlot(moveIndex, ctx.turnId, isActiveMonKnockedOut, hasValidSwitchTarget, MOVES_PER_MON);

        if (!basicValid) {
            return false;
        }

        // No-op is always valid (if basic validation passed)
        if (isNoOp) {
            return true;
        }

        // Switch validation using library
        if (isSwitch) {
            uint256 monToSwitchIndex = uint256(extraData);
            bool isTargetKnockedOut = ENGINE.getMonStateForBattle(
                battleKey, playerIndex, monToSwitchIndex, MonStateIndexName.IsKnockedOut
            ) == 1;
            return ValidatorLogic.validateSwitchForSlot(
                ctx.turnId, monToSwitchIndex, activeMonIndex, otherSlotActiveMonIndex, claimedByOtherSlot, isTargetKnockedOut, MONS_PER_TEAM
            );
        }

        // Regular move validation
        if (isRegularMove) {
            return _validateSpecificMoveSelectionInternal(battleKey, moveIndex, playerIndex, extraData, activeMonIndex);
        }

        return true;
    }

    // Checks if there's any valid switch target for a slot in doubles (loop with early return for gas efficiency)
    function _hasValidSwitchTargetForSlot(
        bytes32 battleKey,
        uint256 playerIndex,
        uint256 otherSlotActiveMonIndex,
        uint256 claimedByOtherSlot
    ) internal view returns (bool) {
        for (uint256 i = 0; i < MONS_PER_TEAM; i++) {
            if (i == otherSlotActiveMonIndex) continue;
            if (i == claimedByOtherSlot) continue;
            bool isKnockedOut = ENGINE.getMonStateForBattle(
                battleKey, playerIndex, i, MonStateIndexName.IsKnockedOut
            ) == 1;
            if (!isKnockedOut) {
                return true;
            }
        }
        return false;
    }

    // Internal version for specific move selection validation
    function _validateSpecificMoveSelectionInternal(
        bytes32 battleKey,
        uint256 moveIndex,
        uint256 playerIndex,
        uint240 extraData,
        uint256 activeMonIndex
    ) internal view returns (bool) {
        IMoveSet moveSet = ENGINE.getMoveForMonForBattle(battleKey, playerIndex, activeMonIndex, moveIndex);
        int32 staminaDelta =
            ENGINE.getMonStateForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Stamina);
        uint32 baseStamina =
            ENGINE.getMonValueForBattle(battleKey, playerIndex, activeMonIndex, MonStateIndexName.Stamina);
        return ValidatorLogic.validateSpecificMoveSelection(
            battleKey, moveSet, playerIndex, activeMonIndex, extraData, baseStamina, staminaDelta
        );
    }

    // Helper to get active mon index for a specific slot from BattleContext
    function _getActiveMonForSlot(BattleContext memory ctx, uint256 playerIndex, uint256 slotIndex)
        internal
        pure
        returns (uint256)
    {
        if (playerIndex == 0) {
            return slotIndex == 0 ? ctx.p0ActiveMonIndex : ctx.p0ActiveMonIndex1;
        } else {
            return slotIndex == 0 ? ctx.p1ActiveMonIndex : ctx.p1ActiveMonIndex1;
        }
    }

    /*
        Check switch for turn flag:

        // 0 or 1:
        - if it's not us, then we skip
        - if it is us, then we need to check the timestamp from last turn, and we either timeout or don't

        // 2:
        - we are committing + revealing:
            - we have not committed:
                - check the timestamp from last turn, and we either timeout or don't

            - we have already committed:
                - other player has revealed
                    - check the timestamp from their reveal, and we either timeout or don't
                - other player has not revealed
                    - we don't timeout

        - we are revealing:
            - other player has not committed:
                - we don't timeout

            - other player has committed:
                - check the timestamp from their commit, and we either timeout or don't
    */
    function validateTimeout(bytes32 battleKey, uint256 playerIndexToCheck) external view returns (address loser) {
        BattleContext memory ctx = ENGINE.getBattleContext(battleKey);
        uint256 otherPlayerIndex = 1 - playerIndexToCheck;

        ICommitManager commitManager = ICommitManager(ctx.moveManager);
        address[2] memory players = [ctx.p0, ctx.p1];

        // Fetch commit data for both players
        (bytes32 playerMoveHash, uint256 playerCommitTurnId) =
            commitManager.getCommitment(battleKey, players[playerIndexToCheck]);
        (bytes32 otherPlayerMoveHash, uint256 otherPlayerCommitTurnId) =
            commitManager.getCommitment(battleKey, players[otherPlayerIndex]);

        // Build params struct
        TimeoutCheckParams memory params = TimeoutCheckParams({
            turnId: ctx.turnId,
            playerSwitchForTurnFlag: ctx.playerSwitchForTurnFlag,
            playerIndexToCheck: playerIndexToCheck,
            lastTurnTimestamp: ctx.turnId == 0 ? ctx.startTimestamp : ENGINE.getLastExecuteTimestamp(battleKey),
            timeoutDuration: TIMEOUT_DURATION,
            prevTurnMultiplier: PREV_TURN_MULTIPLIER,
            playerMoveHash: playerMoveHash,
            playerCommitTurnId: playerCommitTurnId,
            otherPlayerRevealCount: commitManager.getMoveCountForBattleState(battleKey, players[otherPlayerIndex]),
            otherPlayerTimestamp: commitManager.getLastMoveTimestampForPlayer(battleKey, players[otherPlayerIndex]),
            otherPlayerMoveHash: otherPlayerMoveHash,
            otherPlayerCommitTurnId: otherPlayerCommitTurnId
        });

        if (ValidatorLogic.validateTimeoutLogic(params)) {
            return players[playerIndexToCheck];
        }
        return address(0);
    }
}

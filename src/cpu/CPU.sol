// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";

import {IMatchmaker} from "../matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../moves/IMoveSet.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {ICPU} from "./ICPU.sol";
import {CPUMoveManager} from "./CPUMoveManager.sol";
import {IValidator} from "../IValidator.sol";
import {NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX} from "../Constants.sol";

import {ExtraDataType, GameMode} from "../Enums.sol";
import {Battle, ProposedBattle, RevealedMove} from "../Structs.sol";

abstract contract CPU is CPUMoveManager, ICPU, ICPURNG, IMatchmaker {
    uint256 private immutable NUM_MOVES;

    ICPURNG public immutable RNG;
    uint256 public nonceToUse;

    constructor(uint256 numMoves, IEngine engine, ICPURNG rng) CPUMoveManager(engine) {
        NUM_MOVES = numMoves;
        if (address(rng) == address(0)) {
            RNG = ICPURNG(address(this));
        } else {
            RNG = rng;
        }
    }

    /**
     * If it's turn 0, randomly selects a mon index to swap to
     *     Otherwise, randomly selects a valid move, switch index, or no op
     */
    function calculateMove(bytes32 battleKey, uint256 playerIndex)
        external
        virtual
        returns (uint128 moveIndex, uint240 extraData);

    /**
     *  - If it's a switch needed turn, returns only valid switches
     *  - If it's a non-switch turn, returns valid moves, valid switches, and no-op separately
     */
    function calculateValidMoves(bytes32 battleKey, uint256 playerIndex)
        public
        returns (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches)
    {
        uint256 turnId = ENGINE.getTurnIdForBattleState(battleKey);
        uint256 nonce = nonceToUse;
        if (turnId == 0) {
            uint256 teamSize = ENGINE.getTeamSize(battleKey, playerIndex);
            RevealedMove[] memory switchChoices = new RevealedMove[](teamSize);
            for (uint256 i = 0; i < teamSize; i++) {
                switchChoices[i] = RevealedMove({moveIndex: SWITCH_MOVE_INDEX, salt: "", extraData: uint240(i)});
            }
            nonceToUse = nonce;
            return (new RevealedMove[](0), new RevealedMove[](0), switchChoices);
        } else {
            IValidator validator = ENGINE.getBattleValidator(battleKey);
            uint256[] memory validSwitchIndices;
            uint256 validSwitchCount;
            // Check for valid switches
            {
                uint256[] memory activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey);
                uint256 teamSize = ENGINE.getTeamSize(battleKey, playerIndex);
                validSwitchIndices = new uint256[](teamSize);
                for (uint256 i = 0; i < teamSize; i++) {
                    if (i != activeMonIndex[playerIndex]) {
                        if (validator
                            .validatePlayerMove(battleKey, SWITCH_MOVE_INDEX, playerIndex, uint240(i))) {
                            validSwitchIndices[validSwitchCount++] = i;
                        }
                    }
                }
            }
            // If it's a turn where we need to make a switch, then we should just return valid switches
            {
                uint256 playerSwitchForTurnFlag = ENGINE.getPlayerSwitchForTurnFlagForBattleState(battleKey);
                if (playerSwitchForTurnFlag == 1) {
                    RevealedMove[] memory switchChoices = new RevealedMove[](validSwitchCount);
                    for (uint256 i = 0; i < validSwitchCount; i++) {
                        switchChoices[i] = RevealedMove({
                            moveIndex: SWITCH_MOVE_INDEX, salt: "", extraData: uint240(validSwitchIndices[i])
                        });
                    }
                    nonceToUse = nonce;
                    return (new RevealedMove[](0), new RevealedMove[](0), switchChoices);
                }
            }
            uint8[] memory validMoveIndices;
            uint240[] memory validMoveExtraData;
            uint256 validMoveCount;
            // Check for valid moves
            {
                uint256[] memory activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey);
                validMoveIndices = new uint8[](NUM_MOVES);
                validMoveExtraData = new uint240[](NUM_MOVES);
                for (uint256 i = 0; i < NUM_MOVES; i++) {
                    IMoveSet move =
                        ENGINE.getMoveForMonForBattle(battleKey, playerIndex, activeMonIndex[playerIndex], i);
                    uint240 extraDataToUse = 0;
                    if (move.extraDataType() == ExtraDataType.SelfTeamIndex) {
                        // Skip if there are no valid switches
                        if (validSwitchCount == 0) {
                            continue;
                        }
                        uint256 randomIndex =
                            RNG.getRNG(keccak256(abi.encode(nonce++, battleKey, block.timestamp))) % validSwitchCount;
                        extraDataToUse = uint240(validSwitchIndices[randomIndex]);
                        validMoveExtraData[validMoveCount] = extraDataToUse;
                    }
                    if (validator.validatePlayerMove(battleKey, i, playerIndex, extraDataToUse)) {
                        validMoveIndices[validMoveCount++] = uint8(i);
                    }
                }
            }
            // Build separate arrays for moves, switches, and noOp
            RevealedMove[] memory validMovesArray = new RevealedMove[](validMoveCount);
            for (uint256 i = 0; i < validMoveCount; i++) {
                validMovesArray[i] =
                    RevealedMove({moveIndex: validMoveIndices[i], salt: "", extraData: validMoveExtraData[i]});
            }
            RevealedMove[] memory validSwitchesArray = new RevealedMove[](validSwitchCount);
            for (uint256 i = 0; i < validSwitchCount; i++) {
                validSwitchesArray[i] = RevealedMove({
                    moveIndex: SWITCH_MOVE_INDEX, salt: "", extraData: uint240(validSwitchIndices[i])
                });
            }
            RevealedMove[] memory noOpArray = new RevealedMove[](1);
            noOpArray[0] = RevealedMove({moveIndex: NO_OP_MOVE_INDEX, salt: "", extraData: 0});

            nonceToUse = nonce;
            return (noOpArray, validMovesArray, validSwitchesArray);
        }
    }

    function getRNG(bytes32 seed) public pure returns (uint256) {
        return uint256(seed);
    }

    function startBattle(ProposedBattle memory proposal) external returns (bytes32 battleKey) {
        (battleKey,) = ENGINE.computeBattleKey(proposal.p0, proposal.p1);
        ENGINE.startBattle(
            Battle({
                p0: proposal.p0,
                p0TeamIndex: proposal.p0TeamIndex,
                p1: proposal.p1,
                p1TeamIndex: proposal.p1TeamIndex,
                teamRegistry: proposal.teamRegistry,
                validator: proposal.validator,
                rngOracle: proposal.rngOracle,
                ruleset: proposal.ruleset,
                engineHooks: proposal.engineHooks,
                moveManager: proposal.moveManager,
                matchmaker: proposal.matchmaker,
                gameMode: proposal.gameMode
            })
        );
    }

    function validateMatch(bytes32, address) external pure returns (bool) {
        return true;
    }
}

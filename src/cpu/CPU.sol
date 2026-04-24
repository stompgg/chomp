// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";

import {NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX} from "../Constants.sol";
import {ValidatorLogic} from "../lib/ValidatorLogic.sol";
import {IMatchmaker} from "../matchmaker/IMatchmaker.sol";
import {IMoveSet} from "../moves/IMoveSet.sol";
import {MoveSlotLib} from "../moves/MoveSlotLib.sol";
import {ICPURNG} from "../rng/ICPURNG.sol";
import {CPUMoveManager} from "./CPUMoveManager.sol";
import {ICPU} from "./ICPU.sol";

import {ExtraDataType} from "../Enums.sol";
import {Battle, CPUContext, ProposedBattle, RevealedMove} from "../Structs.sol";

abstract contract CPU is CPUMoveManager, ICPU, ICPURNG, IMatchmaker {
    uint256 internal immutable NUM_MOVES;

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
    function calculateMove(CPUContext memory ctx, uint8 playerMoveIndex, uint240 playerExtraData)
        external
        virtual
        returns (uint128 moveIndex, uint240 extraData);

    /**
     * Public test-friendly wrapper: fetches context and forwards. playerIndex is ignored
     * because CPU self-registers as p1 in every battle it hosts.
     */
    function calculateValidMoves(bytes32 battleKey, uint256)
        public
        returns (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches)
    {
        return _calculateValidMoves(ENGINE.getCPUContext(battleKey));
    }

    /**
     *  - If it's a switch needed turn, returns only valid switches
     *  - If it's a non-switch turn, returns valid moves, valid switches, and no-op separately
     */
    function _calculateValidMoves(CPUContext memory ctx)
        internal
        returns (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches)
    {
        uint256 nonce = nonceToUse;
        if (ctx.turnId == 0) {
            uint256 teamSize = ctx.p1TeamSize;
            RevealedMove[] memory switchChoices = new RevealedMove[](teamSize);
            for (uint256 i = 0; i < teamSize; i++) {
                switchChoices[i] = RevealedMove({moveIndex: SWITCH_MOVE_INDEX, salt: "", extraData: uint240(i)});
            }
            return (new RevealedMove[](0), new RevealedMove[](0), switchChoices);
        }

        uint256 activeMonIndex = ctx.p1ActiveMonIndex;
        uint256[] memory validSwitchIndices;
        uint256 validSwitchCount;
        // Check for valid switches
        {
            uint256 teamSize = ctx.p1TeamSize;
            validSwitchIndices = new uint256[](teamSize);
            for (uint256 i = 0; i < teamSize; i++) {
                if (i != activeMonIndex) {
                    if (_validateCPUMove(ctx, SWITCH_MOVE_INDEX, uint240(i))) {
                        validSwitchIndices[validSwitchCount++] = i;
                    }
                }
            }
        }
        // If it's a turn where we need to make a switch, then we should just return valid switches
        if (ctx.playerSwitchForTurnFlag == 1) {
            RevealedMove[] memory switchChoices = new RevealedMove[](validSwitchCount);
            for (uint256 i = 0; i < validSwitchCount; i++) {
                switchChoices[i] = RevealedMove({
                    moveIndex: SWITCH_MOVE_INDEX,
                    salt: "",
                    extraData: uint240(validSwitchIndices[i])
                });
            }
            return (new RevealedMove[](0), new RevealedMove[](0), switchChoices);
        }
        uint8[] memory validMoveIndices = new uint8[](NUM_MOVES);
        uint240[] memory validMoveExtraData = new uint240[](NUM_MOVES);
        uint256 validMoveCount;
        // Check for valid moves
        for (uint256 i = 0; i < NUM_MOVES; i++) {
            uint256 rawMoveSlot = ctx.cpuActiveMonMoveSlots[i];
            uint240 extraDataToUse = 0;
            // Inline moves always have ExtraDataType.None — skip extraData logic
            if (!MoveSlotLib.isInline(rawMoveSlot)) {
                IMoveSet move = MoveSlotLib.toIMoveSet(rawMoveSlot);
                if (move.extraDataType() == ExtraDataType.SelfTeamIndex) {
                    // Skip if there are no valid switches
                    if (validSwitchCount == 0) {
                        continue;
                    }
                    uint256 randomIndex =
                        _sampleRNG(keccak256(abi.encode(nonce++, ctx.battleKey, block.timestamp))) % validSwitchCount;
                    extraDataToUse = uint240(validSwitchIndices[randomIndex]);
                    validMoveExtraData[validMoveCount] = extraDataToUse;
                } else if (move.extraDataType() == ExtraDataType.OpponentNonKOTeamIndex) {
                    uint256 opponentTeamSize = ctx.p0TeamSize;
                    uint256 koBitmap = ctx.p0KOBitmap;
                    uint256[] memory validTargets = new uint256[](opponentTeamSize);
                    uint256 validTargetCount;
                    for (uint256 j = 0; j < opponentTeamSize; j++) {
                        if ((koBitmap & (1 << j)) == 0) {
                            validTargets[validTargetCount++] = j;
                        }
                    }
                    if (validTargetCount == 0) {
                        continue;
                    }
                    uint256 randomIndex =
                        _sampleRNG(keccak256(abi.encode(nonce++, ctx.battleKey, block.timestamp))) % validTargetCount;
                    extraDataToUse = uint240(validTargets[randomIndex]);
                    validMoveExtraData[validMoveCount] = extraDataToUse;
                }
            }
            if (_validateCPUMove(ctx, uint8(i), extraDataToUse)) {
                validMoveIndices[validMoveCount++] = uint8(i);
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
            validSwitchesArray[i] =
                RevealedMove({moveIndex: SWITCH_MOVE_INDEX, salt: "", extraData: uint240(validSwitchIndices[i])});
        }
        RevealedMove[] memory noOpArray = new RevealedMove[](1);
        noOpArray[0] = RevealedMove({moveIndex: NO_OP_MOVE_INDEX, salt: "", extraData: 0});

        nonceToUse = nonce;
        return (noOpArray, validMovesArray, validSwitchesArray);
    }

    function _sampleRNG(bytes32 seed) internal view returns (uint256) {
        if (address(RNG) == address(this)) {
            return uint256(seed);
        }
        return RNG.getRNG(seed);
    }

    /// @notice Validate a candidate CPU move. For the inline validator (ctx.validator == 0) we
    ///         run ValidatorLogic directly against the data the engine already handed us in the
    ///         context — skipping the storage re-resolution, config/state SLOADs, and move slot
    ///         SLOAD that Engine.validatePlayerMoveForBattle would repeat on every call. When an
    ///         external validator is attached we still round-trip through the engine so the
    ///         validator's rules remain authoritative.
    /// @dev NUM_MOVES and ctx.p1TeamSize are used as bounds. In production both match the engine's
    ///      DEFAULT_MOVES_PER_MON / DEFAULT_MONS_PER_TEAM; the CPU's own iteration already bounds
    ///      moveIndex below NUM_MOVES and monToSwitchIndex below p1TeamSize, so the basic/switch
    ///      checks are equivalent to the engine-side versions.
    function _validateCPUMove(CPUContext memory ctx, uint8 moveIndex, uint240 extraData)
        internal
        returns (bool)
    {
        if (ctx.validator == address(0)) {
            return _inlineValidateCPUMove(ctx, moveIndex, extraData);
        }
        return ENGINE.validatePlayerMoveForBattle(ctx.battleKey, moveIndex, 1, extraData);
    }

    function _inlineValidateCPUMove(CPUContext memory ctx, uint8 moveIndex, uint240 extraData)
        private
        view
        returns (bool)
    {
        (, bool isNoOp, bool isSwitch, bool isRegularMove, bool basicValid) = ValidatorLogic.validatePlayerMoveBasics(
            moveIndex, ctx.turnId, ctx.cpuActiveMonKnockedOut, NUM_MOVES
        );
        if (!basicValid) {
            return false;
        }
        if (isNoOp) {
            return true;
        }
        if (isSwitch) {
            uint256 monToSwitchIndex = uint256(extraData);
            bool isTargetKnockedOut = (ctx.p1KOBitmap & (1 << monToSwitchIndex)) != 0;
            return ValidatorLogic.validateSwitch(
                ctx.turnId, ctx.p1ActiveMonIndex, monToSwitchIndex, isTargetKnockedOut, ctx.p1TeamSize
            );
        }
        if (isRegularMove) {
            return ValidatorLogic.validateSpecificMoveSelection(
                ENGINE,
                ctx.battleKey,
                ctx.cpuActiveMonMoveSlots[moveIndex],
                1,
                ctx.p1ActiveMonIndex,
                extraData,
                ctx.cpuActiveMonBaseStamina,
                ctx.cpuActiveMonStaminaDelta
            );
        }
        return true;
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
                matchmaker: proposal.matchmaker
            })
        );
    }

    function validateMatch(bytes32, address) external pure returns (bool) {
        return true;
    }
}

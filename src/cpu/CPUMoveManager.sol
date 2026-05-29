// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {ICPU} from "./ICPU.sol";

abstract contract CPUMoveManager {
    IEngine internal immutable ENGINE;

    error NotP0();

    constructor(IEngine engine) {
        ENGINE = engine;

        // Self-register as an approved matchmaker
        address[] memory self = new address[](1);
        self[0] = address(this);
        address[] memory empty = new address[](0);
        engine.updateMatchmakers(self, empty);
    }

    function selectMove(bytes32 battleKey, uint8 moveIndex, uint104 salt, uint16 extraData) external {
        // Routing read: p0 / winnerIndex / playerSwitchForTurnFlag off the BattleContext (the dedicated
        // getCPURouteContext getter was removed to shrink the engine surface). When the turn is "p0
        // forced switch" (flag == 0) or the game is already over we return without building the full CPUContext.
        BattleContext memory rctx = ENGINE.getBattleContext(battleKey);
        (address p0, uint8 winnerIndex, uint8 playerSwitchForTurnFlag) =
            (rctx.p0, rctx.winnerIndex, rctx.playerSwitchForTurnFlag);

        if (msg.sender != p0) {
            revert NotP0();
        }

        if (winnerIndex != 2) {
            return;
        }

        address winner;
        if (playerSwitchForTurnFlag == 0) {
            winner = ENGINE.executeWithSingleMove(battleKey, moveIndex, salt, extraData);
        } else {
            // P1's turn or both players move: CPU calculates its move. Fetch the full context now.
            CPUContext memory ctx = _buildCPUContext(battleKey);
            (uint128 cpuMoveIndex, uint16 cpuExtraData) =
                ICPU(address(this)).calculateMove(ctx, moveIndex, extraData);
            // Salt narrows to 104 bits to match the engine's storage; ample for an unpredictable
            // RNG source within the seconds-to-minutes commit-reveal window.
            uint104 p1Salt = uint104(uint256(keccak256(abi.encode(battleKey, msg.sender, block.timestamp))));

            if (playerSwitchForTurnFlag == 1) {
                winner = ENGINE.executeWithSingleMove(battleKey, uint8(cpuMoveIndex), p1Salt, cpuExtraData);
            } else {
                winner = ENGINE.executeWithMoves(
                    battleKey, moveIndex, salt, extraData, uint8(cpuMoveIndex), p1Salt, cpuExtraData
                );
            }
        }

        _afterTurn(battleKey, p0, winner);
    }

    /// @notice Off-chain-decision CPU flow: p0 submits BOTH their move and the CPU's move (computed
    ///         client-side) in one tx, and the engine executes them directly — NO on-chain
    ///         `getCPUContext` load and NO `calculateMove`. This removes the dozen-plus cold SLOADs
    ///         + the heuristic compute the engine would otherwise pay every CPU turn.
    /// @dev Trust model: the CPU move is not verified. Lying only makes the CPU play worse against
    ///      p0 (a self-inflicted handicap), so there's no on-chain incentive to cheat in PvE; an
    ///      off-chain server/replay can still validate the CPU move if rewards depend on it. The
    ///      committer binding is the same as `selectMove`: `msg.sender == p0`.
    function selectMoveWithCpuMove(
        bytes32 battleKey,
        uint8 playerMoveIndex,
        uint104 playerSalt,
        uint16 playerExtraData,
        uint8 cpuMoveIndex,
        uint16 cpuExtraData
    ) external {
        BattleContext memory rctx = ENGINE.getBattleContext(battleKey);
        (address p0, uint8 winnerIndex, uint8 playerSwitchForTurnFlag) =
            (rctx.p0, rctx.winnerIndex, rctx.playerSwitchForTurnFlag);

        if (msg.sender != p0) {
            revert NotP0();
        }
        if (winnerIndex != 2) {
            return;
        }

        address winner;
        if (playerSwitchForTurnFlag == 0) {
            // p0 forced switch — CPU doesn't act.
            winner = ENGINE.executeWithSingleMove(battleKey, playerMoveIndex, playerSalt, playerExtraData);
        } else {
            // Derive the CPU's salt deterministically (no client input needed; off-chain replay
            // reconstructs it from the same inputs).
            uint104 cpuSalt = uint104(uint256(keccak256(abi.encode(battleKey, msg.sender, block.timestamp))));
            if (playerSwitchForTurnFlag == 1) {
                // CPU forced switch — p0 doesn't act.
                winner = ENGINE.executeWithSingleMove(battleKey, cpuMoveIndex, cpuSalt, cpuExtraData);
            } else {
                winner = ENGINE.executeWithMoves(
                    battleKey, playerMoveIndex, playerSalt, playerExtraData, cpuMoveIndex, cpuSalt, cpuExtraData
                );
            }
        }

        _afterTurn(battleKey, p0, winner);
    }

    /// @notice Assemble the CPU decision context from granular engine reads. Replaces the removed
    ///         `Engine.getCPUContext` batch getter (to be revisited in the CPU-flow overhaul). Assumes
    ///         the CPU is p1. `getBattle()` is the faithful source for the active mon's move-slot array
    ///         *with its length* (per-slot `getMoveForMonForBattle` reverts past `moves.length`, which
    ///         breaks <4-move mons); KO bitmaps come from the dedicated getter rather than being
    ///         reconstructed from monStates.
    function _buildCPUContext(bytes32 battleKey) internal view returns (CPUContext memory ctx) {
        (BattleConfigView memory cfg, BattleData memory data) = ENGINE.getBattle(battleKey);

        ctx.battleKey = battleKey;
        ctx.p0 = data.p0;
        ctx.p1 = data.p1;
        ctx.validator = address(cfg.validator);
        ctx.winnerIndex = data.winnerIndex;
        ctx.playerSwitchForTurnFlag = data.playerSwitchForTurnFlag;
        ctx.turnId = data.turnId;

        // activeMonIndex packs p0 in the low byte, p1 in the high byte.
        uint256 p1MonIndex = uint8(data.activeMonIndex >> 8);
        ctx.p0ActiveMonIndex = uint8(data.activeMonIndex);
        ctx.p1ActiveMonIndex = uint8(p1MonIndex);

        ctx.p0TeamSize = cfg.teamSizes & 0x0F;
        ctx.p1TeamSize = cfg.teamSizes >> 4;

        ctx.p0KOBitmap = uint8(ENGINE.getKOBitmap(battleKey, 0));
        ctx.p1KOBitmap = uint8(ENGINE.getKOBitmap(battleKey, 1));

        Mon memory p1Active = cfg.teams[1][p1MonIndex];
        MonState memory p1State = cfg.monStates[1][p1MonIndex];
        ctx.cpuActiveMonBaseStamina = p1Active.stats.stamina;
        ctx.cpuActiveMonStaminaDelta =
            p1State.staminaDelta == CLEARED_MON_STATE_SENTINEL ? int32(0) : p1State.staminaDelta;
        ctx.cpuActiveMonKnockedOut = p1State.isKnockedOut;

        uint256 len = p1Active.moves.length;
        if (len > 4) len = 4;
        for (uint256 i; i < len; ++i) {
            ctx.cpuActiveMonMoveSlots[i] = p1Active.moves[i];
        }
    }

    /// @notice Post-execute hook. `winner == address(0)` means the battle is still ongoing;
    ///         otherwise it's the winning player's address. Subclasses override to react.
    function _afterTurn(bytes32 battleKey, address p0, address winner) internal virtual {}
}

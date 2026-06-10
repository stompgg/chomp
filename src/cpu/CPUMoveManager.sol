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

    /// @notice One-tx PvE flow: p0 submits the WHOLE game's moves (theirs + the CPU's, computed
    ///         off-chain) plus their own per-turn salt, and the engine executes every turn in one tx —
    ///         collapsing the N per-turn submit txs into one. The player supplies a salt each turn (the
    ///         RNG entropy on their side); the CPU's salt is always 0x0, since a CPU has no move to
    ///         hide. CPU-ONLY by construction — PvP routes through a different move manager
    ///         (commit-reveal) and never reaches here.
    /// @dev `moves` packs 19 bytes per turn: [p0Move 1 | p0Extra 2 | p0Salt 13 (104-bit) | p1Move 1 |
    ///      p1Extra 2]; the CPU's salt is omitted (0). Raw move indices (the engine applies
    ///      MOVE_INDEX_OFFSET). The CPU move is unverified — same trust model as `selectMoveWithCpuMove`
    ///      (lying only handicaps the CPU). Committer binding: `msg.sender == p0`.
    function executeGame(bytes32 battleKey, bytes calldata moves) external returns (address winner) {
        BattleContext memory rctx = ENGINE.getBattleContext(battleKey);
        if (msg.sender != rctx.p0) {
            revert NotP0();
        }
        if (rctx.winnerIndex != 2) {
            return address(0);
        }

        uint256 numTurns = moves.length / 19;
        uint256[] memory entries = new uint256[](numTurns);
        for (uint256 i; i < numTurns; ++i) {
            uint256 off = i * 19;
            // One chunk load per turn (calldata slice -> bytes19; byte 0 lands in the high byte
            // of the 152-bit word) replaces 19 bounds-checked per-byte reads including a
            // 13-iteration salt loop. Layout: [p0Move 1 | p0Extra 2 | p0Salt 13 | p1Move 1 | p1Extra 2]
            uint256 word = uint256(uint152(bytes19(moves[off:off + 19])));
            uint256 p0Move = (word >> 144) & 0xFF;
            uint256 p0Extra = (word >> 128) & 0xFFFF;
            uint256 p0Salt = (word >> 24) & ((uint256(1) << 104) - 1);
            uint256 p1Move = (word >> 16) & 0xFF;
            uint256 p1Extra = word & 0xFFFF;
            // entry: p0Move 8 | p0Extra 16 | p0Salt 104 | p1Move 8 | p1Extra 16 | p1Salt 104 (= 0).
            entries[i] = p0Move | (p0Extra << 8) | (p0Salt << 24) | (p1Move << 128) | (p1Extra << 136);
        }
        (, winner) = ENGINE.executeBatchedTurns(battleKey, entries);
        _afterTurn(battleKey, rctx.p0, winner);
    }

    /// @notice Assemble the CPU decision context from granular engine reads. The old wide
    ///         `Engine.getBattle` hydration materialized both full teams, all effects, and the
    ///         globalKV buffer (~130k+ per on-chain CPU turn) to extract ~12 scalars — and its
    ///         tuple decode overflowed via-IR's stack allocator once BattleData grew. Granular
    ///         getters read exactly what the CPU consumes. Assumes the CPU is p1. Zero move
    ///         slots mean "no move here" (fixed-lane team storage returns 0 for empty lanes).
    function _buildCPUContext(bytes32 battleKey) internal view returns (CPUContext memory ctx) {
        BattleContext memory bctx = ENGINE.getBattleContext(battleKey);
        ctx.battleKey = battleKey;
        ctx.p0 = bctx.p0;
        ctx.p1 = bctx.p1;
        ctx.validator = bctx.validator;
        ctx.winnerIndex = bctx.winnerIndex;
        ctx.playerSwitchForTurnFlag = bctx.playerSwitchForTurnFlag;
        ctx.turnId = bctx.turnId;
        ctx.p0ActiveMonIndex = bctx.p0ActiveMonIndex;
        ctx.p1ActiveMonIndex = bctx.p1ActiveMonIndex;
        ctx.p0TeamSize = uint8(ENGINE.getTeamSize(battleKey, 0));
        ctx.p1TeamSize = uint8(ENGINE.getTeamSize(battleKey, 1));
        ctx.p0KOBitmap = uint8(ENGINE.getKOBitmap(battleKey, 0));
        ctx.p1KOBitmap = uint8(ENGINE.getKOBitmap(battleKey, 1));

        uint256 p1MonIndex = bctx.p1ActiveMonIndex;
        ctx.cpuActiveMonBaseStamina =
            ENGINE.getMonValueForBattle(battleKey, 1, p1MonIndex, MonStateIndexName.Stamina);
        // getMonStateForBattle normalizes the cleared sentinel to 0, matching the old hydration.
        ctx.cpuActiveMonStaminaDelta =
            ENGINE.getMonStateForBattle(battleKey, 1, p1MonIndex, MonStateIndexName.Stamina);
        ctx.cpuActiveMonKnockedOut =
            ENGINE.getMonStateForBattle(battleKey, 1, p1MonIndex, MonStateIndexName.IsKnockedOut) != 0;
        for (uint256 i; i < 4; ++i) {
            ctx.cpuActiveMonMoveSlots[i] = ENGINE.getMoveForMonForBattle(battleKey, 1, p1MonIndex, i);
        }
    }

    /// @notice Post-execute hook. `winner == address(0)` means the battle is still ongoing;
    ///         otherwise it's the winning player's address. Subclasses override to react.
    function _afterTurn(bytes32 battleKey, address p0, address winner) internal virtual {}
}

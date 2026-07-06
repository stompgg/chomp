// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";

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

    /// @notice Off-chain-decision CPU flow: p0 submits BOTH their move and the CPU's move (computed
    ///         client-side) in one tx, and the engine executes them directly — NO on-chain context
    ///         load and NO on-chain move computation.
    /// @dev Trust model: the CPU move is not verified. Lying only makes the CPU play worse against
    ///      p0 (a self-inflicted handicap), so there's no on-chain incentive to cheat in PvE; an
    ///      off-chain server/replay can still validate the CPU move if rewards depend on it. Committer
    ///      binding: `msg.sender == p0`.
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

    /// @notice 2-slot (Doubles) analog of selectMoveWithCpuMove: p0 submits their full side
    ///         word plus the CPU side's two client-computed lanes in one tx. No forced-switch
    ///         flag dispatch is needed — both side words always land in the engine and a mask
    ///         turn ignores the non-acting lanes (clients pass NO_OP filler there).
    /// @param playerSidePacked p0's wire side word: [m0 8 | e0 16 | m1 8 | e1 16 | salt 104].
    function selectSlotMovesWithCpuMoves(
        bytes32 battleKey,
        uint256 playerSidePacked,
        uint8 cpuMove0,
        uint16 cpuExtra0,
        uint8 cpuMove1,
        uint16 cpuExtra1
    ) external {
        BattleContext memory rctx = ENGINE.getBattleContext(battleKey);
        if (msg.sender != rctx.p0) {
            revert NotP0();
        }
        if (rctx.winnerIndex != 2) {
            return;
        }

        // Same deterministic CPU-side salt as the singles flow.
        uint104 cpuSalt = uint104(uint256(keccak256(abi.encode(battleKey, msg.sender, block.timestamp))));
        uint256 cpuSidePacked = uint256(cpuMove0) | (uint256(cpuExtra0) << 8) | (uint256(cpuMove1) << 24)
            | (uint256(cpuExtra1) << 32) | (uint256(cpuSalt) << 48);
        address winner = ENGINE.executeWithSlotMoves(battleKey, playerSidePacked, cpuSidePacked);

        _afterTurn(battleKey, rctx.p0, winner);
    }

    /// @notice One-tx 2-slot PvE flow: p0 submits the whole game's turns and the engine settles
    ///         them in one tx (executeBatchedSlotTurns). The CPU side's salt is always 0, as on
    ///         the singles batched path.
    /// @dev `moves` packs 25 bytes per turn: [side0 19B = m0 1 | e0 2 | m1 1 | e1 2 | salt 13
    ///      | side1 6B = m0 1 | e0 2 | m1 1 | e1 2] — each slice is the big-endian tail of the
    ///      wire side word, so the stream bytes match the BattleCompleteWithBatchSlotTurns
    ///      replay payload byte-for-byte (minus the winner prefix).
    function executeSlotGame(bytes32 battleKey, bytes calldata moves) external returns (address winner) {
        BattleContext memory rctx = ENGINE.getBattleContext(battleKey);
        if (msg.sender != rctx.p0) {
            revert NotP0();
        }
        if (rctx.winnerIndex != 2) {
            return address(0);
        }

        uint256 numTurns = moves.length / 25;
        uint256[] memory entries = new uint256[](numTurns * 2);
        for (uint256 i; i < numTurns; ++i) {
            uint256 off = i * 25;
            entries[i * 2] = uint256(uint152(bytes19(moves[off:off + 19])));
            entries[i * 2 + 1] = uint256(uint48(bytes6(moves[off + 19:off + 25])));
        }
        (, winner) = ENGINE.executeBatchedSlotTurns(battleKey, entries);
        _afterTurn(battleKey, rctx.p0, winner);
    }

    /// @notice Post-execute hook. `winner == address(0)` means the battle is still ongoing;
    ///         otherwise it's the winning player's address. Subclasses override to react.
    function _afterTurn(bytes32 battleKey, address p0, address winner) internal virtual {}
}

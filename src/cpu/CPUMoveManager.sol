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
        // Cheap routing staticcall: one SLOAD for p0 / winnerIndex / playerSwitchForTurnFlag.
        // When the turn is "p0 forced switch" (flag == 0) or the game is already over we return
        // without ever paying for the full CPUContext (which would load team sizes, KO bitmaps,
        // p1's active mon state, and all four move slots — none of which we'd use).
        (address p0, uint8 winnerIndex, uint8 playerSwitchForTurnFlag) = ENGINE.getCPURouteContext(battleKey);

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
            CPUContext memory ctx = ENGINE.getCPUContext(battleKey);
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
        (address p0, uint8 winnerIndex, uint8 playerSwitchForTurnFlag) = ENGINE.getCPURouteContext(battleKey);

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

    /// @notice Post-execute hook. `winner == address(0)` means the battle is still ongoing;
    ///         otherwise it's the winning player's address. Subclasses override to react.
    function _afterTurn(bytes32 battleKey, address p0, address winner) internal virtual {}
}

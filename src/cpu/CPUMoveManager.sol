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

        if (playerSwitchForTurnFlag == 0) {
            ENGINE.executeWithSingleMove(battleKey, moveIndex, salt, extraData);
            return;
        }

        // P1's turn or both players move: CPU calculates its move. Fetch the full context now.
        CPUContext memory ctx = ENGINE.getCPUContext(battleKey);
        (uint128 cpuMoveIndex, uint16 cpuExtraData) = ICPU(address(this)).calculateMove(ctx, moveIndex, extraData);
        uint104 p1Salt = uint104(uint256(keccak256(abi.encode(battleKey, msg.sender, block.timestamp))));

        if (playerSwitchForTurnFlag == 1) {
            ENGINE.executeWithSingleMove(battleKey, uint8(cpuMoveIndex), p1Salt, cpuExtraData);
            return;
        }

        // Single external call: set both moves and execute
        ENGINE.executeWithMoves(battleKey, moveIndex, salt, extraData, uint8(cpuMoveIndex), p1Salt, cpuExtraData);
    }
}

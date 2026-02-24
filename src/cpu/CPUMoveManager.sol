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

    function selectMove(bytes32 battleKey, uint8 moveIndex, bytes32 salt, uint240 extraData) external {
        if (msg.sender != ENGINE.getPlayersForBattle(battleKey)[0]) {
            revert NotP0();
        }

        if (ENGINE.getWinner(battleKey) != address(0)) {
            return;
        }

        uint256 playerSwitchForTurnFlag = ENGINE.getPlayerSwitchForTurnFlagForBattleState(battleKey);

        // Prepare moves based on turn flag
        uint8 p0MoveIndex;
        uint240 p0ExtraData;
        uint8 p1MoveIndex;
        bytes32 p1Salt;
        uint240 p1ExtraData;

        if (playerSwitchForTurnFlag == 0) {
            // P0's turn: player moves, CPU no-ops
            p0MoveIndex = moveIndex;
            p0ExtraData = extraData;
            p1MoveIndex = NO_OP_MOVE_INDEX;
            p1Salt = "";
            p1ExtraData = 0;
        } else {
            // P1's turn or both players move: CPU calculates its move
            (uint128 cpuMoveIndex, uint240 cpuExtraData) = ICPU(address(this)).calculateMove(battleKey, 1, moveIndex, extraData);
            p1MoveIndex = uint8(cpuMoveIndex);
            p1Salt = keccak256(abi.encode(battleKey, msg.sender, block.timestamp));
            p1ExtraData = cpuExtraData;

            if (playerSwitchForTurnFlag == 1) {
                // P1's turn only: player no-ops
                p0MoveIndex = NO_OP_MOVE_INDEX;
                p0ExtraData = 0;
            } else {
                // Both players move
                p0MoveIndex = moveIndex;
                p0ExtraData = extraData;
            }
        }

        // Single external call: set both moves and execute
        ENGINE.executeWithMoves(battleKey, p0MoveIndex, salt, p0ExtraData, p1MoveIndex, p1Salt, p1ExtraData);
    }
}

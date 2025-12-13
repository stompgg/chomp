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

        address winner = ENGINE.getWinner(battleKey);
        if (winner != address(0)) {
            return;
        }

        uint256 playerSwitchForTurnFlag = ENGINE.getPlayerSwitchForTurnFlagForBattleState(battleKey);

        // Determine move configuration based on turn flag
        if (playerSwitchForTurnFlag == 0) {
            // P0's turn: player moves, CPU no-ops
            _addPlayerMove(battleKey, moveIndex, salt, extraData);
            _addCPUMove(battleKey, NO_OP_MOVE_INDEX, "", 0);
        } else if (playerSwitchForTurnFlag == 1) {
            // P1's turn: player no-ops, CPU moves
            _addPlayerMove(battleKey, NO_OP_MOVE_INDEX, salt, extraData);
            _addCPUMoveFromAI(battleKey);
        } else {
            // Both players move
            _addPlayerMove(battleKey, moveIndex, salt, extraData);
            _addCPUMoveFromAI(battleKey);
        }

        ENGINE.execute(battleKey);
    }

    function _addPlayerMove(bytes32 battleKey, uint8 moveIndex, bytes32 salt, uint240 extraData) private {
        ENGINE.setMove(battleKey, 0, moveIndex, salt, extraData);
    }

    function _addCPUMove(bytes32 battleKey, uint8 moveIndex, bytes32 salt, uint240 extraData) private {
        ENGINE.setMove(battleKey, 1, moveIndex, salt, extraData);
    }

    function _addCPUMoveFromAI(bytes32 battleKey) private {
        (uint128 cpuMoveIndex, uint240 cpuExtraData) = ICPU(address(this)).calculateMove(battleKey, 1);
        bytes32 cpuSalt = keccak256(abi.encode(battleKey, msg.sender, block.timestamp));
        _addCPUMove(battleKey, uint8(cpuMoveIndex), cpuSalt, cpuExtraData);
    }
}

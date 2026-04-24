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
        // Single batched staticcall replaces getPlayersForBattle + getWinner +
        // getPlayerSwitchForTurnFlagForBattleState + the getters CPU.calculateValidMoves needs.
        CPUContext memory ctx = ENGINE.getCPUContext(battleKey);

        if (msg.sender != ctx.p0) {
            revert NotP0();
        }

        if (ctx.winnerIndex != 2) {
            return;
        }

        uint256 playerSwitchForTurnFlag = ctx.playerSwitchForTurnFlag;

        if (playerSwitchForTurnFlag == 0) {
            ENGINE.executeWithSingleMove(battleKey, moveIndex, salt, extraData);
            return;
        }

        // P1's turn or both players move: CPU calculates its move
        (uint128 cpuMoveIndex, uint240 cpuExtraData) =
            ICPU(address(this)).calculateMove(ctx, moveIndex, extraData);
        bytes32 p1Salt = keccak256(abi.encode(battleKey, msg.sender, block.timestamp));

        if (playerSwitchForTurnFlag == 1) {
            ENGINE.executeWithSingleMove(battleKey, uint8(cpuMoveIndex), p1Salt, cpuExtraData);
            return;
        }

        // Single external call: set both moves and execute
        ENGINE.executeWithMoves(battleKey, moveIndex, salt, extraData, uint8(cpuMoveIndex), p1Salt, cpuExtraData);
    }
}

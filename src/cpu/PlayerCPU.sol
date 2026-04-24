// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";

import {ICPURNG} from "../rng/ICPURNG.sol";
import {CPU} from "./CPU.sol";

import {CPUContext, RevealedMove} from "../Structs.sol";

contract PlayerCPU is CPU {
    mapping(bytes32 battleKey => RevealedMove) private declaredMoveForBattle;

    constructor(uint256 numMoves, IEngine engine, ICPURNG rng) CPU(numMoves, engine, rng) {}

    function setMove(bytes32 battleKey, uint8 moveIndex, uint240 extraData) external {
        if (msg.sender != ENGINE.getPlayersForBattle(battleKey)[0]) {
            revert NotP0();
        }
        declaredMoveForBattle[battleKey] = RevealedMove({moveIndex: moveIndex, salt: "", extraData: extraData});
    }

    /**
     * Returns the move that p0 declared for this CPU, ignoring the rest of the context.
     */
    function calculateMove(CPUContext memory ctx, uint8, uint240)
        external
        view
        override
        returns (uint128 moveIndex, uint240 extraData)
    {
        return (declaredMoveForBattle[ctx.battleKey].moveIndex, declaredMoveForBattle[ctx.battleKey].extraData);
    }
}

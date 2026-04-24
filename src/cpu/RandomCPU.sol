// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../IEngine.sol";

import {ICPURNG} from "../rng/ICPURNG.sol";
import {CPU} from "./CPU.sol";

import {CPUContext, RevealedMove} from "../Structs.sol";

contract RandomCPU is CPU {
    constructor(uint256 numMoves, IEngine engine, ICPURNG rng) CPU(numMoves, engine, rng) {}

    /**
     * If it's turn 0, randomly selects a mon index to swap to
     *     Otherwise, randomly selects a valid move, switch index, or no op
     */
    function calculateMove(CPUContext memory ctx, uint8, uint240)
        external
        override
        returns (uint128 moveIndex, uint240 extraData)
    {
        (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
            _calculateValidMoves(ctx);

        uint256 totalChoices = noOp.length + moves.length + switches.length;
        uint256 randomIndex =
            _sampleRNG(keccak256(abi.encode(nonceToUse++, ctx.battleKey, block.timestamp))) % totalChoices;

        if (randomIndex < noOp.length) {
            return (noOp[randomIndex].moveIndex, noOp[randomIndex].extraData);
        }
        randomIndex -= noOp.length;
        if (randomIndex < moves.length) {
            return (moves[randomIndex].moveIndex, moves[randomIndex].extraData);
        }
        randomIndex -= moves.length;
        return (switches[randomIndex].moveIndex, switches[randomIndex].extraData);
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {CPUContext, ProposedBattle} from "../Structs.sol";

interface ICPU {
    function calculateMove(CPUContext memory ctx, uint8 playerMoveIndex, uint16 playerExtraData)
        external
        returns (uint128 moveIndex, uint16 extraData);
    function startBattle(ProposedBattle memory proposal) external returns (bytes32 battleKey);
}

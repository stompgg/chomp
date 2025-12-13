// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ProposedBattle} from "../Structs.sol";

interface ICPU {
    function calculateMove(bytes32 battleKey, uint256 playerIndex)
        external
        returns (uint128 moveIndex, uint240 extraData);
    function startBattle(ProposedBattle memory proposal) external returns (bytes32 battleKey);
}

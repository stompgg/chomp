// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";

import {IEngine} from "../../IEngine.sol";

library NineNineNineLib {
    uint32 constant NINE_NINE_NINE_CRIT_RATE = 90;

    function _getKey(uint256 playerIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, "NINE_NINE_NINE"));
    }

    function _getEffectiveCritRate(IEngine engine, bytes32 battleKey, uint256 playerIndex)
        internal
        view
        returns (uint32)
    {
        uint192 boostTurn = engine.getGlobalKV(battleKey, _getKey(playerIndex));
        uint256 currentTurn = engine.getTurnIdForBattleState(battleKey);
        if (boostTurn > 0 && uint256(boostTurn) == currentTurn) {
            return NINE_NINE_NINE_CRIT_RATE;
        }
        return DEFAULT_CRIT_RATE;
    }
}

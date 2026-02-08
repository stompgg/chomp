// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";

import {IEngine} from "../../IEngine.sol";

library EkinekiLib {
    uint32 constant NINE_NINE_NINE_CRIT_RATE = 90;

    // --- 999 crit rate boost ---

    function _getNineNineNineKey(uint256 playerIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, "NINE_NINE_NINE"));
    }

    function _getEffectiveCritRate(IEngine engine, bytes32 battleKey, uint256 playerIndex)
        internal
        view
        returns (uint32)
    {
        uint192 boostTurn = engine.getGlobalKV(battleKey, _getNineNineNineKey(playerIndex));
        uint256 currentTurn = engine.getTurnIdForBattleState(battleKey);
        if (boostTurn > 0 && uint256(boostTurn) == currentTurn) {
            return NINE_NINE_NINE_CRIT_RATE;
        }
        return DEFAULT_CRIT_RATE;
    }

    // --- Sneak Attack once-per-switch-in tracking ---

    function _getSneakAttackKey(uint256 playerIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, "SNEAK_ATTACK"));
    }

    function _getSneakAttackUsed(IEngine engine, bytes32 battleKey, uint256 playerIndex)
        internal
        view
        returns (uint192)
    {
        return engine.getGlobalKV(battleKey, _getSneakAttackKey(playerIndex));
    }

    function _setSneakAttackUsed(IEngine engine, uint256 playerIndex, uint192 value) internal {
        engine.setGlobalKV(_getSneakAttackKey(playerIndex), value);
    }

    // --- Savior Complex once-per-game tracking ---

    function _getSaviorComplexKey(uint256 playerIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, "SAVIOR_COMPLEX"));
    }

    function _getSaviorComplexTriggered(IEngine engine, bytes32 battleKey, uint256 playerIndex)
        internal
        view
        returns (bool)
    {
        return engine.getGlobalKV(battleKey, _getSaviorComplexKey(playerIndex)) == 1;
    }

    function _setSaviorComplexTriggered(IEngine engine, uint256 playerIndex) internal {
        engine.setGlobalKV(_getSaviorComplexKey(playerIndex), 1);
    }
}

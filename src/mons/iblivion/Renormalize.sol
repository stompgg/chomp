// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";

import {Baselight} from "./Baselight.sol";
import {Loop} from "./Loop.sol";

/**
 * Renormalize Move for Iblivion
 * - Stamina: 0, Type: Yin, Class: Self, Priority: -1 (below normal)
 * - Sets Baselight level to 3
 * - Clears all StatBoost instances (resets all stat boosts including Loop's effect)
 * - Clears Loop active flag so Loop can be used again
 */
contract Renormalize is IMoveSet {
    IEngine immutable ENGINE;
    Baselight immutable BASELIGHT;
    StatBoosts immutable STAT_BOOSTS;
    Loop immutable LOOP;

    constructor(IEngine _ENGINE, Baselight _BASELIGHT, StatBoosts _STAT_BOOSTS, Loop _LOOP) {
        ENGINE = _ENGINE;
        BASELIGHT = _BASELIGHT;
        STAT_BOOSTS = _STAT_BOOSTS;
        LOOP = _LOOP;
    }

    function name() public pure override returns (string memory) {
        return "Renormalize";
    }

    function move(
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint240,
        uint256
    ) external {
        // Set Baselight level to 3
        BASELIGHT.setBaselightLevel(battleKey, attackerPlayerIndex, attackerMonIndex, 3);

        // Clear Loop active flag so Loop can be used again
        LOOP.clearLoopActive(attackerPlayerIndex, attackerMonIndex);

        // Clear all StatBoost effects and reset stats to base values
        STAT_BOOSTS.clearAllBoostsForMon(attackerPlayerIndex, attackerMonIndex);
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 0;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY - 1;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Yang;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

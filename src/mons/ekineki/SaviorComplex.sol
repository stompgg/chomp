// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {MonStateIndexName, StatBoostFlag, StatBoostType} from "../../Enums.sol";
import {StatBoostToApply} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";

contract SaviorComplex is IAbility {
    uint8 public constant STAGE_1_BOOST = 15; // 1 KO'd
    uint8 public constant STAGE_2_BOOST = 25; // 2 KO'd
    uint8 public constant STAGE_3_BOOST = 30; // 3+ KO'd

    IEngine immutable ENGINE;
    StatBoosts immutable STAT_BOOSTS;

    constructor(IEngine _ENGINE, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() external pure returns (string memory) {
        return "Savior Complex";
    }

    function _getSaviorComplexKey(uint256 playerIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, "SAVIOR_COMPLEX"));
    }

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Check if already triggered this game
        if (ENGINE.getGlobalKV(battleKey, _getSaviorComplexKey(playerIndex)) == 1) {
            return;
        }

        // Count KO'd mons via bitmap popcount
        uint256 koBitmap = ENGINE.getKOBitmap(battleKey, playerIndex);
        if (koBitmap == 0) return;
        uint256 koCount = 0;
        for (uint256 bits = koBitmap; bits != 0; bits >>= 1) {
            koCount += bits & 1;
        }

        // Determine boost based on stage
        uint8 boostPercent;
        if (koCount >= 3) {
            boostPercent = STAGE_3_BOOST;
        } else if (koCount >= 2) {
            boostPercent = STAGE_2_BOOST;
        } else {
            boostPercent = STAGE_1_BOOST;
        }

        // Apply temporary sp atk boost (cleared on switch out)
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: boostPercent,
            boostType: StatBoostType.Multiply
        });
        STAT_BOOSTS.addStatBoosts(playerIndex, monIndex, statBoosts, StatBoostFlag.Temp);

        // Mark as triggered (once per game)
        ENGINE.setGlobalKV(_getSaviorComplexKey(playerIndex), 1);
    }
}

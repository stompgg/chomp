// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {MonStateIndexName, StatBoostFlag, StatBoostType} from "../../Enums.sol";
import {StatBoostToApply} from "../../Structs.sol";
import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";
import {EkinekiLib} from "./EkinekiLib.sol";

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

    function activateOnSwitch(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        // Reset sneak attack usage on every switch-in
        EkinekiLib._setSneakAttackUsed(ENGINE, playerIndex, 0);

        // Check if already triggered this game
        if (EkinekiLib._getSaviorComplexTriggered(ENGINE, battleKey, playerIndex)) {
            return;
        }

        // Count KO'd mons on the player's team
        uint256 teamSize = ENGINE.getTeamSize(battleKey, playerIndex);
        uint256 koCount = 0;
        for (uint256 i = 0; i < teamSize; i++) {
            if (ENGINE.getMonStateForBattle(battleKey, playerIndex, i, MonStateIndexName.IsKnockedOut) == 1) {
                koCount++;
            }
        }

        if (koCount == 0) return;

        // Determine boost based on stage
        uint8 boostPercent;
        if (koCount >= 3) {
            boostPercent = STAGE_3_BOOST;
        } else if (koCount >= 2) {
            boostPercent = STAGE_2_BOOST;
        } else {
            boostPercent = STAGE_1_BOOST;
        }

        // Apply sp atk boost
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: boostPercent,
            boostType: StatBoostType.Multiply
        });
        STAT_BOOSTS.addStatBoosts(playerIndex, monIndex, statBoosts, StatBoostFlag.Perm);

        // Mark as triggered (once per game)
        EkinekiLib._setSaviorComplexTriggered(ENGINE, playerIndex);
    }
}

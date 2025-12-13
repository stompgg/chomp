// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";

contract VolatilePunch is StandardAttack {
    uint32 public constant STATUS_EFFECT_CHANCE = 30; // 15% chance for each status

    IEffect immutable BURN_STATUS;
    IEffect immutable FROSTBITE_STATUS;

    constructor(IEngine ENGINE, ITypeCalculator TYPE_CALCULATOR, IEffect _BURN_STATUS, IEffect _FROSTBITE_STATUS)
        StandardAttack(
            address(msg.sender),
            ENGINE,
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Volatile Punch",
                BASE_POWER: 40,
                STAMINA_COST: 3,
                ACCURACY: 100,
                MOVE_TYPE: Type.Metal,
                MOVE_CLASS: MoveClass.Physical,
                PRIORITY: DEFAULT_PRIORITY,
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {
        BURN_STATUS = _BURN_STATUS;
        FROSTBITE_STATUS = _FROSTBITE_STATUS;
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256 rng)
        public
        override
    {
        // Deal the damage to opponent
        (int32 damage,) = _move(battleKey, attackerPlayerIndex, rng);

        // Apply status effects if damage was dealt
        if (damage > 0) {
            uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
            uint256 defenderMonIndex =
                ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[defenderPlayerIndex];

            // Use a different part of the RNG for status application
            uint256 statusRng = uint256(keccak256(abi.encode(rng, "STATUS_EFFECT")));

            // 30% chance for Burn or Frostbite
            if ((statusRng % 100) < STATUS_EFFECT_CHANCE) {
                uint256 statusSelectorRng = uint256(keccak256(abi.encode(rng, "STATUS_SELECTOR")));
                if (statusSelectorRng % 2 == 0) {
                    ENGINE.addEffect(defenderPlayerIndex, defenderMonIndex, BURN_STATUS, "");
                } else {
                    ENGINE.addEffect(defenderPlayerIndex, defenderMonIndex, FROSTBITE_STATUS, "");
                }
            }
        }
    }
}
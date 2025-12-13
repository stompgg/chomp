// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";

import {IEffect} from "../../effects/IEffect.sol";
import {StandardAttack} from "../../moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";

contract PistolSquat is StandardAttack {
    constructor(IEngine ENGINE, ITypeCalculator TYPE_CALCULATOR)
        StandardAttack(
            address(msg.sender),
            ENGINE,
            TYPE_CALCULATOR,
            ATTACK_PARAMS({
                NAME: "Pistol Squat",
                BASE_POWER: 80,
                STAMINA_COST: 2,
                ACCURACY: 100,
                MOVE_TYPE: Type.Metal,
                MOVE_CLASS: MoveClass.Physical,
                PRIORITY: DEFAULT_PRIORITY - 1, // This is -1 priority
                CRIT_RATE: DEFAULT_CRIT_RATE,
                VOLATILITY: DEFAULT_VOL,
                EFFECT_ACCURACY: 0,
                EFFECT: IEffect(address(0))
            })
        )
    {}

    function _findRandomNonKOedMon(uint256 playerIndex, uint256 currentMonIndex, uint256 rng)
        internal
        view
        returns (int32)
    {
        bytes32 battleKey = ENGINE.battleKeyForWrite();
        uint256 teamSize = ENGINE.getTeamSize(battleKey, playerIndex);
        for (uint256 i; i < teamSize; ++i) {
            uint256 monIndex = (i + rng) % teamSize;
            // Only look at other mons
            if (monIndex != currentMonIndex) {
                bool isKOed =
                    ENGINE.getMonStateForBattle(battleKey, playerIndex, monIndex, MonStateIndexName.IsKnockedOut) == 1;
                if (!isKOed) {
                    return int32(int256(monIndex));
                }
            }
        }
        return -1;
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256 rng)
        public
        override
    {
        // Deal the damage
        super.move(battleKey, attackerPlayerIndex, extraData, rng);

        // Deal damage and then force a switch if the opposing mon is not KO'ed
        uint256 otherPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 otherPlayerActiveMonIndex =
            ENGINE.getActiveMonIndexForBattleState(ENGINE.battleKeyForWrite())[otherPlayerIndex];
        bool isKOed =
            ENGINE.getMonStateForBattle(
                battleKey, otherPlayerIndex, otherPlayerActiveMonIndex, MonStateIndexName.IsKnockedOut
            ) == 1;
        if (!isKOed) {
            int32 possibleSwitchTarget = _findRandomNonKOedMon(otherPlayerIndex, otherPlayerActiveMonIndex, rng);
            if (possibleSwitchTarget != -1) {
                ENGINE.switchActiveMon(otherPlayerIndex, uint256(uint32(possibleSwitchTarget)));
            }
        }
    }
}

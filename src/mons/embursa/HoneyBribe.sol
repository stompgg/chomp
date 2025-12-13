// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {StatBoostToApply} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {HeatBeaconLib} from "./HeatBeaconLib.sol";

contract HoneyBribe is IMoveSet {
    uint256 public constant DEFAULT_HEAL_DENOM = 2;
    uint256 public constant MAX_DIVISOR = 3;
    uint8 public constant SP_DEF_PERCENT = 50;

    IEngine immutable ENGINE;
    StatBoosts immutable STAT_BOOSTS;

    constructor(IEngine _ENGINE, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Honey Bribe";
    }

    function _getBribeLevel(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal view returns (uint256) {
        return uint256(ENGINE.getGlobalKV(battleKey, keccak256(abi.encode(playerIndex, monIndex, name()))));
    }

    function _increaseBribeLevel(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        uint256 bribeLevel = _getBribeLevel(battleKey, playerIndex, monIndex);
        if (bribeLevel < MAX_DIVISOR) {
            ENGINE.setGlobalKV(keccak256(abi.encode(playerIndex, monIndex, name())), uint192(bribeLevel + 1));
        }
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Heal active mon by max HP / 2**bribeLevel
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        uint256 bribeLevel = _getBribeLevel(battleKey, attackerPlayerIndex, activeMonIndex);
        uint32 maxHp = ENGINE.getMonValueForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp);
        int32 healAmount = int32(uint32(maxHp / (DEFAULT_HEAL_DENOM * (2 ** bribeLevel))));
        int32 currentDamage =
            ENGINE.getMonStateForBattle(battleKey, attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp);
        if (currentDamage + healAmount > 0) {
            healAmount = -1 * currentDamage;
        }
        ENGINE.updateMonState(attackerPlayerIndex, activeMonIndex, MonStateIndexName.Hp, healAmount);

        // Heal opposing active mon by max HP / 2**(bribeLevel + 1)
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        uint256 defenderMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[defenderPlayerIndex];
        healAmount = int32(uint32(maxHp / (DEFAULT_HEAL_DENOM * (2 ** (bribeLevel + 1)))));
        currentDamage =
            ENGINE.getMonStateForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Hp);
        if (currentDamage + healAmount > 0) {
            healAmount = -1 * currentDamage;
        }
        ENGINE.updateMonState(defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Hp, healAmount);

        // Reduce opposing mon's SpDEF by 1/2
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialDefense,
            boostPercent: SP_DEF_PERCENT,
            boostType: StatBoostType.Divide
        });
        STAT_BOOSTS.addStatBoosts(defenderPlayerIndex, defenderMonIndex, statBoosts, StatBoostFlag.Temp);

        // Update the bribe level
        _increaseBribeLevel(battleKey, attackerPlayerIndex, activeMonIndex);

        // Clear the priority boost
        if (HeatBeaconLib._getPriorityBoost(ENGINE, attackerPlayerIndex) == 1) {
            HeatBeaconLib._clearPriorityBoost(ENGINE, attackerPlayerIndex);
        }
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(bytes32, uint256 attackerPlayerIndex) external view returns (uint32) {
        return DEFAULT_PRIORITY + HeatBeaconLib._getPriorityBoost(ENGINE, attackerPlayerIndex);
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Nature;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

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

    StatBoosts immutable STAT_BOOSTS;

    constructor(StatBoosts _STAT_BOOSTS) {
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Honey Bribe";
    }

    function _bribeKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode(playerIndex, monIndex, name()))));
    }

    function _getBribeLevel(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        internal
        view
        returns (uint256)
    {
        return uint256(engine.getGlobalKV(battleKey, _bribeKey(playerIndex, monIndex)));
    }

    function _increaseBribeLevel(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) internal {
        uint256 bribeLevel = _getBribeLevel(engine, battleKey, playerIndex, monIndex);
        if (bribeLevel < MAX_DIVISOR) {
            engine.setGlobalKV(_bribeKey(playerIndex, monIndex), uint192(bribeLevel + 1));
        }
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderMonIndex,
        uint240,
        uint256
    ) external {
        // Heal active mon by max HP / 2**bribeLevel
        uint256 bribeLevel = _getBribeLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex);
        uint32 maxHp =
            engine.getMonValueForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
        int32 healAmount = int32(uint32(maxHp / (DEFAULT_HEAL_DENOM * (2 ** bribeLevel))));
        int32 currentDamage =
            engine.getMonStateForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
        if (currentDamage + healAmount > 0) {
            healAmount = -1 * currentDamage;
        }
        engine.updateMonState(attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp, healAmount);

        // Heal opposing active mon by max HP / 2**(bribeLevel + 1)
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        healAmount = int32(uint32(maxHp / (DEFAULT_HEAL_DENOM * (2 ** (bribeLevel + 1)))));
        currentDamage =
            engine.getMonStateForBattle(battleKey, defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Hp);
        if (currentDamage + healAmount > 0) {
            healAmount = -1 * currentDamage;
        }
        engine.updateMonState(defenderPlayerIndex, defenderMonIndex, MonStateIndexName.Hp, healAmount);

        // Reduce opposing mon's SpDEF by 1/2
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialDefense,
            boostPercent: SP_DEF_PERCENT,
            boostType: StatBoostType.Divide
        });
        STAT_BOOSTS.addStatBoosts(engine, defenderPlayerIndex, defenderMonIndex, statBoosts, StatBoostFlag.Temp);

        // Update the bribe level
        _increaseBribeLevel(engine, battleKey, attackerPlayerIndex, attackerMonIndex);

        // Clear the priority boost
        if (HeatBeaconLib._getPriorityBoost(engine, attackerPlayerIndex) == 1) {
            HeatBeaconLib._clearPriorityBoost(engine, attackerPlayerIndex);
        }
    }

    function stamina(IEngine, bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(IEngine engine, bytes32, uint256 attackerPlayerIndex) external view returns (uint32) {
        return DEFAULT_PRIORITY + HeatBeaconLib._getPriorityBoost(engine, attackerPlayerIndex);
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Nature;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

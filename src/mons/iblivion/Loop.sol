// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";

import {Baselight} from "./Baselight.sol";

/**
 * Loop Move for Iblivion
 * - Stamina: 0, Type: Yin, Class: Self
 * - Raises all stats (Attack, Defense, Speed, SpATK, SpDef) by X% where X is based on Baselight level:
 *   - Level 1: 15%
 *   - Level 2: 30%
 *   - Level 3: 40%
 * - Fails if Loop is already active
 * - Effect lasts until swap out (uses temp stat boost)
 */
contract Loop is IMoveSet {
    uint8 public constant BOOST_PERCENT_LEVEL_1 = 15;
    uint8 public constant BOOST_PERCENT_LEVEL_2 = 30;
    uint8 public constant BOOST_PERCENT_LEVEL_3 = 40;

    IEngine immutable ENGINE;
    Baselight immutable BASELIGHT;
    StatBoosts immutable STAT_BOOSTS;

    constructor(IEngine _ENGINE, Baselight _BASELIGHT, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        BASELIGHT = _BASELIGHT;
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Loop";
    }

    function _loopActiveKey(uint256 playerIndex, uint256 monIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, monIndex, name()));
    }

    function isLoopActive(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) public view returns (bool) {
        return ENGINE.getGlobalKV(battleKey, _loopActiveKey(playerIndex, monIndex)) != 0;
    }

    function clearLoopActive(uint256 playerIndex, uint256 monIndex) external {
        ENGINE.setGlobalKV(_loopActiveKey(playerIndex, monIndex), 0);
    }

    function _getBoostPercent(uint256 baselightLevel) internal pure returns (uint8) {
        if (baselightLevel >= 3) {
            return BOOST_PERCENT_LEVEL_3;
        } else if (baselightLevel == 2) {
            return BOOST_PERCENT_LEVEL_2;
        } else if (baselightLevel == 1) {
            return BOOST_PERCENT_LEVEL_1;
        } else {
            return 0;
        }
    }

    function move(
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint240,
        uint256
    ) external {
        // Check if Loop is already active
        if (isLoopActive(battleKey, attackerPlayerIndex, attackerMonIndex)) {
            // Fail - Loop is already active
            return;
        }

        uint256 baselightLevel = BASELIGHT.getBaselightLevel(battleKey, attackerPlayerIndex, attackerMonIndex);
        uint8 boostPercent = _getBoostPercent(baselightLevel);

        // If baselight level is 0, no boost to apply
        if (boostPercent == 0) {
            return;
        }

        // Mark Loop as active
        ENGINE.setGlobalKV(_loopActiveKey(attackerPlayerIndex, attackerMonIndex), 1);

        // Apply stat boosts to all 5 stats (Attack, Defense, SpecialAttack, SpecialDefense, Speed)
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](5);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack,
            boostPercent: boostPercent,
            boostType: StatBoostType.Multiply
        });
        statBoosts[1] = StatBoostToApply({
            stat: MonStateIndexName.Defense,
            boostPercent: boostPercent,
            boostType: StatBoostType.Multiply
        });
        statBoosts[2] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: boostPercent,
            boostType: StatBoostType.Multiply
        });
        statBoosts[3] = StatBoostToApply({
            stat: MonStateIndexName.SpecialDefense,
            boostPercent: boostPercent,
            boostType: StatBoostType.Multiply
        });
        statBoosts[4] = StatBoostToApply({
            stat: MonStateIndexName.Speed,
            boostPercent: boostPercent,
            boostType: StatBoostType.Multiply
        });

        // Use Temp flag so boosts are removed on switch out
        STAT_BOOSTS.addStatBoosts(attackerPlayerIndex, attackerMonIndex, statBoosts, StatBoostFlag.Temp);
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 1;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
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

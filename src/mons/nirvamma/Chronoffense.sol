// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {DEFAULT_ACCURACY, DEFAULT_CRIT_RATE, DEFAULT_PRIORITY, DEFAULT_VOL} from "../../Constants.sol";
import {ExtraDataType, MonStateIndexName, MoveClass, StatBoostFlag, StatBoostType, Type} from "../../Enums.sol";
import {MoveMeta, StatBoostToApply} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IEffect} from "../../effects/IEffect.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract Chronoffense is IMoveSet {
    uint32 public constant BP_COEFFICIENT = 20;
    uint32 public constant BP_CAP = 999;
    uint8 public constant BOOST_PERCENT = 25;

    function name() public pure returns (string memory) {
        return "Chronoffense";
    }

    function _anchorKey(uint256 playerIndex, uint256 monIndex) internal pure returns (uint64) {
        return uint64(uint256(keccak256(abi.encode("Chronoffense", playerIndex, monIndex))));
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 defenderMonIndex,
        uint16,
        uint256 rng
    ) external {
        uint64 key = _anchorKey(attackerPlayerIndex, attackerMonIndex);
        uint256 stored = uint256(engine.getGlobalKV(battleKey, key));
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);

        if (stored == 0) {
            // First use: record anchor (turnId + 1 to keep 0 sentinel).
            engine.setGlobalKV(key, uint192(turnId + 1));

            // Buff SpDef by 25%
            StatBoostToApply[] memory boosts = new StatBoostToApply[](2);
            boosts[0] = StatBoostToApply({
                stat: MonStateIndexName.SpecialDefense,
                boostPercent: BOOST_PERCENT,
                boostType: StatBoostType.Multiply
            });
            boosts[1] = StatBoostToApply({
                stat: MonStateIndexName.Defense,
                boostPercent: BOOST_PERCENT,
                boostType: StatBoostType.Multiply
            });
            engine.addStatBoost(attackerPlayerIndex, attackerMonIndex, boosts, StatBoostFlag.Temp);
            return;
        }

        uint256 elapsed = turnId - (stored - 1);
        uint256 bp = elapsed * elapsed * BP_COEFFICIENT;
        if (bp > BP_CAP) {
            bp = BP_CAP;
        }

        engine.dispatchStandardAttack(
            attackerPlayerIndex,
            defenderMonIndex,
            uint32(bp),
            DEFAULT_ACCURACY,
            DEFAULT_VOL,
            Type.Math,
            MoveClass.Special,
            DEFAULT_CRIT_RATE,
            0,
            IEffect(address(0)),
            rng
        );

        // Re-arm
        engine.setGlobalKV(key, 0);
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Math;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function extraDataType() public pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}

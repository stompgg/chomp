// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {StatBoostToApply} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract Initialize is IMoveSet, BasicEffect {
    uint8 public constant ATTACK_BUFF_PERCENT = 50;
    uint8 public constant SP_ATTACK_BUFF_PERCENT = 50;

    IEngine immutable ENGINE;
    StatBoosts immutable STAT_BOOSTS;

    constructor(IEngine _ENGINE, StatBoosts _STAT_BOOSTS) {
        ENGINE = _ENGINE;
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Initialize";
    }

    function _initializeKey(uint256 playerIndex, uint256 monIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(playerIndex, monIndex, name()));
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240, uint256) external {
        uint256 activeMonIndex = ENGINE.getActiveMonIndexForBattleState(battleKey)[attackerPlayerIndex];
        // Check if global KV is set
        uint192 flag = ENGINE.getGlobalKV(battleKey, _initializeKey(attackerPlayerIndex, activeMonIndex));
        if (flag == 0) {
            // Apply the buffs
            _applyBuff(attackerPlayerIndex, activeMonIndex);

            // Apply effect globally
            ENGINE.addEffect(2, 2, this, _encodeState(attackerPlayerIndex, activeMonIndex));
            // Set global KV to prevent this move doing anything until Inutia swaps out
            ENGINE.setGlobalKV(_initializeKey(attackerPlayerIndex, activeMonIndex), 1);
        }
        // Otherwise we don't do anything
    }

    function _applyBuff(uint256 playerIndex, uint256 monIndex) internal {
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](2);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: SP_ATTACK_BUFF_PERCENT,
            boostType: StatBoostType.Multiply
        });
        statBoosts[1] = StatBoostToApply({
            stat: MonStateIndexName.Attack,
            boostPercent: ATTACK_BUFF_PERCENT,
            boostType: StatBoostType.Multiply
        });
        STAT_BOOSTS.addStatBoosts(playerIndex, monIndex, statBoosts, StatBoostFlag.Temp);
    }

    function stamina(bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(bytes32) public pure returns (Type) {
        return Type.Mythic;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    /**
     *  Effect implementation
     */
    function _encodeState(uint256 playerIndex, uint256 monIndex) internal pure returns (bytes32) {
        return bytes32((playerIndex << 128) | monIndex);
    }

    function _decodeState(bytes32 data) internal pure returns (uint256 playerIndex, uint256 monIndex) {
        playerIndex = uint256(data) >> 128;
        monIndex = uint256(data) & type(uint128).max;
    }

    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return (step == EffectStep.OnMonSwitchIn || step == EffectStep.OnMonSwitchOut);
    }

    function onMonSwitchOut(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        // Clear the initialize lock, but do not remove effect
        (uint256 attackerPlayerIndex, uint256 attackingMonIndex) = _decodeState(extraData);
        if ((attackerPlayerIndex == targetIndex) && (attackingMonIndex == monIndex)) {
            ENGINE.setGlobalKV(_initializeKey(attackerPlayerIndex, attackingMonIndex), 0);
        }
        return (extraData, false);
    }

    function onMonSwitchIn(uint256, bytes32 extraData, uint256 targetIndex, uint256 monIndex)
        external
        override
        returns (bytes32 updatedExtraData, bool removeAfterRun)
    {
        (uint256 attackerPlayerIndex,) = _decodeState(extraData);
        if (attackerPlayerIndex == targetIndex) {
            // Give the buff to the next mon
            _applyBuff(attackerPlayerIndex, monIndex);

            // We remove the effect from global tracking
            return (extraData, true);
        }
        return (extraData, false);
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

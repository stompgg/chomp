// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {StatBoostToApply} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract EternalGrudge is IMoveSet {
    uint8 public constant ATTACK_DEBUFF_PERCENT = 50;
    uint8 public constant SP_ATTACK_DEBUFF_PERCENT = 50;

    StatBoosts immutable STAT_BOOSTS;

    constructor(StatBoosts _STAT_BOOSTS) {
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Eternal Grudge";
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
        // Apply the debuff (50% debuff to both attack and special attack)
        uint256 defenderPlayerIndex = (attackerPlayerIndex + 1) % 2;
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](2);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.Attack,
            boostPercent: ATTACK_DEBUFF_PERCENT,
            boostType: StatBoostType.Divide
        });
        statBoosts[1] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: SP_ATTACK_DEBUFF_PERCENT,
            boostType: StatBoostType.Divide
        });
        STAT_BOOSTS.addStatBoosts(engine, defenderPlayerIndex, defenderMonIndex, statBoosts, StatBoostFlag.Temp);

        // KO self by dealing just enough damage
        int32 currentDamage =
            engine.getMonStateForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
        uint32 maxHp =
            engine.getMonValueForBattle(battleKey, attackerPlayerIndex, attackerMonIndex, MonStateIndexName.Hp);
        int32 damageNeededToKOSelf = int32(maxHp) + currentDamage;
        engine.dealDamage(attackerPlayerIndex, attackerMonIndex, damageNeededToKOSelf);
    }

    function stamina(IEngine, bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY + 1;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Yin;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";
import {StatBoostToApply} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {StatBoosts} from "../../effects/StatBoosts.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";

contract TripleThink is IMoveSet {
    uint8 public constant SP_ATTACK_BUFF_PERCENT = 75;

    StatBoosts immutable STAT_BOOSTS;

    constructor(StatBoosts _STAT_BOOSTS) {
        STAT_BOOSTS = _STAT_BOOSTS;
    }

    function name() public pure override returns (string memory) {
        return "Triple Think";
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256,
        uint240,
        uint256
    ) external {
        // Apply the buff
        StatBoostToApply[] memory statBoosts = new StatBoostToApply[](1);
        statBoosts[0] = StatBoostToApply({
            stat: MonStateIndexName.SpecialAttack,
            boostPercent: SP_ATTACK_BUFF_PERCENT,
            boostType: StatBoostType.Multiply
        });
        STAT_BOOSTS.addStatBoosts(engine, attackerPlayerIndex, attackerMonIndex, statBoosts, StatBoostFlag.Temp);
    }

    function stamina(IEngine, bytes32, uint256, uint256) external pure returns (uint32) {
        return 2;
    }

    function priority(IEngine, bytes32, uint256) external pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Math;
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

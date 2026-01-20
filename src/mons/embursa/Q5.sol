// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../Constants.sol";
import "../../Enums.sol";

import {IEngine} from "../../IEngine.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {AttackCalculator} from "../../moves/AttackCalculator.sol";
import {IMoveSet} from "../../moves/IMoveSet.sol";
import {ITypeCalculator} from "../../types/ITypeCalculator.sol";
import {HeatBeaconLib} from "./HeatBeaconLib.sol";

contract Q5 is IMoveSet, BasicEffect {
    uint256 public constant DELAY = 5;
    uint32 public constant BASE_POWER = 150;

    IEngine immutable ENGINE;
    ITypeCalculator immutable TYPE_CALCULATOR;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR) {
        ENGINE = _ENGINE;
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
    }

    function name() public pure override(IMoveSet, BasicEffect) returns (string memory) {
        return "Q5";
    }

    function _packExtraData(uint256 turnCount, uint256 attackerPlayerIndex) internal pure returns (bytes32) {
        return bytes32((turnCount << 128) | attackerPlayerIndex);
    }

    function _unpackExtraData(bytes32 data) internal pure returns (uint256 turnCount, uint256 attackerPlayerIndex) {
        turnCount = uint256(data) >> 128;
        attackerPlayerIndex = uint256(data) & type(uint128).max;
    }

    function move(bytes32, uint256 attackerPlayerIndex, uint240, uint256) external {
        // Add effect to global effects
        ENGINE.addEffect(2, attackerPlayerIndex, this, _packExtraData(1, attackerPlayerIndex));

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
        return Type.Fire;
    }

    function isValidTarget(bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(bytes32) public pure returns (MoveClass) {
        return MoveClass.Special;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    /**
     *  Effect implementation
     */
    function shouldRunAtStep(EffectStep step) external pure override returns (bool) {
        return (step == EffectStep.RoundStart);
    }

    function onRoundStart(uint256 rng, bytes32 extraData, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        (uint256 turnCount, uint256 attackerPlayerIndex) = _unpackExtraData(extraData);
        if (turnCount == DELAY) {
            // Deal damage
            AttackCalculator._calculateDamage(
                ENGINE,
                TYPE_CALCULATOR,
                ENGINE.battleKeyForWrite(),
                attackerPlayerIndex,
                BASE_POWER,
                DEFAULT_ACCURACY,
                DEFAULT_VOL,
                moveType(ENGINE.battleKeyForWrite()),
                moveClass(ENGINE.battleKeyForWrite()),
                rng,
                DEFAULT_CRIT_RATE
            );
            return (extraData, true);
        } else {
            return (_packExtraData(turnCount + 1, attackerPlayerIndex), false);
        }
    }
}

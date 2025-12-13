// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";

contract CustomAttack is IMoveSet {
    struct Args {
        Type TYPE;
        uint32 BASE_POWER;
        uint32 ACCURACY;
        uint32 STAMINA_COST;
        uint32 PRIORITY;
    }

    StandardAttack private immutable _standardAttack;

    constructor(IEngine _ENGINE, ITypeCalculator _TYPE_CALCULATOR, Args memory args) {
        // Create a StandardAttack with the specified parameters and all other values set to 0
        _standardAttack = new StandardAttack(
            address(this),
            _ENGINE,
            _TYPE_CALCULATOR,
            ATTACK_PARAMS({
                BASE_POWER: args.BASE_POWER,
                STAMINA_COST: args.STAMINA_COST,
                ACCURACY: args.ACCURACY,
                PRIORITY: args.PRIORITY,
                MOVE_TYPE: args.TYPE,
                EFFECT_ACCURACY: 0, // No effect
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, // No critical hits
                VOLATILITY: 0, // No volatility
                NAME: "CustomAttack",
                EFFECT: IEffect(address(0)) // No effect
            })
        );
    }

    function name() external pure returns (string memory) {
        return "CustomAttack";
    }

    function move(bytes32 battleKey, uint256 attackerPlayerIndex, uint240 extraData, uint256 rng) external {
        _standardAttack.move(battleKey, attackerPlayerIndex, extraData, rng);
    }

    function priority(bytes32 battleKey, uint256 playerIndex) external view returns (uint32) {
        return _standardAttack.priority(battleKey, playerIndex);
    }

    function stamina(bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external view returns (uint32) {
        return _standardAttack.stamina(battleKey, playerIndex, monIndex);
    }

    function moveType(bytes32 battleKey) external view returns (Type) {
        return _standardAttack.moveType(battleKey);
    }

    function isValidTarget(bytes32 battleKey, uint240 extraData) external view returns (bool) {
        return _standardAttack.isValidTarget(battleKey, extraData);
    }

    function moveClass(bytes32 battleKey) external view returns (MoveClass) {
        return _standardAttack.moveClass(battleKey);
    }

    function basePower(bytes32 battleKey) external view returns (uint32) {
        return _standardAttack.basePower(battleKey);
    }

    function critRate(bytes32 battleKey) external view returns (uint32) {
        return _standardAttack.critRate(battleKey);
    }

    function volatility(bytes32 battleKey) external view returns (uint32) {
        return _standardAttack.volatility(battleKey);
    }

    function effect(bytes32 battleKey) external view returns (IEffect) {
        return _standardAttack.effect(battleKey);
    }

    function effectAccuracy(bytes32 battleKey) external view returns (uint32) {
        return _standardAttack.effectAccuracy(battleKey);
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

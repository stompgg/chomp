// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

contract EffectAttack is IMoveSet {
    struct Args {
        Type TYPE;
        uint32 STAMINA_COST;
        uint32 PRIORITY;
    }

    IEffect immutable EFFECT;
    Type immutable TYPE;
    uint32 immutable STAMINA_COST;
    uint32 immutable PRIORITY;

    constructor(IEffect _EFFECT, Args memory args) {
        EFFECT = _EFFECT;
        TYPE = args.TYPE;
        STAMINA_COST = args.STAMINA_COST;
        PRIORITY = args.PRIORITY;
    }

    function name() external pure returns (string memory) {
        return "Effect Attack";
    }

    function move(IEngine engine, bytes32, uint256 attackerPlayerIndex, uint256, uint256 defenderMonIndex, uint240, uint256) external {
        uint256 targetIndex = (attackerPlayerIndex + 1) % 2;
        engine.addEffect(targetIndex, defenderMonIndex, EFFECT, bytes32(0));
    }

    function priority(IEngine, bytes32, uint256) external view returns (uint32) {
        return PRIORITY;
    }

    function stamina(IEngine, bytes32, uint256, uint256) external view returns (uint32) {
        return STAMINA_COST;
    }

    function moveType(IEngine, bytes32) external view returns (Type) {
        return TYPE;
    }

    function isValidTarget(IEngine, bytes32, uint240) external pure returns (bool) {
        return true;
    }

    function moveClass(IEngine, bytes32) external pure returns (MoveClass) {
        return MoveClass.Physical;
    }

    function basePower(bytes32) external pure returns (uint32) {
        return 0;
    }

    function extraDataType() external pure returns (ExtraDataType) {
        return ExtraDataType.None;
    }
}

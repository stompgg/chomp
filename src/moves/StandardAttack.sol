// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import "../Structs.sol";

import {IEngine} from "../IEngine.sol";
import {IEffect} from "../effects/IEffect.sol";

import {Ownable} from "../lib/Ownable.sol";
import {ITypeCalculator} from "../types/ITypeCalculator.sol";
import {AttackCalculator} from "./AttackCalculator.sol";
import {IMoveSet} from "./IMoveSet.sol";
import {ATTACK_PARAMS} from "./StandardAttackStructs.sol";

contract StandardAttack is IMoveSet, Ownable {
    ITypeCalculator immutable TYPE_CALCULATOR;

    uint32 private _basePower;
    uint32 private _stamina;
    uint32 private _accuracy;
    uint32 private _priority;
    Type private _moveType;
    uint32 private _effectAccuracy;
    MoveClass private _moveClass;
    uint32 private _critRate;
    uint32 private _volatility;
    IEffect private _effect;
    string private _name;

    constructor(address owner, ITypeCalculator _TYPE_CALCULATOR, ATTACK_PARAMS memory params) {
        TYPE_CALCULATOR = _TYPE_CALCULATOR;
        _basePower = params.BASE_POWER;
        _stamina = params.STAMINA_COST;
        _accuracy = params.ACCURACY;
        _priority = params.PRIORITY;
        _moveType = params.MOVE_TYPE;
        _effectAccuracy = params.EFFECT_ACCURACY;
        _moveClass = params.MOVE_CLASS;
        _critRate = params.CRIT_RATE;
        _volatility = params.VOLATILITY;
        _effect = params.EFFECT;
        _name = params.NAME;
        _initializeOwner(owner);
    }

    function move(
        IEngine engine,
        bytes32 battleKey,
        uint256 attackerPlayerIndex,
        uint256,
        uint256 defenderMonIndex,
        uint240,
        uint256 rng
    ) public virtual {
        _move(engine, battleKey, attackerPlayerIndex, defenderMonIndex, rng);
    }

    /// @dev Routes through engine.dispatchStandardAttack which collapses the previous three
    ///      cross-contract calls (getDamageCalcContext + dealDamage + addEffect) into a
    ///      single call frame. The engine uses TypeCalcLib internally for type effectiveness;
    ///      production deploys TYPE_CALCULATOR as TypeCalculator (a thin wrapper around
    ///      TypeCalcLib), so the chart is the same. The injected TYPE_CALCULATOR is no
    ///      longer consulted on the attack path — only the engine's internal chart.
    function _move(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 defenderMonIndex, uint256 rng)
        internal
        virtual
        returns (int32 damage, bytes32 eventType)
    {
        return engine.dispatchStandardAttack(
            attackerPlayerIndex,
            defenderMonIndex,
            basePower(battleKey),
            accuracy(battleKey),
            volatility(battleKey),
            moveType(engine, battleKey),
            moveClass(engine, battleKey),
            critRate(battleKey),
            uint8(_effectAccuracy),
            _effect,
            rng
        );
    }

    function isValidTarget(IEngine, bytes32, uint240) public pure returns (bool) {
        return true;
    }

    function priority(IEngine, bytes32, uint256) public view virtual returns (uint32) {
        return _priority;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public view returns (uint32) {
        return _stamina;
    }

    function moveType(IEngine, bytes32) public view returns (Type) {
        return _moveType;
    }

    function moveClass(IEngine, bytes32) public view returns (MoveClass) {
        return _moveClass;
    }

    function critRate(bytes32) public view returns (uint32) {
        return _critRate;
    }

    function volatility(bytes32) public view returns (uint32) {
        return _volatility;
    }

    function basePower(bytes32) public view returns (uint32) {
        return _basePower;
    }

    function accuracy(bytes32) public view returns (uint32) {
        return _accuracy;
    }

    function effect(bytes32) public view returns (IEffect) {
        return _effect;
    }

    function effectAccuracy(bytes32) public view returns (uint32) {
        return _effectAccuracy;
    }

    function changeVar(uint256 varToChange, uint256 newValue) external onlyOwner {
        if (varToChange == 0) {
            _basePower = uint32(newValue);
        } else if (varToChange == 1) {
            _stamina = uint32(newValue);
        } else if (varToChange == 2) {
            _accuracy = uint32(newValue);
        } else if (varToChange == 3) {
            _priority = uint32(newValue);
        } else if (varToChange == 4) {
            _moveType = Type(newValue);
        } else if (varToChange == 5) {
            _effectAccuracy = uint32(newValue);
        } else if (varToChange == 6) {
            _moveClass = MoveClass(newValue);
        } else if (varToChange == 7) {
            _critRate = uint32(newValue);
        } else if (varToChange == 8) {
            _volatility = uint32(newValue);
        } else if (varToChange == 9) {
            _effect = IEffect(address(uint160(newValue)));
        }
    }

    function extraDataType() public pure virtual returns (ExtraDataType) {
        return ExtraDataType.None;
    }

    function name() external view virtual returns (string memory) {
        return _name;
    }

    /// @notice Batched metadata read — one staticcall returns all six fields. Calls the existing
    ///         getters internally (no `this.` — they're public, so this is a JUMP not a staticcall)
    ///         so subclasses that override individual getters get the override applied
    ///         automatically without having to re-implement getMeta.
    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        virtual
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            extraDataType: extraDataType(),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: basePower(battleKey)
        });
    }
}

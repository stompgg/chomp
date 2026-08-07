// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/// @dev Routes the target nibble straight to the engine, through either the single-target or the
///      spread dispatch, so both paths can be driven with identical inputs.
contract SpreadAttack is IMoveSet {
    struct Args {
        Type TYPE;
        MoveClass MOVE_CLASS;
        uint32 BASE_POWER;
        uint32 ACCURACY;
        uint256 VOLATILITY;
        uint256 CRIT_RATE;
        uint32 STAMINA_COST;
        bool USE_MULTI;
    }

    Args private _a;

    constructor(Args memory args) {
        _a = args;
    }

    function move(
        IEngine engine,
        bytes32,
        uint256 attackerPlayerIndex,
        uint256 attackerMonIndex,
        uint256 targetBits,
        uint256,
        uint16,
        uint256 rng
    ) external {
        Args memory a = _a;
        if (a.USE_MULTI) {
            engine.dispatchCustomAttackMulti(
                attackerPlayerIndex,
                attackerMonIndex,
                targetBits,
                a.BASE_POWER,
                a.ACCURACY,
                a.VOLATILITY,
                a.TYPE,
                a.MOVE_CLASS,
                rng,
                a.CRIT_RATE
            );
        } else {
            engine.dispatchCustomAttack(
                attackerPlayerIndex,
                attackerMonIndex,
                targetBits,
                a.BASE_POWER,
                a.ACCURACY,
                a.VOLATILITY,
                a.TYPE,
                a.MOVE_CLASS,
                rng,
                a.CRIT_RATE
            );
        }
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public view returns (uint32) {
        return _a.STAMINA_COST;
    }

    function moveType(IEngine, bytes32) public view returns (Type) {
        return _a.TYPE;
    }

    function moveClass(IEngine, bytes32) public view returns (MoveClass) {
        return _a.MOVE_CLASS;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        view
        returns (MoveMeta memory)
    {
        return MoveMeta({
            moveType: moveType(engine, battleKey),
            moveClass: moveClass(engine, battleKey),
            priority: priority(engine, battleKey, attackerPlayerIndex),
            stamina: stamina(engine, battleKey, attackerPlayerIndex, attackerMonIndex),
            basePower: 0
        });
    }
}

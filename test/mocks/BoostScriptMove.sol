// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {StatBoostLib} from "../../src/lib/StatBoostLib.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

/// @dev Stat-boost sources are keyed by msg.sender, so each caller is a distinct source.
contract BoostScriptCaller {
    function add(IEngine engine, uint256 mon, StatBoostToApply[] memory boosts, StatBoostFlag flag) external {
        engine.addStatBoost(0, mon, boosts, flag);
    }

    function remove(IEngine engine, uint256 mon, StatBoostFlag flag) external {
        engine.removeStatBoost(0, mon, flag);
    }

    function clearAll(IEngine engine, uint256 mon) external {
        engine.clearAllStatBoosts(0, mon);
    }
}

struct BoostOp {
    uint8 kind; // 0 add, 1 remove, 2 clear all
    uint8 caller;
    bool perm;
    uint8 statCount;
    uint8 statA;
    uint8 statB;
    uint8 pct;
    bool mul;
}

/// @dev Runs a scripted boost sequence on side 0, mon 0 and records all five stat deltas after
///      every step, so a test can compare each intermediate state against a model.
contract BoostScriptMove is IMoveSet {
    uint256 public constant CALLERS = 6;

    BoostScriptCaller[CALLERS] public callers;
    BoostOp[] public script;
    int32[5][] public recorded;
    IEffect public listener;

    constructor() {
        for (uint256 i; i < CALLERS; ++i) {
            callers[i] = new BoostScriptCaller();
        }
    }

    function setScript(BoostOp[] memory ops, IEffect listener_) external {
        delete script;
        delete recorded;
        for (uint256 i; i < ops.length; ++i) {
            script.push(ops[i]);
        }
        listener = listener_;
    }

    function recordedAt(uint256 step) external view returns (int32[5] memory) {
        return recorded[step];
    }

    function recordedLength() external view returns (uint256) {
        return recorded.length;
    }

    function move(IEngine engine, bytes32 battleKey, uint256, uint256, uint256, uint256, uint16, uint256) external {
        if (address(listener) != address(0)) {
            engine.addEffect(0, 0, listener, bytes32(0));
        }
        for (uint256 i; i < script.length; ++i) {
            BoostOp memory op = script[i];
            BoostScriptCaller caller = callers[op.caller];
            StatBoostFlag flag = op.perm ? StatBoostFlag.Perm : StatBoostFlag.Temp;
            if (op.kind == 0) {
                StatBoostToApply[] memory boosts = new StatBoostToApply[](op.statCount);
                StatBoostType boostType = op.mul ? StatBoostType.Multiply : StatBoostType.Divide;
                boosts[0] = StatBoostToApply(MonStateIndexName(op.statA), op.pct, boostType);
                if (op.statCount == 2) {
                    boosts[1] = StatBoostToApply(MonStateIndexName(op.statB), op.pct, boostType);
                }
                caller.add(engine, 0, boosts, flag);
            } else if (op.kind == 1) {
                caller.remove(engine, 0, flag);
            } else {
                caller.clearAll(engine, 0);
            }
            int32[5] memory snapshot;
            for (uint256 k; k < 5; ++k) {
                snapshot[k] =
                    engine.getMonStateForBattle(battleKey, 0, 0, StatBoostLib.statBoostIndexToMonStateIndex(k));
            }
            recorded.push(snapshot);
        }
    }

    function priority(IEngine, bytes32, uint256) public pure returns (uint32) {
        return DEFAULT_PRIORITY;
    }

    function stamina(IEngine, bytes32, uint256, uint256) public pure returns (uint32) {
        return 0;
    }

    function moveType(IEngine, bytes32) public pure returns (Type) {
        return Type.Air;
    }

    function moveClass(IEngine, bytes32) public pure returns (MoveClass) {
        return MoveClass.Self;
    }

    function getMeta(IEngine engine, bytes32 battleKey, uint256 attackerPlayerIndex, uint256 attackerMonIndex)
        external
        pure
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

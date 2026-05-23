// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX} from "../../src/Constants.sol";
import {Battle, CPUContext, CustomBattleProposal, ProposedBattle} from "../../src/Structs.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IMatchmaker} from "../../src/matchmaker/IMatchmaker.sol";
import {ICPURNG} from "../../src/rng/ICPURNG.sol";
import {CPUMoveManager} from "../../src/cpu/CPUMoveManager.sol";
import {ICPU} from "../../src/cpu/ICPU.sol";

/// @notice Deterministic CPU for batched-mode tests: returns a configurable scripted move per
///         `calculateMove` call. State independent — ignores the context hint and the player's
///         move parameters. Used to make end-to-end batched-flow tests reproducible without
///         depending on a real CPU's heuristic decisions.
contract MockBatchedCPU is CPUMoveManager, ICPU, ICPURNG, IMatchmaker {
    struct ScriptedMove {
        uint8 moveIndex;
        uint16 extraData;
    }

    ScriptedMove[] private _script;
    uint256 private _cursor;

    constructor(IEngine engine) CPUMoveManager(engine) {}

    /// @notice Set the sequence of CPU moves. `calculateMove` returns these in order; once
    ///         exhausted, returns NO_OP.
    function setScript(ScriptedMove[] calldata moves) external {
        delete _script;
        for (uint256 i = 0; i < moves.length; i++) {
            _script.push(moves[i]);
        }
        _cursor = 0;
    }

    function calculateMove(CPUContext memory, uint8, uint16)
        external
        override
        returns (uint128 moveIndex, uint16 extraData)
    {
        if (_cursor >= _script.length) {
            return (NO_OP_MOVE_INDEX, 0);
        }
        ScriptedMove memory s = _script[_cursor++];
        return (uint128(s.moveIndex), s.extraData);
    }

    function startBattle(ProposedBattle memory p) external returns (bytes32 battleKey) {
        (battleKey,) = ENGINE.computeBattleKey(p.p0, p.p1);
        ENGINE.startBattle(
            Battle({
                p0: p.p0,
                p0TeamIndex: p.p0TeamIndex,
                p1: p.p1,
                p1TeamIndex: p.p1TeamIndex,
                teamRegistry: p.teamRegistry,
                validator: p.validator,
                rngOracle: p.rngOracle,
                ruleset: p.ruleset,
                engineHooks: p.engineHooks,
                moveManager: p.moveManager,
                matchmaker: p.matchmaker
            })
        );
    }

    function validateMatch(bytes32, address) external pure returns (bool) {
        return true;
    }

    function getRNG(bytes32 seed) external pure returns (uint256) {
        return uint256(seed);
    }
}

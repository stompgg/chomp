// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Battle, ProposedBattle} from "../../src/Structs.sol";
import {IEngine} from "../../src/IEngine.sol";
import {BatchedCPUMoveManager} from "../../src/cpu/BatchedCPUMoveManager.sol";

/// @notice Minimal concrete subclass for tests. Adds `startBattle` since the abstract leaves
///         battle bootstrap to the leaf (each production CPU may want its own pre-flight checks).
contract SimpleBatchedCPU is BatchedCPUMoveManager {
    constructor(IEngine engine) BatchedCPUMoveManager(engine) {}

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
}

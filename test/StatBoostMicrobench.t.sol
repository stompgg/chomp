// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {BoostBenchMove} from "./mocks/BoostBenchMove.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice R1.0 — cost of one addStatBoost / removeStatBoost as a function of K existing
///         sources on the mon (fresh engine per K, so adds are virgin-lane; the K-slope is
///         the scan/unpack/aggregate growth, the K=0 intercept is entry-write + telescope +
///         call overhead).
contract StatBoostMicrobench is Test, BattleHelper {
    function _runK(uint256 k) internal returns (uint256 addGas, uint256 removeGas) {
        MockRandomnessOracle oracle = new MockRandomnessOracle();
        TestTeamRegistry registry = new TestTeamRegistry();
        Engine engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        DefaultCommitManager mgr = new DefaultCommitManager(IEngine(address(engine)));
        DefaultMatchmaker maker = new DefaultMatchmaker(engine);
        BoostBenchMove bench = new BoostBenchMove();

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(bench)));
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        registry.setTeam(ALICE, team);
        registry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, oracle, registry, maker, address(mgr));
        _commitRevealExecuteForAliceAndBob(
            engine, mgr, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, mgr, battleKey, 0, NO_OP_MOVE_INDEX, uint16(k), 0);
        addGas = bench.lastAddGas();
        removeGas = bench.lastRemoveGas();
    }

    function test_microbench_addRemoveByExistingSources() public {
        console.log("");
        console.log("=== R1.0 stat-boost microbench (virgin lanes; K = existing sources) ===");
        for (uint256 k; k <= 4; k++) {
            (uint256 a, uint256 r) = _runK(k);
            console.log("  K =", k);
            console.log("    addStatBoost   :", a);
            console.log("    removeStatBoost:", r);
        }
    }
}

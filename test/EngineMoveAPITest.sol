// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import "../src/Constants.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";

import {BattleHelper} from "./abstract/BattleHelper.sol";
import {MockNewAPIMove} from "./mocks/MockNewAPIMove.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Coverage for the new coalesced move-facing API:
///         - `addEffectIfNotPresent` (ability dedup sites)
contract EngineMoveAPITest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    MockNewAPIMove apiMove;
    DefaultValidator validator;

    uint64 internal constant OP_ADD_RESULT = 2001;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        apiMove = new MockNewAPIMove();
        validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
    }

    function _buildTeam() internal view returns (Mon[] memory team) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(apiMove)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.speed = 10;
        mon.stats.stamina = 10;
        team = new Mon[](1);
        team[0] = mon;
    }

    function _initBattle() internal returns (bytes32 battleKey) {
        Mon[] memory team = _buildTeam();
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
    }

    // ==================== addEffectIfNotPresent ====================

    function test_addEffectIfNotPresent_firstCallAdds_secondCallNoOps() public {
        bytes32 battleKey = _initBattle();

        // Turn 1: Alice fires op=1 (addEffectIfNotPresent); Bob NOOPs.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint16(1), uint16(0)
        );
        assertEq(uint256(engine.getGlobalKV(battleKey, OP_ADD_RESULT)), 1, "first call must return added=true");
        (EffectInstance[] memory aliceEffects,) = engine.getEffects(battleKey, 0, 0);
        assertEq(aliceEffects.length, 1, "effect should be present after first call");
        assertEq(address(aliceEffects[0].effect), address(apiMove), "the added effect address");

        // Turn 2: Alice fires op=1 again. Effect already present → returns false, no new slot.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint16(1), uint16(0)
        );
        assertEq(uint256(engine.getGlobalKV(battleKey, OP_ADD_RESULT)), 0, "second call must return added=false");
        (aliceEffects,) = engine.getEffects(battleKey, 0, 0);
        assertEq(aliceEffects.length, 1, "no duplicate effect slot should be created");
    }

    function test_addEffectIfNotPresent_revertsOutsideWriteContext() public {
        // No active execute — battleKeyForWrite is 0.
        vm.expectRevert(Engine.NoWriteAllowed.selector);
        engine.addEffectIfNotPresent(0, 0, IEffect(address(apiMove)), bytes32(0));
    }
}

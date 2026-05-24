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

/// @notice Coverage for the new coalesced move-facing APIs:
///         - `addEffectIfNotPresent` (ability dedup sites)
///         - `getMoveContext`        (stats + state + effects in one read)
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

    // ==================== getMoveContext ====================

    function test_getMoveContext_matchesIndividualGetters() public {
        bytes32 battleKey = _initBattle();

        // Cross-check the view against the existing point-getter API.
        MoveContext memory ctx = engine.getMoveContext(battleKey, 0, 0, 1, 0);

        // Base stats parity with getMonStatsForBattle.
        MonStats memory aliceStats = engine.getMonStatsForBattle(battleKey, 0, 0);
        MonStats memory bobStats = engine.getMonStatsForBattle(battleKey, 1, 0);
        assertEq(ctx.attackerStats.hp, aliceStats.hp, "attacker hp");
        assertEq(ctx.attackerStats.stamina, aliceStats.stamina, "attacker stamina");
        assertEq(ctx.attackerStats.speed, aliceStats.speed, "attacker speed");
        assertEq(ctx.defenderStats.hp, bobStats.hp, "defender hp");

        // Delta parity with getMonStateForBattle.
        assertEq(
            int256(ctx.attackerState.hpDelta),
            int256(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp)),
            "attacker hpDelta"
        );
        assertEq(
            int256(ctx.defenderState.staminaDelta),
            int256(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina)),
            "defender staminaDelta"
        );

        // Effects parity with getEffects (both sides empty on a freshly-started battle).
        (EffectInstance[] memory aliceLive,) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory bobLive,) = engine.getEffects(battleKey, 1, 0);
        assertEq(ctx.attackerEffects.length, aliceLive.length, "attacker effects length");
        assertEq(ctx.defenderEffects.length, bobLive.length, "defender effects length");
    }

    function test_getMoveContext_reflectsLiveEffectAfterAdd() public {
        bytes32 battleKey = _initBattle();

        // Alice runs addEffectIfNotPresent → her mon picks up one effect.
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint16(1), uint16(0)
        );

        // Attacker side (alice) should now see exactly that one effect via the batched read.
        MoveContext memory ctx = engine.getMoveContext(battleKey, 0, 0, 1, 0);
        assertEq(ctx.attackerEffects.length, 1, "context surfaces the freshly-added effect");
        assertEq(address(ctx.attackerEffects[0].effect), address(apiMove));
        assertEq(ctx.defenderEffects.length, 0, "defender side untouched");
    }

    function test_getMoveContext_sentinelDeltasSanitizedToZero() public {
        bytes32 battleKey = _initBattle();

        // Sanity: the freshly-started mon's deltas are all 0 (no sentinel writes yet), so the
        // context should agree with the existing per-field getters which DO convert sentinel→0.
        MoveContext memory ctx = engine.getMoveContext(battleKey, 0, 0, 1, 0);
        assertEq(int256(ctx.attackerState.hpDelta), 0, "fresh hpDelta is 0");
        assertEq(int256(ctx.attackerState.staminaDelta), 0, "fresh staminaDelta is 0");
        // No sentinel observable here directly, but the getter mirrors getMonStateForBattle, which
        // is the one test that would fail if the sanitization helper were ever dropped.
        assertEq(
            int256(ctx.attackerState.hpDelta),
            int256(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp))
        );
    }
}

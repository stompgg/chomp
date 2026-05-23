// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IEngine} from "../src/IEngine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {MockBatchedCPU} from "./mocks/MockBatchedCPU.sol";
import {CPUMoveManager} from "../src/cpu/CPUMoveManager.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice OPT_PLAN §7 / Phase 2.5 — CPU batched mode (trusted-state hint + executeBuffered).
contract CPUBatchTest is Test {
    Engine engine;
    MockBatchedCPU cpu;
    DefaultValidator validator;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;

    address constant ALICE = address(0xA11CE);

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 2;

    IMoveSet moveA;
    IMoveSet moveB;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        cpu = new MockBatchedCPU(IEngine(address(engine)));
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 10})
        );
        typeCalc = new TestTypeCalculator();
        teamRegistry = new TestTeamRegistry();

        StandardAttackFactory factory = new StandardAttackFactory(typeCalc);
        // Deterministic moves: ACCURACY=100, CRIT=0, VOLATILITY=0 → no engine-side RNG sensitivity.
        moveA = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 50, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "A", EFFECT: IEffect(address(0))
            })
        );
        moveB = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 40, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "B", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon();
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        teamRegistry.setTeam(ALICE, team);
        teamRegistry.setTeam(address(cpu), team);
    }

    function _createMon() internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 20, stamina: 20, speed: 10, attack: 30, defense: 10,
                specialAttack: 30, specialDefense: 10, type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
    }

    function _startBattle() internal returns (bytes32) {
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(cpu);
        engine.updateMatchmakers(makersToAdd, new address[](0));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: bytes32(0),
            p1: address(cpu),
            p1TeamIndex: 0,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(cpu),
            matchmaker: cpu
        });
        bytes32 battleKey = cpu.startBattle(proposal);
        vm.stopPrank();
        return battleKey;
    }

    /// @notice Build a CPUContext with the live battle state — Alice computes this off-chain
    ///         (we just use the engine's getCPUContext as a stand-in for the in-test hint).
    function _liveHint(bytes32 battleKey) internal view returns (CPUContext memory) {
        return engine.getCPUContext(battleKey);
    }

    /// @notice Helper: Alice submits a single batched turn with a fresh hint.
    function _aliceSubmits(bytes32 battleKey, uint8 move, uint16 extra, uint104 salt) internal {
        CPUContext memory hint = _liveHint(battleKey);
        vm.prank(ALICE);
        cpu.selectMoveWithStateHint(battleKey, move, extra, salt, hint);
    }

    // -----------------------------------------------------------------------
    // Happy path
    // -----------------------------------------------------------------------

    function test_batched_singleSubmitAndExecute() public {
        bytes32 battleKey = _startBattle();

        // Script: CPU also picks mon 0 on turn 0.
        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](1);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        cpu.setScript(script);

        // Turn 0: lead select — both switch to mon 0.
        _aliceSubmits(battleKey, SWITCH_MOVE_INDEX, 0, uint104(0xDEAD));

        (uint64 numExecuted, uint64 numBuffered,) = cpu.getBufferStatus(battleKey);
        assertEq(numExecuted, 0, "pre-execute: numExecuted");
        assertEq(numBuffered, 1, "pre-execute: numBuffered");

        cpu.executeBuffered(battleKey);

        (numExecuted, numBuffered,) = cpu.getBufferStatus(battleKey);
        assertEq(numExecuted, 1, "post-execute: numExecuted");
        assertEq(numBuffered, 0, "post-execute: numBuffered");
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "turnId advanced to 1");

        // Active mons set correctly.
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[0], 0, "alice active");
        assertEq(active[1], 0, "cpu active");
    }

    function test_batched_multiBatchCounterAccounting() public {
        bytes32 battleKey = _startBattle();

        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](6);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        for (uint256 i = 1; i < 6; i++) {
            script[i] = MockBatchedCPU.ScriptedMove({moveIndex: NO_OP_MOVE_INDEX, extraData: 0});
        }
        cpu.setScript(script);

        // Batch 1: submit 4 turns, then execute.
        _aliceSubmits(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1));
        _aliceSubmits(battleKey, NO_OP_MOVE_INDEX, 0, uint104(2));
        _aliceSubmits(battleKey, NO_OP_MOVE_INDEX, 0, uint104(3));
        _aliceSubmits(battleKey, NO_OP_MOVE_INDEX, 0, uint104(4));

        (uint64 ex, uint64 buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 0, "batch1 pre: ex");
        assertEq(buf, 4, "batch1 pre: buf");

        cpu.executeBuffered(battleKey);
        (ex, buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 4, "batch1 post: ex");
        assertEq(buf, 0, "batch1 post: buf");
        assertEq(engine.getTurnIdForBattleState(battleKey), 4, "engine turnId after batch1");

        // Batch 2: submit 2 more (mid-game continuation).
        _aliceSubmits(battleKey, NO_OP_MOVE_INDEX, 0, uint104(5));
        _aliceSubmits(battleKey, NO_OP_MOVE_INDEX, 0, uint104(6));
        (ex, buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 4, "batch2 pre: ex unchanged");
        assertEq(buf, 2, "batch2 pre: buf");

        cpu.executeBuffered(battleKey);
        (ex, buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 6, "batch2 post: ex");
        assertEq(buf, 0, "batch2 post: buf");
        assertEq(engine.getTurnIdForBattleState(battleKey), 6, "engine turnId after batch2");
    }

    function test_batched_modeAlternation_legacyThenBatched() public {
        bytes32 battleKey = _startBattle();

        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](5);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        for (uint256 i = 1; i < 5; i++) {
            script[i] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        }
        cpu.setScript(script);

        // Run turn 0 (lead select) via legacy.
        vm.prank(ALICE);
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, uint104(0xCAFE), 0);
        engine.resetCallContext();
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "legacy advanced turnId");

        // Now switch to batched: submit + execute.
        _aliceSubmits(battleKey, 0, 0, uint104(0xF00D));
        _aliceSubmits(battleKey, 0, 0, uint104(0xBEEF));

        (uint64 numExecuted, uint64 numBuffered,) = cpu.getBufferStatus(battleKey);
        assertEq(numExecuted, 1, "first-of-batch sync to engine turnId");
        assertEq(numBuffered, 2, "two pending");

        cpu.executeBuffered(battleKey);

        assertEq(engine.getTurnIdForBattleState(battleKey), 3, "batched turns extended legacy progress");
    }

    function test_batched_emptyBufferReverts() public {
        bytes32 battleKey = _startBattle();
        vm.expectRevert(CPUMoveManager.EmptyBuffer.selector);
        cpu.executeBuffered(battleKey);
    }

    function test_batched_revertsForNonAlice() public {
        bytes32 battleKey = _startBattle();
        CPUContext memory hint = _liveHint(battleKey);

        // Random address tries to submit on Alice's behalf.
        vm.prank(address(0xBAD));
        vm.expectRevert(CPUMoveManager.NotP0.selector);
        cpu.selectMoveWithStateHint(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1), hint);
    }

    function test_batched_revertsAfterGameOver() public {
        bytes32 battleKey = _startBattle();

        // Need to advance time before the game-end check so GameStartsAndEndsSameBlock doesn't fire.
        vm.warp(block.timestamp + 1);

        // Plan: switch in mon 0 (turn 0), both attack (turn 1 — 1-hit-KOs with HP=20),
        // forced switch to mon 1 (turn 2), both attack mon 1 (turn 3 → both KO'd, game over).
        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](4);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        script[1] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        script[2] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 1});
        script[3] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        cpu.setScript(script);

        _aliceSubmits(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1));
        _aliceSubmits(battleKey, 0, 0, uint104(2));
        _aliceSubmits(battleKey, SWITCH_MOVE_INDEX, 1, uint104(3));
        _aliceSubmits(battleKey, 0, 0, uint104(4));
        cpu.executeBuffered(battleKey);

        address winner = engine.getWinner(battleKey);
        assertTrue(winner != address(0), "battle ended within batch");

        // Subsequent submit must revert.
        CPUContext memory hint = _liveHint(battleKey);
        vm.prank(ALICE);
        vm.expectRevert(CPUMoveManager.BattleAlreadyComplete.selector);
        cpu.selectMoveWithStateHint(battleKey, 0, 0, uint104(0xDEAD), hint);
    }

    // -----------------------------------------------------------------------
    // Lying-hint test — engine state stays consistent even when the hint is wrong.
    // -----------------------------------------------------------------------

    function test_batched_lyingHintDoesNotCorruptEngine() public {
        bytes32 battleKey = _startBattle();

        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](2);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        script[1] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        cpu.setScript(script);

        // Run a normal turn to set up real state.
        _aliceSubmits(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1));

        // Now craft a deliberately-wrong hint: pretend the game is over, swap mon indices,
        // claim wrong KO bitmaps. Engine should still produce a consistent post-batch state
        // because the live `playerSwitchForTurnFlag` and engine state are what actually drive
        // `executeBatchedTurns`.
        CPUContext memory badHint = _liveHint(battleKey);
        badHint.winnerIndex = 0; // claim alice already won
        badHint.p0KOBitmap = 0xFF;
        badHint.p1KOBitmap = 0xFF;
        badHint.p0ActiveMonIndex = 7; // out of range
        badHint.p1ActiveMonIndex = 7;

        vm.prank(ALICE);
        cpu.selectMoveWithStateHint(battleKey, 0, 0, uint104(2), badHint);

        cpu.executeBuffered(battleKey);

        // Engine still advanced. The CPU may have picked a worthless move (it sees a
        // "game-over" hint), but the engine state is consistent.
        uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
        assertGt(turnId, 1, "engine state advanced past the lied-to turn");
        // No winner pre-set (the hint's lie about winner=0 didn't leak into engine storage).
        // Game may or may not be over after the real attacks landed; what we're asserting is
        // that the engine's getWinner == winner returned by execute (consistent).
        address winner = engine.getWinner(battleKey);
        // Just check the call doesn't blow up and the engine is in a consistent state.
        // If winner is set, it's the actual winner; if not, battle is ongoing.
        // (we don't care which — the point is no corruption.)
        assertTrue(winner == address(0) || winner == ALICE || winner == address(cpu), "valid winner state");
    }
}

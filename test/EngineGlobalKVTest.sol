// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import "../src/Constants.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";

import {BattleHelper} from "./abstract/BattleHelper.sol";
import {MockKVWriterMove} from "./mocks/MockKVWriterMove.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Tests for the globalKV key-buffer tracker and BattleConfigView.globalKVEntries.
/// @dev Uses MockKVWriterMove exclusively so tests aren't coupled to any real mon's behavior.
contract EngineGlobalKVTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    MockKVWriterMove kvMove;
    DefaultValidator validator;

    // Arbitrary keys used throughout the tests.
    uint16 constant KEY_A = 1001;
    uint16 constant KEY_B = 1002;
    uint16 constant KEY_C = 1003;
    uint16 constant KEY_D = 1004;
    uint16 constant KEY_E = 1005;
    uint16 constant KEY_F = 1006;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        kvMove = new MockKVWriterMove();
        validator = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
    }

    /// @dev Team with one mon that knows only the mock KV-writer move.
    function _buildTeam() internal view returns (Mon[] memory team) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(kvMove)));

        Mon memory mon = _createMon();
        mon.moves = moves;
        mon.stats.hp = 1000;
        mon.stats.speed = 10;
        mon.stats.stamina = 10;
        team = new Mon[](1);
        team[0] = mon;
    }

    /// @dev Start a battle with identical one-mon teams and switch both into mon 0.
    function _initBattle() internal returns (bytes32 battleKey) {
        Mon[] memory team = _buildTeam();
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
    }

    /// @dev Re-run the matchmaker flow at the same storageKey to get a second battle on top of the first.
    function _startSecondBattle() internal returns (bytes32 battleKey2) {
        Mon[] memory team = _buildTeam();
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        battleKey2 = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
    }

    /// @dev Both players use the mock write-move with their respective keys.
    function _bothWrite(bytes32 battleKey, uint16 aliceKey, uint16 bobKey) internal {
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, aliceKey, bobKey);
    }

    /// @dev Alice writes; Bob rests.
    function _aliceWrites(bytes32 battleKey, uint16 aliceKey) internal {
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, aliceKey, 0);
    }

    /// @dev Bob writes; Alice rests.
    function _bobWrites(bytes32 battleKey, uint16 bobKey) internal {
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, bobKey);
    }

    // ==================== Core correctness ====================

    /// Test 1: Single write → view reflects it.
    function test_singleWrite_reflectedInView() public {
        bytes32 battleKey = _initBattle();

        _aliceWrites(battleKey, KEY_A);

        (BattleConfigView memory view_,) = engine.getBattle(battleKey);
        assertEq(view_.globalKVEntries.length, 1, "expected exactly one globalKV entry");
        assertEq(view_.globalKVEntries[0].key, uint64(KEY_A), "key mismatch");

        uint64 storedTs = uint64(uint256(view_.globalKVEntries[0].value) >> 192);
        assertEq(storedTs, uint64(view_.startTimestamp), "packed timestamp should match startTimestamp");
    }

    /// Test 2: Same-battle idempotent re-write keeps count at 1, only the value refreshes.
    function test_sameBattleIdempotentReWrite() public {
        bytes32 battleKey = _initBattle();

        _aliceWrites(battleKey, KEY_A);
        (BattleConfigView memory view1,) = engine.getBattle(battleKey);
        assertEq(view1.globalKVEntries.length, 1, "first write grows buffer by 1");
        bytes32 firstPacked = view1.globalKVEntries[0].value;

        // Second call re-writes via encoded value bump so we can confirm it changed.
        // Layout: bits 0..9 = key, bits 10..15 = value.
        uint16 extraData = KEY_A | (uint16(42) << 10);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, extraData, 0);

        (BattleConfigView memory view2,) = engine.getBattle(battleKey);
        assertEq(view2.globalKVEntries.length, 1, "re-write must not grow the buffer");
        assertEq(view2.globalKVEntries[0].key, uint64(KEY_A));
        assertTrue(view2.globalKVEntries[0].value != firstPacked, "value must have refreshed");
        assertEq(uint256(engine.getGlobalKV(battleKey, uint64(KEY_A))), 42, "latest value wins");
    }

    /// Test 3: Mixed new + existing writes preserve insertion order.
    function test_mixedNewAndExistingWrites_preserveInsertionOrder() public {
        bytes32 battleKey = _initBattle();

        _aliceWrites(battleKey, KEY_A); // buffer: [A]
        _bobWrites(battleKey, KEY_B);   // buffer: [A, B]
        _aliceWrites(battleKey, KEY_A); // refresh, no push → still [A, B]

        (BattleConfigView memory view_,) = engine.getBattle(battleKey);
        assertEq(view_.globalKVEntries.length, 2, "two unique keys only");
        assertEq(view_.globalKVEntries[0].key, uint64(KEY_A), "A at index 0");
        assertEq(view_.globalKVEntries[1].key, uint64(KEY_B), "B at index 1");
    }

    /// Test 4: Multi-slot growth. Writes 6 unique keys across 3 turns → 2 packed slots.
    function test_multiSlotGrowth() public {
        bytes32 battleKey = _initBattle();

        _bothWrite(battleKey, KEY_A, KEY_B); // buffer: [A, B]
        _bothWrite(battleKey, KEY_C, KEY_D); // buffer: [A, B, C, D] (slot 0 full)
        _bothWrite(battleKey, KEY_E, KEY_F); // buffer: [A..F] (spills into slot 1)

        (BattleConfigView memory view_,) = engine.getBattle(battleKey);
        assertEq(view_.globalKVEntries.length, 6, "six unique keys total");

        uint64[6] memory expected = [uint64(KEY_A), uint64(KEY_B), uint64(KEY_C), uint64(KEY_D), uint64(KEY_E), uint64(KEY_F)];
        uint64 expectedTs = uint64(view_.startTimestamp);
        for (uint256 i; i < 6; ++i) {
            assertEq(view_.globalKVEntries[i].key, expected[i], "insertion order mismatch");
            uint64 storedTs = uint64(uint256(view_.globalKVEntries[i].value) >> 192);
            assertEq(storedTs, expectedTs, "entry timestamp mismatch");
        }
    }

    // ==================== Slot reuse across battles ====================

    /// Test 6: Count resets on startBattle — battle 2's view is empty before any writes.
    function test_countResetsOnStartBattle() public {
        bytes32 battleKey1 = _initBattle();
        _bothWrite(battleKey1, KEY_A, KEY_B);
        (BattleConfigView memory view1,) = engine.getBattle(battleKey1);
        assertEq(view1.globalKVEntries.length, 2);

        vm.warp(block.timestamp + 1);
        bytes32 battleKey2 = _startSecondBattle();

        (BattleConfigView memory view2,) = engine.getBattle(battleKey2);
        assertEq(view2.globalKVEntries.length, 0, "battle 2 starts with empty globalKV view");
        assertGt(uint256(view2.startTimestamp), uint256(view1.startTimestamp), "new startTimestamp");
    }

    /// Test 7: Stale lanes from prior battle are invisible in new battle's view.
    function test_staleLanesInvisible() public {
        bytes32 battleKey1 = _initBattle();
        _bothWrite(battleKey1, KEY_A, KEY_B); // battle 1: 2 keys in slot 0 lanes 0-1

        vm.warp(block.timestamp + 1);
        bytes32 battleKey2 = _startSecondBattle();

        // Battle 2 writes just one key (Alice only)
        _aliceWrites(battleKey2, KEY_C);

        (BattleConfigView memory view2,) = engine.getBattle(battleKey2);
        assertEq(view2.globalKVEntries.length, 1, "battle 2 view exposes only its own entry");
        assertEq(view2.globalKVEntries[0].key, uint64(KEY_C), "only battle 2's key visible");
    }

    /// Test 8: getGlobalKV returns 0 for entries written in a prior battle.
    function test_staleEntries_getGlobalKV_returnsZero() public {
        bytes32 battleKey1 = _initBattle();
        _aliceWrites(battleKey1, KEY_A);
        uint192 battle1Val = engine.getGlobalKV(battleKey1, uint64(KEY_A));
        assertGt(uint256(battle1Val), 0, "battle 1 wrote a non-zero value");

        vm.warp(block.timestamp + 1);
        bytes32 battleKey2 = _startSecondBattle();

        uint192 battle2Val = engine.getGlobalKV(battleKey2, uint64(KEY_A));
        assertEq(uint256(battle2Val), 0, "stale battle-1 value must not leak into battle 2");
    }

    /// Test 9: Reusing a key across battles re-tracks it against battle 2's timestamp.
    function test_reusingKeyAcrossBattles() public {
        bytes32 battleKey1 = _initBattle();
        _aliceWrites(battleKey1, KEY_A);

        vm.warp(block.timestamp + 1);
        bytes32 battleKey2 = _startSecondBattle();
        _aliceWrites(battleKey2, KEY_A);

        (BattleConfigView memory view2,) = engine.getBattle(battleKey2);
        assertEq(view2.globalKVEntries.length, 1, "reused key tracked exactly once in battle 2");
        assertEq(view2.globalKVEntries[0].key, uint64(KEY_A));

        // Packed value's timestamp must be battle 2's startTimestamp.
        uint64 storedTs = uint64(uint256(view2.globalKVEntries[0].value) >> 192);
        assertEq(storedTs, uint64(view2.startTimestamp), "entry is tracked against battle 2");

        assertGt(uint256(engine.getGlobalKV(battleKey2, uint64(KEY_A))), 0, "battle 2 value is live");
    }

    // ==================== Gas regression ====================

    /// Test 16: Re-writing a key in a subsequent battle at the same storageKey costs less gas
    /// than the first-ever write (warm SSTORE on both value slot and key slot vs cold).
    function test_reusePaysWarm() public {
        bytes32 battleKey1 = _initBattle();

        uint256 gasBefore1 = gasleft();
        _aliceWrites(battleKey1, KEY_A);
        uint256 battle1TurnGas = gasBefore1 - gasleft();

        vm.warp(block.timestamp + 1);
        bytes32 battleKey2 = _startSecondBattle();

        uint256 gasBefore2 = gasleft();
        _aliceWrites(battleKey2, KEY_A);
        uint256 battle2TurnGas = gasBefore2 - gasleft();

        assertLt(battle2TurnGas, battle1TurnGas, "reuse turn should be cheaper than first-ever turn");
    }
}

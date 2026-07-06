// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {CPU} from "../src/cpu/CPU.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {CPUMoveManager} from "../src/cpu/CPUMoveManager.sol";
import {sideWord, targetBits} from "./abstract/SlotWire.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Exercises the off-chain-decision batched-execution path (CPUMoveManager.executeGame): the
///         19-byte/turn stream decode, MonMoves-event suppression, and the BattleCompleteWithBatchTurns
///         event. CPU move DECISIONS are computed client-side and are not tested on-chain.
contract CPUTest is Test {
    Engine engine;
    DefaultRandomnessOracle defaultOracle;
    TestTeamRegistry teamRegistry;

    address constant ALICE = address(1);

    // Probe event for the batched-event gas measurement.
    event _BatchEvProbe(bytes32 indexed battleKey, bytes payload);

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        teamRegistry = new TestTeamRegistry();
    }

    function _createMon(Type t) internal pure returns (Mon memory) {
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 1,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: t,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
        return mon;
    }

    // One-tx PvE: p0 submits the whole game (their moves + CPU's moves) + a per-turn player salt in one
    // call; CPU salt is always 0. Batched execution skips the per-turn MonMoves event (the submitter
    // already holds every move + salt from the executeGame calldata), so we verify the 19-byte/turn
    // decode end-to-end via deterministic final state, and assert no MonMoves logs are emitted.
    function test_executeGame_decodesStreamWithoutMonMovesEvents() public {
        TestMoveFactory moveFactory = new TestMoveFactory();
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(moveFactory.createMove(MoveClass.Self, Type.Liquid, 0, 0))));
        moves[1] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Liquid, 0, 1))));
        Mon memory mon = _createMon(Type.Liquid);
        mon.stats.hp = 100;
        mon.stats.stamina = 10;
        mon.moves = moves;
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        CPU cpu = new CPU(engine);
        teamRegistry.setTeam(address(cpu), team);
        teamRegistry.setTeam(ALICE, team);
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(cpu),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(cpu),
            matchmaker: cpu
        });
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(cpu);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        bytes32 battleKey = cpu.startBattle(proposal);
        vm.stopPrank();

        // Turn plan: [switch-to-0, attack, attack] with distinct player salts; CPU salt always 0.
        uint8[3] memory p0m = [uint8(SWITCH_MOVE_INDEX), uint8(1), uint8(1)];
        uint8[3] memory p1m = [uint8(SWITCH_MOVE_INDEX), uint8(1), uint8(1)];
        uint104[3] memory p0s = [uint104(0xAAAA1), uint104(0xBBBB2), uint104(0xCCCC3)];
        bytes memory stream;
        for (uint256 i; i < 3; i++) {
            // [p0Move 1 | p0Extra 2 | p0Salt 13 | p1Move 1 | p1Extra 2]
            stream = abi.encodePacked(stream, p0m[i], uint16(0), p0s[i], p1m[i], uint16(0));
        }
        assertEq(stream.length, 3 * 19, "19 bytes per turn");

        vm.recordLogs();
        vm.prank(ALICE);
        cpu.executeGame(battleKey, stream);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Batched execution must NOT emit per-turn MonMoves events (the submitter already holds every
        // move + salt from the executeGame calldata, so the log would be pure overhead).
        bytes32 monMovesSig = keccak256("MonMoves(bytes32,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(engine)) {
                assertTrue(logs[i].topics[0] != monMovesSig, "batched mode must not emit MonMoves");
            }
        }

        // The 19-byte/turn stream decoded correctly: after the turn-0 send-in, both mons used move 1
        // (deal-1 damage) on turns 1 and 2, so each active mon took exactly 2 deterministic points of
        // damage. A misframed decode would corrupt the move bytes and diverge this final state.
        assertEq(engine.getTurnIdForBattleState(battleKey), 3, "all 3 turns executed");
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -2, "p0 mon0 took 2 dmg");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -2, "cpu mon0 took 2 dmg");
    }

    // Measures the marginal gas the BattleCompleteWithBatchTurns event adds over a no-event batched
    // tx: exactly the build (abi.encodePacked of winner + 19B/turn) + the LOG2 emit, at realistic
    // turn counts. This is the whole delta — executeBatchedTurns does nothing else new.
    function test_gas_batchEventOverhead() public {
        uint256[3] memory counts = [uint256(11), 26, 40];
        for (uint256 c; c < 3; c++) {
            uint256 N = counts[c];
            uint256[] memory entries = new uint256[](N);
            for (uint256 i; i < N; i++) {
                uint104 salt = uint104(uint256(keccak256(abi.encode("salt", i))));
                // p0Move 1 | p0Salt | p1Move 1 (CPU salt 0) — a typical attack-vs-attack turn.
                entries[i] = uint256(1) | (uint256(salt) << 24) | (uint256(1) << 128);
            }
            address winner = address(0x1234);
            uint256 g0 = gasleft();
            // Mirror the engine's O(n) single-buffer build (memory-array variant of the calldata
            // assembly in executeBatchedTurns).
            bytes memory payload = new bytes(20 + N * 19);
            assembly {
                let ptr := add(payload, 32)
                mstore(ptr, shl(96, winner))
                ptr := add(ptr, 20)
                let src := add(entries, 32)
                for { let i := 0 } lt(i, N) { i := add(i, 1) } {
                    mstore(ptr, shl(104, mload(add(src, mul(i, 0x20)))))
                    ptr := add(ptr, 19)
                }
            }
            emit _BatchEvProbe(bytes32(uint256(0xABCD)), payload);
            uint256 used = g0 - gasleft();
            emit log_named_uint(string(abi.encodePacked("batch-event gas N=", vm.toString(N))), used);
        }
    }

    // A batched CPU game that CONCLUDES emits exactly one BattleCompleteWithBatchTurns (winner +
    // every executed turn, CPU salt dropped) and NO plain BattleComplete. We decode the payload and
    // confirm the winner + a sample turn round-trip from the 19-byte/turn packing.
    function test_executeGame_emitsBattleCompleteWithBatchTurns() public {
        TestMoveFactory moveFactory = new TestMoveFactory();
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(moveFactory.createMove(MoveClass.Self, Type.Liquid, 0, 0))));
        moves[1] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Liquid, 0, 1))));

        Mon memory cpuMon = _createMon(Type.Liquid);
        cpuMon.stats.hp = 1; // dies to one 1-damage hit -> game concludes inside the batch
        cpuMon.stats.stamina = 10;
        cpuMon.moves = moves;
        Mon[] memory cpuTeam = new Mon[](1);
        cpuTeam[0] = cpuMon;

        Mon memory aliceMon = _createMon(Type.Liquid);
        aliceMon.stats.hp = 100; // survives the CPU's 1-damage hit -> ALICE wins
        aliceMon.stats.stamina = 10;
        aliceMon.moves = moves;
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;

        CPU cpu = new CPU(engine);
        teamRegistry.setTeam(address(cpu), cpuTeam);
        teamRegistry.setTeam(ALICE, aliceTeam);
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(cpu),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(cpu),
            matchmaker: cpu
        });
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(cpu);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        bytes32 battleKey = cpu.startBattle(proposal);
        vm.stopPrank();

        // Game must not start and end in the same block (Engine guards against it).
        vm.warp(vm.getBlockTimestamp() + 1);

        // Turn 0: both send in mon 0 (switch). Turn 1: both attack (move 1) -> CPU mon (hp 1) KO'd.
        uint8[2] memory p0m = [uint8(SWITCH_MOVE_INDEX), uint8(1)];
        uint8[2] memory p1m = [uint8(SWITCH_MOVE_INDEX), uint8(1)];
        uint104[2] memory p0s = [uint104(0xDEAD1), uint104(0xBEEF2)];
        bytes memory stream;
        for (uint256 i; i < 2; i++) {
            // [p0Move 1 | p0Extra 2 | p0Salt 13 | p1Move 1 | p1Extra 2]; CPU salt always 0.
            stream = abi.encodePacked(stream, p0m[i], uint16(0), p0s[i], p1m[i], uint16(0));
        }

        vm.recordLogs();
        vm.prank(ALICE);
        cpu.executeGame(battleKey, stream);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 plainSig = keccak256("BattleComplete(bytes32,address)");
        bytes32 batchSig = keccak256("BattleCompleteWithBatchTurns(bytes32,bytes)");
        bytes memory payload;
        uint256 batchCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(engine)) continue;
            assertTrue(logs[i].topics[0] != plainSig, "batched path must NOT emit plain BattleComplete");
            if (logs[i].topics[0] == batchSig) {
                batchCount++;
                assertEq(logs[i].topics[1], battleKey, "battleKey topic");
                payload = abi.decode(logs[i].data, (bytes));
            }
        }
        assertEq(batchCount, 1, "exactly one BattleCompleteWithBatchTurns");

        // Game concluded after 2 turns -> payload = winner(20) + 2*19.
        assertEq(payload.length, 20 + 2 * 19, "winner + 2 turns");

        address decodedWinner;
        assembly {
            decodedWinner := shr(96, mload(add(payload, 32)))
        }
        assertEq(decodedWinner, ALICE, "winner is ALICE (p0)");

        // Decode turn 1 (the attack): the 19-byte record is the low 152 bits, big-endian.
        uint256 vv;
        assembly {
            vv := shr(104, mload(add(payload, add(32, add(20, 19)))))
        }
        assertEq(vv & 0xFF, 1, "turn1 p0 raw move == attack(1)");
        assertEq((vv >> 24) & ((uint256(1) << 104) - 1), uint256(0xBEEF2), "turn1 p0 salt round-trips");
        assertEq((vv >> 128) & 0xFF, 1, "turn1 p1 raw move == attack(1)");
    }

    // ---------------------------------------------------------------------
    // Doubles PvE (2-slot) flows
    // ---------------------------------------------------------------------

    /// @dev Doubles PvE fixture: ALICE (side 0) two one-shot killers vs the CPU's two victims.
    ///      Started through startCustomBattle so the proposal's battleMode routing is covered.
    function _startDoublesVsCpu(CPU cpu) internal returns (bytes32 battleKey) {
        TestTypeCalculator typeCalc = new TestTypeCalculator();
        CustomAttack killAttack = new CustomAttack(
            typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 3})
        );
        CustomAttack weakAttack = new CustomAttack(
            typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 3})
        );

        Mon memory playerMon = _createMon(Type.Air);
        playerMon.stats.hp = 1000;
        playerMon.stats.stamina = 5;
        playerMon.stats.speed = 10;
        playerMon.stats.attack = 10;
        playerMon.stats.defense = 10;
        playerMon.moves = new uint256[](1);
        playerMon.moves[0] = uint256(uint160(address(killAttack)));
        Mon memory cpuMon = _createMon(Type.Air);
        cpuMon.stats.hp = 100;
        cpuMon.stats.stamina = 5;
        cpuMon.stats.speed = 2;
        cpuMon.stats.attack = 10;
        cpuMon.stats.defense = 10;
        cpuMon.moves = new uint256[](1);
        cpuMon.moves[0] = uint256(uint160(address(weakAttack)));

        Mon[] memory playerTeam = new Mon[](2);
        playerTeam[0] = playerMon;
        playerTeam[1] = playerMon;
        Mon[] memory cpuTeam = new Mon[](2);
        cpuTeam[0] = cpuMon;
        cpuTeam[1] = cpuMon;
        teamRegistry.setTeam(ALICE, playerTeam);
        teamRegistry.setTeam(address(cpu), cpuTeam);

        CustomBattleProposal memory p = CustomBattleProposal({
            p0: ALICE,
            p0TeamIndex: 0,
            monIndices: new uint256[](0),
            facetIds: new uint8[](0),
            moveSelections: new uint8[](0),
            teamRegistry: teamRegistry,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            moveManager: address(cpu),
            matchmaker: cpu,
            engineHooks: new IEngineHook[](0),
            battleMode: BATTLE_MODE_DOUBLES
        });
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(cpu);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        battleKey = cpu.startCustomBattle(p);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Stream slices: big-endian tails of the wire side words (side 1's salt is dropped).
    function _streamTurn(uint256 side0Word, uint256 side1Word) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes19(bytes32(side0Word << 104)), bytes6(bytes32(side1Word << 208)));
    }

    function test_startCustomBattle_routesBattleMode() public {
        CPU cpu = new CPU(engine);
        bytes32 battleKey = _startDoublesVsCpu(cpu);
        (, BattleData memory data) = engine.getBattle(battleKey);
        assertTrue(data.isTwoSlotMode, "proposal battleMode reached the engine");
    }

    /// @dev One-tx Doubles PvE: 25-byte/turn stream in, no per-turn events out, full replay in
    ///      a single BattleCompleteWithBatchSlotTurns log whose payload is byte-identical to
    ///      winner ++ stream.
    function test_executeSlotGame_fullDoublesGameOneTx() public {
        CPU cpu = new CPU(engine);
        bytes32 battleKey = _startDoublesVsCpu(cpu);

        uint256 t0s0 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xAAAA1));
        uint256 t0s1 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, 0);
        uint256 t1s0 = sideWord(0, targetBits(2), 0, targetBits(3), uint104(0xBBBB2));
        uint256 t1s1 = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 0);
        bytes memory stream = abi.encodePacked(_streamTurn(t0s0, t0s1), _streamTurn(t1s0, t1s1));
        assertEq(stream.length, 2 * 25, "25 bytes per turn");

        vm.recordLogs();
        vm.prank(ALICE);
        address winner = cpu.executeSlotGame(battleKey, stream);
        assertEq(winner, ALICE);
        assertEq(engine.getWinner(battleKey), ALICE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 batchSig = keccak256("BattleCompleteWithBatchSlotTurns(bytes32,bytes)");
        bytes32 monMovesSig = keccak256("MonMoves(bytes32,uint256,uint256)");
        bytes32 engineExecuteSig = keccak256("EngineExecute(bytes32)");
        uint256 batchLogs;
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != monMovesSig, "no per-turn MonMoves on the batched path");
            assertTrue(logs[i].topics[0] != engineExecuteSig, "no per-turn EngineExecute on the batched path");
            if (logs[i].topics[0] == batchSig) {
                assertEq(logs[i].topics[1], battleKey);
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                assertEq(payload, abi.encodePacked(winner, stream), "payload = winner ++ submitted stream");
                batchLogs++;
            }
        }
        assertEq(batchLogs, 1, "exactly one batch-completion log");
    }

    /// @dev Turns past the winning one are not executed and not replayed.
    function test_executeSlotGame_stopsAtWinner() public {
        CPU cpu = new CPU(engine);
        bytes32 battleKey = _startDoublesVsCpu(cpu);

        uint256 t0s0 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xAAAA1));
        uint256 t0s1 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, 0);
        uint256 t1s0 = sideWord(0, targetBits(2), 0, targetBits(3), uint104(0xBBBB2));
        uint256 t1s1 = sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 0);
        bytes memory winningStream = abi.encodePacked(_streamTurn(t0s0, t0s1), _streamTurn(t1s0, t1s1));
        bytes memory garbageTail = _streamTurn(
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, uint104(0xCCCC3)),
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, 0)
        );

        vm.recordLogs();
        vm.prank(ALICE);
        address winner = cpu.executeSlotGame(battleKey, abi.encodePacked(winningStream, garbageTail));
        assertEq(winner, ALICE);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 batchSig = keccak256("BattleCompleteWithBatchSlotTurns(bytes32,bytes)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != batchSig) continue;
            bytes memory payload = abi.decode(logs[i].data, (bytes));
            assertEq(payload.length, 20 + 2 * 25, "only the executed turns are replayed");
            assertEq(payload, abi.encodePacked(winner, winningStream));
        }
    }

    /// @dev Per-turn Doubles PvE: the player authors their side word + the CPU's lanes; no
    ///      forced-switch flag dispatch (mask turns ignore non-acting lanes by design).
    function test_selectSlotMovesWithCpuMoves_perTurnFlow() public {
        CPU cpu = new CPU(engine);
        bytes32 battleKey = _startDoublesVsCpu(cpu);

        vm.prank(address(0xBEEF));
        vm.expectRevert(CPUMoveManager.NotP0.selector);
        cpu.selectSlotMovesWithCpuMoves(battleKey, 0, 0, 0, 0, 0);

        vm.prank(ALICE);
        cpu.selectSlotMovesWithCpuMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xAAAA1)),
            SWITCH_MOVE_INDEX,
            0,
            SWITCH_MOVE_INDEX,
            1
        );
        vm.prank(ALICE);
        cpu.selectSlotMovesWithCpuMoves(
            battleKey,
            sideWord(0, targetBits(2), 0, targetBits(3), uint104(0xBBBB2)),
            NO_OP_MOVE_INDEX,
            0,
            NO_OP_MOVE_INDEX,
            0
        );
        assertEq(engine.getWinner(battleKey), ALICE);
    }
}

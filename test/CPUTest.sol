// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {CPU} from "../src/cpu/CPU.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

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
}

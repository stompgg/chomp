// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {OkayCPU} from "../src/cpu/OkayCPU.sol";

import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {MockCPURNG} from "./mocks/MockCPURNG.sol";
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

import {IEffect} from "../src/effects/IEffect.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {GuestFeature} from "../src/mons/sofabbi/GuestFeature.sol";
import {RoundTrip} from "../src/mons/volthare/RoundTrip.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";

contract CPUTest is Test {
    Engine engine;
    DefaultCommitManager commitManager;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;
    MockCPURNG mockCPURNG;
    DefaultMatchmaker matchmaker;

    address constant ALICE = address(1);
    address constant BOB = address(2);

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(engine);
        mockCPURNG = new MockCPURNG();
        typeCalc = new TestTypeCalculator();
        teamRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
        StandardAttackFactory attackFactory = new StandardAttackFactory(typeCalc);

        IMoveSet move1 = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Liquid,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m1",
                EFFECT: IEffect(address(0))
            })
        );
        IMoveSet move2 = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 2,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Liquid,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m2",
                EFFECT: IEffect(address(0))
            })
        );
        IMoveSet roundTrip = new RoundTrip(typeCalc);
        IMoveSet guestFeature = new GuestFeature(typeCalc);

        uint256[] memory boringMoves = new uint256[](2);
        boringMoves[0] = uint256(uint160(address(move1)));
        boringMoves[1] = uint256(uint160(address(move2)));
        Mon memory mon1 = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: boringMoves,
            ability: 0
        });
        Mon memory mon2 = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: boringMoves,
            ability: 0
        });
        Mon memory mon3 = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: boringMoves,
            ability: 0
        });
        uint256[] memory movesWithEffects = new uint256[](2);
        movesWithEffects[0] = uint256(uint160(address(roundTrip)));
        movesWithEffects[1] = uint256(uint160(address(guestFeature)));
        Mon memory mon4 = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 3, // Because Guest Feature costs 3
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: movesWithEffects,
            ability: 0
        });

        Mon[] memory team = new Mon[](4);
        team[0] = mon1;
        team[1] = mon2;
        team[2] = mon3;
        team[3] = mon4;

        teamRegistry.setTeam(ALICE, team);
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

    function test_okayCPUSelectsTypeResist() public {
        OkayCPU okayCPU = new OkayCPU(4, engine, mockCPURNG, typeCalc);

        // Both teams have Liquid, Nature, Fire, Air
        Mon[] memory team = new Mon[](4);
        team[0] = _createMon(Type.Liquid);
        team[1] = _createMon(Type.Liquid);
        team[2] = _createMon(Type.Nature);
        team[3] = _createMon(Type.Air);

        // Set 0.5 effectiveness if Fire hits Air
        typeCalc.setTypeEffectiveness(Type.Liquid, Type.Air, 5);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        bytes32 battleKey = okayCPU.startBattle(proposal);

        // Player switches in mon index 0 (Fire type)
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(0));
        engine.resetCallContext();
        // Get active index for battle, it should be the resisted mon
        uint256[] memory activeIndex = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(activeIndex[1], 3);
    }

    function test_okayCPUWithZeroMoves() public {
        OkayCPU okayCPU = new OkayCPU(1, engine, mockCPURNG, typeCalc);

        // Both teams have just one mon with a TestMove that costs 3 stamina
        Mon[] memory team = new Mon[](1);
        uint256[] memory moves = new uint256[](1);
        TestMoveFactory moveFactory = new TestMoveFactory();
        moves[0] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Liquid, 3, 0))));
        Mon memory mon = _createMon(Type.Liquid);
        mon.moves = moves;
        team[0] = mon;

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        bytes32 battleKey = okayCPU.startBattle(proposal);

        // Turn 0, both player send in mon index 0
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(0));
        engine.resetCallContext();
        // Turn 1, player rests, CPU should select no op because the move costs too much stamina
        mockCPURNG.setRNG(1);
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();
    }

    function test_okayCPURests() public {
        OkayCPU okayCPU = new OkayCPU(1, engine, mockCPURNG, typeCalc);

        // Both teams have just one mon with a TestMove that costs 3 stamina
        Mon[] memory team = new Mon[](1);
        uint256[] memory moves = new uint256[](1);
        TestMoveFactory moveFactory = new TestMoveFactory();
        moves[0] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Liquid, 3, 0))));
        Mon memory mon = _createMon(Type.Liquid);
        mon.stats.stamina = 5;
        mon.moves = moves;
        team[0] = mon;

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        bytes32 battleKey = okayCPU.startBattle(proposal);

        // Turn 0, both player send in mon index 0
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(0));
        engine.resetCallContext();
        // Turn 1, player rests, CPU should select move index 0
        mockCPURNG.setRNG(1); // This triggers the OkayCPU to select a move, which should set its stamina delta to be -3
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();
        // Assert the stamina delta for P1's active mon is -3
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -3);

        // Turn 2, player rests, CPU should rest as well
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();
        // Assert the stamina delta for P1's active mon is still -3 (it didn't go down more)
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -3);
    }

    function test_okayCPUSelectsSelfMoveAtFullHealth() public {
        // Both teams have 2 moves, one Attack that costs 0 stamina, and one Self that costs 1 stamina
        Mon[] memory team = new Mon[](1);
        uint256[] memory moves = new uint256[](2);
        TestMoveFactory moveFactory = new TestMoveFactory();
        moves[0] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Liquid, 0, 0))));
        moves[1] = uint256(uint160(address(moveFactory.createMove(MoveClass.Self, Type.Liquid, 1, 0))));
        Mon memory mon = _createMon(Type.Liquid);
        mon.moves = moves;
        team[0] = mon;

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        bytes32 battleKey = okayCPU.startBattle(proposal);

        // Turn 0, both player send in mon index 0
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(0));
        engine.resetCallContext();
        // Turn 1, p0 rests, CPU should select move index 1 (self move)
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();
        // Assert that the stamina delta is -1 for p1's active mon
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -1);
    }

    function test_okayCPUSelectsOtherMoveAtFullHealth() public {
        // Both teams have 3 moves, one Attack that costs 0 stamina, one Self that costs 1 stamina, and one Other that costs 1 stamina
        Mon[] memory team = new Mon[](1);
        uint256[] memory moves = new uint256[](3);
        TestMoveFactory moveFactory = new TestMoveFactory();
        moves[0] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Liquid, 0, 0))));
        moves[1] = uint256(uint160(address(moveFactory.createMove(MoveClass.Special, Type.Liquid, 0, 0))));
        moves[2] = uint256(uint160(address(moveFactory.createMove(MoveClass.Other, Type.Liquid, 1, 0))));
        Mon memory mon = _createMon(Type.Liquid);
        mon.moves = moves;
        team[0] = mon;

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        bytes32 battleKey = okayCPU.startBattle(proposal);

        // Turn 0, both player send in mon index 0
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(0));
        engine.resetCallContext();
        // Turn 1, p0 rests, CPU should select move index 1 (self move)
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();
        // Assert that the stamina delta is -1 for p1's active mon
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -1);
    }

    function test_okayCPUSelectsAttackMoveAtNonFullHealth() public {
        // Both teams have 2 moves, one Attack that costs 0 stamina, and one Self that costs 1 stamina
        Mon[] memory team = new Mon[](1);
        uint256[] memory moves = new uint256[](2);
        TestMoveFactory moveFactory = new TestMoveFactory();
        moves[0] = uint256(uint160(address(moveFactory.createMove(MoveClass.Self, Type.Liquid, 0, 0)))); 
        moves[1] = uint256(uint160(address(moveFactory.createMove(MoveClass.Physical, Type.Liquid, 0, 1))));
        Mon memory mon = _createMon(Type.Liquid);
        mon.stats.hp = 10;
        mon.moves = moves;
        team[0] = mon;

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        bytes32 battleKey = okayCPU.startBattle(proposal);

        // Turn 0, both player send in mon index 0
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(0));
        engine.resetCallContext();
        // Turn 1, set RNG to trigger smart random select and pick move index 1
        // RNG needs: (RNG % 6 == 5) to trigger smart random, (RNG % 3 != 0) to not switch, ((RNG >> 8) % 2 == 1) to pick move 1
        // 257 satisfies all: 257 % 6 = 5, 257 % 3 = 2, (257 >> 8) = 1
        // So both mons should take 1 damage, as p0 also selects the damage move
        mockCPURNG.setRNG(257);
        okayCPU.selectMove(battleKey, 1, uint104(0), 0);
        engine.resetCallContext();
        // Assert that the hp delta is -1 for p0's active mon and p1's active mon
        int32 hpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -1);
        hpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -1);

        // Turn 2, set RNG to be 0 (do not trigger short circuit)
        // CPU should select no-op because no type advantage is currently set
        mockCPURNG.setRNG(0);
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();
        // Assert that the hp delta is still -1 for p0's active mon
        hpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -1);

        // Turn 3, set the type advantage to 2 (Fire > Fire)
        typeCalc.setTypeEffectiveness(Type.Liquid, Type.Liquid, 2);

        // Now the CPU should select the damage move (move index 1) because it has a type advantage
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();
        // Assert that the hp delta is -2 for p0's active mon
        hpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -2);
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

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);
        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        bytes32 battleKey = okayCPU.startBattle(proposal);
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
        okayCPU.executeGame(battleKey, stream);
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
    event _BatchEvProbe(bytes32 indexed battleKey, bytes payload);

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

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);
        teamRegistry.setTeam(address(okayCPU), cpuTeam);
        teamRegistry.setTeam(ALICE, aliceTeam);
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(okayCPU),
            matchmaker: okayCPU
        });
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(okayCPU);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        bytes32 battleKey = okayCPU.startBattle(proposal);
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
        okayCPU.executeGame(battleKey, stream);
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

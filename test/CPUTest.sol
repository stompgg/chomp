// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";

import {DefaultCommitManager} from "../src/DefaultCommitManager.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {CPUMoveManager} from "../src/cpu/CPUMoveManager.sol";
import {OkayCPU} from "../src/cpu/OkayCPU.sol";
import {PlayerCPU} from "../src/cpu/PlayerCPU.sol";
import {RandomCPU} from "../src/cpu/RandomCPU.sol";

import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {MockCPURNG} from "./mocks/MockCPURNG.sol";
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

import {IAbility} from "../src/abilities/IAbility.sol";
import {IEffect} from "../src/effects/IEffect.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {GuestFeature} from "../src/mons/sofabbi/GuestFeature.sol";
import {RoundTrip} from "../src/mons/volthare/RoundTrip.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";

contract CPUTest is Test {
    Engine engine;
    DefaultCommitManager commitManager;
    RandomCPU cpu;
    PlayerCPU playerCPU;
    DefaultValidator validator;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;
    MockCPURNG mockCPURNG;
    DefaultMatchmaker matchmaker;

    address constant ALICE = address(1);
    address constant BOB = address(2);

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine();
        commitManager = new DefaultCommitManager(engine);
        mockCPURNG = new MockCPURNG();
        cpu = new RandomCPU(2, engine, mockCPURNG);
        playerCPU = new PlayerCPU(2, engine, mockCPURNG);
        validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 4, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );
        typeCalc = new TestTypeCalculator();
        teamRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
        StandardAttackFactory attackFactory = new StandardAttackFactory(engine, typeCalc);

        IMoveSet move1 = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
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
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m2",
                EFFECT: IEffect(address(0))
            })
        );
        IMoveSet roundTrip = new RoundTrip(engine, typeCalc);
        IMoveSet guestFeature = new GuestFeature(engine, typeCalc);

        IMoveSet[] memory boringMoves = new IMoveSet[](2);
        boringMoves[0] = move1;
        boringMoves[1] = move2;
        Mon memory mon1 = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: boringMoves,
            ability: IAbility(address(0))
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
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: boringMoves,
            ability: IAbility(address(0))
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
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: boringMoves,
            ability: IAbility(address(0))
        });
        IMoveSet[] memory movesWithEffects = new IMoveSet[](2);
        movesWithEffects[0] = roundTrip;
        movesWithEffects[1] = guestFeature;
        Mon memory mon4 = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 3, // Because Guest Feature costs 3
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: movesWithEffects,
            ability: IAbility(address(0))
        });

        Mon[] memory team = new Mon[](4);
        team[0] = mon1;
        team[1] = mon2;
        team[2] = mon3;
        team[3] = mon4;

        teamRegistry.setTeam(address(cpu), team);
        teamRegistry.setTeam(address(playerCPU), team);
        teamRegistry.setTeam(ALICE, team);
    }

    /**
     * CPU should:
     * - Only swap if they are KO'ed [x]
     * - Only pick valid moves (e.g. should not pick a move that costs too much stamina) [x]
     * - Moves that need a self team index correctly generate a random index
     */
    function test_cpuOnlyPicksValidMoves() public {
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(cpu),
            p1TeamIndex: 0,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(cpu),
            matchmaker: cpu
        });

        vm.startPrank(ALICE);
        // Authorize the CPU as a matchmaker
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(cpu);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(ALICE);
        // Start the battle directly via CPU
        bytes32 battleKey = cpu.startBattle(proposal);

        // Check that the CPU enumerates mon indices 0 to 4
        {
            (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
                cpu.calculateValidMoves(battleKey, 1);
            assertEq(noOp.length + moves.length + switches.length, 4);
        }

        // Alice selects mon 2, CPU selects mon 1
        mockCPURNG.setRNG(1);
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(2));

        // Assert active mon index for both p0 and p1 are correct
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[0], 2);
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[1], 1);

        // Check that the CPU now has 6 moves (can swap to any one of the other 3 mons, 2 valid moves, and a no op)
        {
            (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
                cpu.calculateValidMoves(battleKey, 1);
            assertEq(noOp.length + moves.length + switches.length, 6);
        }

        // Alice KO's the CPU's mon, the CPU chooses no op
        mockCPURNG.setRNG(0); // [no op, move 1, move 2, swap 0, swap 2, swap 3] and we want no op at index 0
        cpu.selectMove(battleKey, 0, "", 0);

        // Check that the CPU now has 3 moves, all of which are switching to mon index 0, 2, or 3
        {
            (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
                cpu.calculateValidMoves(battleKey, 1);
            assertEq(noOp.length + moves.length + switches.length, 3);
            uint256[] memory swapIds = new uint256[](3);
            swapIds[0] = 0;
            swapIds[1] = 2;
            swapIds[2] = 3;
            for (uint256 i = 0; i < swapIds.length; i++) {
                assertEq(switches[i].moveIndex, SWITCH_MOVE_INDEX);
                assertEq(uint256(switches[i].extraData), swapIds[i]);
            }
        }

        // Alice chooses no op (choice is irrelevant here), CPU chooses to switch to mon index 0
        cpu.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert the CPU now has mon index 0 as the active mon
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[1], 0);

        // Assert that there are now 5 moves, switching to mon index 2, 3, the two moves, and no op
        {
            (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
                cpu.calculateValidMoves(battleKey, 1);
            assertEq(noOp.length + moves.length + switches.length, 5);
        }

        // Alice chooses no op, CPU chooses move2 which should consume all stamina
        mockCPURNG.setRNG(2); // [no op, move 1, move 2, swap 2, swap 3] and we want move 2 at index 2
        // (note that the swaps are 0-indexed, and the moves are 1-indexed to refer to the above variable
        // naming convention, sorry D: )
        cpu.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert that there are now 3 moves, switching to mon index 2, 3, and no op (all stamina has been consumed)
        {
            (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
                cpu.calculateValidMoves(battleKey, 1);
            assertEq(noOp.length + moves.length + switches.length, 3);
        }

        // Alice chooses no op, CPU chooses swapping to mon index 3
        mockCPURNG.setRNG(2); // [no op, swap 2, swap 3] and we want swap 3 at index 2
        cpu.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert the CPU now has mon index 3 as the active mon
        assertEq(engine.getActiveMonIndexForBattleState(battleKey)[1], 3);

        // Assert that there are now 4 moves, switching to mon index 0, 2, the two moves, and no op
        // Assert that both moves generate a valid self team index (either mon 0 or mon 2)
        {
            (RevealedMove[] memory noOp, RevealedMove[] memory moves, RevealedMove[] memory switches) =
                cpu.calculateValidMoves(battleKey, 1);
            assertEq(noOp.length + moves.length + switches.length, 5);
            assertEq(uint256(moves[0].extraData), 0); // rng is set to 2, which % 2 is 0
            assertEq(uint256(moves[1].extraData), 0);
        }
    }

    /**
     * Test that only p0 can call setMove on PlayerCPU
     * Should revert if someone other than p0 attempts to call setMove
     */
    function test_onlyP0CanSetMoveOnPlayerCPU() public {
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(playerCPU),
            p1TeamIndex: 0,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(playerCPU),
            matchmaker: playerCPU
        });

        vm.startPrank(ALICE);
        // Authorize the PlayerCPU as a matchmaker
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(playerCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(ALICE);
        // Start the battle directly via PlayerCPU
        bytes32 battleKey = playerCPU.startBattle(proposal);

        // Test that BOB (not p0) cannot call setMove
        vm.startPrank(BOB);
        vm.expectRevert(CPUMoveManager.NotP0.selector);
        playerCPU.setMove(battleKey, 0, 0);
    }

    /**
     * Test that PlayerCPU flow works correctly for p0 over multiple turns
     * Should allow p0 to call setMove followed by selectMove, and subsequent calls should override previous moves
     */
    function test_playerCPUFlowWorksForP0() public {
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(playerCPU),
            p1TeamIndex: 0,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(playerCPU),
            matchmaker: playerCPU
        });

        vm.startPrank(ALICE);
        // Authorize the PlayerCPU as a matchmaker
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(playerCPU);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(ALICE);
        // Start the battle directly via PlayerCPU
        bytes32 battleKey = playerCPU.startBattle(proposal);

        // First turn: p0 sets move 0 for PlayerCPU
        playerCPU.setMove(battleKey, 0, 0);

        // Verify that calculateMove returns the correct move
        (uint128 moveIndex, uint240 extraData) = playerCPU.calculateMove(battleKey, 0);
        assertEq(moveIndex, 0);
        assertEq(extraData, 0);

        // Execute the turn
        playerCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1));

        // Second turn: p0 sets move 1 for PlayerCPU (should override previous move)
        playerCPU.setMove(battleKey, 1, uint240(42));

        // Verify that calculateMove now returns the new move
        (moveIndex, extraData) = playerCPU.calculateMove(battleKey, 0);
        assertEq(moveIndex, 1);
        assertEq(uint256(extraData), 42);

        // Execute another turn to verify the flow continues to work
        playerCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);
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
            moves: new IMoveSet[](0),
            ability: IAbility(address(0))
        });
        return mon;
    }

    function test_okayCPUSelectsTypeResist() public {
        OkayCPU okayCPU = new OkayCPU(4, engine, mockCPURNG, typeCalc);

        // Both teams have Water, Nature, Fire, Air
        Mon[] memory team = new Mon[](4);
        team[0] = _createMon(Type.Fire);
        team[1] = _createMon(Type.Water);
        team[2] = _createMon(Type.Nature);
        team[3] = _createMon(Type.Air);

        // Set 0.5 effectiveness if Fire hits Air
        typeCalc.setTypeEffectiveness(Type.Fire, Type.Air, 5);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        DefaultValidator validatorToUse = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 4, MOVES_PER_MON: 0, TIMEOUT_DURATION: 10})
        );

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            validator: validatorToUse,
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
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Get active index for battle, it should be the resisted mon
        uint256[] memory activeIndex = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(activeIndex[1], 3);
    }

    function test_okayCPUWithZeroMoves() public {
        OkayCPU okayCPU = new OkayCPU(1, engine, mockCPURNG, typeCalc);

        // Both teams have just one mon with a TestMove that costs 3 stamina
        Mon[] memory team = new Mon[](1);
        IMoveSet[] memory moves = new IMoveSet[](1);
        TestMoveFactory moveFactory = new TestMoveFactory(engine);
        moves[0] = moveFactory.createMove(MoveClass.Physical, Type.Fire, 3, 0);
        Mon memory mon = _createMon(Type.Fire);
        mon.moves = moves;
        team[0] = mon;

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        DefaultValidator validatorToUse = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            validator: validatorToUse,
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
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1, player rests, CPU should select no op because the move costs too much stamina
        mockCPURNG.setRNG(1);
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);
    }

    function test_okayCPURests() public {
        OkayCPU okayCPU = new OkayCPU(1, engine, mockCPURNG, typeCalc);

        // Both teams have just one mon with a TestMove that costs 3 stamina
        Mon[] memory team = new Mon[](1);
        IMoveSet[] memory moves = new IMoveSet[](1);
        TestMoveFactory moveFactory = new TestMoveFactory(engine);
        moves[0] = moveFactory.createMove(MoveClass.Physical, Type.Fire, 3, 0);
        Mon memory mon = _createMon(Type.Fire);
        mon.stats.stamina = 5;
        mon.moves = moves;
        team[0] = mon;

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        DefaultValidator validatorToUse = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            validator: validatorToUse,
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
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1, player rests, CPU should select move index 0
        mockCPURNG.setRNG(1); // This triggers the OkayCPU to select a move, which should set its stamina delta to be -3
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert the stamina delta for P1's active mon is -3
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -3);

        // Turn 2, player rests, CPU should rest as well
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert the stamina delta for P1's active mon is still -3 (it didn't go down more)
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -3);
    }

    function test_okayCPUSelectsSelfMoveAtFullHealth() public {
        // Both teams have 2 moves, one Attack that costs 0 stamina, and one Self that costs 1 stamina
        Mon[] memory team = new Mon[](1);
        IMoveSet[] memory moves = new IMoveSet[](2);
        TestMoveFactory moveFactory = new TestMoveFactory(engine);
        moves[0] = moveFactory.createMove(MoveClass.Physical, Type.Fire, 0, 0);
        moves[1] = moveFactory.createMove(MoveClass.Self, Type.Fire, 1, 0);
        Mon memory mon = _createMon(Type.Fire);
        mon.moves = moves;
        team[0] = mon;

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        DefaultValidator validatorToUse = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            validator: validatorToUse,
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
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1, p0 rests, CPU should select move index 1 (self move)
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert that the stamina delta is -1 for p1's active mon
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -1);
    }

    function test_okayCPUSelectsOtherMoveAtFullHealth() public {
        // Both teams have 3 moves, one Attack that costs 0 stamina, one Self that costs 1 stamina, and one Other that costs 1 stamina
        Mon[] memory team = new Mon[](1);
        IMoveSet[] memory moves = new IMoveSet[](3);
        TestMoveFactory moveFactory = new TestMoveFactory(engine);
        moves[0] = moveFactory.createMove(MoveClass.Physical, Type.Fire, 0, 0);
        moves[1] = moveFactory.createMove(MoveClass.Special, Type.Fire, 0, 0);
        moves[2] = moveFactory.createMove(MoveClass.Other, Type.Fire, 1, 0);
        Mon memory mon = _createMon(Type.Fire);
        mon.moves = moves;
        team[0] = mon;

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        DefaultValidator validatorToUse = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            validator: validatorToUse,
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
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1, p0 rests, CPU should select move index 1 (self move)
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert that the stamina delta is -1 for p1's active mon
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -1);
    }

    function test_okayCPUSelectsAttackMoveAtNonFullHealth() public {
        // Both teams have 2 moves, one Attack that costs 0 stamina, and one Self that costs 1 stamina
        Mon[] memory team = new Mon[](1);
        IMoveSet[] memory moves = new IMoveSet[](2);
        TestMoveFactory moveFactory = new TestMoveFactory(engine);
        moves[0] = moveFactory.createMove(MoveClass.Self, Type.Fire, 0, 0); 
        moves[1] = moveFactory.createMove(MoveClass.Physical, Type.Fire, 0, 1);
        Mon memory mon = _createMon(Type.Fire);
        mon.stats.hp = 10;
        mon.moves = moves;
        team[0] = mon;

        OkayCPU okayCPU = new OkayCPU(moves.length, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(address(okayCPU), team);
        teamRegistry.setTeam(ALICE, team);

        DefaultValidator validatorToUse = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: moves.length, TIMEOUT_DURATION: 10})
        );

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(okayCPU),
            p1TeamIndex: 0,
            validator: validatorToUse,
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
        okayCPU.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1, set RNG to trigger smart random select ([no op, move 0 (self), move 1 (damage)])
        // and SMART_SELECT_SHORT_CIRCUIT_DENOM is set to 6, so if RNG is 5, we'll end up on move index 1
        // So both mons should take 1 damage, as p0 also selects the damage move
        mockCPURNG.setRNG(okayCPU.SMART_SELECT_SHORT_CIRCUIT_DENOM() - 1);
        okayCPU.selectMove(battleKey, 1, "", 0);

        // Assert that the hp delta is -1 for p0's active mon and p1's active mon
        int32 hpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -1);
        hpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -1);

        // Turn 2, set RNG to be 0 (do not trigger short circuit)
        // CPU should select no-op because no type advantage is currently set
        mockCPURNG.setRNG(0);
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert that the hp delta is still -1 for p0's active mon
        hpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -1);

        // Turn 3, set the type advantage to 2 (Fire > Fire)
        typeCalc.setTypeEffectiveness(Type.Fire, Type.Fire, 2);

        // Now the CPU should select the damage move (move index 1) because it has a type advantage
        okayCPU.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Assert that the hp delta is -2 for p0's active mon
        hpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(hpDelta, -2);
    }
}

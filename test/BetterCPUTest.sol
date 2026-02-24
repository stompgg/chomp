// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {BetterCPU} from "../src/cpu/BetterCPU.sol";

import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {MockCPURNG} from "./mocks/MockCPURNG.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

import {IAbility} from "../src/abilities/IAbility.sol";
import {IEffect} from "../src/effects/IEffect.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";

contract BetterCPUTest is Test {
    Engine engine;
    DefaultCommitManager commitManager;
    BetterCPU cpu;
    DefaultValidator validator;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;
    MockCPURNG mockCPURNG;
    DefaultMatchmaker matchmaker;
    StandardAttackFactory attackFactory;

    address constant ALICE = address(1);
    address constant BOB = address(2);

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(engine);
        mockCPURNG = new MockCPURNG();
        typeCalc = new TestTypeCalculator();
        // CPU will be created per-test with appropriate numMoves
        validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 4, MOVES_PER_MON: 4, TIMEOUT_DURATION: 10})
        );
        teamRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
        attackFactory = new StandardAttackFactory(engine, typeCalc);
    }

    function _createMon(Type t, uint32 hp, uint32 attack, uint32 defense) internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: hp,
                stamina: 10,
                speed: 10,
                attack: attack,
                defense: defense,
                specialAttack: attack,
                specialDefense: defense,
                type1: t,
                type2: Type.None
            }),
            moves: new IMoveSet[](0),
            ability: IAbility(address(0))
        });
    }

    function _createAttack(uint32 basePower, Type moveType, MoveClass moveClass) internal returns (IMoveSet) {
        return attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: basePower,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: moveType,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: moveClass,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );
    }

    function _startBattleWithCPU(Mon[] memory aliceTeam, Mon[] memory cpuTeam) internal returns (bytes32) {
        require(aliceTeam.length == cpuTeam.length, "Team sizes must match");

        // Count max moves per mon
        uint32 maxMoves = 0;
        for (uint256 i = 0; i < aliceTeam.length; i++) {
            if (aliceTeam[i].moves.length > maxMoves) maxMoves = uint32(aliceTeam[i].moves.length);
        }
        for (uint256 i = 0; i < cpuTeam.length; i++) {
            if (cpuTeam[i].moves.length > maxMoves) maxMoves = uint32(cpuTeam[i].moves.length);
        }

        // Create CPU with the correct number of moves
        cpu = new BetterCPU(maxMoves, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(ALICE, aliceTeam);
        teamRegistry.setTeam(address(cpu), cpuTeam);

        DefaultValidator validatorToUse = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: uint32(aliceTeam.length), MOVES_PER_MON: maxMoves, TIMEOUT_DURATION: 10})
        );

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(cpu),
            p1TeamIndex: 0,
            validator: validatorToUse,
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
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        return cpu.startBattle(proposal);
    }

    // ============ KILL THREAT DETECTION TESTS ============

    function test_betterCPUSelectsKOMove() public {
        // Create a high-power attack that can KO
        IMoveSet highPowerAttack = _createAttack(100, Type.Fire, MoveClass.Physical);
        IMoveSet lowPowerAttack = _createAttack(10, Type.Fire, MoveClass.Physical);

        IMoveSet[] memory cpuMoves = new IMoveSet[](2);
        cpuMoves[0] = lowPowerAttack; // Move index 0: weak
        cpuMoves[1] = highPowerAttack; // Move index 1: strong (should KO)

        // CPU mon with high attack
        Mon memory cpuMon = _createMon(Type.Fire, 100, 50, 10);
        cpuMon.moves = cpuMoves;

        // Alice mon with low HP (easy to KO)
        Mon memory aliceMon = _createMon(Type.Fire, 10, 10, 10);
        aliceMon.moves = cpuMoves;

        // Need at least 2 mons per team to avoid array bounds issues
        Mon[] memory cpuTeam = new Mon[](2);
        cpuTeam[0] = cpuMon;
        cpuTeam[1] = cpuMon;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;

        bytes32 battleKey = _startBattleWithCPU(aliceTeam, cpuTeam);

        // Turn 0: Both select mon 0
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Deal some damage to Alice's mon so CPU sees it can KO
        // The CPU should select the high power move (index 1) to secure the KO
        // Set RNG to not trigger random selection
        mockCPURNG.setRNG(1);
        cpu.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Check that Alice's mon took massive damage (from high power attack)
        int32 aliceHpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        // High power attack should deal significant damage
        assertTrue(aliceHpDelta < -5, "CPU should have used high power attack");
    }

    // ============ TYPE ADVANTAGE LEAD SELECTION TESTS ============

    function test_betterCPUSelectsTypeResistantLead() public {
        // CPU team: Fire, Liquid, Nature, Air
        // Alice selects Fire, CPU should select Liquid (resists Fire)

        IMoveSet basicAttack = _createAttack(10, Type.Fire, MoveClass.Physical);
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = basicAttack;

        Mon[] memory cpuTeam = new Mon[](4);
        cpuTeam[0] = _createMon(Type.Fire, 100, 10, 10);
        cpuTeam[1] = _createMon(Type.Liquid, 100, 10, 10);
        cpuTeam[2] = _createMon(Type.Nature, 100, 10, 10);
        cpuTeam[3] = _createMon(Type.Air, 100, 10, 10);
        for (uint256 i = 0; i < 4; i++) {
            cpuTeam[i].moves = moves;
        }

        Mon[] memory aliceTeam = new Mon[](4);
        for (uint256 i = 0; i < 4; i++) {
            aliceTeam[i] = _createMon(Type.Fire, 100, 10, 10);
            aliceTeam[i].moves = moves;
        }

        // Set Fire -> Liquid effectiveness to 0.5 (Liquid resists Fire)
        typeCalc.setTypeEffectiveness(Type.Fire, Type.Liquid, 5); // 5 = 0.5x (scaled by 10)

        bytes32 battleKey = _startBattleWithCPU(aliceTeam, cpuTeam);

        // Alice selects mon 0 (Fire type)
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // CPU should have selected Liquid mon (index 1)
        uint256[] memory activeIndex = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(activeIndex[1], 1, "CPU should select Liquid mon to resist Fire");
    }

    // ============ SURVIVAL CHECK / SAFE SWITCH TESTS ============

    function test_betterCPUSwitchesWhenThreatened() public {
        // Setup: Opponent has a move that can KO CPU's active mon
        // CPU has a mon that resists the opponent's type
        // CPU should switch to the resistant mon when threatened

        IMoveSet killerAttack = _createAttack(200, Type.Fire, MoveClass.Physical);
        IMoveSet basicAttack = _createAttack(10, Type.Fire, MoveClass.Physical);

        IMoveSet[] memory aliceMoves = new IMoveSet[](1);
        aliceMoves[0] = killerAttack;

        IMoveSet[] memory cpuMoves = new IMoveSet[](1);
        cpuMoves[0] = basicAttack;

        // Alice: High attack Fire mon with killer attack (2 mons to match CPU)
        Mon memory aliceMon = _createMon(Type.Fire, 100, 100, 10);
        aliceMon.moves = aliceMoves;
        // Also use Fire type for second Alice mon so CPU doesn't pick Liquid for lead
        Mon memory aliceMon2 = _createMon(Type.Liquid, 100, 100, 10);
        aliceMon2.moves = aliceMoves;

        // CPU: Weak Fire mon (will get KO'd) and Liquid mon (resists Fire)
        Mon memory cpuFireMon = _createMon(Type.Fire, 20, 10, 10);
        cpuFireMon.moves = cpuMoves;
        Mon memory cpuLiquidMon = _createMon(Type.Liquid, 100, 10, 10);
        cpuLiquidMon.moves = cpuMoves;

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon2;

        Mon[] memory cpuTeam = new Mon[](2);
        cpuTeam[0] = cpuFireMon;
        cpuTeam[1] = cpuLiquidMon;

        // Set Fire -> Liquid effectiveness to 0.5 (Liquid resists Fire)
        // And Liquid -> Fire to 2x so CPU doesn't auto-select Liquid to resist Alice's lead
        typeCalc.setTypeEffectiveness(Type.Fire, Type.Liquid, 5);
        typeCalc.setTypeEffectiveness(Type.Liquid, Type.Fire, 20);

        bytes32 battleKey = _startBattleWithCPU(aliceTeam, cpuTeam);

        // Turn 0: Alice selects mon 0 (Fire), CPU should select Fire mon (no type advantage for Liquid vs Fire)
        // Since neither mon resists Liquid (Alice's lead could be Liquid), CPU picks randomly
        // We force Fire mon to be selected
        mockCPURNG.setRNG(0);
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Get active mons - CPU might have selected based on type calcs
        uint256[] memory activeIndex = engine.getActiveMonIndexForBattleState(battleKey);
        uint256 cpuStartMon = activeIndex[1];

        // Turn 1: CPU should detect kill threat from Fire attack and switch to Liquid if currently Fire
        mockCPURNG.setRNG(1); // Don't trigger random selection
        cpu.selectMove(battleKey, 0, "", 0); // Alice attacks

        // If CPU started with Fire, it should switch to Liquid to survive
        // If CPU started with Liquid, it should stay (already resists Fire)
        activeIndex = engine.getActiveMonIndexForBattleState(battleKey);
        if (cpuStartMon == 0) {
            assertEq(activeIndex[1], 1, "CPU should switch to Liquid mon to survive");
        }
        // Either way, current mon should be Liquid (index 1)
        assertEq(activeIndex[1], 1, "CPU should have Liquid mon active to resist Fire");
    }

    // ============ STAMINA MANAGEMENT TESTS ============

    function test_betterCPURestsWhenLowStamina() public {
        // Use a weak attack that can't KO to avoid kill threat detection
        IMoveSet expensiveAttack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 10,  // Low power so no kill threat
                STAMINA_COST: 5,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "ExpensiveAttack",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = expensiveAttack;

        // High HP mons so no kill threat after first attack
        Mon memory mon = _createMon(Type.Fire, 200, 10, 10);
        mon.stats.stamina = 10;
        mon.moves = moves;

        // Need 2 mons per team
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        bytes32 battleKey = _startBattleWithCPU(team, team);

        // Turn 0: Both select mon 0
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1: Use the expensive attack (costs 5 stamina)
        // RNG = 1 won't trigger random selection (1 % 10 != 0)
        mockCPURNG.setRNG(1);
        cpu.selectMove(battleKey, 0, "", 0);

        // Stamina delta should be -5
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -5, "Stamina should be -5 after expensive attack");

        // Turn 2: Opponent rests (P4 path). New BetterCPU attacks on free turns even at low stamina.
        mockCPURNG.setRNG(1);
        cpu.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Stamina should be -10 (attacked again with the 5-cost move on the free turn)
        staminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -10, "Should attack on free turn even at low stamina");
    }

    // ============ SETUP MOVE PREFERENCE AT FULL HP ============

    function test_betterCPUSelectsSetupMoveAtFullHP() public {
        IMoveSet attackMove = _createAttack(50, Type.Fire, MoveClass.Physical);
        IMoveSet setupMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Self,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "SetupMove",
                EFFECT: IEffect(address(0))
            })
        );

        IMoveSet[] memory moves = new IMoveSet[](2);
        moves[0] = attackMove;
        moves[1] = setupMove;

        Mon memory mon = _createMon(Type.Fire, 100, 10, 10);
        mon.moves = moves;

        // Need 2 mons per team
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        bytes32 battleKey = _startBattleWithCPU(team, team);

        // Turn 0: Both select mon 0
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1: At full HP, CPU should prefer setup move
        // Set RNG to not trigger random selection
        mockCPURNG.setRNG(1);
        cpu.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Check stamina consumed (setup move costs 1)
        int32 staminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(staminaDelta, -1, "CPU should have used setup move (1 stamina)");
    }

    // ============ DAMAGE ESTIMATION / TYPE ADVANTAGE ATTACK SELECTION ============

    function test_betterCPUSelectsHighestDamageMove() public {
        // Create moves with different base powers
        IMoveSet weakAttack = _createAttack(10, Type.Fire, MoveClass.Physical);
        IMoveSet strongAttack = _createAttack(100, Type.Fire, MoveClass.Physical);
        IMoveSet mediumAttack = _createAttack(50, Type.Fire, MoveClass.Physical);

        IMoveSet[] memory moves = new IMoveSet[](3);
        moves[0] = weakAttack;
        moves[1] = mediumAttack;
        moves[2] = strongAttack;

        Mon memory mon = _createMon(Type.Fire, 100, 50, 10);
        mon.moves = moves;

        // Need 2 mons per team
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        bytes32 battleKey = _startBattleWithCPU(team, team);

        // Turn 0: Both select mon 0
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));

        // Turn 1: CPU is at full HP, so attack first with Alice to damage CPU
        // Then CPU will be at non-full HP and prefer attack moves
        mockCPURNG.setRNG(1);
        cpu.selectMove(battleKey, 2, "", 0); // Alice uses strong attack on CPU

        // Now CPU's HP is damaged, next turn it should use highest damage move
        // Turn 2: CPU should select the strongest attack
        mockCPURNG.setRNG(1); // Don't trigger random
        cpu.selectMove(battleKey, NO_OP_MOVE_INDEX, "", 0);

        // Verify significant damage was dealt (strong attack) - Alice took damage both turns
        int32 aliceHpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertTrue(aliceHpDelta < -20, "CPU should have used strong attack");
    }
}

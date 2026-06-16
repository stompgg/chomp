// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";
import {Test} from "forge-std/Test.sol";

import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";

import {DefaultValidator} from "../../src/DefaultValidator.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";

import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {PanicStatus} from "../../src/effects/status/PanicStatus.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {EternalGrudge} from "../../src/mons/ghouliath/EternalGrudge.sol";
import {GraveAffliction} from "../../src/mons/ghouliath/GraveAffliction.sol";

import {RiseFromTheGrave} from "../../src/mons/ghouliath/RiseFromTheGrave.sol";
import {WitherAway} from "../../src/mons/ghouliath/WitherAway.sol";

contract GhouliathTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultValidator validator;
    RiseFromTheGrave riseFromTheGrave;
    IMoveSet osteoporosis;
    WitherAway witherAway;
    PanicStatus panicStatus;
    EternalGrudge eternalGrudge;
    GraveAffliction graveAffliction;
    BurnStatus burnStatus;
    StandardAttackFactory standardAttackFactory;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(0, 0);
        validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10})
        );
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        standardAttackFactory = new StandardAttackFactory(ITypeCalculator(address(typeCalc)));
        riseFromTheGrave = new RiseFromTheGrave();
        osteoporosis = standardAttackFactory.createAttack(ATTACK_PARAMS({
            BASE_POWER: 90, STAMINA_COST: 2, ACCURACY: 100,
            PRIORITY: 3, MOVE_TYPE: Type.Yin, EFFECT_ACCURACY: 100,
            MOVE_CLASS: MoveClass.Physical, CRIT_RATE: 5, VOLATILITY: 10,
            NAME: "Osteoporosis", EFFECT: IEffect(address(0))
        }));
        panicStatus = new PanicStatus();
        witherAway =
            new WitherAway(ITypeCalculator(address(typeCalc)), IEffect(address(panicStatus)));
        eternalGrudge = new EternalGrudge();
        graveAffliction = new GraveAffliction();
        burnStatus = new BurnStatus();
        matchmaker = new DefaultMatchmaker(engine);
    }

    /*
    Test that:
    - The effect is applied when the mon switches in
    - When the mon is KO'd, the effect is removed from the mon and added as a global effect
    - After the revival delay, the mon is revived
    - The effect is only applied once per battle
    - The global effect is cleared after revival
    */
    function testRiseFromTheGrave() public {
        // Create a team with a mon that has RiseFromTheGrave ability
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 100,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Liquid,
                MOVE_CLASS: MoveClass.Physical,
                NAME: "Attack",
                EFFECT: IEffect(address(0)),
                EFFECT_ACCURACY: 0,
                CRIT_RATE: 0,
                VOLATILITY: 0
            })
        ))));
        Mon memory ghouliathMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(riseFromTheGrave))
        });

        // Create a regular mon for the opponent
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create teams
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = ghouliathMon;
        aliceTeam[1] = regularMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = regularMon;
        bobTeam[1] = regularMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Bob uses the attack (which KOs) on Alice's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify Alice's mon is KO'd
        int32 isKnockedOut = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 1);

        // Verify the effect is added to the global effects list
        (EffectInstance[] memory effects, ) = engine.getEffects(battleKey, 2, 0);
        assertEq(
            address(effects[0].effect),
            address(riseFromTheGrave),
            "RiseFromTheGrave effect should be added to global effects"
        );

        // Alice swaps in mon index 1
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(1), true);
        engine.resetCallContext();
        // We wait for the REVIVAL_DELAY - 1 turns to pass
        for (uint256 i = 0; i < riseFromTheGrave.REVIVAL_DELAY() - 1; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
            );
        }

        // Verify mon is revived
        isKnockedOut = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 0, "Alice's mon should be revived");

        // Assert HP is 1
        int32 damageTaken = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        assertEq(damageTaken, -99, "Alice's mon should have 1 HP");

        // Alice swaps in mon index 0, Bob does attack again, which KOs Alice's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 0, uint16(0), 0);

        // Verify the mon is not revived after REVIVAL_DELAY turns
        // (First we swap in mon index 1)
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(1), true);
        engine.resetCallContext();
        for (uint256 i = 0; i < riseFromTheGrave.REVIVAL_DELAY() - 1; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
            );
        }

        // Verify mon is not revived
        isKnockedOut = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 1, "Alice's mon should be revived");
    }

    function testDoubleRiseFromTheGrave() public {
        // Create a team with a mon that has RiseFromTheGrave ability
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 100,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Liquid,
                MOVE_CLASS: MoveClass.Physical,
                NAME: "Attack",
                EFFECT: IEffect(address(0)),
                EFFECT_ACCURACY: 0,
                CRIT_RATE: 0,
                VOLATILITY: 0
            })
        ))));
        Mon memory ghouliathMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(riseFromTheGrave))
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = ghouliathMon;
        aliceTeam[1] = ghouliathMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = ghouliathMon;
        bobTeam[1] = ghouliathMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Bob uses the attack (which KOs) on Alice's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Alice swaps in mon index 1
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(1), true);
        engine.resetCallContext();
        // Alice KOs Bob's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Bob swaps in mon index 1
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint16(1), true);
        engine.resetCallContext();
        // We wait for the REVIVAL_DELAY turns to pass
        for (uint256 i = 0; i < riseFromTheGrave.REVIVAL_DELAY() - 1; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0
            );
        }

        // Verify Alice's mon is revived
        int32 isKnockedOut = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 0, "Alice's mon should be revived");

        // Verify Bob's mon is revived
        isKnockedOut = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 0, "Bob's mon should be revived");
    }

    function testWitherAway() public {
        // Create a team with a mon that has WitherAway move
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(witherAway)));

        // Create a mon with specific stats
        Mon memory attackerMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 10, // Higher speed to go first
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create a regular mon for the opponent
        Mon memory defenderMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create teams
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = attackerMon;
        aliceTeam[1] = attackerMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = defenderMon;
        bobTeam[1] = defenderMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses WitherAway on Bob's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Verify that both mons have the PanicStatus effect applied
        (EffectInstance[] memory aliceEffects, ) = engine.getEffects(battleKey, 0, 0);
        (EffectInstance[] memory bobEffects, ) = engine.getEffects(battleKey, 1, 0);

        // Check that both mons have at least one effect
        assertGt(aliceEffects.length, 0, "Alice's mon should have at least one effect");
        assertGt(bobEffects.length, 0, "Bob's mon should have at least one effect");

        // Check that the effect is PanicStatus
        bool aliceHasPanic = false;
        bool bobHasPanic = false;

        for (uint256 i = 0; i < aliceEffects.length; i++) {
            if (keccak256(abi.encodePacked(aliceEffects[i].effect.name())) == keccak256(abi.encodePacked("Panic"))) {
                aliceHasPanic = true;
                break;
            }
        }

        for (uint256 i = 0; i < bobEffects.length; i++) {
            if (keccak256(abi.encodePacked(bobEffects[i].effect.name())) == keccak256(abi.encodePacked("Panic"))) {
                bobHasPanic = true;
                break;
            }
        }

        assertTrue(aliceHasPanic, "Alice's mon should have Panic status");
        assertTrue(bobHasPanic, "Bob's mon should have Panic status");

        // Verify that stamina is reduced at the end of the turn due to Panic status
        int32 aliceStaminaDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobStaminaDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);

        // Alice used the move (costs 3 stamina) and got panic (costs 1 more), so -4 total
        assertEq(aliceStaminaDelta, -4, "Alice's mon should have lost 4 stamina");
        // Bob got panic (costs 1 stamina)
        assertEq(bobStaminaDelta, -1, "Bob's mon should have lost 1 stamina");
    }

    function testOsteoporosis() public {
        // Create a team with a mon that has Osteoporosis move
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(osteoporosis)));

        // Create a mon with specific stats to make damage calculation predictable
        Mon memory attackerMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create a regular mon for the opponent with known defense
        Mon memory defenderMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5,
                attack: 5,
                defense: 5,
                specialAttack: 5,
                specialDefense: 5,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create teams
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = attackerMon;
        aliceTeam[1] = attackerMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = defenderMon;
        bobTeam[1] = defenderMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Osteoporosis on Bob's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Calculate the damage dealt
        uint32 damageTaken = uint32(-1 * engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp));

        // Assert it's at least base power / 2
        assertGe(damageTaken, 90 / 2, "Damage taken should be at least base power / 2");
    }

    function testEternalGrudge() public {
        // Create a team with a mon that has EternalGrudge move
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(eternalGrudge)));

        // Create a mon with specific stats to make damage calculation predictable
        Mon memory attackerMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 5,
                attack: 10,
                defense: 5,
                specialAttack: 10,
                specialDefense: 5,
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = attackerMon;
        aliceTeam[1] = attackerMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = attackerMon;
        bobTeam[1] = attackerMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice does nothing, Bob switches to mon index 1
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, NO_OP_MOVE_INDEX, SWITCH_MOVE_INDEX, 0, uint16(1)
        );

        // Alice uses Eternal Grudge on Bob's mon
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        // Assert Alice's mon is KO'd
        int32 isKnockedOut = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.IsKnockedOut);
        assertEq(isKnockedOut, 1, "Alice's mon should be KO'd");

        // Assert Bob's mon has debuffs
        uint256 bobMonIndex = 1;
        int32 attackDelta = engine.getMonStateForBattle(battleKey, 1, bobMonIndex, MonStateIndexName.Attack);
        int32 spAttackDelta = engine.getMonStateForBattle(battleKey, 1, bobMonIndex, MonStateIndexName.SpecialAttack);
        assertEq(attackDelta, -5, "Bob's mon's attack should be debuffed");
        assertEq(spAttackDelta, -5, "Bob's mon's special attack should be debuffed");
    }

    // Build two single-mon (well, duplicated) teams and start a battle. Alice carries
    // [burnApplier, graveAffliction]; Bob carries two fillers. Returns the battle key after both
    // mons are switched in.
    function _startGraveAfflictionBattle(IMoveSet aliceMove0, IMoveSet aliceMove1)
        internal
        returns (bytes32 battleKey)
    {
        DefaultValidator validator2 = new DefaultValidator(
            IEngine(address(engine)),
            DefaultValidator.Args({MONS_PER_TEAM: 2, MOVES_PER_MON: 2, TIMEOUT_DURATION: 10})
        );

        uint256[] memory aliceMoves = new uint256[](2);
        aliceMoves[0] = uint256(uint160(address(aliceMove0)));
        aliceMoves[1] = uint256(uint160(address(aliceMove1)));

        uint256[] memory bobMoves = new uint256[](2);
        bobMoves[0] = uint256(uint160(address(osteoporosis)));
        bobMoves[1] = uint256(uint160(address(osteoporosis)));

        Mon memory aliceMon = Mon({
            stats: MonStats({hp: 100, stamina: 10, speed: 10, attack: 5, defense: 5, specialAttack: 5, specialDefense: 5, type1: Type.Yang, type2: Type.None}),
            moves: aliceMoves,
            ability: 0
        });
        Mon memory bobMon = Mon({
            stats: MonStats({hp: 100, stamina: 10, speed: 5, attack: 5, defense: 5, specialAttack: 5, specialDefense: 5, type1: Type.Liquid, type2: Type.None}),
            moves: bobMoves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = aliceMon;
        aliceTeam[1] = aliceMon;
        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = bobMon;
        bobTeam[1] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        battleKey = _startBattle(validator2, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
    }

    // Grave Affliction halves the current HP of BOTH mons, but only when the opposing mon has a
    // status condition.
    function testGraveAffliction_firesWhenOpponentHasStatus() public {
        // A minimal attack that inflicts Burn on its target (used to give Bob a status condition).
        IMoveSet burnApplier = standardAttackFactory.createAttack(ATTACK_PARAMS({
            BASE_POWER: 10, STAMINA_COST: 2, ACCURACY: 100, PRIORITY: 3,
            MOVE_TYPE: Type.Yang, EFFECT_ACCURACY: 100, MOVE_CLASS: MoveClass.Special,
            CRIT_RATE: 0, VOLATILITY: 0, NAME: "Burnify", EFFECT: IEffect(address(burnStatus))
        }));

        bytes32 battleKey = _startGraveAfflictionBattle(burnApplier, IMoveSet(address(graveAffliction)));

        // Alice burns Bob (move 0); Bob no-ops.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        int32 aliceBefore = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 bobBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceBefore, 0, "Alice should be at full HP before Grave Affliction");

        // Alice uses Grave Affliction (move 1); Bob no-ops.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);

        int32 aliceAfter = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 bobAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Alice has no status, so her only loss is Grave Affliction's self-damage = half her current
        // (full) HP, i.e. 50.
        assertEq(aliceAfter, -50, "Alice should lose exactly half her current HP");

        // Bob loses at least half his current HP from Grave Affliction; Burn's round-end tick adds a
        // little more on top, hence the inequality.
        int32 bobCurrentHp = int32(100) + bobBefore;
        assertLe(bobAfter, bobBefore - bobCurrentHp / 2, "Bob should lose at least half his current HP");
    }

    // With no status on the opponent, Grave Affliction is a no-op for both mons.
    function testGraveAffliction_noOpWhenOpponentHealthy() public {
        bytes32 battleKey =
            _startGraveAfflictionBattle(IMoveSet(address(graveAffliction)), IMoveSet(address(graveAffliction)));

        // Alice uses Grave Affliction (move 0) while Bob has no status; Bob no-ops.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        int32 aliceHp = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 bobHp = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(aliceHp, 0, "Alice should take no damage when opponent has no status");
        assertEq(bobHp, 0, "Bob should take no damage when he has no status");
    }
}

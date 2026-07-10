// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Constants.sol";
import "../../src/Structs.sol";
import {Test} from "forge-std/Test.sol";

import {Engine} from "../../src/Engine.sol";
import {MonStateIndexName, MoveClass, Type} from "../../src/Enums.sol";
import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";

import {IEngine} from "../../src/IEngine.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";

import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {IEffect} from "../../src/effects/IEffect.sol";
import {Overclock} from "../../src/effects/battlefield/Overclock.sol";
import {ZapStatus} from "../../src/effects/status/ZapStatus.sol";

import {DualShock} from "../../src/mons/volthare/DualShock.sol";
import {MegaStarBlast} from "../../src/mons/volthare/MegaStarBlast.sol";
import {PreemptiveShock} from "../../src/mons/volthare/PreemptiveShock.sol";
import {Quickstorm} from "../../src/mons/volthare/Quickstorm.sol";

import {DummyStatus} from "../mocks/DummyStatus.sol";
import {GlobalEffectAttack} from "../mocks/GlobalEffectAttack.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {StandardAttack} from "../../src/moves/StandardAttack.sol";
import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";

contract VolthareTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    PreemptiveShock preemptiveShock;
    Overclock overclock;
    StandardAttackFactory attackFactory;
    DefaultMatchmaker matchmaker;
    ZapStatus qsZap;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        overclock = new Overclock();
        preemptiveShock = new PreemptiveShock(ITypeCalculator(address(typeCalc)));
        attackFactory = new StandardAttackFactory(ITypeCalculator(address(typeCalc)));
        matchmaker = new DefaultMatchmaker(engine);
    }

    /**
     * Test: PreemptiveShock deals damage when switching in
     * - When a mon with PreemptiveShock ability switches in, it should deal BASE_POWER (15)
     *   Lightning Physical damage to the opponent's active mon
     */
    function test_preemptiveShockDealsDamage() public {
        uint256[] memory moves = new uint256[](0);

        // Create a mon with PreemptiveShock ability
        Mon memory preemptiveShockMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(preemptiveShock))
        });

        // Create a regular mon with no ability
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Fire, // Not Lightning, so no same-type resistance
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = preemptiveShockMon;
        aliceTeam[1] = regularMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = regularMon;
        bobTeam[1] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Verify that Bob's mon took damage from PreemptiveShock
        // Damage can vary due to DEFAULT_VOL (10), so check it's within expected range
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        int32 basePower = int32(preemptiveShock.BASE_POWER());
        int32 volatility = int32(preemptiveShock.DEFAULT_VOL());
        assertTrue(bobHpDelta <= -basePower + volatility, "Bob's mon should take at least min PreemptiveShock damage");
        assertTrue(bobHpDelta >= -basePower - volatility, "Bob's mon should take at most max PreemptiveShock damage");
    }

    /**
     * Test: MegaStarBlast with Overclock active
     * - Uses a mock move to apply Overclock, then tests that MegaStarBlast has increased accuracy
     *   and can apply Zap status when Overclock is active
     */
    function test_megaStarBlast() public {
        // Create moves: one to apply Overclock, one is MegaStarBlast
        DummyStatus zapStatus = new DummyStatus();
        MegaStarBlast msb = new MegaStarBlast(typeCalc, zapStatus, overclock);
        GlobalEffectAttack overclockMove = new GlobalEffectAttack(
            overclock, GlobalEffectAttack.Args({TYPE: Type.Lightning, STAMINA_COST: 0, PRIORITY: 0})
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(overclockMove)));
        moves[1] = uint256(uint160(address(msb)));

        // Create a mon with no ability
        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create a regular mon with lots of HP
        Mon memory regularMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = regularMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses the Overclock move (move index 0), Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, uint16(0), 0);

        // Verify that Overclock is applied
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 1, "Overclock should be applied");
        assertEq(address(effects[0].effect), address(overclock), "Overclock should be applied");

        // Precomputed seed: MegaStarBlast hits for full damage and Zap procs (Alice = player 0)
        mockOracle.setRNG(39);

        // Alice uses Mega Star Blast (move index 1), Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint16(0), 0);

        // Verify that Bob's mon is zapped
        (effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should be zapped");
        assertEq(address(effects[0].effect), address(zapStatus), "Bob's mon should be zapped");

        // Verify that Bob has taken damage
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpDelta, -1 * int32(msb.BASE_POWER()), "Bob's mon should take 150 damage");

        // Now that Overclock has cleared, precomputed seed makes MSB miss at base accuracy (Alice)
        mockOracle.setRNG(2);

        // Alice uses Mega Star Blast, Bob does nothing
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint16(0), 0);

        // Verify that Bob's mon is not zapped (again)
        (effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Bob's mon should not be zapped (again)");

        // Verify that Bob's mon did not take more damage
        int32 bobHpDelta2 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpDelta2, bobHpDelta, "Bob's mon should not take more damage");
    }

    /**
     * Test: MegaStarBlast should not clear Overclock set by the opposing team
     * - Bob applies Overclock (stored with player index 1)
     * - Alice (player 0) uses MegaStarBlast
     * - Overclock should remain active (since Alice didn't set it)
     * - Alice's accuracy should be BASE_ACCURACY (not upgraded to 100)
     */
    function test_megaStarBlastDoesNotClearOpponentOverclock() public {
        DummyStatus zapStatus = new DummyStatus();
        MegaStarBlast msb = new MegaStarBlast(typeCalc, zapStatus, overclock);
        GlobalEffectAttack overclockMove = new GlobalEffectAttack(
            overclock, GlobalEffectAttack.Args({TYPE: Type.Lightning, STAMINA_COST: 0, PRIORITY: 0})
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(overclockMove)));
        moves[1] = uint256(uint160(address(msb)));

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // Both players send in their mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Bob applies Overclock (stored with player index 1). Alice does nothing.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 0, 0, 0);

        // Verify Overclock is applied and tagged with Bob's player index
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 1, "Overclock should be applied");
        assertEq(address(effects[0].effect), address(overclock), "Overclock should be applied");
        // Overclock packs [duration << 8 | playerIndex] into extraData — check the player byte.
        assertEq(uint256(effects[0].data) & 0xFF, 1, "Overclock should be tagged with Bob's index");
        assertGt(uint256(effects[0].data) >> 8, 0, "Overclock countdown should be running");

        // Precomputed seed makes Alice's MSB miss at base accuracy (60), confirming Overclock did
        // NOT upgrade accuracy to 100.
        mockOracle.setRNG(2);

        // Alice uses MegaStarBlast. Bob does nothing.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, uint16(0), 0);

        // Overclock should still be present (Alice cannot clear Bob's Overclock)
        (effects,) = engine.getEffects(battleKey, 2, 0);
        assertEq(effects.length, 1, "Overclock should still be active");
        assertEq(address(effects[0].effect), address(overclock), "Overclock should still be Bob's");
        assertEq(uint256(effects[0].data) & 0xFF, 1, "Overclock should still be tagged with Bob's index");

        // Alice's MSB should have missed (accuracy stayed at BASE_ACCURACY, RNG was above it)
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHpDelta, 0, "Bob's mon should take no damage (MSB missed at base accuracy)");
    }

    function test_dualShock() public {
        // Create a team with a mon that knows Dual Shock
        uint256[] memory moves = new uint256[](1);
        ZapStatus zapStatus = new ZapStatus();
        DualShock dualShock = new DualShock(typeCalc, zapStatus, overclock);
        moves[0] = uint256(uint160(address(dualShock)));

        // Create a mon with nice round stats
        Mon memory fastMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 100,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon memory slowMon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 1,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 100,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        // Create teams for Alice and Bob
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = fastMon;

        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = slowMon;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses Dual Shock; the self-zap lands after she has already acted, so no
        // immediate skip flag — the skip is armed at next RoundStart.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.ShouldSkipTurn), 0);
        int32 bobHpAfterFirstShock = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(bobHpAfterFirstShock < 0, "first Dual Shock landed");

        // Next turn: Alice's committed Dual Shock is skipped by the zap (no new damage).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            bobHpAfterFirstShock,
            "zap skipped Alice's next move"
        );
    }

    // Deploys a Volthare (Quickstorm + filler, PreemptiveShock ability) vs a plain Bob, starts the
    // battle, and completes the send-in. Quickstorm's Zap is deployed into `qsZap`.
    function _quickstormBattle() internal returns (bytes32) {
        qsZap = new ZapStatus();
        Quickstorm quickstorm = new Quickstorm(ITypeCalculator(address(typeCalc)), IEffect(address(qsZap)));
        StandardAttack filler = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 10,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Lightning,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Filler",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(quickstorm)));
        moves[1] = uint256(uint160(address(filler)));

        Mon memory aliceMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Lightning,
                type2: Type.None
            }),
            moves: moves,
            ability: uint160(address(preemptiveShock))
        });
        Mon memory bobMon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 50,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = aliceMon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = bobMon;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        return battleKey;
    }

    // Quickstorm lands on Volthare's first acting turn: damages and Zaps the opponent.
    function test_quickstormLandsOnFirstTurn() public {
        bytes32 battleKey = _quickstormBattle();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertLt(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "Quickstorm should damage Bob");
        (bool bobZapped,,) = engine.getEffectData(battleKey, 1, 0, address(qsZap));
        assertTrue(bobZapped, "Quickstorm should Zap Bob on the first turn");
    }

    // Once Volthare acts with anything else, its first-turn window closes and Quickstorm fizzles.
    function test_quickstormFizzlesAfterFirstTurn() public {
        bytes32 battleKey = _quickstormBattle();
        // Turn 1: act with the filler (move 1), spending the first-turn window.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);
        int32 bobHpAfterT1 = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Turn 2: Quickstorm now does nothing.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(
            engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp),
            bobHpAfterT1,
            "Quickstorm should do nothing after the first turn"
        );
        (bool bobZapped,,) = engine.getEffectData(battleKey, 1, 0, address(qsZap));
        assertFalse(bobZapped, "Quickstorm should not Zap after the first turn");
    }
}

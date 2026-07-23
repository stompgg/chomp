// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {IEngine} from "../../src/IEngine.sol";
import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

import {StatBoostsMove} from "../mocks/StatBoostsMove.sol";

import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "../abstract/BattleHelper.sol";

import {StandardAttackFactory} from "../../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../../src/moves/StandardAttackStructs.sol";
import {SpAtkDebuffEffect} from "../mocks/SpAtkDebuffEffect.sol";

contract StatBoostsTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    TestTypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    StatBoostsMove statBoostMove;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        typeCalc = new TestTypeCalculator();
        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));

        // Create the StatBoosts effect and move
        statBoostMove = new StatBoostsMove();
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_statBoostMove() public {
        // Create teams with two mons each
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(statBoostMove))); // Stat boost move (we'll pass different params when using it)

        Mon memory mon1 = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
                speed: 100,
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

        Mon memory mon2 = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = mon1;
        aliceTeam[1] = mon2;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = mon1;
        bobTeam[1] = mon2;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // We'll test Attack stat in detail
        testStatBoost(battleKey, uint256(MonStateIndexName.Attack));
    }

    /*
        - Create a boost
        - Check to see that the effect is added to the mon's effects array
        - Next turn, update, the boost
        - Check to see that the effect is still in the mon's effects array (but no extra array value)
        - Next turn, add a debuff that reduces the boost
        - Check to see that the effect is still in the mon's effects array (but no extra array value)
        - Next turn, switch out
        - Check to see that the effect is removed from the mon's effects array
    */
    function testStatBoost(bytes32 battleKey, uint256 statIndex) internal {
        string memory statName = getStatName(statIndex);

        // 1. Apply a positive boost to Alice's mon
        console.log("Testing %s stat boost", statName);
        console.log("1. Applying 10% boost to Alice's mon");

        int32 initialStat = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName(statIndex));

        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            0, // Alice uses stat boost move
            NO_OP_MOVE_INDEX, // Bob does nothing
            _packStatBoost(0, statIndex, int32(10)), // Alice boosts her own mon by 10%
            0 // Bob does nothing
        );

        // Verify the stat was boosted
        int32 boostedStat = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName(statIndex));
        assertEq(boostedStat, initialStat + 10, "Stat should be boosted by 10%");

        // Verify the source landed in the mon's boost store (boost sources are no longer
        // effect-list entries)
        (BattleConfigView memory cfgView,) = engine.getBattle(battleKey);
        assertEq(cfgView.p0StatBoosts[0].length, 1, "Stat Boost source should be in the boost store");
        uint256 sourceCount = cfgView.p0StatBoosts[0].length;

        // 2. Apply another boost (+10) to the same stat
        console.log("2. Applying additional 1% boost to Alice's mon");

        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            0, // Alice uses stat boost move
            NO_OP_MOVE_INDEX, // Bob does nothing
            _packStatBoost(0, statIndex, int32(10)),
            0 // Bob does nothing
        );

        // Verify the stat was boosted further
        int32 furtherBoostedStat = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName(statIndex));
        assertEq(furtherBoostedStat, initialStat + 21, "Stat should be boosted by 21% total");

        // Verify no duplicate source was added (same caller merges into one source)
        (cfgView,) = engine.getBattle(battleKey);
        assertEq(cfgView.p0StatBoosts[0].length, sourceCount, "No duplicate source should be added");

        // Switch out the mon
        console.log("4. Switching out Alice's mon");

        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            SWITCH_MOVE_INDEX, // Alice switches
            NO_OP_MOVE_INDEX, // Bob does nothing
            uint16(1), // Alice switches to mon 1
            0 // Bob does nothing
        );

        // Verify the temp source expired off the switched-out mon's boost store
        (cfgView,) = engine.getBattle(battleKey);
        assertEq(cfgView.p0StatBoosts[0].length, 0, "Stat Boost source should be removed after switching out");

        // 5. Switch back to the original mon and verify stat is reset
        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            SWITCH_MOVE_INDEX, // Alice switches
            NO_OP_MOVE_INDEX, // Bob does nothing
            uint16(0), // Alice switches back to mon 0
            0 // Bob does nothing
        );

        // Verify the stat was reset
        int32 resetStat = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName(statIndex));
        assertEq(resetStat, initialStat, "Stat should be reset after switching out and back in");
    }

    function getStatName(uint256 statIndex) internal pure returns (string memory) {
        if (statIndex == uint256(MonStateIndexName.Attack)) {
            return "Attack";
        }
        if (statIndex == uint256(MonStateIndexName.Defense)) {
            return "Defense";
        }
        if (statIndex == uint256(MonStateIndexName.SpecialAttack)) {
            return "Special Attack";
        }
        if (statIndex == uint256(MonStateIndexName.SpecialDefense)) {
            return "Special Defense";
        }
        if (statIndex == uint256(MonStateIndexName.Speed)) {
            return "Speed";
        }
        return "Unknown";
    }

    function test_allStatBoosts() public {
        // Create teams with two mons each
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(statBoostMove))); // Stat boost move (we'll pass different params when using it)

        Mon memory mon1 = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
                speed: 100,
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

        Mon memory mon2 = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 100,
                speed: 100,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = mon1;
        aliceTeam[1] = mon2;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = mon1;
        bobTeam[1] = mon2;

        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        // Start a battle
        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));

        // First move: Both players select their first mon (index 0)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Test all stats
        uint256[] memory statIndices = new uint256[](5);
        statIndices[0] = uint256(MonStateIndexName.Attack);
        statIndices[1] = uint256(MonStateIndexName.Defense);
        statIndices[2] = uint256(MonStateIndexName.SpecialAttack);
        statIndices[3] = uint256(MonStateIndexName.SpecialDefense);
        statIndices[4] = uint256(MonStateIndexName.Speed);

        for (uint256 i = 0; i < statIndices.length; i++) {
            // Apply a boost to each stat
            _commitRevealExecuteForAliceAndBob(
                engine,
                commitManager,
                battleKey,
                0, // Alice uses stat boost move
                NO_OP_MOVE_INDEX, // Bob does nothing
                _packStatBoost(0, statIndices[i], int32(2)), // Alice boosts her own mon by +2
                0 // Bob does nothing
            );

            // Verify the stat was boosted
            int32 boostedStat = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName(statIndices[i]));
            assertEq(boostedStat, 2, "Stat should be boosted by +2");

            // Verify the source is in the boost store
            (BattleConfigView memory statView,) = engine.getBattle(battleKey);
            assertTrue(statView.p0StatBoosts[0].length > 0, "Stat Boost source should be added for each stat");
        }

        // Switch out and verify all effects are removed
        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            SWITCH_MOVE_INDEX, // Alice switches
            NO_OP_MOVE_INDEX, // Bob does nothing
            uint16(1), // Alice switches to mon 1
            0 // Bob does nothing
        );

        // Verify all temp sources expired off the switched-out mon
        (BattleConfigView memory afterView,) = engine.getBattle(battleKey);
        assertEq(afterView.p0StatBoosts[0].length, 0, "No Stat Boost sources should remain after switching out");
    }

    function test_permanentTempStatBoostInteraction() public {
        StandardAttackFactory attackFactory = new StandardAttackFactory(typeCalc);
        SpAtkDebuffEffect spAtkDebuff = new SpAtkDebuffEffect();

        // Create teams with two mons each
        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(statBoostMove)));
        moves[1] = uint256(
            uint160(
                address(
                    attackFactory.createAttack(
                        ATTACK_PARAMS({
                            BASE_POWER: 0,
                            STAMINA_COST: 0,
                            ACCURACY: 100,
                            PRIORITY: 1,
                            MOVE_TYPE: Type.Ice,
                            EFFECT_ACCURACY: 100,
                            MOVE_CLASS: MoveClass.Physical,
                            CRIT_RATE: 0,
                            VOLATILITY: 0,
                            NAME: "SpAtkDebuffHit",
                            EFFECT: IEffect(address(spAtkDebuff))
                        })
                    )
                )
            )
        );
        uint32 maxSpAtk = 100;
        Mon memory mon = _createMon();
        mon.stats.specialAttack = maxSpAtk;
        mon.moves = moves;
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        // Both players select their first mon (index 0)
        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Alice uses stat boost move to boost her mon's special atk 50%, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            0, // Alice uses stat boost move
            NO_OP_MOVE_INDEX, // Bob does nothing
            _packStatBoost(0, uint256(MonStateIndexName.SpecialAttack), int32(50)), // Alice boosts her own mon by 50%
            0 // Bob does nothing
        );

        // Verify the stat was boosted
        int32 boostedStat = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertEq(boostedStat, 50, "Stat should be boosted by 50%");

        // Alice does nothing, Bob uses SpAtkDebuffHit to apply SpAtkDebuffEffect to Alice's mon
        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            NO_OP_MOVE_INDEX, // Alice does nothing
            1, // Bob uses SpAtkDebuffHit
            0, // Alice does nothing
            0 // Bob does nothing
        );

        // Verify the stat was reduced
        int32 reducedStat = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertEq(reducedStat, -25, "Stat is at 75% of original value");

        // Alice swaps out, Bob does nothing
        _commitRevealExecuteForAliceAndBob(
            engine,
            commitManager,
            battleKey,
            SWITCH_MOVE_INDEX, // Alice switches
            NO_OP_MOVE_INDEX, // Bob does nothing
            uint16(1), // Alice switches to mon 1
            0 // Bob does nothing
        );

        // Verify the stat was reduced
        int32 reducedStatAfterSwitch = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertEq(reducedStatAfterSwitch, -50, "Stat should be set to -50% now");
    }

    /// @dev Stack +75% multiplicative SpAtk to the point where the raw value exceeds int32 max
    /// but the math still fits in uint256 (no wrap). The clamp must pin boosted SpAtk at
    /// MAX_BOOSTED_STAT exactly. With base=100, raw exceeds int32.max around N=31, while
    /// 175^N stays under uint256 max through N≈34, so 32 stacks lands in the clamp-but-no-wrap
    /// regime — the strongest tight assertion we can make.
    function test_statBoostExactClampWithoutWrap() public {
        bytes32 battleKey = _setupSingleStatBoostBattle(100);

        for (uint256 i = 0; i < 32; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine,
                commitManager,
                battleKey,
                0,
                NO_OP_MOVE_INDEX,
                _packStatBoost(0, uint256(MonStateIndexName.SpecialAttack), int32(75)),
                0
            );
        }

        int32 spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        assertEq(int256(spAtkDelta) + 100, int256(type(int32).max), "Boosted SpAtk should be clamped at int32 max");
    }

    /// @dev Push past the unchecked-wrap threshold. `175^N * 100` overflows uint256 around N=34;
    /// past that, raw values are unpredictable. The only guarantee is no revert and that the
    /// clamp keeps the stored boosted stat inside [1, MAX_BOOSTED_STAT] — which is what keeps
    /// monState.<stat>Delta from drifting outside int32 (so the engine's checked addition in
    /// `_updateMonStateInternal` never reverts).
    function test_statBoostWrapRegimeStaysInInt32Range() public {
        bytes32 battleKey = _setupSingleStatBoostBattle(100);

        // 60 stacks > 34 (uint256 wrap point). Verify safe behavior past wrap.
        for (uint256 i = 0; i < 60; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine,
                commitManager,
                battleKey,
                0,
                NO_OP_MOVE_INDEX,
                _packStatBoost(0, uint256(MonStateIndexName.SpecialAttack), int32(75)),
                0
            );
        }

        int32 spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        int256 boosted = int256(spAtkDelta) + 100;
        // [1, MAX_BOOSTED_STAT] is the post-wrap invariant the apply-time clamp guarantees.
        assertTrue(
            boosted >= 1 && boosted <= int256(type(int32).max), "Boosted SpAtk should stay within [1, int32.max]"
        );
    }

    /// @dev Push the per-instance count well past the 7-bit storage field (and past 256, where
    /// the in-memory uint8 increment would otherwise revert). The merge cap holds storage at
    /// 127 and the unchecked accumulation prevents reverts in `_accumulateBoosts` / `_denomPower`.
    function test_statBoostMassiveStackBeyondUint8DoesNotRevert() public {
        bytes32 battleKey = _setupSingleStatBoostBattle(100);

        // 300 > 256 (uint8 increment revert point) and >> 127 (storage field width). Both
        // protections are exercised here.
        for (uint256 i = 0; i < 300; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine,
                commitManager,
                battleKey,
                0,
                NO_OP_MOVE_INDEX,
                _packStatBoost(0, uint256(MonStateIndexName.SpecialAttack), int32(75)),
                0
            );
        }

        int32 spAtkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.SpecialAttack);
        int256 boosted = int256(spAtkDelta) + 100;
        assertTrue(
            boosted >= 1 && boosted <= int256(type(int32).max), "Boosted SpAtk should stay within [1, int32.max]"
        );
    }

    /// @dev With the StatBoosts apply-time clamp + AttackCalculator's uint256 product, a heavily
    /// boosted attacker stat must not revert the damage path. Without the changes,
    /// `scaledBasePower * attackStat * rngScaling` would overflow the uint32 multiplication.
    function test_dealDamageDoesNotRevertWithExtremelyBoostedAttack() public {
        StandardAttackFactory attackFactory = new StandardAttackFactory(typeCalc);
        uint256 attackMoveAddr = uint256(
            uint160(
                address(
                    attackFactory.createAttack(
                        ATTACK_PARAMS({
                            BASE_POWER: 100,
                            STAMINA_COST: 0,
                            ACCURACY: 100,
                            PRIORITY: 1,
                            MOVE_TYPE: Type.Air,
                            EFFECT_ACCURACY: 0,
                            MOVE_CLASS: MoveClass.Physical,
                            CRIT_RATE: 0,
                            VOLATILITY: 0,
                            NAME: "BoostedHit",
                            EFFECT: IEffect(address(0))
                        })
                    )
                )
            )
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(statBoostMove)));
        moves[1] = attackMoveAddr;

        Mon memory attacker = _createMon();
        attacker.stats.hp = 10_000;
        attacker.stats.attack = 100;
        attacker.stats.defense = 100;
        attacker.stats.stamina = 100;
        attacker.moves = moves;

        Mon memory defender = attacker;

        Mon[] memory team = new Mon[](2);
        team[0] = attacker;
        team[1] = defender;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // 32 stacks of +75% with base 100 lands raw above int32.max but the math still fits
        // in uint256 — exact-clamp regime. Attack pins at MAX_BOOSTED_STAT = int32.max.
        for (uint256 i = 0; i < 32; i++) {
            _commitRevealExecuteForAliceAndBob(
                engine,
                commitManager,
                battleKey,
                0,
                NO_OP_MOVE_INDEX,
                _packStatBoost(0, uint256(MonStateIndexName.Attack), int32(75)),
                0
            );
        }

        // Confirm Alice's attack stat is clamped (delta + base == int32.max).
        int32 atkDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Attack);
        assertEq(int256(atkDelta) + 100, int256(type(int32).max), "Alice's attack should be clamped at int32 max");

        // Now attack. The damage formula must compute in uint256 and clamp to int32 — no revert.
        int32 defenderHpDeltaBefore = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, NO_OP_MOVE_INDEX, 0, 0);
        int32 defenderHpDeltaAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        // Damage was applied (hpDelta moved). Whether the defender survives or KOs depends on the
        // clamped damage value vs HP — both outcomes are valid; the only invariant is no revert.
        assertTrue(defenderHpDeltaAfter != defenderHpDeltaBefore, "Boosted attack should land");
    }

    /// @dev Helper: spin up a battle with a single mon per team that has only the StatBoostsMove,
    /// configured with the given base SpecialAttack value, and select it as active.
    function _setupSingleStatBoostBattle(uint32 baseSpAtk) internal returns (bytes32) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(statBoostMove)));

        Mon memory mon = _createMon();
        mon.stats.specialAttack = baseSpAtk;
        mon.moves = moves;

        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        return battleKey;
    }
}

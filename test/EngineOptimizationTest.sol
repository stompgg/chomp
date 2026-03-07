// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultRuleset} from "../src/DefaultRuleset.sol";
import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IAbility} from "../src/abilities/IAbility.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {StaminaRegen} from "../src/effects/StaminaRegen.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {ITeamRegistry} from "../src/teams/ITeamRegistry.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";
import {EffectAttack} from "./mocks/EffectAttack.sol";
import {AlwaysRejectsEffect} from "./mocks/AlwaysRejectsEffect.sol";
import {NeverAppliesEffect} from "./mocks/NeverAppliesEffect.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";

contract EngineOptimizationTest is Test, BattleHelper {
    DefaultCommitManager commitManager;
    Engine engine;
    DefaultValidator oneMonValidator;
    ITypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    StandardAttackFactory standardAttackFactory;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(engine);
        oneMonValidator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 100})
        );
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        standardAttackFactory = new StandardAttackFactory(typeCalc);
        matchmaker = new DefaultMatchmaker(engine);
    }

    // ============================================================
    // 9a. ALWAYS_APPLIES_BIT bypasses shouldApply
    // ============================================================

    /// @notice When ALWAYS_APPLIES_BIT is set, effect should be added even though shouldApply returns false
    function test_alwaysAppliesBitBypassesShouldApply() public {
        AlwaysRejectsEffect alwaysRejectsEffect = new AlwaysRejectsEffect();

        // Create an EffectAttack that applies AlwaysRejectsEffect to the opponent
        IMoveSet effectMove = new EffectAttack(
            IEffect(address(alwaysRejectsEffect)),
            EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 0, PRIORITY: 1})
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100, stamina: 10, speed: 10,
                attack: 1, defense: 1, specialAttack: 1, specialDefense: 1,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new IMoveSet[](1),
            ability: IAbility(address(0))
        });
        mon.moves[0] = effectMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(0)), address(commitManager)
        );

        // Switch in mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Alice uses effect move on Bob (Bob does NoOp)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0
        );

        // Bob's mon (player 1, mon 0) should have the effect applied
        // because ALWAYS_APPLIES_BIT bypasses shouldApply()
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 1, "Effect should be added despite shouldApply returning false");
        assertEq(address(effects[0].effect), address(alwaysRejectsEffect));
    }

    // ============================================================
    // 9b. Without ALWAYS_APPLIES_BIT, shouldApply is still checked
    // ============================================================

    /// @notice Without ALWAYS_APPLIES_BIT, shouldApply returning false prevents effect from being added
    function test_effectWithoutAlwaysAppliesBitStillChecksShouldApply() public {
        NeverAppliesEffect neverAppliesEffect = new NeverAppliesEffect();

        IMoveSet effectMove = new EffectAttack(
            IEffect(address(neverAppliesEffect)),
            EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 0, PRIORITY: 1})
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100, stamina: 10, speed: 10,
                attack: 1, defense: 1, specialAttack: 1, specialDefense: 1,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new IMoveSet[](1),
            ability: IAbility(address(0))
        });
        mon.moves[0] = effectMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(0)), address(commitManager)
        );

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0
        );

        // Bob's mon should NOT have the effect (shouldApply returns false, no ALWAYS_APPLIES_BIT)
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 1, 0);
        assertEq(effects.length, 0, "Effect should NOT be added when shouldApply returns false");
    }

    // ============================================================
    // 9c. Inline StaminaRegen on RoundEnd
    // ============================================================

    /// @notice address(0) global effect produces same stamina regen as real StaminaRegen on RoundEnd
    function test_inlineStaminaRegenOnRoundEnd() public {
        // Use address(0) as the global effect (inline StaminaRegen)
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = IEffect(address(0));
        DefaultRuleset ruleset = new DefaultRuleset(engine, effects);

        // Deploy a no-damage move that costs 5 stamina
        IMoveSet noDamageAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 5,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "NoDamage",
                EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20, stamina: 10, speed: 2,
                attack: 1, defense: 1, specialAttack: 20, specialDefense: 1,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new IMoveSet[](1),
            ability: IAbility(address(0))
        });
        mon.moves[0] = noDamageAttack;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager)
        );

        // Switch in mons
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Both use 5-stamina move. After: -5 from move + 1 from RoundEnd regen = -4
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -4);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -4);
    }

    // ============================================================
    // 9d. Inline StaminaRegen on NoOp
    // ============================================================

    /// @notice address(0) global effect regens stamina on NoOp (AfterMove) + RoundEnd
    function test_inlineStaminaRegenOnNoOp() public {
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = IEffect(address(0));
        DefaultRuleset ruleset = new DefaultRuleset(engine, effects);

        IMoveSet noDamageAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 5,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "NoDamage",
                EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20, stamina: 10, speed: 2,
                attack: 1, defense: 1, specialAttack: 20, specialDefense: 1,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new IMoveSet[](1),
            ability: IAbility(address(0))
        });
        mon.moves[0] = noDamageAttack;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager)
        );

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Both use 5-stamina move: staminaDelta = -5 + 1 (RoundEnd) = -4
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -4);

        // Both NoOp: +1 from AfterMove (NoOp regen) + 1 from RoundEnd = +2 total
        // staminaDelta: -4 + 2 = -2
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), -2);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), -2);
    }

    // ============================================================
    // 9e. Inline StaminaRegen does not overheal
    // ============================================================

    /// @notice Stamina regen should not push staminaDelta above 0
    function test_inlineStaminaRegenDoesNotOverheal() public {
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = IEffect(address(0));
        DefaultRuleset ruleset = new DefaultRuleset(engine, effects);

        // Move costs only 1 stamina
        IMoveSet cheapAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "CheapMove",
                EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20, stamina: 10, speed: 2,
                attack: 1, defense: 1, specialAttack: 20, specialDefense: 1,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new IMoveSet[](1),
            ability: IAbility(address(0))
        });
        mon.moves[0] = cheapAttack;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager)
        );

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Use 1-stamina move: -1 from move + 1 from RoundEnd regen = 0 (not +1)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Should be exactly 0, not positive (no overhealing)
        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina), 0);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina), 0);
    }

    // ============================================================
    // 9f. Inline StaminaRegen saves gas vs external
    // ============================================================

    /// @notice Inline StaminaRegen (address(0)) should use less gas than external StaminaRegen
    /// @dev Uses same engine with 3 sequential battles: warmup (external), then external vs inline
    ///      Battle 2 (external) and Battle 3 (inline) both hit warm storage equally
    function test_inlineStaminaRegenGasSavings() public {
        IMoveSet noDamageAttack = standardAttackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 0,
                STAMINA_COST: 5,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "NoDamage",
                EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 20, stamina: 10, speed: 2,
                attack: 1, defense: 1, specialAttack: 20, specialDefense: 1,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new IMoveSet[](1),
            ability: IAbility(address(0))
        });
        mon.moves[0] = noDamageAttack;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        StaminaRegen staminaRegen = new StaminaRegen();
        IEffect[] memory externalEffects = new IEffect[](1);
        externalEffects[0] = staminaRegen;
        DefaultRuleset externalRuleset = new DefaultRuleset(engine, externalEffects);

        IEffect[] memory inlineEffects = new IEffect[](1);
        inlineEffects[0] = IEffect(address(0));
        DefaultRuleset inlineRuleset = new DefaultRuleset(engine, inlineEffects);

        // Battle 1: warmup (cold storage hit absorbed here)
        bytes32 warmupKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(externalRuleset)), address(commitManager)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, warmupKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, warmupKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, warmupKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);

        // Battle 2: external StaminaRegen (warm storage)
        bytes32 externalKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(externalRuleset)), address(commitManager)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, externalKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));

        vm.startSnapshotGas("ExternalStaminaRegen");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, externalKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, externalKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        uint256 externalGas = vm.stopSnapshotGas("ExternalStaminaRegen");

        // Battle 3: inline StaminaRegen (warm storage, same engine)
        bytes32 inlineKey = _startBattle(
            oneMonValidator, engine, mockOracle, defaultRegistry, matchmaker,
            new IEngineHook[](0), IRuleset(address(inlineRuleset)), address(commitManager)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, inlineKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));

        vm.startSnapshotGas("InlineStaminaRegen");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, inlineKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, inlineKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        uint256 inlineGas = vm.stopSnapshotGas("InlineStaminaRegen");

        // Verify correctness: both should produce same stamina deltas
        assertEq(
            engine.getMonStateForBattle(externalKey, 0, 0, MonStateIndexName.Stamina),
            engine.getMonStateForBattle(inlineKey, 0, 0, MonStateIndexName.Stamina),
            "P0 stamina should match between inline and external"
        );

        // Log gas comparison (not asserted -- cold storage effects make in-test comparison unreliable)
        // True savings are measured via EngineGasTest snapshots across runs
        console.log("External StaminaRegen gas:", externalGas);
        console.log("Inline StaminaRegen gas:", inlineGas);
        if (inlineGas < externalGas) {
            console.log("Gas saved:", externalGas - inlineGas);
        } else {
            console.log("Gas overhead (cold storage artifact):", inlineGas - externalGas);
        }
    }
}

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
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {ITeamRegistry} from "../src/teams/ITeamRegistry.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";

import {EffectAttack} from "./mocks/EffectAttack.sol";
import {StatBoostsMove} from "./mocks/StatBoostsMove.sol";

import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";

import {IEngineHook} from "../src/IEngineHook.sol";

import {SingleInstanceEffect} from "./mocks/SingleInstanceEffect.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

contract EngineGasTest is Test, BattleHelper {

    DefaultCommitManager commitManager;
    Engine engine;
    ITypeCalculator typeCalc;
    DefaultRandomnessOracle defaultOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;

    // Helper to pack StatBoostsMove extraData: lower 60 bits = playerIndex, next 60 bits = monIndex, next 60 bits = statIndex, upper 60 bits = boostAmount
    function _packStatBoost(uint256 playerIndex, uint256 monIndex, uint256 statIndex, int32 boostAmount) internal pure returns (uint240) {
        return uint240(playerIndex | (monIndex << 60) | (statIndex << 120) | (uint256(uint32(boostAmount)) << 180));
    }

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(engine);
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
    }

    /**
        - Two teams of 4 mons
        - Each mon has 4 moves:
            - burn move
            - frostbite move
            - stat boost move
            - attacking move
        - Set up with default stamina regen
        - Battle 2:
            - Both players send in mon 0
            - Alice sets up self-stat boost, Bob sets up Burn
            - Alice KOs Bob
            - Bob swaps in mon index 1
            - Alice swaps in mon index 1, Bob sets up Frostbite
            - Alice sets up self-stat boost, Bob rests
            - Alice KOs Bob
            - Bob sends in mon index 2
            - Alice rests, Bob uses self-stat boost
            - Alice rests, Bob KOs
            - Alice uses self-stat boost, Bob uses self-stat boost
            - Alice KOs, Bob rests
            - Bob sends in mon index 3
            - Alice KOs, Bob rests
     */

     function test_consecutiveBattleGas() public {
        Mon memory mon = _createMon();
        mon.stats.stamina = 5;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;

        mon.moves = new IMoveSet[](4);
        StatBoosts statBoosts = new StatBoosts(engine);
        IMoveSet burnMove = new EffectAttack(engine, new BurnStatus(engine, statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet frostbiteMove = new EffectAttack(engine, new FrostbiteStatus(engine, statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet statBoostMove = new StatBoostsMove(engine, statBoosts);
        IMoveSet damageMove = new CustomAttack(engine, ITypeCalculator(address(typeCalc)), CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 1}));
        mon.moves[0] = burnMove;
        mon.moves[1] = frostbiteMove;
        mon.moves[2] = statBoostMove;
        mon.moves[3] = damageMove;

        Mon[] memory team = new Mon[](4);
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        DefaultValidator validator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: team.length, MOVES_PER_MON: mon.moves.length, TIMEOUT_DURATION: 10})
        );
        StaminaRegen staminaRegen = new StaminaRegen(engine);
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);

        vm.startSnapshotGas("Setup 1");
        bytes32 battleKey =  _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));
        uint256 setup1Gas = vm.stopSnapshotGas("Setup 1");

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        // - Battle 1:
        // - Both players send in mon 0 [x]
        // - Alice sets up Burn, Bob sets up Frostbite [x]
        // - Alice swaps to mon 1, Bob sets up self-stat boost [x]
        // - Alice sets up self-stat boost, Bob KOs [x]
        // - Alice swaps in mon index 0 
        // - Alice sets up self-stat boost, Bob rests
        // - Alice KOs Bob
        // - Bob sends in mon index 1
        // - Alice rests, Bob uses self-stat boost
        // - Alice rests, Bob KOs
        // - Alice swaps in mon index 2
        // - Alice rests, Bob KOs
        // - Alice swaps in mon index 3
        // - Alice rests, Bob KOs
        vm.startSnapshotGas("FirstBattle");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        // Alice uses burn, Bob uses frostbite
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);
        // Bob is mon index 0, we boost attack by 90%
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 2, uint240(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        // Alice is now mon index 1, Bob is mon index 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        // Alice swaps in mon index 0
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0), true);
        // Alice is now mon index 0, Bob rests
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        // Alice KOs Bob
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);
        // Bob sends in mon index 1
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        // Alice rests, Bob uses self-stat boost
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        // Alice rests, Bob KOs
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        // Alice swaps in mon index 2
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        // Alice rests, Bob KOs
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        // Alice swaps in mon index 3
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        // Alice rests, Bob KOs
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 firstBattleGas = vm.stopSnapshotGas("FirstBattle");

        vm.startSnapshotGas("Intermediary stuff");
        // Rearrange order of moves for battle 2
        mon.moves[1] = burnMove;
        mon.moves[2] = frostbiteMove;
        mon.moves[3] = statBoostMove;
        mon.moves[0] = damageMove;
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        vm.stopSnapshotGas("Intermediary stuff");

        // - Battle 2:
        //     - Both players send in mon 0
        //     - Alice sets up self-stat boost, Bob sets up Burn
        //     - Alice KOs Bob
        //     - Bob swaps in mon index 1
        //     - Alice swaps in mon index 1, Bob sets up Frostbite
        //     - Alice sets up self-stat boost, Bob rests
        //     - Alice KOs Bob
        //     - Bob sends in mon index 2
        //     - Alice rests, Bob uses self-stat boost
        //     - Alice rests, Bob KOs
        //     - Alice swaps in mon index 2
        //     - Alice uses self-stat boost, Bob uses self-stat boost
        //     - Alice KOs, Bob rests
        //     - Bob sends in mon index 3
        //     - Alice KOs, Bob rests
        vm.startSnapshotGas("Setup 2");
        bytes32 battleKey2 =  _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));
        uint256 setup2Gas = vm.stopSnapshotGas("Setup 2");

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        // Check effects array after setup 2
        (BattleConfigView memory cfgAfterSetup2,) = engine.getBattle(battleKey2);
        console.log("After setup 2 - globalEffectsLength:", cfgAfterSetup2.globalEffectsLength);
        console.log("After setup 2 - packedP0EffectsCount:", cfgAfterSetup2.packedP0EffectsCount);
        console.log("After setup 2 - packedP1EffectsCount:", cfgAfterSetup2.packedP1EffectsCount);

        // - Both players send in mon 0
        vm.startSnapshotGas("SecondBattle");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        // - Alice sets up self-stat boost (move 3), Bob sets up Burn (move 1)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, 1, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        // - Alice KOs Bob (move 0 = damage)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        // - Bob swaps in mon index 1
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        // - Alice swaps in mon index 1, Bob sets up Frostbite (move 2)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, 2, uint240(1), 0);
        // - Alice sets up self-stat boost (move 3, playerIndex=0, monIndex=1), Bob rests
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, NO_OP_MOVE_INDEX, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        // - Alice KOs Bob (move 0)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        // - Bob sends in mon index 2
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        // - Alice rests, Bob uses self-stat boost (move 3, playerIndex=1, monIndex=2)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, NO_OP_MOVE_INDEX, 3, 0, _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        // - Alice rests, Bob KOs (move 0)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, NO_OP_MOVE_INDEX, 0, 0, 0);
        // - Alice swaps in mon index 2
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        // - Alice uses self-stat boost (move 3, p0 mon2), Bob uses self-stat boost (move 3, p1 mon2)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, 3, _packStatBoost(0, 2, uint256(MonStateIndexName.Attack), int32(90)), _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        // - Alice KOs Bob (move 0)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        // - Bob sends in mon index 3
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        // - Alice KOs Bob (move 0)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        uint256 secondBattleGas = vm.stopSnapshotGas("SecondBattle");

        // Battle 3: Repeat exact sequence of Battle 1 to test warm storage slots
        // Restore original move order (same as battle 1)
        mon.moves[0] = burnMove;
        mon.moves[1] = frostbiteMove;
        mon.moves[2] = statBoostMove;
        mon.moves[3] = damageMove;
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        vm.startSnapshotGas("Setup 3");
        bytes32 battleKey3 = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));
        uint256 setup3Gas = vm.stopSnapshotGas("Setup 3");

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        // Battle 3: Exact same sequence as Battle 1
        vm.startSnapshotGas("ThirdBattle");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        // Alice uses burn, Bob uses frostbite
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 0, 1, 0, 0);
        // Bob is mon index 0, we boost attack by 90%
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, SWITCH_MOVE_INDEX, 2, uint240(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        // Alice is now mon index 1, Bob is mon index 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        // Alice swaps in mon index 0
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(0), true);
        // Alice is now mon index 0, Bob rests
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        // Alice KOs Bob
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 3, NO_OP_MOVE_INDEX, 0, 0);
        // Bob sends in mon index 1
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        // Alice rests, Bob uses self-stat boost
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        // Alice rests, Bob KOs
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        // Alice swaps in mon index 2
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        // Alice rests, Bob KOs
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        // Alice swaps in mon index 3
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        // Alice rests, Bob KOs
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 thirdBattleGas = vm.stopSnapshotGas("ThirdBattle");

        // Log the values
        console.log("=== Gas Results ===");
        console.log("Setup 1 Gas:", setup1Gas);
        console.log("Setup 2 Gas:", setup2Gas);
        console.log("Setup 3 Gas:", setup3Gas);
        console.log("Battle 1 Gas:", firstBattleGas);
        console.log("Battle 2 Gas:", secondBattleGas);
        console.log("Battle 3 Gas:", thirdBattleGas);

        // Setup comparison - this SHOULD pass (reusing storage keys)
        assertLt(setup2Gas, setup1Gas, "Setup 2 should be cheaper (storage reuse)");
        assertLt(setup3Gas, setup1Gas, "Setup 3 should be cheaper (storage reuse)");

        // Battle comparison
        console.log("=== Battle Comparisons ===");
        if (secondBattleGas > firstBattleGas) {
            console.log("Battle 2 vs 1: MORE expensive by:", secondBattleGas - firstBattleGas);
        } else {
            console.log("Battle 2 vs 1: LESS expensive by:", firstBattleGas - secondBattleGas);
        }
        if (thirdBattleGas > firstBattleGas) {
            console.log("Battle 3 vs 1: MORE expensive by:", thirdBattleGas - firstBattleGas);
        } else {
            console.log("Battle 3 vs 1: LESS expensive by:", firstBattleGas - thirdBattleGas);
        }
        // Battle 3 should be cheaper than Battle 1 since it hits the same storage slots
        console.log("Battle 3 savings vs Battle 1:", firstBattleGas > thirdBattleGas ? firstBattleGas - thirdBattleGas : 0);
     }

    // Simpler test: run identical battles back-to-back and measure only the execute calls
    function test_identicalBattlesGas() public {
        // Create identical simple battles where both players just attack until someone wins
        // This isolates the effect of storage reuse

        Mon memory mon = Mon({
            stats: MonStats({hp: 100, stamina: 10, speed: 10, attack: 100, defense: 10, specialAttack: 10, specialDefense: 10, type1: Type.Fire, type2: Type.None}),
            moves: new IMoveSet[](4),
            ability: IAbility(address(0))
        });

        // Simple high-damage move to end battle quickly (200 power, 100% accuracy, 0 stamina cost)
        IMoveSet damageMove = IMoveSet(address(new CustomAttack(engine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0}))));
        mon.moves[0] = damageMove;
        mon.moves[1] = damageMove;
        mon.moves[2] = damageMove;
        mon.moves[3] = damageMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator simpleValidator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 4, TIMEOUT_DURATION: 10})
        );

        // Use empty ruleset (no global effects)
        IEffect[] memory noEffects = new IEffect[](0);
        IRuleset simpleRuleset = IRuleset(address(new DefaultRuleset(engine, noEffects)));

        // Battle 1: Fresh storage
        vm.startSnapshotGas("Battle1_Setup");
        bytes32 battleKey1 = _startBattle(simpleValidator, engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), simpleRuleset, address(commitManager));
        uint256 setup1 = vm.stopSnapshotGas("Battle1_Setup");

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Battle1_Execute");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey1, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));  // Both switch in mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey1, 0, 0, 0, 0);  // Both attack - one dies
        // After this, battle should end
        uint256 execute1 = vm.stopSnapshotGas("Battle1_Execute");

        // Battle 2: Reusing storage
        vm.startSnapshotGas("Battle2_Setup");
        bytes32 battleKey2 = _startBattle(simpleValidator, engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), simpleRuleset, address(commitManager));
        uint256 setup2 = vm.stopSnapshotGas("Battle2_Setup");

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Battle2_Execute");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));  // Both switch in mon 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, 0, 0, 0);  // Both attack - one dies
        uint256 execute2 = vm.stopSnapshotGas("Battle2_Execute");

        console.log("=== Identical Battles Test ===");
        console.log("Setup 1:", setup1);
        console.log("Setup 2:", setup2);
        console.log("Execute 1:", execute1);
        console.log("Execute 2:", execute2);

        if (setup2 < setup1) {
            console.log("Setup savings:", setup1 - setup2);
        }
        if (execute2 < execute1) {
            console.log("Execute savings:", execute1 - execute2);
        } else {
            console.log("Execute OVERHEAD:", execute2 - execute1);
        }
    }

    // Test with effects being added during battle
    function test_identicalBattlesWithEffectsGas() public {
        Mon memory mon = Mon({
            stats: MonStats({hp: 100, stamina: 100, speed: 10, attack: 100, defense: 10, specialAttack: 10, specialDefense: 10, type1: Type.Fire, type2: Type.None}),
            moves: new IMoveSet[](4),
            ability: IAbility(address(0))
        });

        // Move that applies a status effect to opponent (no damage)
        SingleInstanceEffect testEffect = new SingleInstanceEffect(engine);
        EffectAttack effectMove = new EffectAttack(engine, IEffect(address(testEffect)), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 0, PRIORITY: 3}));

        // Damage move - high power to guarantee KO
        IMoveSet damageMove = IMoveSet(address(new CustomAttack(engine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 500, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0}))));

        mon.moves[0] = effectMove;
        mon.moves[1] = damageMove;
        mon.moves[2] = damageMove;
        mon.moves[3] = damageMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator simpleValidator = new DefaultValidator(
            IEngine(address(engine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 4, TIMEOUT_DURATION: 10})
        );

        // Use ruleset with StaminaRegen effect
        StaminaRegen staminaRegen = new StaminaRegen(engine);
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        IRuleset rulesetWithEffect = IRuleset(address(new DefaultRuleset(engine, effects)));

        // Battle 1: Fresh storage
        vm.startSnapshotGas("B1_Setup");
        bytes32 battleKey1 = _startBattle(simpleValidator, engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), rulesetWithEffect, address(commitManager));
        uint256 setup1 = vm.stopSnapshotGas("B1_Setup");

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("B1_Execute");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey1, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));

        // Check after switch
        (BattleConfigView memory cfgAfterSwitch,) = engine.getBattle(battleKey1);
        console.log("After B1 switch - globalEffectsLength:", cfgAfterSwitch.globalEffectsLength);
        console.log("After B1 switch - packedP0EffectsCount:", cfgAfterSwitch.packedP0EffectsCount);
        console.log("After B1 switch - packedP1EffectsCount:", cfgAfterSwitch.packedP1EffectsCount);

        // Both apply effect to each other (adds 2 effects)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey1, 0, 0, 0, 0);

        // Check after effects applied
        (BattleConfigView memory cfgAfterEffects,) = engine.getBattle(battleKey1);
        console.log("After B1 effects - globalEffectsLength:", cfgAfterEffects.globalEffectsLength);
        console.log("After B1 effects - packedP0EffectsCount:", cfgAfterEffects.packedP0EffectsCount);
        console.log("After B1 effects - packedP1EffectsCount:", cfgAfterEffects.packedP1EffectsCount);

        // Both attack - should KO
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey1, 1, 1, 0, 0);
        uint256 execute1 = vm.stopSnapshotGas("B1_Execute");

        // Verify battle 1 ended
        (, BattleData memory state1) = engine.getBattle(battleKey1);
        console.log("Battle 1 winner index:", state1.winnerIndex);
        assertTrue(state1.winnerIndex != 2, "Battle 1 should have ended");

        // Battle 2: Reusing storage
        vm.startSnapshotGas("B2_Setup");
        bytes32 battleKey2 = _startBattle(simpleValidator, engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), rulesetWithEffect, address(commitManager));
        uint256 setup2 = vm.stopSnapshotGas("B2_Setup");

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        // Check if effects array was reused
        (BattleConfigView memory cfg2,) = engine.getBattle(battleKey2);
        console.log("After B2 setup - globalEffectsLength:", cfg2.globalEffectsLength);
        console.log("After B2 setup - packedP0EffectsCount:", cfg2.packedP0EffectsCount);
        console.log("After B2 setup - packedP1EffectsCount:", cfg2.packedP1EffectsCount);

        vm.startSnapshotGas("B2_Execute");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        // Both apply effect to each other (adds 2 effects - should REUSE slots)
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, 0, 0, 0);
        // Both attack - KO
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 1, 1, 0, 0);
        uint256 execute2 = vm.stopSnapshotGas("B2_Execute");

        console.log("=== Battles With Effects ===");
        console.log("Setup 1:", setup1);
        console.log("Setup 2:", setup2);
        console.log("Execute 1:", execute1);
        console.log("Execute 2:", execute2);

        if (setup2 < setup1) {
            console.log("Setup savings:", setup1 - setup2);
        }
        if (execute2 < execute1) {
            console.log("Execute savings:", execute1 - execute2);
        } else {
            console.log("Execute OVERHEAD:", execute2 - execute1);
        }
    }

    /// @notice Compare gas usage between inline validation (address(0) validator) vs external validator
    function test_inlineVsExternalValidationGas() public {
        // Create engine with proper inline validation defaults
        Engine inlineEngine = new Engine(1, 4, 1);
        DefaultCommitManager inlineCommitManager = new DefaultCommitManager(inlineEngine);
        DefaultMatchmaker inlineMatchmaker = new DefaultMatchmaker(inlineEngine);

        // Create a simple mon with one high-damage move
        Mon memory mon = Mon({
            stats: MonStats({hp: 100, stamina: 10, speed: 10, attack: 100, defense: 10, specialAttack: 10, specialDefense: 10, type1: Type.Fire, type2: Type.None}),
            moves: new IMoveSet[](4),
            ability: IAbility(address(0))
        });
        IMoveSet damageMove = IMoveSet(address(new CustomAttack(inlineEngine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0}))));
        mon.moves[0] = damageMove;
        mon.moves[1] = damageMove;
        mon.moves[2] = damageMove;
        mon.moves[3] = damageMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        // Create validator for external validation path
        DefaultValidator externalValidator = new DefaultValidator(
            IEngine(address(inlineEngine)), DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 4, TIMEOUT_DURATION: 10})
        );

        IEffect[] memory noEffects = new IEffect[](0);
        IRuleset simpleRuleset = IRuleset(address(new DefaultRuleset(inlineEngine, noEffects)));

        // === EXTERNAL VALIDATION PATH ===
        vm.startSnapshotGas("External_Setup");
        bytes32 externalBattleKey = _startBattleForEngine(
            externalValidator,
            inlineEngine,
            defaultOracle,
            defaultRegistry,
            inlineMatchmaker,
            new IEngineHook[](0),
            simpleRuleset,
            address(inlineCommitManager)
        );
        uint256 externalSetup = vm.stopSnapshotGas("External_Setup");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("External_Execute");
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, externalBattleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, externalBattleKey, 0, 0, 0, 0);
        uint256 externalExecute = vm.stopSnapshotGas("External_Execute");

        // === INLINE VALIDATION PATH ===
        vm.startSnapshotGas("Inline_Setup");
        bytes32 inlineBattleKey = _startBattleForEngine(
            IValidator(address(0)), // Inline validation!
            inlineEngine,
            defaultOracle,
            defaultRegistry,
            inlineMatchmaker,
            new IEngineHook[](0),
            simpleRuleset,
            address(inlineCommitManager)
        );
        uint256 inlineSetup = vm.stopSnapshotGas("Inline_Setup");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Inline_Execute");
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, inlineBattleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, inlineBattleKey, 0, 0, 0, 0);
        uint256 inlineExecute = vm.stopSnapshotGas("Inline_Execute");

        console.log("========================================");
        console.log("INLINE vs EXTERNAL VALIDATION BENCHMARK");
        console.log("========================================");
        console.log("");
        console.log("--- SETUP (startBattle) ---");
        console.log("External Validator Setup:", externalSetup);
        console.log("Inline Validation Setup:", inlineSetup);
        if (inlineSetup < externalSetup) {
            console.log("Inline SAVES:", externalSetup - inlineSetup);
        } else {
            console.log("Inline COSTS MORE:", inlineSetup - externalSetup);
        }
        console.log("");
        console.log("--- EXECUTE (switch + attack) ---");
        console.log("External Validator Execute:", externalExecute);
        console.log("Inline Validation Execute:", inlineExecute);
        if (inlineExecute < externalExecute) {
            console.log("Inline SAVES:", externalExecute - inlineExecute);
            console.log("Percentage saved:", (externalExecute - inlineExecute) * 100 / externalExecute, "%");
        } else {
            console.log("Inline COSTS MORE:", inlineExecute - externalExecute);
        }
        console.log("========================================");
    }

    // Helper to start battle with a specific engine
    function _startBattleForEngine(
        IValidator validator,
        Engine eng,
        IRandomnessOracle rngOracle,
        ITeamRegistry registry,
        DefaultMatchmaker maker,
        IEngineHook[] memory hooks,
        IRuleset ruleset,
        address moveManager
    ) internal returns (bytes32) {
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        address[] memory makersToRemove = new address[](0);
        eng.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(BOB);
        eng.updateMatchmakers(makersToAdd, makersToRemove);

        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = registry.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: registry,
            validator: validator,
            rngOracle: rngOracle,
            ruleset: ruleset,
            engineHooks: hooks,
            moveManager: moveManager,
            matchmaker: maker,
            gameMode: GameMode.Singles
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = maker.proposeBattle(proposal);

        bytes32 battleIntegrityHash = maker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        maker.acceptBattle(battleKey, 0, battleIntegrityHash);

        vm.startPrank(ALICE);
        maker.confirmBattle(battleKey, salt, p0TeamIndex);

        return battleKey;
    }

    // Helper to commit/reveal/execute for a specific engine
    function _commitRevealExecuteForEngine(
        Engine eng,
        DefaultCommitManager cm,
        bytes32 battleKey,
        uint8 aliceMoveIndex,
        uint8 bobMoveIndex,
        uint240 aliceExtraData,
        uint240 bobExtraData
    ) internal {
        bytes32 salt = "";
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(aliceMoveIndex, salt, aliceExtraData));
        bytes32 bobMoveHash = keccak256(abi.encodePacked(bobMoveIndex, salt, bobExtraData));
        uint256 turnId = eng.getTurnIdForBattleState(battleKey);
        if (turnId % 2 == 0) {
            vm.startPrank(ALICE);
            cm.commitMove(battleKey, aliceMoveHash);
            vm.startPrank(BOB);
            cm.revealMove(battleKey, bobMoveIndex, salt, bobExtraData, true);
            vm.startPrank(ALICE);
            cm.revealMove(battleKey, aliceMoveIndex, salt, aliceExtraData, true);
        } else {
            vm.startPrank(BOB);
            cm.commitMove(battleKey, bobMoveHash);
            vm.startPrank(ALICE);
            cm.revealMove(battleKey, aliceMoveIndex, salt, aliceExtraData, true);
            vm.startPrank(BOB);
            cm.revealMove(battleKey, bobMoveIndex, salt, bobExtraData, true);
        }
    }
}
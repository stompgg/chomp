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
import {IValidator} from "../src/IValidator.sol";
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

/// @title Inline Engine Gas Test
/// @notice Same as EngineGasTest but uses inline validation (address(0) validator) for comparison
contract InlineEngineGasTest is Test, BattleHelper {

    DefaultCommitManager commitManager;
    Engine engine;
    ITypeCalculator typeCalc;
    DefaultRandomnessOracle defaultOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;

    // Inline validation constants
    uint256 constant MONS_PER_TEAM = 4;
    uint256 constant MOVES_PER_MON = 4;

    function _packStatBoost(uint256 playerIndex, uint256 monIndex, uint256 statIndex, int32 boostAmount) internal pure returns (uint240) {
        return uint240(playerIndex | (monIndex << 60) | (statIndex << 120) | (uint256(uint32(boostAmount)) << 180));
    }

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        // Create engine with inline validation defaults
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        commitManager = new DefaultCommitManager(engine);
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
    }

    /// @notice Helper to start battle with inline validation (address(0) validator)
    function _startBattleInline(
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
            validator: IValidator(address(0)), // INLINE VALIDATION
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

        StaminaRegen staminaRegen = new StaminaRegen(engine);
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);

        vm.startSnapshotGas("Setup 1");
        bytes32 battleKey = _startBattleInline(engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));
        uint256 setup1Gas = vm.stopSnapshotGas("Setup 1");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("FirstBattle");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 1, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, 2, uint240(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 firstBattleGas = vm.stopSnapshotGas("FirstBattle");

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

        vm.startSnapshotGas("Setup 2");
        bytes32 battleKey2 = _startBattleInline(engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));
        uint256 setup2Gas = vm.stopSnapshotGas("Setup 2");

        vm.warp(vm.getBlockTimestamp() + 1);

        (BattleConfigView memory cfgAfterSetup2,) = engine.getBattle(battleKey2);
        console.log("After setup 2 - globalEffectsLength:", cfgAfterSetup2.globalEffectsLength);
        console.log("After setup 2 - packedP0EffectsCount:", cfgAfterSetup2.packedP0EffectsCount);
        console.log("After setup 2 - packedP1EffectsCount:", cfgAfterSetup2.packedP1EffectsCount);

        vm.startSnapshotGas("SecondBattle");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, 1, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, 2, uint240(1), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, NO_OP_MOVE_INDEX, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, NO_OP_MOVE_INDEX, 3, 0, _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, NO_OP_MOVE_INDEX, 0, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, 3, _packStatBoost(0, 2, uint256(MonStateIndexName.Attack), int32(90)), _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        uint256 secondBattleGas = vm.stopSnapshotGas("SecondBattle");

        // Battle 3: Repeat exact sequence of Battle 1
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
        bytes32 battleKey3 = _startBattleInline(engine, defaultOracle, defaultRegistry, matchmaker, new IEngineHook[](0), IRuleset(address(ruleset)), address(commitManager));
        uint256 setup3Gas = vm.stopSnapshotGas("Setup 3");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("ThirdBattle");
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 0, 1, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, SWITCH_MOVE_INDEX, 2, uint240(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(0), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 3, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 thirdBattleGas = vm.stopSnapshotGas("ThirdBattle");

        console.log("=== INLINE VALIDATION Gas Results ===");
        console.log("Setup 1 Gas:", setup1Gas);
        console.log("Setup 2 Gas:", setup2Gas);
        console.log("Setup 3 Gas:", setup3Gas);
        console.log("Battle 1 Gas:", firstBattleGas);
        console.log("Battle 2 Gas:", secondBattleGas);
        console.log("Battle 3 Gas:", thirdBattleGas);

        assertLt(setup2Gas, setup1Gas, "Setup 2 should be cheaper (storage reuse)");
        assertLt(setup3Gas, setup1Gas, "Setup 3 should be cheaper (storage reuse)");

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
        console.log("Battle 3 savings vs Battle 1:", firstBattleGas > thirdBattleGas ? firstBattleGas - thirdBattleGas : 0);
    }

    function test_identicalBattlesGas() public {
        // Note: We need to recreate engine with correct team size for inline validation
        // Important: Create engine BEFORE moves so moves reference the correct engine
        Engine inlineEngine = new Engine(1, 4, 1);

        Mon memory mon = Mon({
            stats: MonStats({hp: 100, stamina: 10, speed: 10, attack: 100, defense: 10, specialAttack: 10, specialDefense: 10, type1: Type.Fire, type2: Type.None}),
            moves: new IMoveSet[](4),
            ability: IAbility(address(0))
        });

        // Use inlineEngine for moves so they reference the correct engine
        IMoveSet damageMove = IMoveSet(address(new CustomAttack(inlineEngine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0}))));
        mon.moves[0] = damageMove;
        mon.moves[1] = damageMove;
        mon.moves[2] = damageMove;
        mon.moves[3] = damageMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        DefaultCommitManager inlineCommitManager = new DefaultCommitManager(inlineEngine);
        DefaultMatchmaker inlineMatchmaker = new DefaultMatchmaker(inlineEngine);

        IEffect[] memory noEffects = new IEffect[](0);
        IRuleset simpleRuleset = IRuleset(address(new DefaultRuleset(inlineEngine, noEffects)));

        // Battle 1: Fresh storage
        vm.startSnapshotGas("Battle1_Setup");
        bytes32 battleKey1 = _startBattleInlineCustomEngine(inlineEngine, defaultOracle, defaultRegistry, inlineMatchmaker, new IEngineHook[](0), simpleRuleset, address(inlineCommitManager));
        uint256 setup1 = vm.stopSnapshotGas("Battle1_Setup");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Battle1_Execute");
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey1, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey1, 0, 0, 0, 0);
        uint256 execute1 = vm.stopSnapshotGas("Battle1_Execute");

        // Battle 2: Reusing storage
        vm.startSnapshotGas("Battle2_Setup");
        bytes32 battleKey2 = _startBattleInlineCustomEngine(inlineEngine, defaultOracle, defaultRegistry, inlineMatchmaker, new IEngineHook[](0), simpleRuleset, address(inlineCommitManager));
        uint256 setup2 = vm.stopSnapshotGas("Battle2_Setup");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Battle2_Execute");
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey2, 0, 0, 0, 0);
        uint256 execute2 = vm.stopSnapshotGas("Battle2_Execute");

        console.log("=== INLINE Identical Battles Test ===");
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

    function test_identicalBattlesWithEffectsGas() public {
        Mon memory mon = Mon({
            stats: MonStats({hp: 100, stamina: 100, speed: 10, attack: 100, defense: 10, specialAttack: 10, specialDefense: 10, type1: Type.Fire, type2: Type.None}),
            moves: new IMoveSet[](4),
            ability: IAbility(address(0))
        });

        // Recreate engine with correct team size
        Engine inlineEngine = new Engine(1, 4, 1);
        DefaultCommitManager inlineCommitManager = new DefaultCommitManager(inlineEngine);
        DefaultMatchmaker inlineMatchmaker = new DefaultMatchmaker(inlineEngine);

        StatBoosts statBoosts = new StatBoosts(inlineEngine);
        IMoveSet effectMove = new EffectAttack(
            inlineEngine,
            new SingleInstanceEffect(inlineEngine),
            EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet damageMove = IMoveSet(address(new CustomAttack(inlineEngine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0}))));
        mon.moves[0] = effectMove;
        mon.moves[1] = damageMove;
        mon.moves[2] = damageMove;
        mon.moves[3] = damageMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        StaminaRegen staminaRegen = new StaminaRegen(inlineEngine);
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        IRuleset rulesetWithEffect = IRuleset(address(new DefaultRuleset(inlineEngine, effects)));

        // Battle 1: Fresh storage
        vm.startSnapshotGas("B1_Setup");
        bytes32 battleKey1 = _startBattleInlineCustomEngine(inlineEngine, defaultOracle, defaultRegistry, inlineMatchmaker, new IEngineHook[](0), rulesetWithEffect, address(inlineCommitManager));
        uint256 setup1 = vm.stopSnapshotGas("B1_Setup");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("B1_Execute");
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey1, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));

        (BattleConfigView memory cfgAfterSwitch,) = inlineEngine.getBattle(battleKey1);
        console.log("After B1 switch - globalEffectsLength:", cfgAfterSwitch.globalEffectsLength);
        console.log("After B1 switch - packedP0EffectsCount:", cfgAfterSwitch.packedP0EffectsCount);
        console.log("After B1 switch - packedP1EffectsCount:", cfgAfterSwitch.packedP1EffectsCount);

        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey1, 0, 0, 0, 0);

        (BattleConfigView memory cfgAfterEffects,) = inlineEngine.getBattle(battleKey1);
        console.log("After B1 effects - globalEffectsLength:", cfgAfterEffects.globalEffectsLength);
        console.log("After B1 effects - packedP0EffectsCount:", cfgAfterEffects.packedP0EffectsCount);
        console.log("After B1 effects - packedP1EffectsCount:", cfgAfterEffects.packedP1EffectsCount);

        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey1, 1, 1, 0, 0);
        uint256 execute1 = vm.stopSnapshotGas("B1_Execute");

        (, BattleData memory data1) = inlineEngine.getBattle(battleKey1);
        console.log("Battle 1 winner index:", data1.winnerIndex);

        // Battle 2: Reusing storage
        vm.startSnapshotGas("B2_Setup");
        bytes32 battleKey2 = _startBattleInlineCustomEngine(inlineEngine, defaultOracle, defaultRegistry, inlineMatchmaker, new IEngineHook[](0), rulesetWithEffect, address(inlineCommitManager));
        uint256 setup2 = vm.stopSnapshotGas("B2_Setup");

        vm.warp(vm.getBlockTimestamp() + 1);

        (BattleConfigView memory cfg2,) = inlineEngine.getBattle(battleKey2);
        console.log("After B2 setup - globalEffectsLength:", cfg2.globalEffectsLength);
        console.log("After B2 setup - packedP0EffectsCount:", cfg2.packedP0EffectsCount);
        console.log("After B2 setup - packedP1EffectsCount:", cfg2.packedP1EffectsCount);

        vm.startSnapshotGas("B2_Execute");
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey2, 0, 0, 0, 0);
        _commitRevealExecuteForEngine(inlineEngine, inlineCommitManager, battleKey2, 1, 1, 0, 0);
        uint256 execute2 = vm.stopSnapshotGas("B2_Execute");

        console.log("=== INLINE Battles With Effects ===");
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

    // Helper to start battle with inline validation for a custom engine
    function _startBattleInlineCustomEngine(
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
            validator: IValidator(address(0)), // INLINE VALIDATION
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

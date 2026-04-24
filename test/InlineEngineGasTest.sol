// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultRuleset} from "../src/DefaultRuleset.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {SignedCommitLib} from "../src/commit-manager/SignedCommitLib.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IValidator} from "../src/IValidator.sol";
import {EIP712} from "../src/lib/EIP712.sol";

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

import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
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
            matchmaker: maker
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

        mon.moves = new uint256[](4);
        StatBoosts statBoosts = new StatBoosts();
        IMoveSet burnMove = new EffectAttack(new BurnStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet frostbiteMove = new EffectAttack(new FrostbiteStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet statBoostMove = new StatBoostsMove(statBoosts);
        IMoveSet damageMove = new CustomAttack(ITypeCalculator(address(typeCalc)), CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 1}));
        mon.moves[0] = uint256(uint160(address(burnMove)));
        mon.moves[1] = uint256(uint160(address(frostbiteMove)));
        mon.moves[2] = uint256(uint160(address(statBoostMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));

        Mon[] memory team = new Mon[](4);
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        StaminaRegen staminaRegen = new StaminaRegen();
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
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 firstBattleGas = vm.stopSnapshotGas("FirstBattle");

        // Rearrange order of moves for battle 2
        mon.moves[1] = uint256(uint160(address(burnMove)));
        mon.moves[2] = uint256(uint160(address(frostbiteMove)));
        mon.moves[3] = uint256(uint160(address(statBoostMove)));
        mon.moves[0] = uint256(uint160(address(damageMove)));
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
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, 2, uint240(1), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, NO_OP_MOVE_INDEX, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, NO_OP_MOVE_INDEX, 3, 0, _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, NO_OP_MOVE_INDEX, 0, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 3, 3, _packStatBoost(0, 2, uint256(MonStateIndexName.Attack), int32(90)), _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey2, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        uint256 secondBattleGas = vm.stopSnapshotGas("SecondBattle");

        // Battle 3: Repeat exact sequence of Battle 1
        mon.moves[0] = uint256(uint160(address(burnMove)));
        mon.moves[1] = uint256(uint160(address(frostbiteMove)));
        mon.moves[2] = uint256(uint160(address(statBoostMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));
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
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, 3, NO_OP_MOVE_INDEX, 0, 0);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(1), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(2), true);
        engine.resetCallContext();
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey3, SWITCH_MOVE_INDEX, 0, uint240(3), true);
        engine.resetCallContext();
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
            moves: new uint256[](4),
            ability: 0
        });

        // Use inlineEngine for moves so they reference the correct engine
        IMoveSet damageMove = IMoveSet(address(new CustomAttack(typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0}))));
        mon.moves[0] = uint256(uint160(address(damageMove)));
        mon.moves[1] = uint256(uint160(address(damageMove)));
        mon.moves[2] = uint256(uint160(address(damageMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));

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
            moves: new uint256[](4),
            ability: 0
        });

        // Recreate engine with correct team size
        Engine inlineEngine = new Engine(1, 4, 1);
        DefaultCommitManager inlineCommitManager = new DefaultCommitManager(inlineEngine);
        DefaultMatchmaker inlineMatchmaker = new DefaultMatchmaker(inlineEngine);

        StatBoosts statBoosts = new StatBoosts();
        IMoveSet effectMove = new EffectAttack(
            new SingleInstanceEffect(),
            EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet damageMove = IMoveSet(address(new CustomAttack(typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 200, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0}))));
        mon.moves[0] = uint256(uint160(address(effectMove)));
        mon.moves[1] = uint256(uint160(address(damageMove)));
        mon.moves[2] = uint256(uint160(address(damageMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        StaminaRegen staminaRegen = new StaminaRegen();
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
            matchmaker: maker
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
            engine.resetCallContext();
            vm.startPrank(ALICE);
            cm.revealMove(battleKey, aliceMoveIndex, salt, aliceExtraData, true);
            engine.resetCallContext();
        } else {
            vm.startPrank(BOB);
            cm.commitMove(battleKey, bobMoveHash);
            vm.startPrank(ALICE);
            cm.revealMove(battleKey, aliceMoveIndex, salt, aliceExtraData, true);
            engine.resetCallContext();
            vm.startPrank(BOB);
            cm.revealMove(battleKey, bobMoveIndex, salt, bobExtraData, true);
            engine.resetCallContext();
        }
        vm.stopPrank();
        eng.resetCallContext();
    }
}

/// @title Fully Optimized Inline Gas Test
/// @notice Mirrors the battle sequences from InlineEngineGasTest but stacks every
///         available optimization: inline validation (address(0) validator),
///         inline RNG (address(0) oracle), inline stamina regen,
///         SignedMatchmaker (no propose/accept/confirm storage), and
///         SignedCommitManager::executeWithDualSignedMoves (1 TX per two-player turn).
/// @dev Forced single-player switches after KOs use SignedCommitManager::executeSinglePlayerMove.
contract FullyOptimizedInlineGasTest is Test, BattleHelper, EIP712 {

    uint256 constant MONS_PER_TEAM = 4;
    uint256 constant MOVES_PER_MON = 4;

    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    SignedCommitManager signedCommitManager;
    SignedMatchmaker signedMatchmaker;
    ITypeCalculator typeCalc;
    TestTeamRegistry defaultRegistry;

    // Storage used by _analyzeSteps to track warm/cold SLOAD/SSTORE access
    // across one pass. Cleared between passes.
    mapping(bytes32 => bool) private _seenSlot;
    bytes32[] private _seenKeys;

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("SignedCommitManager", "1");
    }

    function _packStatBoost(uint256 playerIndex, uint256 monIndex, uint256 statIndex, int32 boostAmount) internal pure returns (uint240) {
        return uint240(playerIndex | (monIndex << 60) | (statIndex << 120) | (uint256(uint32(boostAmount)) << 180));
    }

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        signedCommitManager = new SignedCommitManager(IEngine(address(engine)));
        signedMatchmaker = new SignedMatchmaker(engine);
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
    }

    /// @dev Starts a battle via SignedMatchmaker::startGame (1 TX instead of 3).
    ///      Also authorizes the matchmaker each call to mirror _startBattleInline.
    function _startBattleFullyOptimized(IRuleset ruleset) internal returns (bytes32) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(signedMatchmaker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        (bytes32 battleKey, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: p1,
                p1TeamIndex: 0,
                teamRegistry: defaultRegistry,
                validator: IValidator(address(0)),
                rngOracle: IRandomnessOracle(address(0)),
                ruleset: ruleset,
                moveManager: address(signedCommitManager),
                matchmaker: signedMatchmaker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce
        });

        bytes32 structHash = BattleOfferLib.hashBattleOffer(offer);
        bytes32 digest = signedMatchmaker.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(p1);
        signedMatchmaker.startGame(offer, signature);

        return battleKey;
    }

    function _signDualReveal(
        uint256 privateKey,
        bytes32 battleKey,
        uint64 turnId,
        bytes32 committerMoveHash,
        uint8 revealerMoveIndex,
        bytes32 revealerSalt,
        uint240 revealerExtraData
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256("SignedCommitManager"),
                keccak256("1"),
                block.chainid,
                address(signedCommitManager)
            )
        );
        bytes32 structHash = SignedCommitLib.hashDualSignedReveal(
            SignedCommitLib.DualSignedReveal({
                battleKey: battleKey,
                turnId: turnId,
                committerMoveHash: committerMoveHash,
                revealerMoveIndex: revealerMoveIndex,
                revealerSalt: revealerSalt,
                revealerExtraData: revealerExtraData
            })
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev Executes a two-player turn in 1 TX via executeWithDualSignedMoves.
    ///      p0Move/p1Move semantics match _commitRevealExecuteForAliceAndBob so the
    ///      battle scripts can be transcribed directly from the non-optimized test.
    function _fastTurn(
        bytes32 battleKey,
        uint8 p0MoveIndex,
        uint8 p1MoveIndex,
        uint240 p0ExtraData,
        uint240 p1ExtraData
    ) internal {
        uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
        bytes32 committerSalt = keccak256(abi.encode("committer", battleKey, turnId));
        bytes32 revealerSalt = keccak256(abi.encode("revealer", battleKey, turnId));

        uint8 committerMoveIndex;
        uint240 committerExtraData;
        uint8 revealerMoveIndex;
        uint240 revealerExtraData;
        uint256 revealerPk;
        address committer;

        if (turnId % 2 == 0) {
            committerMoveIndex = p0MoveIndex;
            committerExtraData = p0ExtraData;
            revealerMoveIndex = p1MoveIndex;
            revealerExtraData = p1ExtraData;
            revealerPk = P1_PK;
            committer = p0;
        } else {
            committerMoveIndex = p1MoveIndex;
            committerExtraData = p1ExtraData;
            revealerMoveIndex = p0MoveIndex;
            revealerExtraData = p0ExtraData;
            revealerPk = P0_PK;
            committer = p1;
        }

        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));
        bytes memory revealerSig = _signDualReveal(
            revealerPk, battleKey, turnId, committerMoveHash,
            revealerMoveIndex, revealerSalt, revealerExtraData
        );

        vm.prank(committer);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            committerMoveIndex, committerSalt, committerExtraData,
            revealerMoveIndex, revealerSalt, revealerExtraData,
            revealerSig
        );
        engine.resetCallContext();
    }

    /// @dev Single-player forced switch after a KO. This uses the optimized
    ///      SignedCommitManager path because there is no hidden opponent move to reveal.
    function _fastSwitchReveal(bytes32 battleKey, bool isP0, uint240 extraData) internal {
        vm.prank(isP0 ? p0 : p1);
        signedCommitManager.executeSinglePlayerMove(battleKey, SWITCH_MOVE_INDEX, bytes32(0), extraData);
        engine.resetCallContext();
    }

    /// @notice Compares the inherited single-player reveal flow against the dedicated
    ///         SignedCommitManager single-player fast path.
    function test_signedCommitManagerOnePlayerActionGasComparison() public {
        Mon memory mon = _createMon();
        mon.stats.stamina = 5;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;
        mon.moves = new uint256[](4);

        IMoveSet damageMove = new CustomAttack(
            ITypeCalculator(address(typeCalc)),
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 1})
        );
        for (uint256 i; i < mon.moves.length; i++) {
            mon.moves[i] = uint256(uint160(address(damageMove)));
        }

        Mon[] memory team = new Mon[](4);
        for (uint256 i; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);

        bytes32 oldFlowBattleKey = _startBattleFullyOptimized(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);
        _fastTurn(oldFlowBattleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _fastTurn(oldFlowBattleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(oldFlowBattleKey), 1);

        vm.prank(p1);
        uint256 gasBefore = gasleft();
        signedCommitManager.revealMove(oldFlowBattleKey, SWITCH_MOVE_INDEX, bytes32(0), uint240(1), true);
        uint256 oldFlowGas = gasBefore - gasleft();
        engine.resetCallContext();

        _fastTurn(oldFlowBattleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(oldFlowBattleKey), 1);

        vm.prank(p1);
        gasBefore = gasleft();
        signedCommitManager.revealMove(oldFlowBattleKey, SWITCH_MOVE_INDEX, bytes32(0), uint240(2), true);
        uint256 oldFlowSecondGas = gasBefore - gasleft();
        engine.resetCallContext();

        bytes32 fastPathBattleKey = _startBattleFullyOptimized(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);
        _fastTurn(fastPathBattleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _fastTurn(fastPathBattleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(fastPathBattleKey), 1);

        vm.prank(p1);
        gasBefore = gasleft();
        signedCommitManager.executeSinglePlayerMove(fastPathBattleKey, SWITCH_MOVE_INDEX, bytes32(0), uint240(1));
        uint256 fastPathGas = gasBefore - gasleft();
        engine.resetCallContext();

        _fastTurn(fastPathBattleKey, 0, NO_OP_MOVE_INDEX, uint240(0), uint240(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(fastPathBattleKey), 1);

        vm.prank(p1);
        gasBefore = gasleft();
        signedCommitManager.executeSinglePlayerMove(fastPathBattleKey, SWITCH_MOVE_INDEX, bytes32(0), uint240(2));
        uint256 fastPathSecondGas = gasBefore - gasleft();
        engine.resetCallContext();

        console.log("Old SignedCommitManager first revealMove gas:", oldFlowGas);
        console.log("New first executeSinglePlayerMove gas:", fastPathGas);
        console.log("First forced-switch savings:", oldFlowGas - fastPathGas);
        console.log("Old SignedCommitManager second revealMove gas:", oldFlowSecondGas);
        console.log("New second executeSinglePlayerMove gas:", fastPathSecondGas);
        console.log("Second forced-switch savings:", oldFlowSecondGas - fastPathSecondGas);

        assertLt(fastPathGas, oldFlowGas);
        assertLt(fastPathSecondGas, oldFlowSecondGas);
    }

    /// @notice Mirrors InlineEngineGasTest::test_consecutiveBattleGas move-for-move,
    ///         but every TX goes through the dual-signed fast path.
    function test_consecutiveBattleGas() public {
        Mon memory mon = _createMon();
        mon.stats.stamina = 5;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;

        mon.moves = new uint256[](4);
        StatBoosts statBoosts = new StatBoosts();
        IMoveSet burnMove = new EffectAttack(new BurnStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet frostbiteMove = new EffectAttack(new FrostbiteStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet statBoostMove = new StatBoostsMove(statBoosts);
        IMoveSet damageMove = new CustomAttack(ITypeCalculator(address(typeCalc)), CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 1}));
        mon.moves[0] = uint256(uint160(address(burnMove)));
        mon.moves[1] = uint256(uint160(address(frostbiteMove)));
        mon.moves[2] = uint256(uint160(address(statBoostMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));

        Mon[] memory team = new Mon[](4);
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        // Use the INLINE_STAMINA_REGEN_RULESET sentinel so the engine takes its internal stamina-regen
        // fast path (no external StaminaRegen contract, no onAfterMove/onRoundEnd callbacks). This is
        // the intended production configuration for the fully-optimized stack.
        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);

        vm.startSnapshotGas("Fast_Setup_1");
        bytes32 battleKey = _startBattleFullyOptimized(ruleset);
        uint256 setup1Gas = vm.stopSnapshotGas("Fast_Setup_1");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Fast_Battle1");
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _fastTurn(battleKey, 0, 1, 0, 0);
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, 2, uint240(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastSwitchReveal(battleKey, true, uint240(0));
        _fastTurn(battleKey, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey, false, uint240(1));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey, true, uint240(2));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey, true, uint240(3));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 firstBattleGas = vm.stopSnapshotGas("Fast_Battle1");

        // Rearrange moves for battle 2 (same as InlineEngineGasTest)
        mon.moves[1] = uint256(uint160(address(burnMove)));
        mon.moves[2] = uint256(uint160(address(frostbiteMove)));
        mon.moves[3] = uint256(uint160(address(statBoostMove)));
        mon.moves[0] = uint256(uint160(address(damageMove)));
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        vm.startSnapshotGas("Fast_Setup_2");
        bytes32 battleKey2 = _startBattleFullyOptimized(IRuleset(address(ruleset)));
        uint256 setup2Gas = vm.stopSnapshotGas("Fast_Setup_2");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Fast_Battle2");
        _fastTurn(battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _fastTurn(battleKey2, 3, 1, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey2, false, uint240(1));
        _fastTurn(battleKey2, SWITCH_MOVE_INDEX, 2, uint240(1), 0);
        _fastTurn(battleKey2, 3, NO_OP_MOVE_INDEX, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey2, false, uint240(2));
        _fastTurn(battleKey2, NO_OP_MOVE_INDEX, 3, 0, _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey2, NO_OP_MOVE_INDEX, 0, 0, 0);
        _fastSwitchReveal(battleKey2, true, uint240(2));
        _fastTurn(battleKey2, 3, 3, _packStatBoost(0, 2, uint256(MonStateIndexName.Attack), int32(90)), _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey2, false, uint240(3));
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        uint256 secondBattleGas = vm.stopSnapshotGas("Fast_Battle2");

        // Battle 3: Repeat exact sequence of Battle 1
        mon.moves[0] = uint256(uint160(address(burnMove)));
        mon.moves[1] = uint256(uint160(address(frostbiteMove)));
        mon.moves[2] = uint256(uint160(address(statBoostMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        vm.startSnapshotGas("Fast_Setup_3");
        bytes32 battleKey3 = _startBattleFullyOptimized(IRuleset(address(ruleset)));
        uint256 setup3Gas = vm.stopSnapshotGas("Fast_Setup_3");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Fast_Battle3");
        _fastTurn(battleKey3, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
        _fastTurn(battleKey3, 0, 1, 0, 0);
        _fastTurn(battleKey3, SWITCH_MOVE_INDEX, 2, uint240(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey3, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastSwitchReveal(battleKey3, true, uint240(0));
        _fastTurn(battleKey3, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey3, 3, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey3, false, uint240(1));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey3, true, uint240(2));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey3, true, uint240(3));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 thirdBattleGas = vm.stopSnapshotGas("Fast_Battle3");

        console.log("=== FULLY OPTIMIZED Gas Results ===");
        console.log("Setup 1 Gas:", setup1Gas);
        console.log("Setup 2 Gas:", setup2Gas);
        console.log("Setup 3 Gas:", setup3Gas);
        console.log("Battle 1 Gas:", firstBattleGas);
        console.log("Battle 2 Gas:", secondBattleGas);
        console.log("Battle 3 Gas:", thirdBattleGas);

        assertLt(setup2Gas, setup1Gas, "Setup 2 should be cheaper (storage reuse)");
        assertLt(setup3Gas, setup1Gas, "Setup 3 should be cheaper (storage reuse)");
    }
}

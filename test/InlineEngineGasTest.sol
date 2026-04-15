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

/// @title Fully Optimized Inline Gas Test
/// @notice Mirrors the battle sequences from InlineEngineGasTest but stacks every
///         available optimization: inline validation (address(0) validator),
///         SignedMatchmaker (no propose/accept/confirm storage), and
///         SignedCommitManager::executeWithDualSignedMoves (1 TX per two-player turn).
/// @dev Forced single-player switches after KOs still use the inherited revealMove
///      since those turns don't need commit-reveal.
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
    DefaultRandomnessOracle defaultOracle;
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

        defaultOracle = new DefaultRandomnessOracle();
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
                rngOracle: defaultOracle,
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
    }

    /// @dev Single-player forced switch after a KO. Falls back to the inherited
    ///      revealMove path since there is no commit-reveal for one-sided turns.
    function _fastSwitchReveal(bytes32 battleKey, bool isP0, uint240 extraData) internal {
        vm.prank(isP0 ? p0 : p1);
        signedCommitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, 0, extraData, true);
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

        StaminaRegen staminaRegen = new StaminaRegen();
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);

        vm.startSnapshotGas("Fast_Setup_1");
        bytes32 battleKey = _startBattleFullyOptimized(IRuleset(address(ruleset)));
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

    // =====================================================================
    // Opcode-level breakdown
    // =====================================================================

    struct OpcodeTally {
        uint256 totalSteps;
        uint256 sloadCount;
        uint256 sloadCold;
        uint256 sloadWarm;
        uint256 sstoreCount;
        uint256 sstoreCold;
        uint256 sstoreWarm;
        uint256 tloadCount;
        uint256 tstoreCount;
        uint256 logCount;
        uint256 logTopicCount;
        uint256 logDataBytes;
        uint256 callCount;
        uint256 staticcallCount;
        uint256 delegatecallCount;
        uint256 memoryOpCount;
        uint256 keccakCount;
        uint256 otherCount;
    }

    /// @notice Records an attack turn at opcode granularity and dumps a
    ///         category breakdown to docs/gas-analysis/.
    /// @dev Uses vm.startDebugTraceRecording() to capture every opcode executed
    ///      during the turn, then applies EIP-2929 warm/cold rules via a
    ///      Solidity-side access set to compute gas per category.
    function test_opcodeBreakdown_attackTurn() public {
        // Simple setup: 4 mons per team, all with the same high-HP, low-power
        // damage move. No ruleset, no ability, no side effects — keeps the
        // recorded opcode stream focused on the core battle path.
        Mon memory mon = _createMon();
        mon.stats.hp = 10_000;
        mon.stats.stamina = 10;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;

        mon.moves = new uint256[](4);
        IMoveSet damageMove = new CustomAttack(
            ITypeCalculator(address(typeCalc)),
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0})
        );
        for (uint256 i = 0; i < 4; i++) {
            mon.moves[i] = uint256(uint160(address(damageMove)));
        }

        Mon[] memory team = new Mon[](4);
        for (uint256 i = 0; i < 4; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        bytes32 battleKey = _startBattleFullyOptimized(IRuleset(address(0)));
        vm.warp(vm.getBlockTimestamp() + 1);

        // Turn 0: both switch in (not recorded)
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));

        // Measure the turn's real gas via a snapshot+revert cycle so the
        // debug-tracer overhead (returning a big DebugStep[] array) doesn't
        // pollute the number we report. First pass: no tracer, just measure.
        uint256 snapshot = vm.snapshotState();
        uint256 gasBefore = gasleft();
        _fastTurn(battleKey, 0, 0, 0, 0);
        uint256 turnGas = gasBefore - gasleft();
        vm.revertToState(snapshot);

        // Second pass: same turn, this time with the opcode tracer enabled.
        vm.startDebugTraceRecording();
        _fastTurn(battleKey, 0, 0, 0, 0);
        Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();

        _analyzeAndDumpSteps(steps, turnGas, "docs/gas-analysis/opcode_attack_turn.json");
    }

    /// @notice Records `_startBattleFullyOptimized` (cold setup) at opcode
    ///         granularity. The dominant bucket should be SSTORE-residual
    ///         from the fresh team / config / battleData writes.
    function test_opcodeBreakdown_setup() public {
        Mon memory mon = _createMon();
        mon.stats.hp = 10_000;
        mon.stats.stamina = 10;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;

        mon.moves = new uint256[](4);
        IMoveSet damageMove = new CustomAttack(
            ITypeCalculator(address(typeCalc)),
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 0})
        );
        for (uint256 i = 0; i < 4; i++) {
            mon.moves[i] = uint256(uint160(address(damageMove)));
        }

        Mon[] memory team = new Mon[](4);
        for (uint256 i = 0; i < 4; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        uint256 snapshot = vm.snapshotState();
        uint256 gasBefore = gasleft();
        _startBattleFullyOptimized(IRuleset(address(0)));
        uint256 setupGas = gasBefore - gasleft();
        vm.revertToState(snapshot);

        vm.startDebugTraceRecording();
        _startBattleFullyOptimized(IRuleset(address(0)));
        Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();

        _analyzeAndDumpSteps(steps, setupGas, "docs/gas-analysis/opcode_setup_cold.json");
    }

    /// @notice Records a turn where a status effect gets applied (EffectAttack
    ///         → BurnStatus) and StaminaRegen is already ticking. This has a
    ///         very different opcode shape from a pure damage turn.
    function test_opcodeBreakdown_effectTurn() public {
        Mon memory mon = _createMon();
        mon.stats.hp = 10_000;
        mon.stats.stamina = 10;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;

        StatBoosts statBoosts = new StatBoosts();
        IMoveSet burnMove = new EffectAttack(
            new BurnStatus(statBoosts),
            EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );

        mon.moves = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            mon.moves[i] = uint256(uint160(address(burnMove)));
        }

        Mon[] memory team = new Mon[](4);
        for (uint256 i = 0; i < 4; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        StaminaRegen staminaRegen = new StaminaRegen();
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = staminaRegen;
        DefaultRuleset ruleset = new DefaultRuleset(IEngine(address(engine)), effects);

        bytes32 battleKey = _startBattleFullyOptimized(IRuleset(address(ruleset)));
        vm.warp(vm.getBlockTimestamp() + 1);

        // Turn 0: switch in
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));

        uint256 snapshot = vm.snapshotState();
        uint256 gasBefore = gasleft();
        _fastTurn(battleKey, 0, 0, 0, 0);
        uint256 turnGas = gasBefore - gasleft();
        vm.revertToState(snapshot);

        vm.startDebugTraceRecording();
        _fastTurn(battleKey, 0, 0, 0, 0);
        Vm.DebugStep[] memory steps = vm.stopAndReturnDebugTraceRecording();

        _analyzeAndDumpSteps(steps, turnGas, "docs/gas-analysis/opcode_effect_turn.json");
    }

    function _analyzeAndDumpSteps(
        Vm.DebugStep[] memory steps,
        uint256 totalGas,
        string memory outPath
    ) internal {
        OpcodeTally memory t;
        t.totalSteps = steps.length;

        for (uint256 i = 0; i < steps.length; i++) {
            Vm.DebugStep memory step = steps[i];
            uint8 op = step.opcode;

            if (op == 0x54) {
                // SLOAD — stack[0] is the slot
                t.sloadCount++;
                uint256 slot = step.stack[0];
                bytes32 key = keccak256(abi.encode(step.contractAddr, slot));
                if (_seenSlot[key]) {
                    t.sloadWarm++;
                } else {
                    t.sloadCold++;
                    _seenSlot[key] = true;
                    _seenKeys.push(key);
                }
            } else if (op == 0x55) {
                // SSTORE — stack[0] is the slot
                t.sstoreCount++;
                uint256 slot = step.stack[0];
                bytes32 key = keccak256(abi.encode(step.contractAddr, slot));
                if (_seenSlot[key]) {
                    t.sstoreWarm++;
                } else {
                    t.sstoreCold++;
                    _seenSlot[key] = true;
                    _seenKeys.push(key);
                }
            } else if (op == 0x5C) {
                t.tloadCount++;
            } else if (op == 0x5D) {
                t.tstoreCount++;
            } else if (op >= 0xA0 && op <= 0xA4) {
                // LOG0..LOG4 — stack[0]=offset, stack[1]=size, topics follow
                t.logCount++;
                t.logTopicCount += (op - 0xA0);
                t.logDataBytes += step.stack[1];
            } else if (op == 0xF1) {
                t.callCount++;
            } else if (op == 0xFA) {
                t.staticcallCount++;
            } else if (op == 0xF4) {
                t.delegatecallCount++;
            } else if (op == 0x51 || op == 0x52 || op == 0x53) {
                t.memoryOpCount++;
            } else if (op == 0x20) {
                t.keccakCount++;
            } else {
                t.otherCount++;
            }
        }

        // Per-category gas, computed two different ways depending on how much
        // we actually know.
        //
        // "Accurately tracked" (fixed base cost + fields pulled from the
        // stack): SLOAD (warm/cold known), TLOAD/TSTORE, LOG (topics + data
        // size), CALL (warm base only — ignores cold target access + memory
        // expansion), KECCAK (base only), generic compute/memory opcodes at
        // 3 gas each (a conservative average for PUSH/POP/ADD/MSTORE/…).
        //
        // SSTORE pricing depends on EIP-2200 dirty-write state we don't
        // track, so we treat the SSTORE bucket as the RESIDUAL: every gas
        // unit that the turn spent and that we couldn't account for under
        // one of the categories above. In practice this residual also
        // absorbs memory expansion and EXT* / call memory overhead.
        uint256 sloadGas = t.sloadCold * 2100 + t.sloadWarm * 100;
        uint256 tloadGas = t.tloadCount * 100;
        uint256 tstoreGas = t.tstoreCount * 100;
        uint256 logGas = t.logCount * 375 + t.logTopicCount * 375 + t.logDataBytes * 8;
        uint256 callGas = (t.callCount + t.staticcallCount + t.delegatecallCount) * 100;
        uint256 keccakGas = t.keccakCount * 30;
        uint256 memoryGas = t.memoryOpCount * 3;
        uint256 computeGas = t.otherCount * 3;
        uint256 accounted = sloadGas + tloadGas + tstoreGas + logGas + callGas + keccakGas + memoryGas + computeGas;
        // Residual: SSTORE gas plus any undercounted memory expansion / cold
        // CALL target access / long KECCAK data.
        uint256 sstoreGas = totalGas > accounted ? totalGas - accounted : 0;

        // Clear warm-set so a follow-up call starts fresh
        for (uint256 i = 0; i < _seenKeys.length; i++) {
            delete _seenSlot[_seenKeys[i]];
        }
        delete _seenKeys;

        console.log("=== Opcode breakdown ===");
        console.log("Total gas:", totalGas);
        console.log("Total opcodes:", t.totalSteps);
        console.log("SLOAD count/cold/warm:", t.sloadCount, t.sloadCold, t.sloadWarm);
        console.log("SSTORE count/cold/warm:", t.sstoreCount, t.sstoreCold, t.sstoreWarm);
        console.log("TLOAD / TSTORE:", t.tloadCount, t.tstoreCount);
        console.log("LOG count / topics / bytes:", t.logCount, t.logTopicCount, t.logDataBytes);
        console.log("CALL / STATICCALL / DELEGATECALL:", t.callCount, t.staticcallCount, t.delegatecallCount);
        console.log("KECCAK256:", t.keccakCount);
        console.log("Memory ops (MLOAD/MSTORE):", t.memoryOpCount);
        console.log("Other opcodes:", t.otherCount);
        console.log("--- gas attribution ---");
        console.log("SLOAD (accurate):", sloadGas);
        console.log("TLOAD+TSTORE:", tloadGas + tstoreGas);
        console.log("LOG (accurate):", logGas);
        console.log("CALL base:", callGas);
        console.log("KECCAK256 base:", keccakGas);
        console.log("Memory ops @3:", memoryGas);
        console.log("Compute opcodes @3:", computeGas);
        console.log("SSTORE (residual):", sstoreGas);

        // Write JSON for the visualization. The residual bucket (sstore_gas)
        // absorbs anything we couldn't attribute under the fixed-cost rules.
        string memory root = "opcode_breakdown";
        vm.serializeUint(root, "total_gas", totalGas);
        vm.serializeUint(root, "total_opcodes", t.totalSteps);
        vm.serializeUint(root, "sload_count", t.sloadCount);
        vm.serializeUint(root, "sload_cold", t.sloadCold);
        vm.serializeUint(root, "sload_warm", t.sloadWarm);
        vm.serializeUint(root, "sload_gas", sloadGas);
        vm.serializeUint(root, "sstore_count", t.sstoreCount);
        vm.serializeUint(root, "sstore_cold", t.sstoreCold);
        vm.serializeUint(root, "sstore_warm", t.sstoreWarm);
        vm.serializeUint(root, "sstore_gas", sstoreGas);
        vm.serializeUint(root, "tload_count", t.tloadCount);
        vm.serializeUint(root, "tstore_count", t.tstoreCount);
        vm.serializeUint(root, "tload_tstore_gas", tloadGas + tstoreGas);
        vm.serializeUint(root, "log_count", t.logCount);
        vm.serializeUint(root, "log_topics", t.logTopicCount);
        vm.serializeUint(root, "log_data_bytes", t.logDataBytes);
        vm.serializeUint(root, "log_gas", logGas);
        vm.serializeUint(root, "call_count", t.callCount);
        vm.serializeUint(root, "staticcall_count", t.staticcallCount);
        vm.serializeUint(root, "delegatecall_count", t.delegatecallCount);
        vm.serializeUint(root, "call_gas", callGas);
        vm.serializeUint(root, "keccak_count", t.keccakCount);
        vm.serializeUint(root, "keccak_gas", keccakGas);
        vm.serializeUint(root, "memory_ops", t.memoryOpCount);
        vm.serializeUint(root, "memory_gas", memoryGas);
        vm.serializeUint(root, "other_count", t.otherCount);
        string memory json = vm.serializeUint(root, "compute_gas", computeGas);
        vm.writeJson(json, outPath);
        console.log("Wrote", outPath);
    }
}

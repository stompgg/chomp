// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {DefaultRuleset} from "../src/DefaultRuleset.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {Engine} from "../src/Engine.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {StaminaRegen} from "../src/effects/StaminaRegen.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {BattleHelper} from "./abstract/BattleHelper.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Regression tests for stale BattleConfig state leaking across battles via the
///         MappingAllocator storage-key recycling scheme. Each test runs battle 1 to completion
///         through the legacy commit-reveal (setMove storage) path, then asserts battle 2 — which
///         recycles battle 1's config storage — starts from a clean slate.
contract RecycledKeyHygieneTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    DefaultValidator twoMoveValidator;
    ITypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;

    IMoveSet koAttack; // move 0: KOs any small-hp mon
    IMoveSet staminaSink; // move 1: no damage, costs 1 stamina

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        engine = new Engine(0, 0);
        commitManager = new DefaultCommitManager(engine);
        twoMoveValidator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 2, TIMEOUT_DURATION: 100})
        );
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);

        koAttack = IMoveSet(
            address(
                new CustomAttack(
                    typeCalc,
                    CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 1})
                )
            )
        );
        staminaSink = IMoveSet(
            address(
                new CustomAttack(
                    typeCalc,
                    CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 0, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 1})
                )
            )
        );

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(koAttack)));
        moves[1] = uint256(uint160(address(staminaSink)));
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 5,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
    }

    function _startBattleWithRuleset(IRuleset ruleset) internal returns (bytes32) {
        return _startBattle(
            twoMoveValidator,
            engine,
            mockOracle,
            defaultRegistry,
            matchmaker,
            new IEngineHook[](0),
            ruleset,
            address(commitManager)
        );
    }

    /// @dev Runs a full battle through the commit-reveal storage path: send-in turn, then a mutual
    ///      KO-move turn (priority player wins). The final turn's moves are setMove-written, i.e.
    ///      they land in BattleConfig storage.
    function _runBattleToGameOver(IRuleset ruleset) internal returns (bytes32 battleKey, bytes32 storageKey) {
        battleKey = _startBattleWithRuleset(ruleset);
        storageKey = engine.getStorageKey(battleKey);
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        // A battle cannot start and end in the same block
        vm.warp(vm.getBlockTimestamp() + 1);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        assertTrue(engine.getWinner(battleKey) != address(0), "battle 1 should be over");
    }

    function test_recycledKey_staleMoves_cannotDriveNextBattle() public {
        (, bytes32 storageKey1) = _runBattleToGameOver(IRuleset(address(0)));

        // Battle 2 for the same pair recycles battle 1's config storage
        bytes32 battleKey2 = _startBattleWithRuleset(IRuleset(address(0)));
        assertEq(engine.getStorageKey(battleKey2), storageKey1, "expected recycled storage key");

        // No moves have been set for battle 2 yet: the permissionless execute() must not be able
        // to run battle 2's turn 0 off battle 1's leftover move slots.
        vm.stopPrank();
        engine.resetCallContext();
        vm.expectRevert(Engine.MovesNotSet.selector);
        engine.execute(battleKey2);
    }

    function test_endPath_staleMoves_cannotDriveNextBattle() public {
        bytes32 battleKey1 = _startBattleWithRuleset(IRuleset(address(0)));
        bytes32 storageKey1 = engine.getStorageKey(battleKey1);

        // Turn 0: Alice commits, then both players reveal WITHOUT executing — both moves are now
        // setMove-written into config storage and the battle stalls.
        uint104 salt = 0;
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint16(0)));
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey1, aliceMoveHash);
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey1, SWITCH_MOVE_INDEX, salt, 0, false);
        vm.startPrank(ALICE);
        commitManager.revealMove(battleKey1, SWITCH_MOVE_INDEX, salt, 0, false);
        vm.stopPrank();

        // Force-end the stalled battle past MAX_BATTLE_DURATION
        vm.warp(vm.getBlockTimestamp() + MAX_BATTLE_DURATION + 1);
        engine.end(battleKey1);
        assertEq(engine.getWinner(battleKey1), ALICE);

        bytes32 battleKey2 = _startBattleWithRuleset(IRuleset(address(0)));
        assertEq(engine.getStorageKey(battleKey2), storageKey1, "expected recycled storage key");

        vm.stopPrank();
        engine.resetCallContext();
        vm.expectRevert(Engine.MovesNotSet.selector);
        engine.execute(battleKey2);
    }

    function test_recycledKey_inlineStaminaRegenCleared() public {
        (, bytes32 storageKey1) = _runBattleToGameOver(IRuleset(INLINE_STAMINA_REGEN_RULESET));

        // Battle 2 on the recycled key has NO ruleset: no stamina regen of any kind should run.
        bytes32 battleKey2 = _startBattleWithRuleset(IRuleset(address(0)));
        assertEq(engine.getStorageKey(battleKey2), storageKey1, "expected recycled storage key");

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        // Turn 1: both use the stamina-costing no-damage move
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 1, 1, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey2, 0, 0, MonStateIndexName.Stamina), -1, "p0 should not regen");
        assertEq(engine.getMonStateForBattle(battleKey2, 1, 0, MonStateIndexName.Stamina), -1, "p1 should not regen");
    }

    function test_recycledKey_globalEffectsLengthCleared() public {
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = IEffect(address(new StaminaRegen()));
        DefaultRuleset regenRuleset = new DefaultRuleset(engine, effects);
        (, bytes32 storageKey1) = _runBattleToGameOver(IRuleset(address(regenRuleset)));

        // Battle 2 uses an external ruleset that returns ZERO effects: battle 1's global effect
        // must not stay live.
        DefaultRuleset emptyRuleset = new DefaultRuleset(engine, new IEffect[](0));
        bytes32 battleKey2 = _startBattleWithRuleset(IRuleset(address(emptyRuleset)));
        assertEq(engine.getStorageKey(battleKey2), storageKey1, "expected recycled storage key");

        (BattleConfigView memory cfg,) = engine.getBattle(battleKey2);
        assertEq(cfg.globalEffects.length, 0, "stale global effect leaked into battle 2");

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey2, 1, 1, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey2, 0, 0, MonStateIndexName.Stamina), -1, "p0 should not regen");
        assertEq(engine.getMonStateForBattle(battleKey2, 1, 0, MonStateIndexName.Stamina), -1, "p1 should not regen");
    }

    function test_recycledKey_saltsCleared() public {
        bytes32 battleKey1 = _startBattleWithRuleset(IRuleset(address(0)));
        bytes32 storageKey1 = engine.getStorageKey(battleKey1);

        // Run battle 1 with a NONZERO salt so config.p0Salt/p1Salt get written via setMove.
        uint104 salt = 42;
        _commitRevealExecuteWithSalt(battleKey1, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, salt);
        vm.warp(vm.getBlockTimestamp() + 1);
        _commitRevealExecuteWithSalt(battleKey1, 0, 0, salt);
        assertTrue(engine.getWinner(battleKey1) != address(0), "battle 1 should be over");

        bytes32 battleKey2 = _startBattleWithRuleset(IRuleset(address(0)));
        assertEq(engine.getStorageKey(battleKey2), storageKey1, "expected recycled storage key");

        (BattleConfigView memory cfg,) = engine.getBattle(battleKey2);
        assertEq(uint256(cfg.p0Salt), 0, "stale p0Salt leaked into battle 2");
        assertEq(uint256(cfg.p1Salt), 0, "stale p1Salt leaked into battle 2");
    }

    /// @dev Same flow as BattleHelper._commitRevealExecuteForAliceAndBob but with a caller-chosen salt.
    function _commitRevealExecuteWithSalt(bytes32 battleKey, uint8 aliceMoveIndex, uint8 bobMoveIndex, uint104 salt)
        internal
    {
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(aliceMoveIndex, salt, uint16(0)));
        bytes32 bobMoveHash = keccak256(abi.encodePacked(bobMoveIndex, salt, uint16(0)));
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        if (turnId % 2 == 0) {
            vm.startPrank(ALICE);
            commitManager.commitMove(battleKey, aliceMoveHash);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, bobMoveIndex, salt, 0, true);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, aliceMoveIndex, salt, 0, true);
        } else {
            vm.startPrank(BOB);
            commitManager.commitMove(battleKey, bobMoveHash);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, aliceMoveIndex, salt, 0, true);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, bobMoveIndex, salt, 0, true);
        }
        vm.stopPrank();
        engine.resetCallContext();
    }
}

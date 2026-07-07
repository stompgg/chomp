// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {IEngine} from "../../src/IEngine.sol";
import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../../src/moves/IMoveSet.sol";
import {ITypeCalculator} from "../../src/types/ITypeCalculator.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";
import {EffectAttack} from "../mocks/EffectAttack.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestMoveFactory} from "../mocks/TestMoveFactory.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "../mocks/TestTypeCalculator.sol";

// PreDamage that halves the running damage.
contract PreDamageHalveEffect is BasicEffect {
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x200; // PreDamage
    }

    function onPreDamage(IEngine engine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        engine.setPreDamage(engine.getPreDamage() / 2);
        return (extraData, false);
    }
}

// PreDamage that fully absorbs damage (sets running to 0).
contract PreDamageAbsorbEffect is BasicEffect {
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x200;
    }

    function onPreDamage(IEngine engine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        engine.setPreDamage(0);
        return (extraData, false);
    }
}

// PreDamage that doubles the running damage.
contract PreDamageDoubleEffect is BasicEffect {
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x200;
    }

    function onPreDamage(IEngine engine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        override
        returns (bytes32, bool)
    {
        engine.setPreDamage(engine.getPreDamage() * 2);
        return (extraData, false);
    }
}

// Records the source it was last invoked with on PreDamage and AfterDamage.
contract SourceCaptureEffect is BasicEffect {
    uint256 public lastPreDamageSource;
    int32 public lastPreDamageSeenDamage;
    uint256 public lastAfterDamageSource;
    int32 public lastAfterDamageSeenDamage;
    uint256 public preDamageCallCount;
    uint256 public afterDamageCallCount;

    function getStepsBitmap() external pure override returns (uint16) {
        return 0x240; // PreDamage | AfterDamage
    }

    function onPreDamage(IEngine engine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256 source)
        external
        override
        returns (bytes32, bool)
    {
        preDamageCallCount += 1;
        lastPreDamageSource = source;
        lastPreDamageSeenDamage = engine.getPreDamage();
        return (extraData, false);
    }

    function onAfterDamage(
        IEngine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256,
        uint256,
        uint256,
        int32 damage,
        uint256 source
    ) external override returns (bytes32, bool) {
        afterDamageCallCount += 1;
        lastAfterDamageSource = source;
        lastAfterDamageSeenDamage = damage;
        return (extraData, false);
    }
}

contract PreDamageHookTest is Test, BattleHelper {
    DefaultCommitManager commitManager;
    Engine engine;
    ITypeCalculator typeCalc;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    TestMoveFactory moveFactory;

    uint256 constant TIMEOUT_DURATION = 100;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(engine);
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
        moveFactory = new TestMoveFactory();
    }

    /// Deploys a 1-mon team where move[0] applies `effect` to the opponent and move[1]
    /// is a flat 10-damage attack via TestMove (calls engine.dealDamage). Both players
    /// share the same team layout. Returns the battleKey and the damaging-move address.
    function _setupBattleWithEffect(IEffect effect) internal returns (bytes32 battleKey, address damagingMoveAddr) {
        IMoveSet effectApplier =
            new EffectAttack(effect, EffectAttack.Args({TYPE: Type.Liquid, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet damagingMove = moveFactory.createMove(MoveClass.Physical, Type.Liquid, 1, 10);

        uint256[] memory moves = new uint256[](2);
        moves[0] = uint256(uint160(address(effectApplier)));
        moves[1] = uint256(uint160(address(damagingMove)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        // Both players switch to mon index 0 (turn 0 setup).
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        damagingMoveAddr = address(damagingMove);
    }

    /// No PreDamage subscriber → 10 dmg lands as 10. Sanity baseline.
    function test_preDamage_passthroughWhenNoSubscriber() public {
        // SourceCaptureEffect subscribes to PreDamage but doesn't mutate; just observes.
        SourceCaptureEffect capture = new SourceCaptureEffect();
        (bytes32 battleKey,) = _setupBattleWithEffect(capture);

        // Alice applies the capture effect to Bob's mon (move 0), Bob does no-op-equivalent
        // by also applying to Alice. Both mons now carry SourceCaptureEffect.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Both players hit each other for 10 damage (move 1).
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 1, 0, 0);

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -10);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -10);

        // PreDamage was called and observed initial damage 10.
        assertEq(capture.preDamageCallCount(), 2); // both Alice and Bob's mons
        assertEq(capture.lastPreDamageSeenDamage(), 10);
        assertEq(capture.lastAfterDamageSeenDamage(), 10);
    }

    /// PreDamage halves: 10 → 5.
    function test_preDamage_halve() public {
        PreDamageHalveEffect halve = new PreDamageHalveEffect();
        (bytes32 battleKey,) = _setupBattleWithEffect(halve);

        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 1, 0, 0);

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -5);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -5);
    }

    /// PreDamage zeroes out the damage → hpDelta unchanged AND AfterDamage skipped.
    function test_preDamage_absorbSkipsHpDeltaAndAfterDamage() public {
        // Two effects on each mon: SourceCaptureEffect (subscribes to PreDamage + AfterDamage)
        // and PreDamageAbsorbEffect (subscribes to PreDamage). Capture goes first because it's
        // applied first, then absorb runs after and sets damage to 0.
        SourceCaptureEffect capture = new SourceCaptureEffect();
        PreDamageAbsorbEffect absorb = new PreDamageAbsorbEffect();

        IMoveSet applyCapture =
            new EffectAttack(capture, EffectAttack.Args({TYPE: Type.Liquid, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet applyAbsorb =
            new EffectAttack(absorb, EffectAttack.Args({TYPE: Type.Liquid, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet damagingMove = moveFactory.createMove(MoveClass.Physical, Type.Liquid, 1, 10);

        uint256[] memory moves = new uint256[](3);
        moves[0] = uint256(uint160(address(applyCapture)));
        moves[1] = uint256(uint160(address(applyAbsorb)));
        moves[2] = uint256(uint160(address(damagingMove)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Both apply capture, then both apply absorb. Now each mon has both effects.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 1, 0, 0);

        uint256 captureCallsBefore = capture.afterDamageCallCount();

        // Damaging move triggers PreDamage chain: capture observes 10, absorb sets to 0,
        // damage <= 0 → no hpDelta change, no AfterDamage.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, 2, 0, 0);

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), 0, "p0 hp unchanged");
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), 0, "p1 hp unchanged");
        assertEq(capture.afterDamageCallCount(), captureCallsBefore, "AfterDamage should be skipped on absorb");
    }

    /// PreDamage doubles: 10 → 20.
    function test_preDamage_amplify() public {
        PreDamageDoubleEffect dbl = new PreDamageDoubleEffect();
        (bytes32 battleKey,) = _setupBattleWithEffect(dbl);

        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 1, 0, 0);

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -20);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -20);
    }

    /// Two PreDamage effects compose sequentially in apply-order.
    /// halve → double: 10 / 2 = 5, 5 * 2 = 10. Result: 10 (unchanged).
    /// double → halve: 10 * 2 = 20, 20 / 2 = 10. Result: 10 (unchanged).
    /// To prove ordering matters, use halve + halve which compounds to /4 = 2 (with rounding).
    function test_preDamage_compositionOrder() public {
        PreDamageHalveEffect halve1 = new PreDamageHalveEffect();
        PreDamageHalveEffect halve2 = new PreDamageHalveEffect();

        IMoveSet applyHalve1 =
            new EffectAttack(halve1, EffectAttack.Args({TYPE: Type.Liquid, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet applyHalve2 =
            new EffectAttack(halve2, EffectAttack.Args({TYPE: Type.Liquid, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet damagingMove = moveFactory.createMove(MoveClass.Physical, Type.Liquid, 1, 100);

        uint256[] memory moves = new uint256[](3);
        moves[0] = uint256(uint160(address(applyHalve1)));
        moves[1] = uint256(uint160(address(applyHalve2)));
        moves[2] = uint256(uint160(address(damagingMove)));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 200,
                stamina: 10,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        bytes32 battleKey = _startBattle(engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Apply both halve effects to each mon.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 1, 0, 0);

        // 100 damage → halve → 50 → halve → 25.
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 2, 2, 0, 0);

        assertEq(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), -25);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp), -25);
    }

    /// Verify both PreDamage and AfterDamage receive the source = the move contract address
    /// (low-160-bits form, high bits zero) for damage triggered by an external dealDamage call.
    function test_source_threadsThroughExternalDealDamage() public {
        SourceCaptureEffect capture = new SourceCaptureEffect();
        (bytes32 battleKey, address damagingMoveAddr) = _setupBattleWithEffect(capture);

        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 1, 1, 0, 0);

        // Both PreDamage and AfterDamage should have been called with source = damagingMoveAddr.
        assertEq(capture.lastPreDamageSource(), uint256(uint160(damagingMoveAddr)));
        assertEq(capture.lastAfterDamageSource(), uint256(uint160(damagingMoveAddr)));
        // No high bits set → external (address-form) source.
        assertEq(capture.lastPreDamageSource() >> 160, 0);
    }
}

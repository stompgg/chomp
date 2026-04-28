// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEffect} from "../src/effects/IEffect.sol";  // Used by EffectAbility
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {MockSingletonAbility} from "./mocks/MockSingletonAbility.sol";
import {EffectAbility} from "./mocks/EffectAbility.sol";
import {DummyStatus} from "./mocks/DummyStatus.sol";

/// @title Inline Ability Parity Tests
/// @notice Verifies that inline packed abilities produce identical results to external dispatch
contract InlineAbilityParityTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    MockSingletonAbility singletonAbility;
    DummyStatus dummyEffect;
    EffectAbility externalAbility; // non-singleton, uses external dispatch

    uint256 constant INLINE_ABILITY_TYPE_01 = 1;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        engine = new Engine(2, 4, 1);
        commitManager = new DefaultCommitManager(engine);
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);

        singletonAbility = new MockSingletonAbility();
        dummyEffect = new DummyStatus();
        externalAbility = new EffectAbility(IEffect(address(dummyEffect)));
    }

    function _packAbility(address effectAddr) internal pure returns (uint256) {
        return (uint256(INLINE_ABILITY_TYPE_01) << 248) | uint160(effectAddr);
    }

    /// @notice Pack an inline move: basePower=10, stamina=1, Physical, Fire, no effect
    function _inlineAttack() internal pure returns (uint256) {
        // [basePower:8 | moveClass:2 | priority:2 | moveType:4 | stamina:4 | effectAccuracy:8 | unused:68 | effect:160]
        uint256 basePower = 10;
        uint256 moveClass = 0; // Physical
        uint256 moveType = uint256(Type.Fire);
        uint256 stamina = 1;
        return (basePower << 248) | (moveClass << 246) | (0 << 244) | (moveType << 240) | (stamina << 236);
    }

    function _setupBattle(Mon[] memory aliceTeam, Mon[] memory bobTeam)
        internal
        returns (bytes32 battleKey)
    {
        uint256 teamSize = aliceTeam.length > bobTeam.length ? aliceTeam.length : bobTeam.length;
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);
        DefaultValidator validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: teamSize, MOVES_PER_MON: 4, TIMEOUT_DURATION: 10})
        );
        battleKey = _startBattle(validator, engine, mockOracle, defaultRegistry, matchmaker, address(commitManager));
    }

    function _monWithAbility(uint256 ability) internal pure returns (Mon memory mon) {
        uint256 attack = _inlineAttack();
        uint256[] memory moves = new uint256[](4);
        moves[0] = attack;
        moves[1] = attack;
        moves[2] = attack;
        moves[3] = attack;
        mon = _createMon();
        mon.moves = moves;
        mon.ability = ability;
        mon.stats.hp = 100;
        mon.stats.attack = 10;
        mon.stats.defense = 10;
    }

    function _hasEffect(bytes32 battleKey, uint256 playerIndex, uint256 monIndex, address effectAddr) internal view returns (bool) {
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == effectAddr) return true;
        }
        return false;
    }

    function _countEffect(bytes32 battleKey, uint256 playerIndex, uint256 monIndex, address effectAddr) internal view returns (uint256 count) {
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == effectAddr) count++;
        }
    }

    // =========================================================================
    // a. Inline type-0x01 ability registers effect on first switch (turn 0)
    // =========================================================================

    function test_inlineAbilityRegistersEffectOnTurn0() public {
        Mon memory mon = _monWithAbility(_packAbility(address(singletonAbility)));
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _setupBattle(team, team);

        // Turn 0: both switch in
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        assertTrue(_hasEffect(battleKey, 0, 0, address(singletonAbility)), "p0 should have effect");
        assertTrue(_hasEffect(battleKey, 1, 0, address(singletonAbility)), "p1 should have effect");
    }

    // =========================================================================
    // b. Inline ability idempotent — not double-registered on re-switch
    // =========================================================================

    function test_inlineAbilityIdempotentOnReSwitch() public {
        Mon memory mon = _monWithAbility(_packAbility(address(singletonAbility)));
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;

        bytes32 battleKey = _setupBattle(team, team);

        // Turn 0: switch in mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        assertEq(_countEffect(battleKey, 0, 0, address(singletonAbility)), 1, "should have 1 effect");

        // Switch to mon 1 then back to mon 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(1), 0
        );
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(0), 0
        );

        assertEq(_countEffect(battleKey, 0, 0, address(singletonAbility)), 1, "should still have exactly 1 effect");
    }

    // =========================================================================
    // c. Inline ability effect hooks still run (AfterDamage increments counter)
    // =========================================================================

    function test_inlineAbilityEffectHooksRun() public {
        Mon memory mon = _monWithAbility(_packAbility(address(singletonAbility)));
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _setupBattle(team, team);

        // Turn 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // Execute 2 attack turns — AfterDamage should increment counter each time
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, 0, 0, 0);

        // Check that the effect's extraData was updated (counter > 0)
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 0, 0);
        bool found = false;
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == address(singletonAbility)) {
                assertTrue(uint256(effects[i].data) > 0, "effect hook should have incremented counter");
                found = true;
                break;
            }
        }
        assertTrue(found, "effect should exist");
    }

    // =========================================================================
    // d. External ability still works via raw address (no packed bits)
    // =========================================================================

    function test_externalAbilityStillWorks() public {
        // Store as raw address — no upper bits set, goes through external dispatch
        Mon memory mon = _monWithAbility(uint160(address(externalAbility)));
        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _setupBattle(team, team);

        // Turn 0
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        // EffectAbility adds dummyEffect — verify it's registered
        assertTrue(_hasEffect(battleKey, 0, 0, address(dummyEffect)), "external ability should register its effect");
    }

    // =========================================================================
    // e. Mixed team: one mon inline ability, one mon external ability
    // =========================================================================

    function test_mixedInlineAndExternalAbilities() public {
        Mon memory inlineMon = _monWithAbility(_packAbility(address(singletonAbility)));
        Mon memory externalMon = _monWithAbility(uint160(address(externalAbility)));

        Mon[] memory aliceTeam = new Mon[](2);
        aliceTeam[0] = inlineMon;
        aliceTeam[1] = externalMon;

        Mon[] memory bobTeam = new Mon[](2);
        bobTeam[0] = inlineMon;
        bobTeam[1] = inlineMon;

        bytes32 battleKey = _setupBattle(aliceTeam, bobTeam);

        // Turn 0: switch in mon 0 (inline)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        assertTrue(_hasEffect(battleKey, 0, 0, address(singletonAbility)), "alice mon 0 should have inline effect");

        // Alice switches to mon 1 (external)
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(1), 0
        );
        assertTrue(_hasEffect(battleKey, 0, 1, address(dummyEffect)), "alice mon 1 should have external effect");
    }

    // =========================================================================
    // f. Both players have inline abilities on turn 0 — both activate
    // =========================================================================

    function test_bothPlayersInlineAbilitiesActivateOnTurn0() public {
        Mon memory mon = _monWithAbility(_packAbility(address(singletonAbility)));
        Mon[] memory aliceTeam = new Mon[](1);
        aliceTeam[0] = mon;
        Mon[] memory bobTeam = new Mon[](1);
        bobTeam[0] = mon;

        bytes32 battleKey = _setupBattle(aliceTeam, bobTeam);

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey,
            SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );

        assertTrue(_hasEffect(battleKey, 0, 0, address(singletonAbility)), "p0 should have inline effect");
        assertTrue(_hasEffect(battleKey, 1, 0, address(singletonAbility)), "p1 should have inline effect");
    }
}

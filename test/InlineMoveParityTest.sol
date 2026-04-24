// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {IValidator} from "../src/IValidator.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";

/// @title Inline Move Parity Tests
/// @notice Verifies that inline packed moves work correctly in the Engine
contract InlineMoveParityTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    StatBoosts statBoosts;

    // Inline validation constants
    uint256 constant MONS_PER_TEAM = 1;
    uint256 constant MOVES_PER_MON = 4;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        commitManager = new DefaultCommitManager(engine);
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
        statBoosts = new StatBoosts();
    }

    /// @notice Pack an inline move value from components
    function _packMove(
        uint8 basePower,
        uint8 moveClassVal,
        uint8 priorityOffset,
        uint8 moveTypeVal,
        uint8 stamina,
        uint8 effectAccuracy,
        address effect
    ) internal pure returns (uint256) {
        uint256 packed = uint256(basePower) << 248;
        packed |= uint256(moveClassVal) << 246;
        packed |= uint256(priorityOffset) << 244;
        packed |= uint256(moveTypeVal) << 240;
        packed |= uint256(stamina) << 236;
        packed |= uint256(effectAccuracy) << 228;
        packed |= uint256(uint160(effect));
        return packed;
    }

    function _startBattleInline(Mon[] memory aliceTeam, Mon[] memory bobTeam) internal returns (bytes32) {
        defaultRegistry.setTeam(ALICE, aliceTeam);
        defaultRegistry.setTeam(BOB, bobTeam);

        uint256[] memory indices = new uint256[](aliceTeam.length);
        for (uint256 i; i < aliceTeam.length; i++) {
            indices[i] = i;
        }
        defaultRegistry.setIndices(indices);

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        engine.updateMatchmakers(makersToAdd, new address[](0));

        vm.startPrank(BOB);
        engine.updateMatchmakers(makersToAdd, new address[](0));

        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory teamIndices = defaultRegistry.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, teamIndices));

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: IValidator(address(0)),
            rngOracle: mockOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        bytes32 integrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, integrityHash);
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, 0);

        return battleKey;
    }

    function _doSwitchTurn(bytes32 battleKey) internal {
        bytes32 salt = "";
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        bytes32 moveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint240(0)));
        if (turnId % 2 == 0) {
            vm.startPrank(ALICE);
            commitManager.commitMove(battleKey, moveHash);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, false);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, true);
        } else {
            vm.startPrank(BOB);
            commitManager.commitMove(battleKey, moveHash);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, false);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, true);
        }
        vm.stopPrank();
        engine.resetCallContext();
    }

    function _doAttackTurn(bytes32 battleKey, uint8 aliceMove, uint8 bobMove) internal {
        bytes32 salt = "";
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        if (turnId % 2 == 0) {
            bytes32 moveHash = keccak256(abi.encodePacked(aliceMove, salt, uint240(0)));
            vm.startPrank(ALICE);
            commitManager.commitMove(battleKey, moveHash);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, bobMove, salt, 0, false);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, aliceMove, salt, 0, true);
        } else {
            bytes32 moveHash = keccak256(abi.encodePacked(bobMove, salt, uint240(0)));
            vm.startPrank(BOB);
            commitManager.commitMove(battleKey, moveHash);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, aliceMove, salt, 0, false);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, bobMove, salt, 0, true);
        }
        vm.stopPrank();
        engine.resetCallContext();
    }

    /// @notice Test that an inline Physical move deals damage correctly
    function test_inlinePhysicalMove_dealsDamage() public {
        // Pack a move: basePower=70, Physical, default priority, Air type, stamina=2, no effect
        // Air=10 in Type enum, Physical=0 in MoveClass
        uint256 inlineMove = _packMove(70, 0, 0, 10, 2, 0, address(0));

        // Verify it's detected as inline
        assertTrue(inlineMove >> 160 != 0, "Should be detected as inline");

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 200,
                stamina: 10,
                speed: 10,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yang, // Yang so Air→Yang is checked for neutral
                type2: Type.None
            }),
            moves: new uint256[](4),
            ability: 0
        });
        mon.moves[0] = inlineMove;
        mon.moves[1] = inlineMove;
        mon.moves[2] = inlineMove;
        mon.moves[3] = inlineMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _startBattleInline(team, team);

        // Switch in
        _doSwitchTurn(battleKey);

        // Both attack with inline move
        _doAttackTurn(battleKey, 0, 0);

        // Both mons should have taken damage
        int32 aliceHp = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 bobHp = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(aliceHp < 0, "Alice should have taken damage");
        assertTrue(bobHp < 0, "Bob should have taken damage");
    }

    /// @notice Test that an inline Special move deals damage using SpAtk/SpDef
    function test_inlineSpecialMove_dealsDamage() public {
        // Pack: basePower=90, Special(1), default priority, Earth(2), stamina=3, no effect
        uint256 inlineMove = _packMove(90, 1, 0, 2, 3, 0, address(0));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 200,
                stamina: 10,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 100,
                specialDefense: 50, // Low SpDef so damage is higher
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: new uint256[](4),
            ability: 0
        });
        mon.moves[0] = inlineMove;
        mon.moves[1] = inlineMove;
        mon.moves[2] = inlineMove;
        mon.moves[3] = inlineMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _startBattleInline(team, team);
        _doSwitchTurn(battleKey);
        _doAttackTurn(battleKey, 0, NO_OP_MOVE_INDEX);

        // Bob should have taken damage (SpAtk=100, SpDef=50, base=90 -> ~180 damage)
        int32 bobHp = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertTrue(bobHp < 0, "Bob should have taken damage from special attack");
        // Damage should be roughly basePower * SpAtk / SpDef = 90 * 100 / 50 = 180
        // (with some variance from volatility)
        assertTrue(bobHp < -100, "Damage should be significant (SpAtk >> SpDef)");
    }

    /// @notice Test inline move with effect: effect is applied when RNG hits
    function test_inlineMoveWithEffect_appliesEffect() public {
        BurnStatus burnStatus = new BurnStatus(statBoosts);

        // Pack: basePower=50, Special(1), default priority, Fire(4), stamina=1, effectAccuracy=100, effect=burn
        uint256 inlineMove = _packMove(50, 1, 0, 4, 1, 100, address(burnStatus));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 500,
                stamina: 10,
                speed: 10,
                attack: 10,
                defense: 10,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: new uint256[](4),
            ability: 0
        });
        mon.moves[0] = inlineMove;
        mon.moves[1] = inlineMove;
        mon.moves[2] = inlineMove;
        mon.moves[3] = inlineMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _startBattleInline(team, team);
        _doSwitchTurn(battleKey);

        // Alice attacks, Bob does nothing
        _doAttackTurn(battleKey, 0, NO_OP_MOVE_INDEX);

        // Bob should have the burn effect applied (effectAccuracy=100 -> guaranteed)
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 1, 0);
        bool hasBurn = false;
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == address(burnStatus)) {
                hasBurn = true;
                break;
            }
        }
        assertTrue(hasBurn, "Bob should have burn status from inline move effect");
    }

    /// @notice Test basePower=0 inline move (like ChillOut) deals no damage but applies effect
    function test_inlineBasePowerZero_noEffectDamage_appliesEffect() public {
        FrostbiteStatus frostbiteStatus = new FrostbiteStatus(statBoosts);

        // Pack ChillOut: basePower=0, Other(3), default priority, Ice(6), stamina=0, effectAccuracy=100, effect=frostbite
        uint256 chillOutPacked = _packMove(0, 3, 0, 6, 0, 100, address(frostbiteStatus));

        // Fill remaining move slots with a damaging move
        uint256 dummyMove = _packMove(10, 0, 0, 10, 1, 0, address(0));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 200,
                stamina: 10,
                speed: 10,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: new uint256[](4),
            ability: 0
        });
        mon.moves[0] = chillOutPacked;
        mon.moves[1] = dummyMove;
        mon.moves[2] = dummyMove;
        mon.moves[3] = dummyMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _startBattleInline(team, team);
        _doSwitchTurn(battleKey);

        // Alice uses ChillOut (move 0), Bob does nothing
        _doAttackTurn(battleKey, 0, NO_OP_MOVE_INDEX);

        // Bob's HP damage should only be from frostbite chip (6% of 200 = 12), NOT from basePower=0 move
        int32 bobHp = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertEq(bobHp, -12, "Bob should only take frostbite chip damage, not move damage");

        // Bob should have frostbite applied
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, 1, 0);
        bool hasFrostbite = false;
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == address(frostbiteStatus)) {
                hasFrostbite = true;
                break;
            }
        }
        assertTrue(hasFrostbite, "Bob should have frostbite from ChillOut-style inline move");
    }

    /// @notice Test that inline stamina cost is deducted correctly
    function test_inlineMove_deductsStamina() public {
        // Pack: basePower=70, Physical(0), default, Air(10), stamina=3, no effect
        uint256 inlineMove = _packMove(70, 0, 0, 10, 3, 0, address(0));

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 500,
                stamina: 5,
                speed: 10,
                attack: 100,
                defense: 100,
                specialAttack: 100,
                specialDefense: 100,
                type1: Type.Yang,
                type2: Type.None
            }),
            moves: new uint256[](4),
            ability: 0
        });
        mon.moves[0] = inlineMove;
        mon.moves[1] = inlineMove;
        mon.moves[2] = inlineMove;
        mon.moves[3] = inlineMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _startBattleInline(team, team);
        _doSwitchTurn(battleKey);

        // Both attack
        _doAttackTurn(battleKey, 0, 0);

        // Each should have lost 3 stamina
        int32 aliceStamina = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Stamina);
        int32 bobStamina = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Stamina);
        assertEq(aliceStamina, -3, "Alice should have lost 3 stamina");
        assertEq(bobStamina, -3, "Bob should have lost 3 stamina");
    }

    // When two mirror mons use the same inline-packed damaging move against each other with the oracle
    // feeding a single rng, the per-attacker rng mix inside _dispatchStandardAttackInternal must make the
    // two damage rolls differ. Without the mix, identical stats + identical raw rng would collapse to
    // identical damage (the `volatility` in AttackCalculator would roll the same value for both sides).
    // This is the inline-path counterpart to StandardAttackRngTest.test_sameMoveFromMirrorMonsRollsDifferentDamage.
    function test_inlinePath_mirrorMonsRollDifferentDamage() public {
        // basePower=50, Physical(0), default priority, Fire(4), stamina=1, no effect.
        // Inline path uses DEFAULT_VOL (10) for the volatility roll, so a different rng produces a different
        // scaled damage.
        uint256 inlineMove = _packMove(50, 0, 0, 4, 1, 0, address(0));
        assertTrue(inlineMove >> 160 != 0, "move should be detected as inline");

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 10,
                speed: 5,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new uint256[](4),
            ability: 0
        });
        mon.moves[0] = inlineMove;
        mon.moves[1] = inlineMove;
        mon.moves[2] = inlineMove;
        mon.moves[3] = inlineMove;

        Mon[] memory team = new Mon[](1);
        team[0] = mon;

        bytes32 battleKey = _startBattleInline(team, team);
        _doSwitchTurn(battleKey);

        // Oracle returns the same rng for both attackers this turn.
        mockOracle.setRNG(1);

        // Both players use move 0 simultaneously — Alice attacks Bob with the same move Bob attacks Alice with.
        _doAttackTurn(battleKey, 0, 0);

        int32 aliceHpDelta = engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp);
        int32 bobHpDelta = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);

        assertLt(aliceHpDelta, 0, "Alice should have taken damage");
        assertLt(bobHpDelta, 0, "Bob should have taken damage");
        assertTrue(
            aliceHpDelta != bobHpDelta,
            "Inline-path mirror mons using the same move should not roll identical damage"
        );
    }
}

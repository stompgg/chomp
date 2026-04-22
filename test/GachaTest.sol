// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Engine.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";

import {DefaultValidator} from "../src/DefaultValidator.sol";
import {GachaRegistry} from "../src/gacha/GachaRegistry.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {IGachaRNG} from "../src/rng/IGachaRNG.sol";
import {DefaultMonRegistry} from "../src/teams/DefaultMonRegistry.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

import "./mocks/TestTeamRegistry.sol";

contract GachaTest is Test, BattleHelper {
    DefaultRandomnessOracle defaultOracle;
    Engine engine;
    DefaultCommitManager commitManager;
    TestTeamRegistry defaultRegistry;
    DefaultMonRegistry monRegistry;
    MockGachaRNG mockRNG;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(engine);
        defaultRegistry = new TestTeamRegistry();
        monRegistry = new DefaultMonRegistry();
        mockRNG = new MockGachaRNG();
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_firstRoll() public {
        GachaRegistry gachaRegistry = new GachaRegistry(monRegistry, engine, mockRNG);

        // Set up mon IDs 0 to INITIAL ROLLS
        for (uint256 i = 0; i < gachaRegistry.INITIAL_ROLLS(); i++) {
            monRegistry.createMon(
                i,
                MonStats({
                    hp: 10,
                    stamina: 2,
                    speed: 2,
                    attack: 1,
                    defense: 1,
                    specialAttack: 1,
                    specialDefense: 1,
                    type1: Type.Fire,
                    type2: Type.None
                }),
                new uint256[](0),
                new uint256[](0),
                new bytes32[](0),
                new bytes32[](0)
            );
        }

        vm.prank(ALICE);
        uint256[] memory monIds = gachaRegistry.firstRoll();
        assertEq(monIds.length, gachaRegistry.INITIAL_ROLLS());

        // Alice rolls again, it should fail
        vm.expectRevert(GachaRegistry.AlreadyFirstRolled.selector);
        vm.prank(ALICE);
        gachaRegistry.firstRoll();
    }

    function test_assignPoints() public {
        GachaRegistry gachaRegistry = new GachaRegistry(monRegistry, engine, mockRNG);

        // Set up mon IDs 0 to INITIAL ROLLS
        for (uint256 i = 0; i < gachaRegistry.INITIAL_ROLLS(); i++) {
            monRegistry.createMon(
                i,
                MonStats({
                    hp: 10,
                    stamina: 2,
                    speed: 2,
                    attack: 1,
                    defense: 1,
                    specialAttack: 1,
                    specialDefense: 1,
                    type1: Type.Fire,
                    type2: Type.None
                }),
                new uint256[](0),
                new uint256[](0),
                new bytes32[](0),
                new bytes32[](0)
            );
        }

        // Start battle
        Mon[] memory team = new Mon[](1);
        team[0] = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        DefaultValidator validator =
            new DefaultValidator(engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 0, TIMEOUT_DURATION: 0}));
        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));

        // Alice commits switching to mon index 0
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint240(0))));

        // Alice wins the battle (inactivity for Bob), we skip ahead
        mockRNG.setRNG(1); // No extra bonus for points
        vm.warp(block.timestamp + 1);
        engine.end(battleKey);

        // Assert Alice won
        assertEq(engine.getWinner(battleKey), ALICE);

        // Verify points are correct (includes first-game bonus of ROLL_COST)
        assertEq(gachaRegistry.pointsBalance(ALICE), gachaRegistry.ROLL_COST() + gachaRegistry.POINTS_PER_WIN());
        assertEq(gachaRegistry.pointsBalance(BOB), gachaRegistry.ROLL_COST() + gachaRegistry.POINTS_PER_LOSS());
    }

    function test_spendPoints() public {
        GachaRegistry gachaRegistry = new GachaRegistry(monRegistry, engine, mockRNG);

        // Set up mon IDs 0 to INITIAL ROLLS + 1
        for (uint256 i = 0; i < gachaRegistry.INITIAL_ROLLS(); i++) {
            monRegistry.createMon(
                i,
                MonStats({
                    hp: 10,
                    stamina: 2,
                    speed: 2,
                    attack: 1,
                    defense: 1,
                    specialAttack: 1,
                    specialDefense: 1,
                    type1: Type.Fire,
                    type2: Type.None
                }),
                new uint256[](0),
                new uint256[](0),
                new bytes32[](0),
                new bytes32[](0)
            );
        }

        // Start battle - with first-game bonus, one battle is enough to roll
        Mon[] memory team = new Mon[](1);
        team[0] = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);
        DefaultValidator validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 0, TIMEOUT_DURATION: 0})
        );
        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;
        bytes32 battleKey =
            _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        // Alice commits switching to mon index 0
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint240(0))));

        // Alice wins the battle
        engine.end(battleKey);

        // Assert Alice has enough points to roll
        assertGe(gachaRegistry.pointsBalance(ALICE), gachaRegistry.ROLL_COST());

        // Alice rolls
        vm.startPrank(ALICE);
        // (Do first roll first)
        gachaRegistry.firstRoll();
        vm.expectRevert(GachaRegistry.NoMoreStock.selector);
        uint256[] memory monIds = gachaRegistry.roll(1);
        vm.stopPrank();

        // Add one more mon to the registry and roll again
        monRegistry.createMon(
            gachaRegistry.INITIAL_ROLLS(),
            MonStats({
                hp: 10,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            new uint256[](0),
            new uint256[](0),
            new bytes32[](0),
            new bytes32[](0)
        );
        vm.startPrank(ALICE);
        monIds = gachaRegistry.roll(1);
        assertEq(monIds.length, 1);

        // Verify Alice cannot roll again (should underflow)
        vm.expectRevert();
        gachaRegistry.roll(1);
    }

    function test_firstGameBonusNotReawardedAfterRoll() public {
        // Repro: first battle → roll → second battle. The ROLL_COST first-game
        // bonus must only fire once, even though a roll happens in between.
        GachaRegistry gachaRegistry = new GachaRegistry(monRegistry, engine, mockRNG);

        // One mon in the registry is enough for a single regular roll.
        monRegistry.createMon(
            0,
            MonStats({
                hp: 10,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            new uint256[](0),
            new uint256[](0),
            new bytes32[](0),
            new bytes32[](0)
        );

        Mon[] memory team = new Mon[](1);
        team[0] = Mon({
            stats: MonStats({
                hp: 10,
                stamina: 2,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        DefaultValidator validator =
            new DefaultValidator(engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 0, TIMEOUT_DURATION: 0}));
        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;

        // ---- First battle ----
        bytes32 battleKey =
            _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint240(0))));
        vm.stopPrank();
        mockRNG.setRNG(1);
        engine.end(battleKey);
        assertEq(engine.getWinner(battleKey), ALICE);

        // Alice: ROLL_COST (first-game bonus) + POINTS_PER_WIN
        uint256 alicePointsAfterFirstBattle = gachaRegistry.pointsBalance(ALICE);
        assertEq(alicePointsAfterFirstBattle, gachaRegistry.ROLL_COST() + gachaRegistry.POINTS_PER_WIN());

        // ---- Roll ----
        vm.startPrank(ALICE);
        gachaRegistry.roll(1);
        vm.stopPrank();

        uint256 alicePointsAfterRoll = gachaRegistry.pointsBalance(ALICE);
        assertEq(alicePointsAfterRoll, alicePointsAfterFirstBattle - gachaRegistry.ROLL_COST());

        // ---- Second battle ----
        battleKey =
            _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint240(0))));
        vm.stopPrank();
        mockRNG.setRNG(1);
        engine.end(battleKey);
        assertEq(engine.getWinner(battleKey), ALICE);

        // Second battle awards POINTS_PER_WIN only — the first-game bonus must not fire again.
        assertEq(
            gachaRegistry.pointsBalance(ALICE),
            alicePointsAfterRoll + gachaRegistry.POINTS_PER_WIN()
        );
    }

}

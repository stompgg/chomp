// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Engine.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";

import {DefaultValidator} from "../src/DefaultValidator.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {GachaTeamRegistry} from "../src/teams/GachaTeamRegistry.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";

import "./mocks/TestTeamRegistry.sol";

contract GachaTest is Test, BattleHelper {
    DefaultRandomnessOracle defaultOracle;
    Engine engine;
    DefaultCommitManager commitManager;
    TestTeamRegistry defaultRegistry;
    MockGachaRNG mockRNG;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(0, 0, 0);
        commitManager = new DefaultCommitManager(engine);
        defaultRegistry = new TestTeamRegistry();
        mockRNG = new MockGachaRNG();
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_firstRoll() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG);

        // Need NUM_STARTERS starters + (INITIAL_ROLLS - 1) non-starters = 6 mons minimum.
        uint256 poolSize = gachaRegistry.NUM_STARTERS() + gachaRegistry.INITIAL_ROLLS() - 1;
        for (uint256 i = 0; i < poolSize; i++) {
            gachaRegistry.createMon(
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
        uint256[] memory monIds = gachaRegistry.firstRoll(0);
        assertEq(monIds.length, gachaRegistry.INITIAL_ROLLS());
        assertEq(monIds[0], 0, "starter at index 0");
        for (uint256 i = 1; i < monIds.length; i++) {
            assertGe(monIds[i], gachaRegistry.NUM_STARTERS(), "non-starter range");
        }

        // Alice rolls again, it should fail
        vm.expectRevert(GachaTeamRegistry.AlreadyFirstRolled.selector);
        vm.prank(ALICE);
        gachaRegistry.firstRoll(0);
    }

    function test_firstRoll_invalidStarter_reverts() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG);
        uint256 poolSize = gachaRegistry.NUM_STARTERS() + gachaRegistry.INITIAL_ROLLS() - 1;
        for (uint256 i = 0; i < poolSize; i++) {
            gachaRegistry.createMon(
                i,
                MonStats({
                    hp: 10, stamina: 2, speed: 2, attack: 1, defense: 1,
                    specialAttack: 1, specialDefense: 1, type1: Type.Fire, type2: Type.None
                }),
                new uint256[](0), new uint256[](0), new bytes32[](0), new bytes32[](0)
            );
        }

        // Read NUM_STARTERS first so prank applies to firstRoll, not the constant getter.
        uint256 invalidStarter = gachaRegistry.NUM_STARTERS();
        vm.expectRevert(GachaTeamRegistry.InvalidStarterId.selector);
        vm.prank(ALICE);
        gachaRegistry.firstRoll(invalidStarter);
    }

    function test_firstRoll_emitsRollWithZeroSpend() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG);
        uint256 poolSize = gachaRegistry.NUM_STARTERS() + gachaRegistry.INITIAL_ROLLS() - 1;
        for (uint256 i = 0; i < poolSize; i++) {
            gachaRegistry.createMon(
                i,
                MonStats({
                    hp: 10, stamina: 2, speed: 2, attack: 1, defense: 1,
                    specialAttack: 1, specialDefense: 1, type1: Type.Fire, type2: Type.None
                }),
                new uint256[](0), new uint256[](0), new bytes32[](0), new bytes32[](0)
            );
        }

        // Don't try to match the monIds[] payload — just assert the spend is 0.
        // (Prank-aware emitter; topic is the player.)
        vm.recordLogs();
        vm.prank(ALICE);
        gachaRegistry.firstRoll(0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Find Roll(address,uint256[],uint256). topic0 = keccak("Roll(address,uint256[],uint256)").
        bytes32 rollSig = keccak256("Roll(address,uint256[],uint256)");
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == rollSig) {
                found = true;
                (uint256[] memory ids, uint256 spent) = abi.decode(logs[i].data, (uint256[], uint256));
                assertEq(ids.length, gachaRegistry.INITIAL_ROLLS());
                assertEq(spent, 0, "first roll is free");
            }
        }
        assertTrue(found, "Roll event emitted");
    }

    function test_assignPoints() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG);

        // Set up mon IDs 0 to INITIAL ROLLS
        for (uint256 i = 0; i < gachaRegistry.INITIAL_ROLLS(); i++) {
            gachaRegistry.createMon(
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
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint16(0))));

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
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG);

        // Minimum pool for firstRoll: NUM_STARTERS + INITIAL_ROLLS - 1 = 6.
        uint256 poolSize = gachaRegistry.NUM_STARTERS() + gachaRegistry.INITIAL_ROLLS() - 1;
        for (uint256 i = 0; i < poolSize; i++) {
            gachaRegistry.createMon(
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
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint16(0))));

        // Alice wins the battle
        engine.end(battleKey);

        // Assert Alice has enough points to roll
        assertGe(gachaRegistry.pointsBalance(ALICE), gachaRegistry.ROLL_COST());

        // Alice does her first roll, then a paid roll.
        vm.startPrank(ALICE);
        gachaRegistry.firstRoll(0); // owns starter 0 + 3 non-starters (with mockRNG=0 → ids 3,4,5).
        uint256[] memory monIds = gachaRegistry.roll(1); // costs ROLL_COST, picks unowned id 1 or 2.
        assertEq(monIds.length, 1);

        // Alice has 10 - 7 = 3 points remaining; another roll(1) underflows.
        vm.expectRevert();
        gachaRegistry.roll(1);
        vm.stopPrank();
    }


    function test_firstGameBonusNotReawardedAfterRoll() public {
        // Repro: first battle → roll → second battle. The ROLL_COST first-game
        // bonus must only fire once, even though a roll happens in between.
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG);

        // One mon in the registry is enough for a single regular roll.
        gachaRegistry.createMon(
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
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint16(0))));
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
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint16(0))));
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

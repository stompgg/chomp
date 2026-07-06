// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Engine.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";

import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

import "./mocks/TestTeamRegistry.sol";
import "src/Constants.sol";

contract GachaTest is Test, BattleHelper {
    DefaultRandomnessOracle defaultOracle;
    Engine engine;
    DefaultCommitManager commitManager;
    TestTeamRegistry defaultRegistry;
    MockGachaRNG mockRNG;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(engine);
        defaultRegistry = new TestTeamRegistry();
        mockRNG = new MockGachaRNG();
        matchmaker = new DefaultMatchmaker(engine);
    }

    function test_firstRoll() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));

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
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));
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
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));
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
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));

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
        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;
        bytes32 battleKey = _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));

        // Alice commits switching to mon index 0
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint16(0))));

        // Alice wins the battle (inactivity for Bob), we skip ahead
        mockRNG.setRNG(1); // No extra bonus for points
        vm.warp(block.timestamp + MAX_BATTLE_DURATION + 1);
        engine.end(battleKey);

        // Assert Alice won
        assertEq(engine.getWinner(battleKey), ALICE);

        // First-ever battle: each side gets FIRST_GAME_EVER_BONUS + (base + streak day 1) * 1.
        assertEq(
            gachaRegistry.pointsBalance(ALICE),
            gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_WIN() + 1
        );
        assertEq(
            gachaRegistry.pointsBalance(BOB),
            gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_LOSS() + 1
        );
    }

    function test_spendPoints() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));

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
        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;
        bytes32 battleKey =
            _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + MAX_BATTLE_DURATION + 1);

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
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));

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
        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;

        // ---- First battle ----
        bytes32 battleKey =
            _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));
        vm.warp(vm.getBlockTimestamp() + MAX_BATTLE_DURATION + 1);
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint16(0))));
        vm.stopPrank();
        mockRNG.setRNG(1);
        engine.end(battleKey);
        assertEq(engine.getWinner(battleKey), ALICE);

        // Alice: FIRST_GAME_EVER_BONUS + (POINTS_PER_WIN + streak day 1) * 1
        uint256 alicePointsAfterFirstBattle = gachaRegistry.pointsBalance(ALICE);
        assertEq(
            alicePointsAfterFirstBattle,
            gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_WIN() + 1
        );

        // ---- Roll ----
        vm.startPrank(ALICE);
        gachaRegistry.roll(1);
        vm.stopPrank();

        uint256 alicePointsAfterRoll = gachaRegistry.pointsBalance(ALICE);
        assertEq(alicePointsAfterRoll, alicePointsAfterFirstBattle - gachaRegistry.ROLL_COST());

        // ---- Second battle ----
        battleKey =
            _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));
        vm.warp(vm.getBlockTimestamp() + MAX_BATTLE_DURATION + 1);
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


    /// @dev D24: doubles battles pay the same default rewards through the same gacha hook —
    ///      driven to a real win so onBattleEnd reads doubles KO bitmaps, not a timeout.
    function test_doublesBattlePaysSameDefaultRewards() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));
        TestTypeCalculator typeCalc = new TestTypeCalculator();
        CustomAttack killAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 3})
        );

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(killAttack)));
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 5,
                speed: 2,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Air,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](2);
        team[0] = mon;
        team[1] = mon;
        defaultRegistry.setTeam(ALICE, team);
        defaultRegistry.setTeam(BOB, team);

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(this);
        vm.prank(ALICE);
        engine.updateMatchmakers(toAdd, new address[](0));
        vm.prank(BOB);
        engine.updateMatchmakers(toAdd, new address[](0));

        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;
        (bytes32 battleKey,) = engine.computeBattleKey(ALICE, BOB);
        engine.startBattleWithMode(
            Battle({
                p0: ALICE,
                p0TeamIndex: 0,
                p1: BOB,
                p1TeamIndex: 0,
                teamRegistry: defaultRegistry,
                rngOracle: IRandomnessOracle(address(0)),
                ruleset: IRuleset(address(0)),
                moveManager: address(this),
                matchmaker: IMatchmaker(address(this)),
                engineHooks: hooks
            }),
            BATTLE_MODE_DOUBLES
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        mockRNG.setRNG(1);

        // Turn 0: leads. Turn 1: Alice's two mons KO both of Bob's actives (side wipe).
        uint104 salt = uint104(0xD0B);
        engine.executeWithSlotMoves(
            battleKey,
            uint256(SWITCH_MOVE_INDEX) | (uint256(SWITCH_MOVE_INDEX) << 24) | (uint256(1) << 32) | (uint256(salt) << 48),
            uint256(SWITCH_MOVE_INDEX) | (uint256(SWITCH_MOVE_INDEX) << 24) | (uint256(1) << 32) | (uint256(salt) << 48)
        );
        uint16 targetB0 = uint16(uint256(1) << (TARGET_BITS_SHIFT + 2));
        uint16 targetB1 = uint16(uint256(1) << (TARGET_BITS_SHIFT + 3));
        address winner = engine.executeWithSlotMoves(
            battleKey,
            uint256(0) | (uint256(targetB0) << 8) | (uint256(0) << 24) | (uint256(targetB1) << 32) | (uint256(salt) << 48),
            uint256(NO_OP_MOVE_INDEX) | (uint256(NO_OP_MOVE_INDEX) << 24) | (uint256(salt) << 48)
        );
        assertEq(winner, ALICE);

        // Same default formulas as singles: first-game bonus + (base + streak day 1) * 1.
        assertEq(
            gachaRegistry.pointsBalance(ALICE),
            gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_WIN() + 1
        );
        assertEq(
            gachaRegistry.pointsBalance(BOB),
            gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_LOSS() + 1
        );
    }
}

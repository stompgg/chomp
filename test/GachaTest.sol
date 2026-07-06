// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Engine.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";

import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {GachaTeamRegistry} from "../src/game-layer/GachaTeamRegistry.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {MockGachaRNG} from "./mocks/MockGachaRNG.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

import {defaultBattle, sideWord, targetBits} from "./abstract/SlotWire.sol";
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
        bytes32 battleKey =
            _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));

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
            alicePointsAfterFirstBattle, gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_WIN() + 1
        );

        // ---- Roll ----
        vm.startPrank(ALICE);
        gachaRegistry.roll(1);
        vm.stopPrank();

        uint256 alicePointsAfterRoll = gachaRegistry.pointsBalance(ALICE);
        assertEq(alicePointsAfterRoll, alicePointsAfterFirstBattle - gachaRegistry.ROLL_COST());

        // ---- Second battle ----
        battleKey = _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, hooks, address(commitManager));
        vm.warp(vm.getBlockTimestamp() + MAX_BATTLE_DURATION + 1);
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, bytes32(""), uint16(0))));
        vm.stopPrank();
        mockRNG.setRNG(1);
        engine.end(battleKey);
        assertEq(engine.getWinner(battleKey), ALICE);

        // Second battle awards POINTS_PER_WIN only — the first-game bonus must not fire again.
        assertEq(gachaRegistry.pointsBalance(ALICE), alicePointsAfterRoll + gachaRegistry.POINTS_PER_WIN());
    }

    /// @dev D24: doubles battles pay the same default rewards through the same gacha hook —
    ///      driven to a real win so onBattleEnd reads doubles KO bitmaps, not a timeout.
    function test_doublesBattlePaysSameDefaultRewards() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));
        TestTypeCalculator typeCalc = new TestTypeCalculator();
        CustomAttack killAttack = new CustomAttack(
            typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 3})
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
        Battle memory battle = defaultBattle(ALICE, BOB, defaultRegistry, address(this), IMatchmaker(address(this)));
        battle.engineHooks = hooks;
        engine.startBattleWithMode(battle, BATTLE_MODE_DOUBLES);
        vm.warp(vm.getBlockTimestamp() + 1);
        mockRNG.setRNG(1);

        // Turn 0: leads. Turn 1: Alice's two mons KO both of Bob's actives (side wipe).
        uint104 salt = uint104(0xD0B);
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, salt),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, salt)
        );
        uint16 targetB0 = targetBits(2);
        uint16 targetB1 = targetBits(3);
        address winner = engine.executeWithSlotMoves(
            battleKey,
            sideWord(0, targetB0, 0, targetB1, salt),
            sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, salt)
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

    address constant CARL = address(0x3);
    address constant DAVE = address(0x4);

    /// @dev Multi battle setup shared by the rewards tests: ALICE+CARL (side 0, killers) vs
    ///      BOB+DAVE (side 1). Returns the pre-start battle key.
    function _startMultiWithGachaHook(GachaTeamRegistry gachaRegistry) internal returns (bytes32 battleKey) {
        TestTypeCalculator typeCalc = new TestTypeCalculator();
        CustomAttack killAttack = new CustomAttack(
            typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 3})
        );
        CustomAttack weakAttack = new CustomAttack(
            typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 3})
        );

        address[4] memory seats = [ALICE, BOB, CARL, DAVE];
        for (uint256 i; i < 4; ++i) {
            Mon[] memory team = new Mon[](4);
            for (uint256 j; j < 4; ++j) {
                uint256[] memory moves = new uint256[](1);
                moves[0] = uint256(uint160(address(i % 2 == 0 ? killAttack : weakAttack)));
                team[j] = Mon({
                    stats: MonStats({
                        hp: i % 2 == 0 ? 1000 : 100,
                        stamina: 5,
                        speed: i % 2 == 0 ? 10 : 2,
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
            }
            defaultRegistry.setTeam(seats[i], team);
            address[] memory toAdd = new address[](1);
            toAdd[0] = address(this);
            vm.prank(seats[i]);
            engine.updateMatchmakers(toAdd, new address[](0));
        }

        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;
        (battleKey,) = engine.computePartyKey(ALICE, BOB, CARL, DAVE);
        Battle memory battle = defaultBattle(ALICE, BOB, defaultRegistry, address(this), IMatchmaker(address(this)));
        battle.p2 = CARL;
        battle.p3 = DAVE;
        battle.engineHooks = hooks;
        engine.startBattleWithMode(battle, BATTLE_MODE_MULTI);
        vm.warp(vm.getBlockTimestamp() + 1);
        mockRNG.setRNG(1);
    }

    /// @dev Drives side 0 through a full side-1 wipe (4 kill rounds x 2 mons, forced switches
    ///      stepping through each seat quarter).
    function _runMultiSideWipe(bytes32 battleKey) internal {
        uint16 targetB0 = targetBits(2);
        uint16 targetB1 = targetBits(3);
        uint104 salt = uint104(0xD0B);
        // Turn 0: all four slots send in their quarter leads (0 and 4).
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, salt),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, salt)
        );
        for (uint256 round; round < 4; ++round) {
            engine.executeWithSlotMoves(
                battleKey,
                sideWord(0, targetB0, 0, targetB1, salt),
                sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, salt)
            );
            if (engine.getWinner(battleKey) != address(0)) break;
            engine.executeWithSlotMoves(
                battleKey,
                sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, salt),
                sideWord(SWITCH_MOVE_INDEX, uint16(round + 1), SWITCH_MOVE_INDEX, uint16(round + 5), salt)
            );
        }
        assertEq(engine.getWinner(battleKey), ALICE);
    }

    /// @dev Finds the single GachaMultiEvent in the recorded logs and pins all four lanes.
    function _assertGachaMultiEvent(
        address emitter,
        bytes32 battleKey,
        uint256 lane0,
        uint256 lane1,
        uint256 lane2,
        uint256 lane3
    ) internal {
        _assertGachaMultiEventMasked(emitter, battleKey, [lane0, lane1, lane2, lane3], type(uint256).max);
    }

    function _assertGachaMultiEventMasked(address emitter, bytes32 battleKey, uint256[4] memory lanes, uint256 mask)
        internal
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("GachaMultiEvent(bytes32,uint256,uint256,uint256,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != emitter || logs[i].topics[0] != topic) continue;
            assertEq(logs[i].topics[1], battleKey);
            (uint256 s0, uint256 s1, uint256 s2, uint256 s3) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertEq(s0 & mask, lanes[0] & mask, "seat 0 lane");
            assertEq(s1 & mask, lanes[1] & mask, "seat 1 lane");
            assertEq(s2 & mask, lanes[2] & mask, "seat 2 lane");
            assertEq(s3 & mask, lanes[3] & mask, "seat 3 lane");
            ++found;
        }
        assertEq(found, 1, "exactly one GachaMultiEvent");
    }

    /// @dev D24: every human seat gets the singles formulas; KO/exp slices come from the
    ///      seat's quarter. Exact GachaMultiEvent lanes pinned (exp lanes empty: 0-mon walk).
    function test_multiBattlePaysPerSeatRewards() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));
        bytes32 battleKey = _startMultiWithGachaHook(gachaRegistry);

        // Lane = points | bonus(FIRST_ROLL|FIRST_GAME = 3) << 176 | expMult(2) << 184
        //        | outcome << 192 | streakDay(1) << 200.
        uint256 winPts = gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_WIN() + 1;
        uint256 lossPts = gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_LOSS() + 1;
        uint256 winLane = winPts | (uint256(3) << 176) | (uint256(2) << 184) | (uint256(1) << 192) | (uint256(1) << 200);
        uint256 lossLane = lossPts | (uint256(3) << 176) | (uint256(2) << 184) | (uint256(1) << 200);

        vm.recordLogs();
        _runMultiSideWipe(battleKey);
        _assertGachaMultiEvent(address(gachaRegistry), battleKey, winLane, winLane, lossLane, lossLane);

        assertEq(gachaRegistry.pointsBalance(ALICE), winPts);
        assertEq(gachaRegistry.pointsBalance(CARL), winPts);
        assertEq(gachaRegistry.pointsBalance(BOB), lossPts);
        assertEq(gachaRegistry.pointsBalance(DAVE), lossPts);
    }

    /// @dev CPU seats short-circuit: no playerData writes, zero event lane; human teammates
    ///      and opponents settle normally.
    function test_multiBattleCpuSeatGetsNothing() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(0, 0, engine, mockRNG, GachaTeamRegistry(address(0)));
        address[] memory cpus = new address[](1);
        cpus[0] = DAVE;
        gachaRegistry.setWhitelistedOpponents(cpus, new address[](0));

        bytes32 battleKey = _startMultiWithGachaHook(gachaRegistry);

        uint256 winPts = gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_WIN() + 1;
        uint256 lossPts = gachaRegistry.FIRST_GAME_EVER_BONUS() + gachaRegistry.POINTS_PER_LOSS() + 1;
        uint256 winLane = winPts | (uint256(3) << 176) | (uint256(2) << 184) | (uint256(1) << 192) | (uint256(1) << 200);
        uint256 lossLane = lossPts | (uint256(3) << 176) | (uint256(2) << 184) | (uint256(1) << 200);

        vm.recordLogs();
        _runMultiSideWipe(battleKey);
        _assertGachaMultiEvent(address(gachaRegistry), battleKey, winLane, winLane, lossLane, 0);

        assertEq(gachaRegistry.pointsBalance(DAVE), 0, "CPU seat earns nothing");
        assertEq(gachaRegistry.pointsBalance(BOB), lossPts, "human teammate of a CPU still settles");
    }

    /// @dev Pins the per-seat KO quarter slice via the event exp lanes: BOB's fast lead KOs
    ///      CARL's lead (side-0 roster 4) before dying, so the two winning seats report
    ///      different exp — ALICE all-alive (6s), CARL one KO lane (4). A full wipe alone
    ///      cannot catch a wrong slice (both loser quarters read 0xF either way). Facet-draw
    ///      lane bits [80,176) are masked (exp on the shared unregistered mon crosses levels).
    function test_multiBattleExpSlicesPerSeatQuarter() public {
        GachaTeamRegistry gachaRegistry = new GachaTeamRegistry(4, 4, engine, mockRNG, GachaTeamRegistry(address(0)));
        TestTypeCalculator typeCalc = new TestTypeCalculator();
        CustomAttack killAttack = new CustomAttack(
            typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 3})
        );

        address[4] memory seats = [ALICE, BOB, CARL, DAVE];
        for (uint256 i; i < 4; ++i) {
            Mon[] memory team = new Mon[](4);
            for (uint256 j; j < 4; ++j) {
                uint256[] memory moves = new uint256[](1);
                moves[0] = uint256(uint160(address(killAttack)));
                // ALICE: fast tanks. CARL: fragile teammates. BOB: fast-lead glass cannons
                // (only mon 0 outspeeds side 0). DAVE: slow fodder.
                uint32 speed = i == 1 && j == 0 ? 50 : (i == 0 || i == 2 ? 10 : 2);
                team[j] = Mon({
                    stats: MonStats({
                        hp: i == 0 ? 1000 : 100,
                        stamina: 5,
                        speed: speed,
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
            }
            defaultRegistry.setTeam(seats[i], team);
            address[] memory toAdd = new address[](1);
            toAdd[0] = address(this);
            vm.prank(seats[i]);
            engine.updateMatchmakers(toAdd, new address[](0));
        }

        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaRegistry;
        (bytes32 battleKey,) = engine.computePartyKey(ALICE, BOB, CARL, DAVE);
        Battle memory battle = defaultBattle(ALICE, BOB, defaultRegistry, address(this), IMatchmaker(address(this)));
        battle.p2 = CARL;
        battle.p3 = DAVE;
        battle.engineHooks = hooks;
        engine.startBattleWithMode(battle, BATTLE_MODE_MULTI);
        vm.warp(vm.getBlockTimestamp() + 1);
        mockRNG.setRNG(1);
        vm.recordLogs();

        uint104 salt = uint104(0xD0B);
        uint16 targetA1 = targetBits(1);
        uint16 targetB0 = targetBits(2);
        uint16 targetB1 = targetBits(3);

        // Turn 0: quarter leads (0 and 4) everywhere.
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, salt),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, salt)
        );

        // Round 1: BOB's speed-50 lead KOs CARL's lead first; side 0 then KOs it back. A1 is
        // dead before acting so B1 survives the round.
        engine.executeWithSlotMoves(
            battleKey, sideWord(0, targetB0, 0, targetB1, salt), sideWord(0, targetA1, NO_OP_MOVE_INDEX, 0, salt)
        );
        // Forced switches: A slot 1 refills from CARL's quarter (5), B slot 0 from BOB's (1).
        engine.executeWithSlotMoves(
            battleKey,
            sideWord(NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 5, salt),
            sideWord(SWITCH_MOVE_INDEX, 1, NO_OP_MOVE_INDEX, 0, salt)
        );

        // Side 1 remaining: 1,2,3 (BOB) + 4..7 (DAVE); actives (1, 4). Kill rounds (1,4)
        // (2,5) (3,6) then 7; replacements are uniformly (round+2, round+5) — the final
        // forced turn's slot-0 lane is ignored (BOB's quarter is spent, slot skipped).
        for (uint256 round; round < 4; ++round) {
            engine.executeWithSlotMoves(
                battleKey,
                sideWord(0, targetB0, 0, targetB1, salt),
                sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, salt)
            );
            if (engine.getWinner(battleKey) != address(0)) break;
            engine.executeWithSlotMoves(
                battleKey,
                sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, salt),
                sideWord(SWITCH_MOVE_INDEX, uint16(round + 2), SWITCH_MOVE_INDEX, uint16(round + 5), salt)
            );
        }
        assertEq(engine.getWinner(battleKey), ALICE);

        // Exp bytes (lanes at bit 16, 8b each): alive = (2 + streak 1) * 2 = 6, KO = (1+1)*2 = 4.
        uint256 winPts = 16 + 2 + 1;
        uint256 lossPts = 16 + 1 + 1;
        uint256 aliceLane = winPts | (uint256(0x06060606) << 16) | (uint256(3) << 176) | (uint256(2) << 184)
            | (uint256(1) << 192) | (uint256(1) << 200);
        uint256 carlLane = winPts | (uint256(0x06060604) << 16) | (uint256(3) << 176) | (uint256(2) << 184)
            | (uint256(1) << 192) | (uint256(1) << 200);
        uint256 loserLane =
            lossPts | (uint256(0x04040404) << 16) | (uint256(3) << 176) | (uint256(2) << 184) | (uint256(1) << 200);
        uint256 facetLaneMask = ~(((uint256(1) << 96) - 1) << 80);
        _assertGachaMultiEventMasked(
            address(gachaRegistry), battleKey, [aliceLane, carlLane, loserLane, loserLane], facetLaneMask
        );
    }
}

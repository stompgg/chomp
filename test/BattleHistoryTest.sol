// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {IAbility} from "../src/abilities/IAbility.sol";

import {BattleHistory} from "../src/hooks/BattleHistory.sol";

contract BattleHistoryTest is Test, BattleHelper {
    uint256 constant TIMEOUT = 10;
    address constant CAROL = address(0x3);

    DefaultCommitManager commitManager;
    Engine engine;
    DefaultValidator validator;
    ITypeCalculator typeCalc;
    DefaultRandomnessOracle defaultOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    BattleHistory battleHistory;

    IMoveSet simpleAttack;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine();
        commitManager = new DefaultCommitManager(engine);
        validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: TIMEOUT})
        );
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
        battleHistory = new BattleHistory(engine);

        // Create a simple attack that deals 1 damage (enough to KO a mon with 1 HP)
        simpleAttack = new CustomAttack(
            engine, typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 0})
        );

        // Setup matchmakers for all players
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);

        vm.startPrank(ALICE);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.startPrank(BOB);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.startPrank(CAROL);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.stopPrank();
    }

    /// @notice Helper to create a mon with specific speed
    function _createMon(uint32 speed, uint32 hp) internal view returns (Mon memory) {
        IMoveSet[] memory moves = new IMoveSet[](1);
        moves[0] = simpleAttack;

        return Mon({
            stats: MonStats({
                hp: hp,
                stamina: 10,
                speed: speed,
                attack: 10,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: IAbility(address(0))
        });
    }

    /// @notice Helper to start a battle between two players with custom speeds
    function _startCustomBattle(address p0, address p1, uint32 p0Speed, uint32 p1Speed) internal returns (bytes32) {
        // Create mons with specified speeds - faster mon will win
        Mon memory p0Mon = _createMon(p0Speed, 10);
        Mon memory p1Mon = _createMon(p1Speed, 10);

        Mon[] memory p0Team = new Mon[](1);
        Mon[] memory p1Team = new Mon[](1);
        p0Team[0] = p0Mon;
        p1Team[0] = p1Mon;

        defaultRegistry.setTeam(p0, p0Team);
        defaultRegistry.setTeam(p1, p1Team);

        // Create hooks array with BattleHistory
        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = IEngineHook(address(battleHistory));

        // Setup and start battle
        vm.startPrank(p0);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        // Compute p0 team hash
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(p0, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: p0,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: p1,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: hooks,
            moveManager: address(commitManager),
            matchmaker: matchmaker,
            gameMode: GameMode.Singles
        });

        // Propose battle
        vm.startPrank(p0);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(p1);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        // Confirm and start battle
        vm.startPrank(p0);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);

        // Advance time to avoid GameStartsAndEndsSameBlock error
        vm.warp(vm.getBlockTimestamp() + 1);

        return battleKey;
    }

    /// @notice Helper to commit, reveal, and execute moves for any two players
    function _commitRevealExecute(
        bytes32 battleKey,
        address p0,
        address p1,
        uint8 p0MoveIndex,
        uint8 p1MoveIndex,
        uint240 p0ExtraData,
        uint240 p1ExtraData
    ) internal {
        bytes32 salt = "";
        bytes32 p0MoveHash = keccak256(abi.encodePacked(p0MoveIndex, salt, p0ExtraData));
        bytes32 p1MoveHash = keccak256(abi.encodePacked(p1MoveIndex, salt, p1ExtraData));

        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        if (turnId % 2 == 0) {
            vm.startPrank(p0);
            commitManager.commitMove(battleKey, p0MoveHash);
            vm.startPrank(p1);
            commitManager.revealMove(battleKey, p1MoveIndex, salt, p1ExtraData, true);
            vm.startPrank(p0);
            commitManager.revealMove(battleKey, p0MoveIndex, salt, p0ExtraData, true);
        } else {
            vm.startPrank(p1);
            commitManager.commitMove(battleKey, p1MoveHash);
            vm.startPrank(p0);
            commitManager.revealMove(battleKey, p0MoveIndex, salt, p0ExtraData, true);
            vm.startPrank(p1);
            commitManager.revealMove(battleKey, p1MoveIndex, salt, p1ExtraData, true);
        }
    }

    /// @notice Helper to complete a battle
    function _completeBattle(bytes32 battleKey) internal {
        (, BattleData memory battleData) = engine.getBattle(battleKey);

        // First move - both players switch to their mon
        _commitRevealExecute(
            battleKey, battleData.p0, battleData.p1, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
        );

        // Second move - both attack (faster mon wins)
        _commitRevealExecute(battleKey, battleData.p0, battleData.p1, 0, 0, 0, 0);
    }

    function test_BattleHistoryOnlyUpdatesWhenCompleted() public {
        // Start battle between Alice (speed 2) and Bob (speed 1)
        // Alice should win because she's faster
        bytes32 battleKey = _startCustomBattle(ALICE, BOB, 2, 1);

        // Check that battle stats are 0 before battle completion
        assertEq(battleHistory.getNumBattles(ALICE), 0, "Alice should have 0 battles before completion");
        assertEq(battleHistory.getNumBattles(BOB), 0, "Bob should have 0 battles before completion");

        // First turn - both switch to their mons
        _commitRevealExecute(battleKey, ALICE, BOB, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));

        // Stats should still be 0 after first turn
        assertEq(battleHistory.getNumBattles(ALICE), 0, "Alice should have 0 battles after switch");
        assertEq(battleHistory.getNumBattles(BOB), 0, "Bob should have 0 battles after switch");

        // Second turn - both attack (Alice wins)
        _commitRevealExecute(battleKey, ALICE, BOB, 0, 0, 0, 0);

        // Now stats should be updated
        assertEq(battleHistory.getNumBattles(ALICE), 1, "Alice should have 1 battle after completion");
        assertEq(battleHistory.getNumBattles(BOB), 1, "Bob should have 1 battle after completion");

        // Verify winner
        assertEq(engine.getWinner(battleKey), ALICE, "Alice should be the winner");
    }

    function test_GetNumBattlesTracksCorrectly() public {
        // Initial state - no battles
        assertEq(battleHistory.getNumBattles(ALICE), 0);
        assertEq(battleHistory.getNumBattles(BOB), 0);
        assertEq(battleHistory.getNumBattles(CAROL), 0);

        // Battle 1: Alice vs Bob (Alice wins with speed 2 > 1)
        bytes32 battleKey1 = _startCustomBattle(ALICE, BOB, 2, 1);
        _completeBattle(battleKey1);

        assertEq(battleHistory.getNumBattles(ALICE), 1);
        assertEq(battleHistory.getNumBattles(BOB), 1);
        assertEq(battleHistory.getNumBattles(CAROL), 0);

        // Battle 2: Alice vs Carol (Carol wins with speed 3 > 2)
        bytes32 battleKey2 = _startCustomBattle(ALICE, CAROL, 2, 3);
        _completeBattle(battleKey2);

        assertEq(battleHistory.getNumBattles(ALICE), 2);
        assertEq(battleHistory.getNumBattles(BOB), 1);
        assertEq(battleHistory.getNumBattles(CAROL), 1);

        // Battle 3: Bob vs Carol (Bob wins with speed 4 > 3)
        bytes32 battleKey3 = _startCustomBattle(BOB, CAROL, 4, 3);
        _completeBattle(battleKey3);

        assertEq(battleHistory.getNumBattles(ALICE), 2);
        assertEq(battleHistory.getNumBattles(BOB), 2);
        assertEq(battleHistory.getNumBattles(CAROL), 2);
    }

    function test_GetBattleSummaryTracksWinsAndLosses() public {
        // Battle 1: Alice vs Bob (Alice wins - speed 2 > 1)
        bytes32 battleKey1 = _startCustomBattle(ALICE, BOB, 2, 1);
        _completeBattle(battleKey1);

        (uint256 totalBattles1, uint256 aliceWins1) = battleHistory.getBattleSummary(ALICE, BOB);
        assertEq(totalBattles1, 1, "Should have 1 total battle");
        assertEq(aliceWins1, 1, "Alice should have 1 win");

        // Check from Bob's perspective
        (uint256 totalBattles1Bob, uint256 bobWins1) = battleHistory.getBattleSummary(BOB, ALICE);
        assertEq(totalBattles1Bob, 1, "Should have 1 total battle from Bob's perspective");
        assertEq(bobWins1, 0, "Bob should have 0 wins");

        // Battle 2: Alice vs Bob (Bob wins - speed 1 > 0)
        bytes32 battleKey2 = _startCustomBattle(ALICE, BOB, 0, 1);
        _completeBattle(battleKey2);

        (uint256 totalBattles2, uint256 aliceWins2) = battleHistory.getBattleSummary(ALICE, BOB);
        assertEq(totalBattles2, 2, "Should have 2 total battles");
        assertEq(aliceWins2, 1, "Alice should still have 1 win");

        // Check from Bob's perspective
        (uint256 totalBattles2Bob, uint256 bobWins2) = battleHistory.getBattleSummary(BOB, ALICE);
        assertEq(totalBattles2Bob, 2, "Should have 2 total battles from Bob's perspective");
        assertEq(bobWins2, 1, "Bob should have 1 win now");

        // Battle 3: Alice vs Bob (Alice wins - speed 5 > 1)
        bytes32 battleKey3 = _startCustomBattle(ALICE, BOB, 5, 1);
        _completeBattle(battleKey3);

        (uint256 totalBattles3, uint256 aliceWins3) = battleHistory.getBattleSummary(ALICE, BOB);
        assertEq(totalBattles3, 3, "Should have 3 total battles");
        assertEq(aliceWins3, 2, "Alice should have 2 wins");

        // Check from Bob's perspective
        (uint256 totalBattles3Bob, uint256 bobWins3) = battleHistory.getBattleSummary(BOB, ALICE);
        assertEq(totalBattles3Bob, 3, "Should have 3 total battles from Bob's perspective");
        assertEq(bobWins3, 1, "Bob should still have 1 win");
    }

    function test_MultiplePlayersIndependentSummaries() public {
        // Alice vs Bob (Alice wins)
        bytes32 battleKey1 = _startCustomBattle(ALICE, BOB, 2, 1);
        _completeBattle(battleKey1);

        // Alice vs Carol (Carol wins)
        bytes32 battleKey2 = _startCustomBattle(ALICE, CAROL, 1, 2);
        _completeBattle(battleKey2);

        // Bob vs Carol (Bob wins)
        bytes32 battleKey3 = _startCustomBattle(BOB, CAROL, 2, 1);
        _completeBattle(battleKey3);

        // Check Alice vs Bob
        (uint256 aliceBobTotal, uint256 aliceVsBobWins) = battleHistory.getBattleSummary(ALICE, BOB);
        assertEq(aliceBobTotal, 1);
        assertEq(aliceVsBobWins, 1);

        // Check Alice vs Carol
        (uint256 aliceCarolTotal, uint256 aliceVsCarolWins) = battleHistory.getBattleSummary(ALICE, CAROL);
        assertEq(aliceCarolTotal, 1);
        assertEq(aliceVsCarolWins, 0);

        // Check Bob vs Carol
        (uint256 bobCarolTotal, uint256 bobVsCarolWins) = battleHistory.getBattleSummary(BOB, CAROL);
        assertEq(bobCarolTotal, 1);
        assertEq(bobVsCarolWins, 1);

        // Verify total battle counts
        assertEq(battleHistory.getNumBattles(ALICE), 2);
        assertEq(battleHistory.getNumBattles(BOB), 2);
        assertEq(battleHistory.getNumBattles(CAROL), 2);
    }

    function test_OpponentTrackingFunctions() public {
        // Initially, no opponents
        assertEq(battleHistory.getNumOpponents(ALICE), 0);
        (uint256 aliceBobBattles, ) = battleHistory.getBattleSummary(ALICE, BOB);
        assertEq(aliceBobBattles, 0);

        // Alice fights Bob
        bytes32 battleKey1 = _startCustomBattle(ALICE, BOB, 2, 1);
        _completeBattle(battleKey1);

        assertEq(battleHistory.getNumOpponents(ALICE), 1);
        assertEq(battleHistory.getNumOpponents(BOB), 1);
        (aliceBobBattles, ) = battleHistory.getBattleSummary(ALICE, BOB);
        assertGt(aliceBobBattles, 0);
        (uint256 bobAliceBattles, ) = battleHistory.getBattleSummary(BOB, ALICE);
        assertGt(bobAliceBattles, 0);

        // Alice fights Carol
        bytes32 battleKey2 = _startCustomBattle(ALICE, CAROL, 2, 1);
        _completeBattle(battleKey2);

        assertEq(battleHistory.getNumOpponents(ALICE), 2);
        assertEq(battleHistory.getNumOpponents(BOB), 1);
        assertEq(battleHistory.getNumOpponents(CAROL), 1);
        (uint256 aliceCarolBattles, ) = battleHistory.getBattleSummary(ALICE, CAROL);
        assertGt(aliceCarolBattles, 0);
        (uint256 bobCarolBattles, ) = battleHistory.getBattleSummary(BOB, CAROL);
        assertEq(bobCarolBattles, 0);

        // Check opponent lists
        address[] memory aliceOpponents = battleHistory.getOpponents(ALICE);
        assertEq(aliceOpponents.length, 2);

        // Alice fought Bob twice - should still only have 2 unique opponents
        bytes32 battleKey3 = _startCustomBattle(ALICE, BOB, 2, 1);
        _completeBattle(battleKey3);

        assertEq(battleHistory.getNumOpponents(ALICE), 2, "Alice should still have 2 unique opponents");
    }
}

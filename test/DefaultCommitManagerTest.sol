// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

contract DefaultCommitManagerTest is Test, BattleHelper {
    address constant CARL = address(3);
    uint256 constant TIMEOUT = 10;

    DefaultCommitManager commitManager;
    Engine engine;
    ITypeCalculator typeCalc;
    DefaultRandomnessOracle defaultOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(engine);
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);

        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);

        vm.startPrank(ALICE);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.startPrank(BOB);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        uint256[] memory moves = new uint256[](0);
        Mon memory dummyMon = Mon({
            stats: MonStats({
                hp: 1,
                stamina: 1,
                speed: 1,
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
        Mon[] memory dummyTeam = new Mon[](1);
        dummyTeam[0] = dummyMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, dummyTeam);
        defaultRegistry.setTeam(BOB, dummyTeam);
    }

    function test_cannotCommitForArbitraryBattleKey() public {
        bytes32 battleKey = _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        vm.startPrank(CARL);
        vm.expectRevert(DefaultCommitManager.NotP0OrP1.selector);
        commitManager.commitMove(battleKey, "");
    }

    function test_NotYetRevealed() public {
        bytes32 battleKey = _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));

        // Alice commits
        vm.startPrank(ALICE);
        uint8 moveIndex = SWITCH_MOVE_INDEX;
        bytes32 moveHash = keccak256(abi.encodePacked(moveIndex, uint104(0), uint16(0)));
        commitManager.commitMove(battleKey, moveHash);

        // Alice tries to reveal
        vm.expectRevert(DefaultCommitManager.NotYetRevealed.selector);
        commitManager.revealMove(battleKey, moveIndex, uint104(0), uint16(0), false);
    }

    function test_RevealBeforeSelfCommit() public {
        bytes32 battleKey = _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        // Alice sets commitment
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        // Bob sets commitment
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        // Alice sets commitment
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        // Bob sets commitment
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, NO_OP_MOVE_INDEX, NO_OP_MOVE_INDEX, 0, 0);
        // Alice's turn again to move
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultCommitManager.RevealBeforeSelfCommit.selector);
        commitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0, false);
    }

    function test_BattleNotYetStarted() public {
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        commitManager.revealMove(bytes32(0), NO_OP_MOVE_INDEX, uint104(0), 0, false);
        vm.startPrank(BOB);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        commitManager.commitMove(bytes32(0), bytes32(0));
    }

    function test_BattleAlreadyComplete() public {
        vm.warp(1);
        bytes32 battleKey = _startBattle(engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        // Run past MAX_BATTLE_DURATION so anyone can force-end the stalled battle (awards p0).
        vm.warp(MAX_BATTLE_DURATION + 2);
        engine.end(battleKey);
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultCommitManager.BattleAlreadyComplete.selector);
        commitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, uint104(0), 0, false);
        vm.startPrank(BOB);
        vm.expectRevert(DefaultCommitManager.BattleAlreadyComplete.selector);
        commitManager.commitMove(battleKey, bytes32(0));
    }

}

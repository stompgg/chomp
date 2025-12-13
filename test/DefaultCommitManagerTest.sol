// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
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
    DefaultValidator validator;
    ITypeCalculator typeCalc;
    DefaultRandomnessOracle defaultOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine();
        commitManager = new DefaultCommitManager(engine);
        validator = new DefaultValidator(
            engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 0, TIMEOUT_DURATION: TIMEOUT})
        );
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
        IMoveSet[] memory moves = new IMoveSet[](0);
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
            ability: IAbility(address(0))
        });
        Mon[] memory dummyTeam = new Mon[](1);
        dummyTeam[0] = dummyMon;

        // Register teams
        defaultRegistry.setTeam(ALICE, dummyTeam);
        defaultRegistry.setTeam(BOB, dummyTeam);
    }

    function test_cannotCommitForArbitraryBattleKey() public {
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        vm.startPrank(CARL);
        vm.expectRevert(DefaultCommitManager.NotP0OrP1.selector);
        commitManager.commitMove(battleKey, "");
    }

    function test_NotYetRevealed() public {
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));

        // Alice commits
        vm.startPrank(ALICE);
        uint8 moveIndex = SWITCH_MOVE_INDEX;
        bytes32 moveHash = keccak256(abi.encodePacked(moveIndex, bytes32(""), uint240(0)));
        commitManager.commitMove(battleKey, moveHash);

        // Alice tries to reveal
        vm.expectRevert(DefaultCommitManager.NotYetRevealed.selector);
        commitManager.revealMove(battleKey, moveIndex, bytes32(""), uint240(0), false);
    }

    function test_RevealBeforeSelfCommit() public {
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        // Alice sets commitment
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0)
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
        commitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(""), 0, false);
    }

    function test_BattleNotYetStarted() public {
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        commitManager.revealMove(bytes32(0), NO_OP_MOVE_INDEX, bytes32(""), 0, false);
        vm.startPrank(BOB);
        vm.expectRevert(DefaultCommitManager.BattleNotYetStarted.selector);
        commitManager.commitMove(bytes32(0), bytes32(0));
    }

    function test_BattleAlreadyComplete() public {
        vm.warp(1);
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        vm.warp(TIMEOUT * TIMEOUT);
        engine.end(battleKey);
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultCommitManager.BattleAlreadyComplete.selector);
        commitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, bytes32(""), 0, false);
        vm.startPrank(BOB);
        vm.expectRevert(DefaultCommitManager.BattleAlreadyComplete.selector);
        commitManager.commitMove(battleKey, bytes32(0));
    }

    function test_timeoutIfP0FailsCommit() public {
        vm.warp(1);
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        vm.warp(TIMEOUT * validator.PREV_TURN_MULTIPLIER() + 1);
        engine.end(battleKey);
        assertEq(engine.getWinner(battleKey), BOB);
    }

    function test_timeoutIfP1FailsReveal() public {
        vm.warp(1);
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, bytes32("1"));
        vm.warp(TIMEOUT * validator.PREV_TURN_MULTIPLIER() + 1);
        engine.end(battleKey);
        assertEq(engine.getWinner(battleKey), ALICE);
    }

    function test_timeoutIfP0FailsReveal() public {
        vm.warp(1);
        bytes32 battleKey = _startBattle(validator, engine, defaultOracle, defaultRegistry, matchmaker, address(commitManager));
        vm.startPrank(ALICE);
        commitManager.commitMove(battleKey, bytes32("1"));
        vm.startPrank(BOB);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, bytes32(""), uint240(0), false);
        vm.warp(TIMEOUT * validator.PREV_TURN_MULTIPLIER() + 1);
        engine.end(battleKey);
        assertEq(engine.getWinner(battleKey), BOB);
    }
}

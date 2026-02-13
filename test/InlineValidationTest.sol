// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IValidator} from "../src/IValidator.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {MockRandomnessOracle} from "./mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {TestMoveFactory} from "./mocks/TestMoveFactory.sol";
/// @title Inline Validation Tests
/// @notice Tests that inline validation works correctly when validator is address(0)
contract InlineValidationTest is Test, BattleHelper {
    Engine engine;
    DefaultCommitManager commitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry defaultRegistry;
    DefaultMatchmaker matchmaker;
    TestMoveFactory moveFactory;

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 1;

    address p0 = address(0x1);
    address p1 = address(0x2);

    function setUp() public {

        mockOracle = new MockRandomnessOracle();
        defaultRegistry = new TestTeamRegistry();
        // Create engine with inline validation defaults
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON);
        commitManager = new DefaultCommitManager(engine);
        matchmaker = new DefaultMatchmaker(engine);
        moveFactory = new TestMoveFactory(IEngine(address(engine)));

        _setupTeams();
    }

    function _setupTeams() internal {
        IMoveSet testMove = moveFactory.createMove(MoveClass.Physical, Type.Fire, 10, 10);

        Mon memory mon = _createMon();
        mon.stats.hp = 100;
        mon.stats.stamina = 100;
        mon.stats.speed = 100;
        mon.stats.attack = 100;
        mon.stats.defense = 100;
        mon.stats.specialAttack = 100;
        mon.stats.specialDefense = 100;
        mon.moves = new IMoveSet[](MOVES_PER_MON);
        mon.moves[0] = testMove;

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        team[0] = mon;
        team[1] = mon;

        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        uint256[] memory indices = new uint256[](MONS_PER_TEAM);
        indices[0] = 0;
        indices[1] = 1;
        defaultRegistry.setIndices(indices);
    }

    function _startBattleWithInlineValidation() internal returns (bytes32) {
        vm.startPrank(p0);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(p0, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        // Use address(0) as validator for inline validation
        ProposedBattle memory proposal = ProposedBattle({
            p0: p0,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: p1,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: IValidator(address(0)), // Inline validation!
            rngOracle: mockOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        vm.startPrank(p0);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(p1);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        vm.startPrank(p0);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);

        return battleKey;
    }

    /// @notice Test that inline switch validation works correctly
    function test_inlineValidation_switchWorks() public {
        bytes32 battleKey = _startBattleWithInlineValidation();

        // Both players switch in mon 0
        bytes32 salt = "";
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint240(0)));
        bytes32 p1MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint240(0)));

        vm.startPrank(p0);
        commitManager.commitMove(battleKey, p0MoveHash);

        vm.startPrank(p1);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, false);

        vm.startPrank(p0);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, true);

        // Verify both players have mon 0 active
        uint256 p0ActiveMon = engine.getActiveMonIndexForBattleState(battleKey)[0];
        uint256 p1ActiveMon = engine.getActiveMonIndexForBattleState(battleKey)[1];
        assertEq(p0ActiveMon, 0, "P0 should have mon 0 active");
        assertEq(p1ActiveMon, 0, "P1 should have mon 0 active");
    }

    /// @notice Test that inline move validation works correctly
    function test_inlineValidation_moveWorks() public {
        bytes32 battleKey = _startBattleWithInlineValidation();

        // Both players switch in mon 0
        bytes32 salt = "";
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint240(0)));

        vm.startPrank(p0);
        commitManager.commitMove(battleKey, p0MoveHash);
        vm.startPrank(p1);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, false);
        vm.startPrank(p0);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, true);

        // Now use move 0 (attack)
        bytes32 p0AttackHash = keccak256(abi.encodePacked(uint8(0), salt, uint240(0)));

        vm.startPrank(p1);
        commitManager.commitMove(battleKey, p0AttackHash);
        vm.startPrank(p0);
        commitManager.revealMove(battleKey, 0, salt, 0, false);
        vm.startPrank(p1);
        commitManager.revealMove(battleKey, 0, salt, 0, true);

        // Check that battle advanced (turn should be 2)
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        assertEq(turnId, 2, "Turn should be 2 after switch + attack");
    }

    /// @notice Test that inline validation rejects invalid switch (to already active mon)
    function test_inlineValidation_rejectsInvalidSwitch() public {
        bytes32 battleKey = _startBattleWithInlineValidation();

        // Both players switch in mon 0
        bytes32 salt = "";
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint240(0)));

        vm.startPrank(p0);
        commitManager.commitMove(battleKey, p0MoveHash);
        vm.startPrank(p1);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, false);
        vm.startPrank(p0);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, true);

        // P1 commits turn 1 - try to switch to mon 0 again (invalid - already active)
        // The inline validation should treat this as invalid and fall through
        bytes32 p1InvalidSwitchHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint240(0)));

        vm.startPrank(p1);
        commitManager.commitMove(battleKey, p1InvalidSwitchHash);

        // P0 reveals a valid move
        vm.startPrank(p0);
        commitManager.revealMove(battleKey, NO_OP_MOVE_INDEX, salt, 0, false);

        // P1 reveals invalid switch - should still execute but switch is ignored
        vm.startPrank(p1);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, true);

        // P1's active mon should still be 0 (switch was invalid)
        uint256 p1ActiveMon = engine.getActiveMonIndexForBattleState(battleKey)[1];
        assertEq(p1ActiveMon, 0, "P1 should still have mon 0 active (invalid switch)");
    }

    /// @notice Test multiple turns with inline validation
    function test_inlineValidation_multipleRounds() public {
        bytes32 battleKey = _startBattleWithInlineValidation();
        bytes32 salt = "";

        // Turn 0: Both switch in mon 0
        bytes32 p0MoveHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, salt, uint240(0)));
        vm.startPrank(p0);
        commitManager.commitMove(battleKey, p0MoveHash);
        vm.startPrank(p1);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, false);
        vm.startPrank(p0);
        commitManager.revealMove(battleKey, SWITCH_MOVE_INDEX, salt, 0, true);

        // Run a few attack rounds to verify inline validation works across multiple turns
        for (uint256 i = 0; i < 5; i++) {
            // Check if battle ended
            (, BattleData memory bd) = engine.getBattle(battleKey);
            if (bd.winnerIndex != 2) break;
            // Skip if only one player needs to move (KO occurred)
            if (bd.playerSwitchForTurnFlag != 2) break;

            uint256 turnId = engine.getTurnIdForBattleState(battleKey);
            bytes32 attackHash = keccak256(abi.encodePacked(uint8(0), salt, uint240(0)));

            if (turnId % 2 == 0) {
                vm.startPrank(p0);
                commitManager.commitMove(battleKey, attackHash);
                vm.startPrank(p1);
                commitManager.revealMove(battleKey, 0, salt, 0, false);
                vm.startPrank(p0);
                commitManager.revealMove(battleKey, 0, salt, 0, true);
            } else {
                vm.startPrank(p1);
                commitManager.commitMove(battleKey, attackHash);
                vm.startPrank(p0);
                commitManager.revealMove(battleKey, 0, salt, 0, false);
                vm.startPrank(p1);
                commitManager.revealMove(battleKey, 0, salt, 0, true);
            }
        }

        // Battle should have progressed past turn 1
        uint256 finalTurnId = engine.getTurnIdForBattleState(battleKey);
        assertTrue(finalTurnId > 1, "Battle should have progressed past turn 1");
    }
}

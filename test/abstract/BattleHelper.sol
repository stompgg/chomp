// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import "../../src/Structs.sol";

import {DefaultCommitManager} from "../../src/DefaultCommitManager.sol";
import {Engine} from "../../src/Engine.sol";
import {IEngineHook} from "../../src/IEngineHook.sol";
import {IValidator} from "../../src/IValidator.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";
import {IRandomnessOracle} from "../../src/rng/IRandomnessOracle.sol";
import {ITeamRegistry} from "../../src/teams/ITeamRegistry.sol";

import {Test} from "forge-std/Test.sol";

abstract contract BattleHelper is Test {
    address constant ALICE = address(0x1);
    address constant BOB = address(0x2);

    // Helper function to commit, reveal, and execute moves for both players
    function _commitRevealExecuteForAliceAndBob(
        Engine engine,
        DefaultCommitManager commitManager,
        bytes32 battleKey,
        uint8 aliceMoveIndex,
        uint8 bobMoveIndex,
        uint240 aliceExtraData,
        uint240 bobExtraData
    ) internal {
        bytes32 salt = "";
        bytes32 aliceMoveHash = keccak256(abi.encodePacked(aliceMoveIndex, salt, aliceExtraData));
        bytes32 bobMoveHash = keccak256(abi.encodePacked(bobMoveIndex, salt, bobExtraData));
        // Decide which player commits
        uint256 turnId = engine.getTurnIdForBattleState(battleKey);
        if (turnId % 2 == 0) {
            vm.startPrank(ALICE);
            commitManager.commitMove(battleKey, aliceMoveHash);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, bobMoveIndex, salt, bobExtraData, true);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, aliceMoveIndex, salt, aliceExtraData, true);
        } else {
            vm.startPrank(BOB);
            commitManager.commitMove(battleKey, bobMoveHash);
            vm.startPrank(ALICE);
            commitManager.revealMove(battleKey, aliceMoveIndex, salt, aliceExtraData, true);
            vm.startPrank(BOB);
            commitManager.revealMove(battleKey, bobMoveIndex, salt, bobExtraData, true);
        }
    }

    function _startBattle(
        IValidator validator,
        Engine engine,
        IRandomnessOracle rngOracle,
        ITeamRegistry defaultRegistry,
        DefaultMatchmaker matchmaker,
        address moveManager
    ) internal returns (bytes32) {
        return _startBattle(validator, engine, rngOracle, defaultRegistry, matchmaker, new IEngineHook[](0), moveManager);
    }

    function _startBattle(
        IValidator validator,
        Engine engine,
        IRandomnessOracle rngOracle,
        ITeamRegistry defaultRegistry,
        DefaultMatchmaker matchmaker,
        IEngineHook[] memory engineHooks,
        address moveManager
    ) internal returns (bytes32) {
        return _startBattle(validator, engine, rngOracle, defaultRegistry, matchmaker, engineHooks, IRuleset(address(0)), moveManager);
    }

    function _startBattle(
        IValidator validator,
        Engine engine,
        IRandomnessOracle rngOracle,
        ITeamRegistry defaultRegistry,
        DefaultMatchmaker matchmaker,
        IEngineHook[] memory engineHooks,
        IRuleset ruleset,
        address moveManager
    ) internal returns (bytes32) {
        // Both players authorize the matchmaker
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        vm.startPrank(BOB);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        // Compute p0 team hash
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: rngOracle,
            ruleset: ruleset,
            engineHooks: engineHooks,
            moveManager: moveManager,
            matchmaker: matchmaker
        });

        // Propose battle
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.startPrank(BOB);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        // Confirm and start battle
        vm.startPrank(ALICE);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);

        return battleKey;
    }

    function _createMon() internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 1,
                stamina: 10,
                speed: 1,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: new IMoveSet[](0),
            ability: IAbility(address(0))
        });
    }
}

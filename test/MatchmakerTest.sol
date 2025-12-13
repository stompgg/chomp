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

contract MatchmakerTest is Test, BattleHelper {

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

    function test_P0P1SameError() public {
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: ALICE,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultMatchmaker.P0P1Same.selector);
        matchmaker.proposeBattle(proposal);
    }

    function test_ProposerNotP0() public {
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        uint256[] memory p0TeamIndices = defaultRegistry.getMonRegistryIndicesForTeam(ALICE, p0TeamIndex);
        bytes32 p0TeamHash = keccak256(abi.encodePacked(salt, p0TeamIndex, p0TeamIndices));

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: BOB,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: ALICE,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultMatchmaker.ProposerNotP0.selector);
        matchmaker.proposeBattle(proposal);
    }

    function test_AcceptorNotP1() public {
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
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.expectRevert(DefaultMatchmaker.AcceptorNotP1.selector);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
    }

    function test_ConfirmerNotP0() public {
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
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle as Bob
        vm.startPrank(BOB);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        vm.expectRevert(DefaultMatchmaker.ConfirmerNotP0.selector);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
    }

    function test_BattleChangedBeforeAcceptance() public {
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
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle as Bob but change parameters to be from expected
        vm.startPrank(BOB);
        proposal.p0TeamHash = salt;
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        vm.expectRevert(DefaultMatchmaker.BattleChangedBeforeAcceptance.selector);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
    }

    function test_InvalidP0TeamHash() public {
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        bytes32 p0TeamHash = salt;

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle as Bob
        vm.startPrank(BOB);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        // Accept battle as Alice, provide wrong team index for hash
        vm.startPrank(ALICE);
        vm.expectRevert(DefaultMatchmaker.InvalidP0TeamHash.selector);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
    }

    function test_BattleNotAccepted() public {
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        bytes32 p0TeamHash = salt;

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Attempt to start the battle
        vm.expectRevert(DefaultMatchmaker.BattleNotAccepted.selector);
        matchmaker.confirmBattle(battleKey, salt, p0TeamIndex);
    }

    function test_sameBattleKeySameTwoPlayers() public {
        bytes32 salt = "";
        uint96 p0TeamIndex = 0;
        bytes32 p0TeamHash = salt;

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: p0TeamIndex,
            p0TeamHash: p0TeamHash,
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Propose battle as Bob
        proposal.p0 = BOB;
        proposal.p1 = ALICE;

        vm.startPrank(BOB);
        bytes32 battleKey2 = matchmaker.proposeBattle(proposal);

        // Ensure both keys are the same
        assertEq(battleKey, battleKey2);
    }

    function test_confirmStillFailsIfNoAcceptOnFastBattle() public {
        uint96 p0TeamIndex = 0;

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: p0TeamIndex,
            p0TeamHash: matchmaker.FAST_BATTLE_SENTINAL_HASH(),
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Attempt to confirm battle as Alice
        vm.expectRevert(DefaultMatchmaker.BattleNotAccepted.selector);
        matchmaker.confirmBattle(battleKey, "", p0TeamIndex);
    }

    function test_fastBattleSucceeds() public {
        uint96 p0TeamIndex = 0;

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: p0TeamIndex,
            p0TeamHash: matchmaker.FAST_BATTLE_SENTINAL_HASH(),
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle as Bob
        vm.startPrank(BOB);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        // Check that the battle has started on the Engine
        (, BattleData memory battleData) = engine.getBattle(battleKey);
        assertEq(battleData.p0, ALICE);
        assertEq(battleData.p1, BOB);

        // Check that Alice and Bob can commit/reveal/reveal to switch to mon index 0
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint240(0), uint240(0));
    }

    function test_fastBattleSucceedsAndNoSubsequentAccept() public {
        uint96 p0TeamIndex = 0;

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: p0TeamIndex,
            p0TeamHash: matchmaker.FAST_BATTLE_SENTINAL_HASH(),
            p1: address(0),
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        bytes32 battleKey = matchmaker.proposeBattle(proposal);

        // Accept battle as Bob
        vm.startPrank(BOB);
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        bytes32 updatedBattleKey = matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);

        // Attempt to accept the battle again as Bob
        vm.expectRevert(DefaultMatchmaker.AlreadyAccepted.selector);
        matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
    }

    function test_battleActuallyReusesStorage() public {
        uint96 p0TeamIndex = 0;

        // Create proposal
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: p0TeamIndex,
            p0TeamHash: matchmaker.FAST_BATTLE_SENTINAL_HASH(),
            p1: BOB,
            p1TeamIndex: 0,
            teamRegistry: defaultRegistry,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(commitManager),
            matchmaker: matchmaker
        });

        // Propose battle as Alice
        vm.startPrank(ALICE);
        vm.startSnapshotGas("Propose1");
        bytes32 battleKey = matchmaker.proposeBattle(proposal);
        uint256 accept1Gas = vm.stopSnapshotGas("Propose1");

        // Accept battle as Bob
        vm.startPrank(BOB);
        vm.startSnapshotGas("Accept1");
        bytes32 battleIntegrityHash = matchmaker.getBattleProposalIntegrityHash(proposal);
        bytes32 updatedBattleKey = matchmaker.acceptBattle(battleKey, 0, battleIntegrityHash);
        uint256 gasUsed2 = vm.stopSnapshotGas("Accept1");

        // Propose battle as Alice
        vm.startPrank(ALICE);
        vm.startSnapshotGas("Accept2");
        bytes32 battleKey2 = matchmaker.proposeBattle(proposal);
        uint256 accept2Gas = vm.stopSnapshotGas("Accept2");
        
        // Should be at least 50% cheaper
        assertLt(accept2Gas / 2, accept1Gas);
    }
}

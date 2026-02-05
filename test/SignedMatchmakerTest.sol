// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

import {BattleOffer, Battle, Mon, MonStats, Type, BattleData} from "../src/Structs.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IAbility} from "../src/abilities/IAbility.sol";

import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {DefaultCommitManager} from "../src/DefaultCommitManager.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";

contract SignedMatchmakerTest is Test, BattleHelper {

    Engine engine;
    DefaultValidator validator;
    DefaultRandomnessOracle rngOracle;
    DefaultCommitManager commitManager;
    SignedMatchmaker matchmaker;
    TestTeamRegistry teamRegistry;

    // Test accounts with known private keys for signing
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    function setUp() public {
        // Derive addresses from private keys
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        // Deploy contracts
        engine = new Engine();
        rngOracle = new DefaultRandomnessOracle();
        commitManager = new DefaultCommitManager(engine);
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 0, TIMEOUT_DURATION: 100})
        );
        teamRegistry = new TestTeamRegistry();
        matchmaker = new SignedMatchmaker(engine);

        // Register teams for both players
        Mon[] memory team = new Mon[](1);
        team[0] = _createMon();
        teamRegistry.setTeam(p0, team);
        teamRegistry.setTeam(p1, team);

        // Both players authorize the matchmaker
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);

        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
    }

    function _createBattleOffer(uint96 p0TeamIndex, uint96 p1TeamIndex, uint256 pairHashNonce)
        internal
        view
        returns (BattleOffer memory)
    {
        return BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: p0TeamIndex,
                p1: p1,
                p1TeamIndex: p1TeamIndex,
                teamRegistry: teamRegistry,
                validator: validator,
                rngOracle: rngOracle,
                ruleset: IRuleset(address(0)),
                moveManager: address(commitManager),
                matchmaker: matchmaker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: pairHashNonce
        });
    }

    /// @dev Signs a BattleOffer with p0's private key, assuming p1TeamIndex = 0 for signing
    function _signOffer(BattleOffer memory offer) internal view returns (bytes memory) {
        // Create a deep copy with p1TeamIndex = 0 for signing (as the contract expects)
        // Note: Solidity memory structs are reference types, so we must create a new Battle
        BattleOffer memory offerForSigning = BattleOffer({
            battle: Battle({
                p0: offer.battle.p0,
                p0TeamIndex: offer.battle.p0TeamIndex,
                p1: offer.battle.p1,
                p1TeamIndex: 0, // Always sign with 0
                teamRegistry: offer.battle.teamRegistry,
                validator: offer.battle.validator,
                rngOracle: offer.battle.rngOracle,
                ruleset: offer.battle.ruleset,
                moveManager: offer.battle.moveManager,
                matchmaker: offer.battle.matchmaker,
                engineHooks: offer.battle.engineHooks
            }),
            pairHashNonce: offer.pairHashNonce
        });

        bytes32 structHash = BattleOfferLib.hashBattleOffer(offerForSigning);
        bytes32 digest = matchmaker.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    /*
        Test: If p0 signs a message and sends it to p1 (with the correct pair hash nonce),
        p1 can start the battle successfully.
    */
    function test_validSignatureStartsBattle() public {
        // Get current nonce for the pair
        (bytes32 battleKey, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        // Create offer with p1TeamIndex = 0
        BattleOffer memory offer = _createBattleOffer(0, 0, nonce);

        // p0 signs the offer
        bytes memory signature = _signOffer(offer);

        // p1 starts the battle
        vm.prank(p1);
        matchmaker.startGame(offer, signature);

        // Verify battle was created (use battleKey computed before battle started)
        (, BattleData memory battleData) = engine.getBattle(battleKey);
        assertEq(battleData.p0, p0);
        assertEq(battleData.p1, p1);
    }

    /*
        Test: If we try to reuse the same signature for a follow-up battle,
        it should fail because the pair hash nonce has changed.
    */
    function test_reusedSignatureFailsDueToNonceChange() public {
        // Get current nonce
        (, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        // Create and sign offer
        BattleOffer memory offer = _createBattleOffer(0, 0, nonce);
        bytes memory signature = _signOffer(offer);

        // First battle succeeds
        vm.prank(p1);
        matchmaker.startGame(offer, signature);

        // Try to reuse the same signature for another battle - should fail
        vm.prank(p1);
        vm.expectRevert(SignedMatchmaker.InvalidNonce.selector);
        matchmaker.startGame(offer, signature);
    }

    /*
        Test: If we try to use an invalid signature to start the battle, we should revert.
    */
    function test_invalidSignatureReverts() public {
        (, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = _createBattleOffer(0, 0, nonce);

        // Create an invalid signature (signed by p1 instead of p0)
        BattleOffer memory offerForSigning = offer;
        offerForSigning.battle.p1TeamIndex = 0;
        bytes32 structHash = BattleOfferLib.hashBattleOffer(offerForSigning);
        bytes32 digest = matchmaker.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P1_PK, digest); // Wrong signer!
        bytes memory badSignature = abi.encodePacked(r, s, v);

        vm.prank(p1);
        vm.expectRevert(SignedMatchmaker.InvalidSignature.selector);
        matchmaker.startGame(offer, badSignature);
    }

    /*
        Test: If someone other than p1 tries to start the battle (even with a valid signature),
        it should revert.
    */
    function test_nonP1CannotStartBattle() public {
        (, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = _createBattleOffer(0, 0, nonce);
        bytes memory signature = _signOffer(offer);

        // p0 tries to start the battle - should fail
        vm.prank(p0);
        vm.expectRevert(SignedMatchmaker.NotP1.selector);
        matchmaker.startGame(offer, signature);

        // Random address tries to start - should also fail
        address random = address(0x1234);
        vm.prank(random);
        vm.expectRevert(SignedMatchmaker.NotP1.selector);
        matchmaker.startGame(offer, signature);
    }

    /*
        Test: If we start the battle with a non-zero team index for p1,
        this is correctly reflected when the battle starts.
        We verify by checking that the mon stats match the alternative team.
    */
    function test_nonZeroP1TeamIndexIsReflected() public {
        // Create a different mon with distinct stats for p1's alternative team
        uint96 p1TeamIndex = 5;
        uint32 altHp = 999;
        Mon memory altMon = Mon({
            stats: MonStats({
                hp: altHp,
                stamina: 50,
                speed: 50,
                attack: 50,
                defense: 50,
                specialAttack: 50,
                specialDefense: 50,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: new IMoveSet[](0),
            ability: IAbility(address(0))
        });

        // Register the alternative team at index 5 for p1
        Mon[] memory altTeam = new Mon[](1);
        altTeam[0] = altMon;
        teamRegistry.setTeamAt(p1, p1TeamIndex, altTeam);

        (bytes32 battleKey, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        // Create offer with p1TeamIndex = 5 (non-zero)
        BattleOffer memory offer = _createBattleOffer(0, p1TeamIndex, nonce);

        // p0 signs (with p1TeamIndex = 0 as per protocol)
        bytes memory signature = _signOffer(offer);

        // p1 starts with their actual team index
        vm.prank(p1);
        matchmaker.startGame(offer, signature);

        // Verify the battle used the alternative team by checking the mon's HP stat
        // playerIndex 1 = p1, monIndex 0 = first mon
        MonStats memory p1MonStats = engine.getMonStatsForBattle(battleKey, 1, 0);
        assertEq(p1MonStats.hp, altHp, "p1's mon should have the alternative team's HP");
    }

    function test_openBattleOffer() public {
        // Create offer with p1TeamIndex = 0
        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: address(0),
                p1TeamIndex: 0,
                teamRegistry: teamRegistry,
                validator: validator,
                rngOracle: rngOracle,
                ruleset: IRuleset(address(0)),
                moveManager: address(commitManager),
                matchmaker: matchmaker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: 0
        });

        // p0 signs the offer
        bytes memory signature = _signOffer(offer);

        // p1 starts the battle
        vm.prank(p1);
        matchmaker.startGame(offer, signature);

        // Check that nonce for p0 is now 1
        assertEq(matchmaker.openBattleOfferNonce(p0), 1);
    }

    function test_openBattleNonceFails() public {
        // Create offer with p1TeamIndex = 0
        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: address(0),
                p1TeamIndex: 0,
                teamRegistry: teamRegistry,
                validator: validator,
                rngOracle: rngOracle,
                ruleset: IRuleset(address(0)),
                moveManager: address(commitManager),
                matchmaker: matchmaker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: 0
        });

        // p0 signs the offer
        bytes memory signature = _signOffer(offer);

        // p1 starts the battle
        vm.prank(p1);
        matchmaker.startGame(offer, signature);

        // Try to start another battle with the same nonce - should fail
        vm.prank(p1);
        vm.expectRevert(SignedMatchmaker.InvalidOpenBattleOfferNonce.selector);
        matchmaker.startGame(offer, signature);
    }

    function test_openBattleSequentialNonceMultipleTakers() public {
        // Create offer with p1TeamIndex = 0
        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: address(0),
                p1TeamIndex: 0,
                teamRegistry: teamRegistry,
                validator: validator,
                rngOracle: rngOracle,
                ruleset: IRuleset(address(0)),
                moveManager: address(commitManager),
                matchmaker: matchmaker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: 0
        });

        // p0 signs the offer
        bytes memory signature = _signOffer(offer);

        // p1 starts the battle
        vm.prank(p1);
        matchmaker.startGame(offer, signature);

        // p0 signs a new offer with nonce of 1
        offer.pairHashNonce = 1;
        signature = _signOffer(offer);

        // p2 starts the battle
        address p2 = vm.addr(0x1234);
        vm.startPrank(p2);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(matchmaker);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        Mon[] memory team = new Mon[](1);
        team[0] = _createMon();
        teamRegistry.setTeam(p2, team);
        matchmaker.startGame(offer, signature);

        // Check that nonce for p0 is now 2
        assertEq(matchmaker.openBattleOfferNonce(p0), 2);
    }
}


// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";

import {IEngine} from "../src/IEngine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";

import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @notice Validation-side tests for `SignedCommitManager.submitTurnMoves` (OPT_PLAN §10).
/// @dev Covers: wrong committer signer, wrong revealer signer, wrong turnId, replay, missing
///      committer sig regression (unilateral-revealer attack), empty buffer.
contract BufferSubmissionTest is BatchHelper {

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 2;

    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    uint256 constant MALLORY_PK = 0xDEAD;
    address p0;
    address p1;
    address mallory;

    Engine engine;
    SignedCommitManager mgr;
    SignedMatchmaker maker;
    ITypeCalculator typeCalc;
    TestTeamRegistry registry;
    StandardAttackFactory attackFactory;
    IMoveSet attack;
    bytes32 battleKey;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);
        mallory = vm.addr(MALLORY_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        typeCalc = new TypeCalculator();
        registry = new TestTeamRegistry();
        attackFactory = new StandardAttackFactory(typeCalc);

        attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 10, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "A", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 1000, stamina: 20, speed: 10,
                attack: 30, defense: 10, specialAttack: 30, specialDefense: 10,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        mon.moves[0] = uint256(uint160(address(attack)));
        mon.moves[1] = uint256(uint160(address(attack)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        registry.setTeam(p0, team);
        registry.setTeam(p1, team);

        battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _startBattle() internal returns (bytes32) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(maker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        (bytes32 key, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0, p0TeamIndex: 0,
                p1: p1, p1TeamIndex: 0,
                teamRegistry: registry,
                validator: IValidator(address(0)),
                rngOracle: IRandomnessOracle(address(0)),
                ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: address(mgr),
                matchmaker: maker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce
        });

        bytes32 digest = maker.hashTypedData(BattleOfferLib.hashBattleOffer(offer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(p1);
        maker.startGame(offer, sig);
        return key;
    }

    function _validTurnZero() internal view returns (TurnSubmission memory) {
        return _buildTurnSubmission(
            address(mgr), battleKey, 0,
            SWITCH_MOVE_INDEX, 0, uint104(0xC011),
            SWITCH_MOVE_INDEX, 0, uint104(0xBABE),
            P0_PK, P1_PK
        );
    }

    // -----------------------------------------------------------------
    // happy path
    // -----------------------------------------------------------------

    function test_submitTurnMoves_happyPath_turn0() public {
        TurnSubmission memory entry = _validTurnZero();
        mgr.submitTurnMoves(battleKey, entry);

        (uint64 ex, uint64 buf,) = mgr.getBufferStatus(battleKey);
        assertEq(ex, 0);
        assertEq(buf, 1);
    }

    function test_submitTurnMoves_relayerCanSubmit() public {
        // Mallory (a third party) submits an entry signed by p0+p1. Should succeed — sigs are
        // the binding, not msg.sender.
        TurnSubmission memory entry = _validTurnZero();
        vm.prank(mallory);
        mgr.submitTurnMoves(battleKey, entry);

        (uint64 ex, uint64 buf,) = mgr.getBufferStatus(battleKey);
        assertEq(ex, 0);
        assertEq(buf, 1);
    }

    // -----------------------------------------------------------------
    // signature failures
    // -----------------------------------------------------------------

    function test_submitTurnMoves_wrongCommitterSigner() public {
        // Build entry where committer slot was actually signed by Mallory (not p0).
        TurnSubmission memory entry = _buildTurnSubmission(
            address(mgr), battleKey, 0,
            SWITCH_MOVE_INDEX, 0, uint104(0xC011),
            SWITCH_MOVE_INDEX, 0, uint104(0xBABE),
            MALLORY_PK, // ← wrong committer key
            P1_PK
        );
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        mgr.submitTurnMoves(battleKey, entry);
    }

    function test_submitTurnMoves_wrongRevealerSigner() public {
        TurnSubmission memory entry = _buildTurnSubmission(
            address(mgr), battleKey, 0,
            SWITCH_MOVE_INDEX, 0, uint104(0xC011),
            SWITCH_MOVE_INDEX, 0, uint104(0xBABE),
            P0_PK,
            MALLORY_PK // ← wrong revealer key
        );
        vm.expectRevert(SignedCommitManager.InvalidSignature.selector);
        mgr.submitTurnMoves(battleKey, entry);
    }

    /// @notice Regression for the §9 unilateral-revealer attack: revealer cannot fabricate the
    ///         committer's preimage by signing only the revealer half.
    function test_submitTurnMoves_unilateralRevealerAttack_blocked() public {
        // Mallory wants to play p0's move as if it were a chosen preimage. Forge a TurnSubmission
        // with the committer slot filled in (arbitrary values) but with an EMPTY committer sig.
        TurnSubmission memory entry = _validTurnZero();
        entry.committerSig = bytes(""); // strip committer sig
        vm.expectRevert(); // ECDSA library reverts on bad length — any revert is fine.
        mgr.submitTurnMoves(battleKey, entry);
    }

    function test_submitTurnMoves_emptyRevealerSig() public {
        TurnSubmission memory entry = _validTurnZero();
        entry.revealerSig = bytes("");
        vm.expectRevert();
        mgr.submitTurnMoves(battleKey, entry);
    }

    // -----------------------------------------------------------------
    // append-position + replay
    // -----------------------------------------------------------------

    function test_submitTurnMoves_wrongTurnId_gap() public {
        // Skip turn 0, try to submit turn 1 directly.
        TurnSubmission memory entry = _buildTurnSubmission(
            address(mgr), battleKey, 1, // skip ahead
            NO_OP_MOVE_INDEX, 0, uint104(1),
            NO_OP_MOVE_INDEX, 0, uint104(2),
            P0_PK, P1_PK
        );
        vm.expectRevert(SignedCommitManager.WrongTurnId.selector);
        mgr.submitTurnMoves(battleKey, entry);
    }

    function test_submitTurnMoves_replay_sameSlot() public {
        TurnSubmission memory entry = _validTurnZero();
        mgr.submitTurnMoves(battleKey, entry);
        // Resubmitting the same entry should fail append-position check (next slot is 1, not 0).
        vm.expectRevert(SignedCommitManager.WrongTurnId.selector);
        mgr.submitTurnMoves(battleKey, entry);
    }

    function test_submitTurnMoves_nonExistentBattle_reverts() public {
        // Use a different battleKey that hasn't started. After the getCommitContext->
        // getSubmitContext change, we no longer SLOAD `startTimestamp`; we rely on the
        // `winnerIndex != 2` check to reject submissions, which fires for non-existent
        // battles too (their BattleData is default-zero, so winnerIndex == 0 != 2).
        bytes32 fakeKey = keccak256("nope");
        TurnSubmission memory entry = _buildTurnSubmission(
            address(mgr), fakeKey, 0,
            SWITCH_MOVE_INDEX, 0, uint104(1),
            SWITCH_MOVE_INDEX, 0, uint104(2),
            P0_PK, P1_PK
        );
        vm.expectRevert(DefaultCommitManager.BattleAlreadyComplete.selector);
        mgr.submitTurnMoves(fakeKey, entry);
    }

    function test_executeBuffered_emptyReverts() public {
        vm.expectRevert(SignedCommitManager.EmptyBuffer.selector);
        mgr.executeBuffered(battleKey);
    }

    // -----------------------------------------------------------------
    // counter accounting
    // -----------------------------------------------------------------

    function test_submitTurnMoves_advancesBuffered() public {
        mgr.submitTurnMoves(battleKey, _validTurnZero());

        TurnSubmission memory turn1 = _buildTurnSubmission(
            address(mgr), battleKey, 1,
            0, 0, uint104(100),
            0, 0, uint104(200),
            P0_PK, P1_PK
        );
        mgr.submitTurnMoves(battleKey, turn1);

        (uint64 ex, uint64 buf, uint64 ts) = mgr.getBufferStatus(battleKey);
        assertEq(ex, 0);
        assertEq(buf, 2);
        assertEq(ts, uint64(block.timestamp));
    }

    function test_submitTurnMoves_lastSubmitTimestampUpdates() public {
        mgr.submitTurnMoves(battleKey, _validTurnZero());

        uint256 t1 = block.timestamp;
        (,, uint64 ts1) = mgr.getBufferStatus(battleKey);
        assertEq(ts1, uint64(t1));

        vm.warp(t1 + 100);
        TurnSubmission memory turn1 = _buildTurnSubmission(
            address(mgr), battleKey, 1,
            0, 0, uint104(100),
            0, 0, uint104(200),
            P0_PK, P1_PK
        );
        mgr.submitTurnMoves(battleKey, turn1);

        (,, uint64 ts2) = mgr.getBufferStatus(battleKey);
        assertEq(ts2, uint64(t1 + 100));
    }
}

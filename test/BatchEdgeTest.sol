// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";
import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
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

/// @notice Edge-case tests for `executeBuffered` (OPT_PLAN §10).
/// @dev Covers: mid-batch game-over, forced-switch turn dispatch via §6.1 flag, mode alternation
///      (legacy single-turn execute followed by batched submit), and submitting more than 2
///      turns in a single batch with intermediate switch-only turns.
contract BatchEdgeTest is BatchHelper {

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 2;

    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    SignedCommitManager mgr;
    SignedMatchmaker maker;
    ITypeCalculator typeCalc;
    TestTeamRegistry registry;
    StandardAttackFactory attackFactory;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        typeCalc = new TypeCalculator();
        registry = new TestTeamRegistry();
        attackFactory = new StandardAttackFactory(typeCalc);
    }

    function _setupTeams(uint32 hp, uint32 power) internal {
        IMoveSet hit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: power, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Hit", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: hp, stamina: 20, speed: 10,
                attack: 30, defense: 10, specialAttack: 30, specialDefense: 10,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        mon.moves[0] = uint256(uint160(address(hit)));
        mon.moves[1] = uint256(uint160(address(hit)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        registry.setTeam(p0, team);
        registry.setTeam(p1, team);
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

    /// @notice Forced-switch dispatch: when KO causes `playerSwitchForTurnFlag != 2` mid-batch,
    ///         `executeBuffered` routes to `executeWithSingleMove` and ignores the non-acting half.
    function test_executeBuffered_forcedSwitch_routesViaFlag() public {
        // Glass mons: both sides have HP=5, hit power=100 → first damage trade KOs both active mons.
        _setupTeams(5, 100);

        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Plan:
        //  turn 0: both switch in mon 0
        //  turn 1: damage trade — both mons KO simultaneously
        //  turn 2: forced double-switch (flag stays 2 because both KOd) — both submit SWITCH
        //  turn 3: damage trade with mon 1
        _submitTurnMoves(mgr, battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 1, 0, 0, 0, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 2, SWITCH_MOVE_INDEX, 1, SWITCH_MOVE_INDEX, 1, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 3, 0, 0, 0, 0, P0_PK, P1_PK);

        mgr.executeBuffered(battleKey);

        // All four turns drained; mon 0 KOd on both sides; mon 1 took damage on turn 3.
        (uint64 ex, uint64 buf,) = mgr.getBufferStatus(battleKey);
        assertEq(ex, 4, "all four turns executed");
        assertEq(buf, 0, "buffer drained");
        assertEq(engine.getKOBitmap(battleKey, 0), 1, "p0 mon 0 KO");
        assertEq(engine.getKOBitmap(battleKey, 1), 1, "p1 mon 0 KO");
    }

    /// @notice Single-side KO mid-batch: only one player needs to switch next turn (flag != 2).
    ///         The buffered entry has both halves; engine dispatches only the acting player's.
    function test_executeBuffered_singleSideSwitch() public {
        // p0 has high HP, p1 has glass HP — only p1's mon KOs on turn 1.
        IMoveSet hit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 200, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Hit", EFFECT: IEffect(address(0))
            })
        );

        Mon memory tough = Mon({
            stats: MonStats({
                hp: 10000, stamina: 20, speed: 10,
                attack: 30, defense: 10, specialAttack: 30, specialDefense: 10,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        tough.moves[0] = uint256(uint160(address(hit)));
        tough.moves[1] = uint256(uint160(address(hit)));

        Mon memory glass = tough;
        glass.stats.hp = 5;

        Mon[] memory p0Team = new Mon[](MONS_PER_TEAM);
        Mon[] memory p1Team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            p0Team[i] = tough;
            p1Team[i] = glass;
        }
        registry.setTeam(p0, p0Team);
        registry.setTeam(p1, p1Team);

        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Plan:
        //  turn 0: switch in
        //  turn 1: damage trade — p0 KOs p1's glass mon
        //  turn 2: only p1 needs to switch (flag == 1). p0's slot is NO_OP, engine ignores.
        //  turn 3: damage trade with p1's mon 1
        _submitTurnMoves(mgr, battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 1, 0, 0, 0, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 2, NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 3, 0, 0, 0, 0, P0_PK, P1_PK);

        mgr.executeBuffered(battleKey);

        (uint64 ex, uint64 buf,) = mgr.getBufferStatus(battleKey);
        assertEq(ex, 4, "all four turns executed via flag dispatch");
        assertEq(buf, 0, "buffer drained");

        // p1 mon 0 is KOd, mon 1 is active.
        assertEq(engine.getKOBitmap(battleKey, 1), 1, "p1 mon 0 KO");
        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[1], 1, "p1 active mon is 1");
    }

    /// @notice Game-over mid-batch with a normal 2-mon game: remaining buffered entries become
    ///         dead; `numTurnsBuffered` resets to 0 and `numTurnsExecuted` advances by ACTUAL
    ///         executed (not buffered) count. Subsequent buffered turns after game-over would
    ///         revert in `_executeInternal` (with `GameAlreadyOver`), so the loop must break.
    /// @dev Engineers deterministic KO order with asymmetric setups: p0 is fast (speed=100) and
    ///      strong, p1 is slow (speed=1) and glass. p0 always KOs first, never gets KO'd.
    function test_executeBuffered_gameOverMidBatch_dropsRemaining() public {
        IMoveSet bigHit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 200, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Big", EFFECT: IEffect(address(0))
            })
        );

        Mon memory fast = Mon({
            stats: MonStats({
                hp: 10000, stamina: 20, speed: 100, // way faster
                attack: 100, defense: 100, specialAttack: 100, specialDefense: 100,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        fast.moves[0] = uint256(uint160(address(bigHit)));
        fast.moves[1] = uint256(uint160(address(bigHit)));

        Mon memory glass = fast;
        glass.stats.hp = 1;
        glass.stats.speed = 1;

        Mon[] memory p0Team = new Mon[](MONS_PER_TEAM);
        Mon[] memory p1Team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            p0Team[i] = fast;
            p1Team[i] = glass;
        }
        registry.setTeam(p0, p0Team);
        registry.setTeam(p1, p1Team);

        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Sequence (2-mon teams):
        //   turn 0: switch in
        //   turn 1: p0 attacks first → p1 mon 0 KO. flag → 1.
        //   turn 2: p1 switches mon 1 in (single-player turn dispatched via flag).
        //   turn 3: p0 attacks → p1 mon 1 KO → p1 team wiped → game over, winner = p0.
        //   turn 4 + 5: must NOT run (`_executeInternal` would revert `GameAlreadyOver`).
        _submitTurnMoves(mgr, battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 1, 0, 0, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 2, NO_OP_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 3, 0, 0, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 4, NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 5, NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);

        mgr.executeBuffered(battleKey);

        (uint64 ex, uint64 buf,) = mgr.getBufferStatus(battleKey);
        assertEq(ex, 4, "executed count stops at game-over turn (turn 0,1,2,3)");
        assertEq(buf, 0, "buffer reset to 0");
        assertEq(engine.getWinner(battleKey), p0, "p0 wins");
    }

    /// @notice Mode alternation: legacy single-turn `executeWithDualSignedMoves` followed by
    ///         a batched `submitTurnMoves` works seamlessly. The first submit syncs
    ///         `numTurnsExecuted` from the engine's `turnId`.
    function test_executeBuffered_modeAlternation_legacyThenBatched() public {
        _setupTeams(10000, 30);
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Turn 0: legacy dual-signed execute.
        {
            uint64 turnId = 0;
            uint96 cSalt = uint96(1);
            uint96 rSalt = uint96(2);
            bytes32 cHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, cSalt, uint16(0)));
            bytes memory cSig = _signCommit(address(mgr), P0_PK, cHash, battleKey, turnId);
            bytes memory rSig = _signDualReveal(address(mgr), P1_PK, battleKey, turnId, cHash,
                SWITCH_MOVE_INDEX, rSalt, 0);
            mgr.executeWithDualSignedMoves(battleKey, SWITCH_MOVE_INDEX, cSalt, 0,
                SWITCH_MOVE_INDEX, rSalt, 0, cSig, rSig);
            engine.resetCallContext();
        }
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "engine turnId after legacy");

        // Submit a batched turn at turnId = 1. First-of-batch sync should mirror engine.turnId.
        _submitTurnMoves(mgr, battleKey, 1, 0, 0, 0, 0, P0_PK, P1_PK);

        (uint64 exBefore, uint64 bufBefore,) = mgr.getBufferStatus(battleKey);
        assertEq(exBefore, 1, "first-of-batch sync set numTurnsExecuted = engine turnId");
        assertEq(bufBefore, 1, "one entry buffered");

        mgr.executeBuffered(battleKey);

        (uint64 exAfter, uint64 bufAfter,) = mgr.getBufferStatus(battleKey);
        assertEq(exAfter, 2, "numTurnsExecuted after drain");
        assertEq(bufAfter, 0, "buffer drained");
        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "engine turnId after batched");
    }

    /// @notice After a batched drain, a follow-up legacy call still works (no state corruption).
    function test_executeBuffered_modeAlternation_batchedThenLegacy() public {
        _setupTeams(10000, 30);
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Two batched turns.
        _submitTurnMoves(mgr, battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 1, 0, 0, 0, 0, P0_PK, P1_PK);
        mgr.executeBuffered(battleKey);
        engine.resetCallContext();

        // Follow up with a legacy dual-signed turn at turnId = 2.
        uint64 turnId = 2;
        uint96 cSalt = uint96(100);
        uint96 rSalt = uint96(200);
        bytes32 cHash = keccak256(abi.encodePacked(uint8(0), cSalt, uint16(0)));
        bytes memory cSig = _signCommit(address(mgr), P0_PK, cHash, battleKey, turnId);
        bytes memory rSig = _signDualReveal(address(mgr), P1_PK, battleKey, turnId, cHash,
            uint8(1), rSalt, 0);

        mgr.executeWithDualSignedMoves(battleKey, 0, cSalt, 0, 1, rSalt, 0, cSig, rSig);

        assertEq(engine.getTurnIdForBattleState(battleKey), 3, "engine turnId after batched+legacy");
    }
}

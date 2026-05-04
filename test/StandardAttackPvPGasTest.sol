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
import {SignedCommitHelper} from "./abstract/SignedCommitHelper.sol";

import {IEngine} from "../src/IEngine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";

import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// @title StandardAttack PvP gas benchmark
/// @notice Measures the per-turn cost of a fully-optimized PvP battle whose moves are real
///         StandardAttack-derived contracts (the production shape for ~30 mon move contracts
///         in src/mons/). Uses the production TypeCalculator (which delegates to TypeCalcLib)
///         so pre/post numbers reflect only gas-path changes, not type-chart differences.
///
///         Existing PvP benchmarks (FullyOptimizedInlineGasTest) use CustomAttack /
///         EffectAttack / StatBoostsMove — none of which extend StandardAttack — so the
///         StandardAttack hot path doesn't show up there.
contract StandardAttackPvPGasTest is SignedCommitHelper {

    uint256 constant MONS_PER_TEAM = 4;
    uint256 constant MOVES_PER_MON = 4;

    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    SignedCommitManager signedCommitManager;
    SignedMatchmaker signedMatchmaker;
    ITypeCalculator typeCalc;
    TestTeamRegistry defaultRegistry;
    StandardAttackFactory attackFactory;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        signedCommitManager = new SignedCommitManager(IEngine(address(engine)));
        signedMatchmaker = new SignedMatchmaker(engine);

        // Production TypeCalculator wraps TypeCalcLib — same chart the engine's internal
        // dispatch path uses. With this, moving from StandardAttack._move to
        // engine.dispatchStandardAttack is a pure code-path swap, no damage-value drift.
        typeCalc = new TypeCalculator();

        defaultRegistry = new TestTeamRegistry();
        attackFactory = new StandardAttackFactory(typeCalc);
    }

    function _startBattle(IRuleset ruleset) internal returns (bytes32) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(signedMatchmaker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        (bytes32 battleKey, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: p1,
                p1TeamIndex: 0,
                teamRegistry: defaultRegistry,
                validator: IValidator(address(0)), // inline validator
                rngOracle: IRandomnessOracle(address(0)), // inline RNG
                ruleset: ruleset,
                moveManager: address(signedCommitManager),
                matchmaker: signedMatchmaker,
                engineHooks: new IEngineHook[](0)
            }),
            pairHashNonce: nonce
        });

        bytes32 structHash = BattleOfferLib.hashBattleOffer(offer);
        bytes32 digest = signedMatchmaker.hashTypedData(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(p1);
        signedMatchmaker.startGame(offer, signature);

        return battleKey;
    }

    function _fastTurn(
        bytes32 battleKey,
        uint8 p0MoveIndex,
        uint8 p1MoveIndex,
        uint16 p0ExtraData,
        uint16 p1ExtraData
    ) internal {
        uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
        uint104 committerSalt = uint104(uint256(keccak256(abi.encode("committer", battleKey, turnId))));
        uint104 revealerSalt = uint104(uint256(keccak256(abi.encode("revealer", battleKey, turnId))));

        uint8 committerMoveIndex;
        uint16 committerExtraData;
        uint8 revealerMoveIndex;
        uint16 revealerExtraData;
        uint256 committerPk;
        uint256 revealerPk;
        address committer;

        if (turnId % 2 == 0) {
            committerMoveIndex = p0MoveIndex;
            committerExtraData = p0ExtraData;
            revealerMoveIndex = p1MoveIndex;
            revealerExtraData = p1ExtraData;
            committerPk = P0_PK;
            revealerPk = P1_PK;
            committer = p0;
        } else {
            committerMoveIndex = p1MoveIndex;
            committerExtraData = p1ExtraData;
            revealerMoveIndex = p0MoveIndex;
            revealerExtraData = p0ExtraData;
            committerPk = P1_PK;
            revealerPk = P0_PK;
            committer = p1;
        }

        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));
        address mgr = address(signedCommitManager);
        bytes memory committerSig = _signCommit(mgr, committerPk, committerMoveHash, battleKey, turnId);
        bytes memory revealerSig = _signDualReveal(
            mgr, revealerPk, battleKey, turnId, committerMoveHash, revealerMoveIndex, revealerSalt, revealerExtraData
        );

        vm.prank(committer);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            committerMoveIndex,
            committerSalt,
            committerExtraData,
            revealerMoveIndex,
            revealerSalt,
            revealerExtraData,
            committerSig,
            revealerSig
        );
        engine.resetCallContext();
    }

    function _createMon(Type t1) internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 10000, // High HP — no KOs during the measured window
                stamina: 50,
                speed: 10,
                attack: 30,
                defense: 10,
                specialAttack: 30,
                specialDefense: 10,
                type1: t1,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
    }

    /// @notice Hot-path benchmark: PvP battle, 4 turns of damage trades using two real
    ///         StandardAttack-derived moves. No KOs, no switches, no effects — isolates
    ///         the StandardAttack._move → AttackCalculator → engine.dealDamage path that
    ///         4-B will collapse into engine.dispatchStandardAttack.
    function test_standardAttackPvP_damageTrade() public {
        // Two damage-only StandardAttack moves. Both Fire → Fire (TypeCalcLib: 1x baseline).
        IMoveSet moveA = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "AttackA",
                EFFECT: IEffect(address(0))
            })
        );
        IMoveSet moveB = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 25,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Fire,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "AttackB",
                EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon(Type.Fire);
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));
        mon.moves[2] = uint256(uint160(address(moveA)));
        mon.moves[3] = uint256(uint160(address(moveB)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        // Inline stamina-regen ruleset — production-shape.
        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);

        bytes32 battleKey = _startBattle(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Turn 0: lead-in switch.
        vm.startSnapshotGas("Turn0_Lead");
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        uint256 turn0 = vm.stopSnapshotGas("Turn0_Lead");

        // Turns 1-4: pure damage trades. Both players use move 0 / move 1 alternately.
        // No effects fire, no KOs (mon HP is 10000), so this is isolated dispatch cost.
        vm.startSnapshotGas("Turn1_BothAttack");
        _fastTurn(battleKey, 0, 0, 0, 0);
        uint256 turn1 = vm.stopSnapshotGas("Turn1_BothAttack");

        vm.startSnapshotGas("Turn2_BothAttack");
        _fastTurn(battleKey, 1, 1, 0, 0);
        uint256 turn2 = vm.stopSnapshotGas("Turn2_BothAttack");

        vm.startSnapshotGas("Turn3_BothAttack");
        _fastTurn(battleKey, 0, 1, 0, 0);
        uint256 turn3 = vm.stopSnapshotGas("Turn3_BothAttack");

        vm.startSnapshotGas("Turn4_BothAttack");
        _fastTurn(battleKey, 1, 0, 0, 0);
        uint256 turn4 = vm.stopSnapshotGas("Turn4_BothAttack");

        // Sanity: battle still in progress, both mons still alive.
        assertEq(engine.getWinner(battleKey), address(0), "battle must still be in progress");
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(battleKey), 2, "flag must still be 2");

        uint256 avg = (turn1 + turn2 + turn3 + turn4) / 4;

        console.log("========================================");
        console.log("StandardAttack PvP damage-trade benchmark");
        console.log("========================================");
        console.log("Turn 0 (lead select)              :", turn0);
        console.log("Turn 1 (both attack, move 0)      :", turn1);
        console.log("Turn 2 (both attack, move 1)      :", turn2);
        console.log("Turn 3 (mixed)                    :", turn3);
        console.log("Turn 4 (mixed)                    :", turn4);
        console.log("Average flag==2 attack turn       :", avg);
        console.log("========================================");
    }
}

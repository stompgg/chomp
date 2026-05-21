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

/// @notice Gas-savings demonstration for OPT_PLAN §11 Phase 2: drive an identical N-turn battle
///         through legacy per-turn `executeWithDualSignedMoves` (N transactions worth of work in
///         one foundry tx) vs batched `submitTurnMoves × N + executeBuffered × 1` and print both
///         numbers + the delta. Submissions cost ~one SSTORE-warm per turn — the saving comes
///         from the single `executeBuffered` amortizing cold SLOADs across sub-turns via the
///         EVM's warm-storage discount (see §12 Decision Log on the shadow-layer deferral).
contract BatchGasTest is BatchHelper {

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
    IMoveSet moveA;
    IMoveSet moveB;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        typeCalc = new TypeCalculator();
        registry = new TestTeamRegistry();
        attackFactory = new StandardAttackFactory(typeCalc);

        moveA = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "A", EFFECT: IEffect(address(0))
            })
        );
        moveB = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 25, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "B", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100000, stamina: 20, speed: 10,
                attack: 30, defense: 10, specialAttack: 30, specialDefense: 10,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));

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
                p0: p0, p0TeamIndex: 0, p1: p1, p1TeamIndex: 0,
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

    /// @dev Returns gas consumed for an identical N-turn battle via the legacy per-turn flow.
    function _measureLegacy(uint256 nTurns) internal returns (uint256) {
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch — not counted in the steady-state measurement.
        {
            uint64 t = 0;
            uint104 cSalt = uint104(uint256(keccak256(abi.encode("legacy-c", battleKey, t))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("legacy-r", battleKey, t))));
            bytes32 cHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, cSalt, uint16(0)));
            bytes memory cSig = _signCommit(address(mgr), P0_PK, cHash, battleKey, t);
            bytes memory rSig = _signDualReveal(address(mgr), P1_PK, battleKey, t, cHash,
                SWITCH_MOVE_INDEX, rSalt, 0);
            mgr.executeWithDualSignedMoves(battleKey, SWITCH_MOVE_INDEX, cSalt, 0,
                SWITCH_MOVE_INDEX, rSalt, 0, cSig, rSig);
            engine.resetCallContext();
        }

        // Now do nTurns of damage trades and measure total gas.
        uint256 startGas = gasleft();
        for (uint64 i = 1; i <= nTurns; i++) {
            uint64 t = i;
            uint104 cSalt = uint104(uint256(keccak256(abi.encode("legacy-c", battleKey, t))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("legacy-r", battleKey, t))));

            uint8 cMove; uint16 cExtra; uint8 rMove; uint16 rExtra;
            uint256 cPk; uint256 rPk;
            (cMove, cExtra, cPk, rMove, rExtra, rPk) = t % 2 == 0
                ? (uint8(0), uint16(0), P0_PK, uint8(1), uint16(0), P1_PK)
                : (uint8(1), uint16(0), P1_PK, uint8(0), uint16(0), P0_PK);

            bytes32 cHash = keccak256(abi.encodePacked(cMove, cSalt, cExtra));
            bytes memory cSig = _signCommit(address(mgr), cPk, cHash, battleKey, t);
            bytes memory rSig = _signDualReveal(address(mgr), rPk, battleKey, t, cHash, rMove, rSalt, rExtra);

            mgr.executeWithDualSignedMoves(battleKey, cMove, cSalt, cExtra, rMove, rSalt, rExtra, cSig, rSig);
            engine.resetCallContext();
        }
        return startGas - gasleft();
    }

    /// @dev Returns gas consumed for an identical N-turn battle via submit-then-batch.
    ///      Measured = total of (N submits + 1 executeBuffered). Lead-in turn 0 still goes
    ///      through the legacy single-turn flow so the steady-state comparison is apples-to-apples.
    function _measureBatched(uint256 nTurns) internal returns (uint256) {
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch via legacy single-turn (not counted).
        {
            uint64 t = 0;
            uint104 cSalt = uint104(uint256(keccak256(abi.encode("batched-c", battleKey, t))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("batched-r", battleKey, t))));
            bytes32 cHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, cSalt, uint16(0)));
            bytes memory cSig = _signCommit(address(mgr), P0_PK, cHash, battleKey, t);
            bytes memory rSig = _signDualReveal(address(mgr), P1_PK, battleKey, t, cHash,
                SWITCH_MOVE_INDEX, rSalt, 0);
            mgr.executeWithDualSignedMoves(battleKey, SWITCH_MOVE_INDEX, cSalt, 0,
                SWITCH_MOVE_INDEX, rSalt, 0, cSig, rSig);
            engine.resetCallContext();
        }

        uint256 startGas = gasleft();
        for (uint64 i = 1; i <= nTurns; i++) {
            uint8 p0Move = i % 2 == 1 ? uint8(0) : uint8(1);
            uint8 p1Move = i % 2 == 1 ? uint8(1) : uint8(0);
            _submitTurnMoves(mgr, battleKey, i, p0Move, 0, p1Move, 0, P0_PK, P1_PK);
        }
        mgr.executeBuffered(battleKey);
        engine.resetCallContext();
        return startGas - gasleft();
    }

    function _logComparison(string memory label, uint256 legacyGas, uint256 batchedGas) internal {
        console.log(label);
        console.log("  legacy total gas   :", legacyGas);
        console.log("  batched total gas  :", batchedGas);
        if (batchedGas < legacyGas) {
            console.log("  savings            :", legacyGas - batchedGas);
            console.log("  savings %          :", (legacyGas - batchedGas) * 100 / legacyGas);
        } else {
            console.log("  REGRESSION (gas+)  :", batchedGas - legacyGas);
        }
    }

    function test_batchGas_B2() public {
        uint256 legacyGas = _measureLegacy(2);
        uint256 batchedGas = _measureBatched(2);
        _logComparison("=== B=2 ===", legacyGas, batchedGas);
    }

    function test_batchGas_B4() public {
        uint256 legacyGas = _measureLegacy(4);
        uint256 batchedGas = _measureBatched(4);
        _logComparison("=== B=4 ===", legacyGas, batchedGas);
    }

    function test_batchGas_B8() public {
        uint256 legacyGas = _measureLegacy(8);
        uint256 batchedGas = _measureBatched(8);
        _logComparison("=== B=8 ===", legacyGas, batchedGas);
    }
}

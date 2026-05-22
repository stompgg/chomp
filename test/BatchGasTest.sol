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
    // High-power one-shot move used only by `_runWarmupBattle` to KO mons quickly so battle 1
    // ends before we measure battle 2 (steady-state slot reuse via MappingAllocator's free list).
    IMoveSet moveOneShot;
    Mon[] warmupTeam;
    Mon[] measureTeam;

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
        moveOneShot = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 250, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "X", EFFECT: IEffect(address(0))
            })
        );

        // Warmup team (low HP) — used to drive battle 1 to completion so battle 2 inherits
        // a freed storageKey (warm SSTOREs in the steady state).
        Mon memory warmupMon = Mon({
            stats: MonStats({
                hp: 20, stamina: 20, speed: 10,
                attack: 30, defense: 10, specialAttack: 30, specialDefense: 10,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        warmupMon.moves[0] = uint256(uint160(address(moveOneShot)));
        warmupMon.moves[1] = uint256(uint160(address(moveB)));
        for (uint256 i; i < MONS_PER_TEAM; i++) warmupTeam.push(warmupMon);

        // Measured team (high HP) — same shape as warmup team so storage layout matches.
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
        for (uint256 i; i < MONS_PER_TEAM; i++) measureTeam.push(mon);
    }

    function _setRegistryTeams(Mon[] storage team) internal {
        Mon[] memory teamMem = new Mon[](team.length);
        for (uint256 i; i < team.length; i++) teamMem[i] = team[i];
        registry.setTeam(p0, teamMem);
        registry.setTeam(p1, teamMem);
    }

    /// @dev Drive a low-HP battle to completion so the engine's MappingAllocator frees the
    ///      storageKey. The next `_startBattle()` will reuse the freed slot.
    /// @param useBatchedFlow When true, dual-signed turns go through submitTurnMoves + executeBuffered
    ///      to warm the manager's per-storageKey buffer slots. When false, uses legacy
    ///      executeWithDualSignedMoves (faster warmup; matches the measured-legacy flow).
    function _runWarmupAndCapture(bool useBatchedFlow) internal returns (bytes32) {
        _setRegistryTeams(warmupTeam);
        bytes32 wkey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Turn 0 send-in via legacy (fast) regardless of flow mode.
        {
            uint64 t = 0;
            uint104 cSalt = uint104(uint256(keccak256(abi.encode("warm-c", wkey, t))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("warm-r", wkey, t))));
            bytes32 cHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, cSalt, uint16(0)));
            bytes memory rSig = _signDualReveal(address(mgr), P1_PK, wkey, t, cHash,
                SWITCH_MOVE_INDEX, rSalt, 0);
            vm.prank(vm.addr(P0_PK));
            mgr.executeWithDualSignedMoves(wkey, SWITCH_MOVE_INDEX, cSalt, 0,
                SWITCH_MOVE_INDEX, rSalt, 0, rSig);
            engine.resetCallContext();
        }

        // Keep firing one-shots (and forced switches) until someone wins.
        uint64 turn = 1;
        while (engine.getWinner(wkey) == address(0)) {
            uint8 flag = uint8(engine.getPlayerSwitchForTurnFlagForBattleState(wkey));

            uint104 cSalt = uint104(uint256(keccak256(abi.encode("warm-c", wkey, turn))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("warm-r", wkey, turn))));

            if (flag == 2) {
                if (useBatchedFlow) {
                    // Warm the manager's per-(storageKey,lane) buffer slots by going through
                    // submitTurnMoves + executeBuffered for the warmup dual-signed turns.
                    _submitTurnMoves(mgr, wkey, turn, uint8(0), 0, uint8(0), 0, P0_PK, P1_PK);
                    mgr.executeBuffered(wkey);
                } else {
                    (address committer,,) = engine.getCommitAuthForDualSigned(wkey);
                    uint256 cPk = committer == p0 ? P0_PK : P1_PK;
                    uint256 rPk = committer == p0 ? P1_PK : P0_PK;
                    bytes32 cHash = keccak256(abi.encodePacked(uint8(0), cSalt, uint16(0)));
                    bytes memory rSig = _signDualReveal(address(mgr), rPk, wkey, turn, cHash,
                        uint8(0), rSalt, 0);
                    vm.prank(vm.addr(cPk));
                    mgr.executeWithDualSignedMoves(wkey, uint8(0), cSalt, 0, uint8(0), rSalt, 0, rSig);
                }
            } else {
                // Forced switch (single-player). Use the legacy single endpoint regardless of mode.
                uint256[] memory active = engine.getActiveMonIndexForBattleState(wkey);
                uint256 switchTo = active[flag] + 1;
                if (switchTo >= MONS_PER_TEAM) switchTo = 0;
                address actingPlayer = flag == 0 ? p0 : p1;
                vm.prank(actingPlayer);
                mgr.executeSinglePlayerMove(wkey, SWITCH_MOVE_INDEX, cSalt, uint16(switchTo));
            }
            engine.resetCallContext();
            turn++;
            require(turn < 64, "warmup battle did not end within 64 turns");
        }

        require(engine.getWinner(wkey) != address(0), "warmup battle should end");

        // Swap back to high-HP team for the measured battle.
        _setRegistryTeams(measureTeam);
        return wkey;
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
    ///      Includes a warmup battle so the measured battle inherits warmed manager + engine
    ///      storage slots (true steady state).
    function _measureLegacy(uint256 nTurns) internal returns (uint256) {
        // Warmup battle: drives a battle to completion so the engine's MappingAllocator
        // frees the storageKey, which the measured battle reuses (warm SSTOREs).
        bytes32 warmKey = _runWarmupAndCapture(false);
        bytes32 battleKey = _startBattle();
        require(engine.getWinner(warmKey) != address(0), "STEADY-STATE PRECONDITION: warmup battle must end");
        require(
            engine.getStorageKey(warmKey) == engine.getStorageKey(battleKey),
            "STEADY-STATE PRECONDITION: measured battle should reuse warmup's storageKey"
        );
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch — not counted in the steady-state measurement.
        {
            uint64 t = 0;
            uint104 cSalt = uint104(uint256(keccak256(abi.encode("legacy-c", battleKey, t))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("legacy-r", battleKey, t))));
            bytes32 cHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, cSalt, uint16(0)));
            bytes memory rSig = _signDualReveal(address(mgr), P1_PK, battleKey, t, cHash,
                SWITCH_MOVE_INDEX, rSalt, 0);
            vm.prank(vm.addr(P0_PK));
            mgr.executeWithDualSignedMoves(battleKey, SWITCH_MOVE_INDEX, cSalt, 0,
                SWITCH_MOVE_INDEX, rSalt, 0, rSig);
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
            bytes memory rSig = _signDualReveal(address(mgr), rPk, battleKey, t, cHash, rMove, rSalt, rExtra);

            vm.prank(vm.addr(cPk));
            mgr.executeWithDualSignedMoves(battleKey, cMove, cSalt, cExtra, rMove, rSalt, rExtra, rSig);
            engine.resetCallContext();
        }
        return startGas - gasleft();
    }

    /// @dev Returns gas consumed for an identical N-turn battle via submit-then-batch.
    ///      Measured = total of (N submits + 1 executeBuffered). Lead-in turn 0 still goes
    ///      through the legacy single-turn flow so the steady-state comparison is apples-to-apples.
    function _measureBatched(uint256 nTurns) internal returns (uint256) {
        // Warmup uses the batched flow so the manager's per-storageKey buffer slots are also
        // warm in the measured battle (mirrors `BatchAccessProfileRealisticTest`).
        bytes32 warmKey = _runWarmupAndCapture(true);
        bytes32 battleKey = _startBattle();
        require(engine.getWinner(warmKey) != address(0), "STEADY-STATE PRECONDITION: warmup battle must end");
        require(
            engine.getStorageKey(warmKey) == engine.getStorageKey(battleKey),
            "STEADY-STATE PRECONDITION: measured battle should reuse warmup's storageKey"
        );
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch via legacy single-turn (not counted).
        {
            uint64 t = 0;
            uint104 cSalt = uint104(uint256(keccak256(abi.encode("batched-c", battleKey, t))));
            uint104 rSalt = uint104(uint256(keccak256(abi.encode("batched-r", battleKey, t))));
            bytes32 cHash = keccak256(abi.encodePacked(SWITCH_MOVE_INDEX, cSalt, uint16(0)));
            bytes memory rSig = _signDualReveal(address(mgr), P1_PK, battleKey, t, cHash,
                SWITCH_MOVE_INDEX, rSalt, 0);
            vm.prank(vm.addr(P0_PK));
            mgr.executeWithDualSignedMoves(battleKey, SWITCH_MOVE_INDEX, cSalt, 0,
                SWITCH_MOVE_INDEX, rSalt, 0, rSig);
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

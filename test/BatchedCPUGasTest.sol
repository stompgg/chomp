// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {IEffect} from "../src/effects/IEffect.sol";
import {IEngine} from "../src/IEngine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {IValidator} from "../src/IValidator.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {SimpleBatchedCPU} from "./mocks/SimpleBatchedCPU.sol";
import {OkayCPU} from "../src/cpu/OkayCPU.sol";
import {MockCPURNG} from "./mocks/MockCPURNG.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Gas comparison: legacy CPU (`OkayCPU.selectMove × N`) vs batched off-chain CPU
///         (`SimpleBatchedCPU.submitTurn × N + executeBuffered × 1`). Same warmup-then-measure
///         harness as `BatchGasTest`: drive battle 1 to completion so battle 2 reuses the
///         freed storage slots, then measure battle 2.
///
///         HARNESS BIAS: legacy is measured under one foundry tx, so per-tx cold-SLOAD
///         penalties don't reset between turns. The "prod" estimate adds back per-call cold
///         penalty + 21k tx-intrinsic to approximate the per-tx-fresh production cost. Cold
///         counts come from a per-call state-diff recording (production-faithful).
contract BatchedCPUGasTest is Test {
    Engine engine;
    SimpleBatchedCPU batchedCpu;
    OkayCPU legacyCpu;
    DefaultValidator validator;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;
    MockCPURNG mockRng;

    address constant ALICE = address(0xA11CE);

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 2;

    IMoveSet moveA;
    IMoveSet moveB;
    IMoveSet moveOneShot;
    Mon[] warmupTeam;
    Mon[] measureTeam;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        batchedCpu = new SimpleBatchedCPU(IEngine(address(engine)));
        mockRng = new MockCPURNG();
        legacyCpu = new OkayCPU(MOVES_PER_MON, engine, mockRng, typeCalc);
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 10})
        );
        typeCalc = new TestTypeCalculator();
        teamRegistry = new TestTeamRegistry();

        // Re-deploy legacyCpu now that typeCalc exists.
        legacyCpu = new OkayCPU(MOVES_PER_MON, engine, mockRng, typeCalc);

        StandardAttackFactory factory = new StandardAttackFactory(typeCalc);
        moveA = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "A", EFFECT: IEffect(address(0))
            })
        );
        moveB = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 25, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "B", EFFECT: IEffect(address(0))
            })
        );
        moveOneShot = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 250, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "X", EFFECT: IEffect(address(0))
            })
        );

        Mon memory warmupMon = Mon({
            stats: MonStats({
                hp: 20, stamina: 20, speed: 10, attack: 30, defense: 10,
                specialAttack: 30, specialDefense: 10, type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        warmupMon.moves[0] = uint256(uint160(address(moveOneShot)));
        warmupMon.moves[1] = uint256(uint160(address(moveB)));
        for (uint256 i; i < MONS_PER_TEAM; i++) warmupTeam.push(warmupMon);

        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100000, stamina: 20, speed: 10, attack: 30, defense: 10,
                specialAttack: 30, specialDefense: 10, type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));
        for (uint256 i; i < MONS_PER_TEAM; i++) measureTeam.push(mon);
    }

    function _setTeams(address cpuAddr, Mon[] storage team) internal {
        Mon[] memory teamMem = new Mon[](team.length);
        for (uint256 i; i < team.length; i++) teamMem[i] = team[i];
        teamRegistry.setTeam(ALICE, teamMem);
        teamRegistry.setTeam(cpuAddr, teamMem);
    }

    function _startLegacyBattle() internal returns (bytes32) {
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(legacyCpu);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE, p0TeamIndex: 0, p0TeamHash: bytes32(0),
            p1: address(legacyCpu), p1TeamIndex: 0,
            validator: validator, rngOracle: defaultOracle,
            ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(legacyCpu),
            matchmaker: legacyCpu
        });
        bytes32 battleKey = legacyCpu.startBattle(proposal);
        vm.stopPrank();
        return battleKey;
    }

    function _startBatchedBattle() internal returns (bytes32) {
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(batchedCpu);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE, p0TeamIndex: 0, p0TeamHash: bytes32(0),
            p1: address(batchedCpu), p1TeamIndex: 0,
            validator: validator, rngOracle: defaultOracle,
            ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(batchedCpu),
            matchmaker: batchedCpu
        });
        bytes32 battleKey = batchedCpu.startBattle(proposal);
        vm.stopPrank();
        return battleKey;
    }

    function _runLegacyWarmup() internal {
        _setTeams(address(legacyCpu), warmupTeam);
        bytes32 wkey = _startLegacyBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        uint8[6] memory aliceMoves = [SWITCH_MOVE_INDEX, uint8(0), SWITCH_MOVE_INDEX, 0, 0, 0];
        uint16[6] memory aliceExtras = [uint16(0), 0, 1, 0, 0, 0];
        for (uint256 i = 0; i < 6 && engine.getWinner(wkey) == address(0); i++) {
            vm.prank(ALICE);
            legacyCpu.selectMove(wkey, aliceMoves[i], uint104(uint256(keccak256(abi.encode("warm", i)))), aliceExtras[i]);
            engine.resetCallContext();
        }
        require(engine.getWinner(wkey) != address(0), "legacy warmup must end");
    }

    function _runBatchedWarmup() internal {
        _setTeams(address(batchedCpu), warmupTeam);
        bytes32 wkey = _startBatchedBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        // 4 turns covers: lead, attack-KO, forced-switch, attack-KO → game over.
        vm.prank(ALICE);
        batchedCpu.submitTurn(wkey, SWITCH_MOVE_INDEX, 0, uint104(1), SWITCH_MOVE_INDEX, 0, uint104(2));
        vm.prank(ALICE);
        batchedCpu.submitTurn(wkey, 0, 0, uint104(3), 0, 0, uint104(4));
        vm.prank(ALICE);
        batchedCpu.submitTurn(wkey, SWITCH_MOVE_INDEX, 1, uint104(5), SWITCH_MOVE_INDEX, 1, uint104(6));
        vm.prank(ALICE);
        batchedCpu.submitTurn(wkey, 0, 0, uint104(7), 0, 0, uint104(8));
        batchedCpu.executeBuffered(wkey);
        require(engine.getWinner(wkey) != address(0), "batched warmup must end");
    }

    function _resetState() internal {
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        batchedCpu = new SimpleBatchedCPU(IEngine(address(engine)));
        mockRng = new MockCPURNG();
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 10})
        );
        typeCalc = new TestTypeCalculator();
        legacyCpu = new OkayCPU(MOVES_PER_MON, engine, mockRng, typeCalc);
        teamRegistry = new TestTeamRegistry();
    }

    function _measureLegacy(uint256 nTurns) internal returns (uint256) {
        _resetState();
        _runLegacyWarmup();
        _setTeams(address(legacyCpu), measureTeam);
        bytes32 battleKey = _startLegacyBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch (turn 0), not counted.
        vm.prank(ALICE);
        legacyCpu.selectMove(battleKey, SWITCH_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();

        uint256 startGas = gasleft();
        for (uint256 i = 0; i < nTurns; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("legacy", battleKey, i))));
            vm.prank(ALICE);
            legacyCpu.selectMove(battleKey, aliceMove, salt, 0);
            engine.resetCallContext();
        }
        return startGas - gasleft();
    }

    function _measureBatched(uint256 nTurns) internal returns (uint256 submitGas, uint256 executeGas) {
        _resetState();
        _runBatchedWarmup();
        _setTeams(address(batchedCpu), measureTeam);
        bytes32 battleKey = _startBatchedBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch via submit (counts as turn 0 of buffer; we DON'T count it in the measurement
        // to mirror the legacy harness which skips its lead-in too).
        vm.prank(ALICE);
        batchedCpu.submitTurn(battleKey, SWITCH_MOVE_INDEX, 0, uint104(0), SWITCH_MOVE_INDEX, 0, uint104(0));

        uint256 startGas = gasleft();
        for (uint256 i = 0; i < nTurns; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint8 cpuMove = uint8((i + 1) % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("batched", battleKey, i))));
            vm.prank(ALICE);
            batchedCpu.submitTurn(battleKey, aliceMove, 0, salt, cpuMove, 0, salt);
        }
        submitGas = startGas - gasleft();

        uint256 g0 = gasleft();
        batchedCpu.executeBuffered(battleKey);
        executeGas = g0 - gasleft();
    }

    function _coldAccesses(Vm.AccountAccess[] memory diffs)
        internal pure returns (uint256 coldCount, uint256 totalSload, uint256 totalSstore)
    {
        bytes32[] memory seen = new bytes32[](512);
        uint256 seenN;
        for (uint256 i; i < diffs.length; i++) {
            Vm.StorageAccess[] memory sa = diffs[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.isWrite) totalSstore++; else totalSload++;
                bool found;
                for (uint256 k; k < seenN; k++) {
                    if (seen[k] == a.slot) { found = true; break; }
                }
                if (!found) {
                    seen[seenN++] = a.slot;
                    coldCount++;
                }
            }
        }
    }

    function _logComparison(string memory label, uint256 nTurns, uint256 legacyGas, uint256 submitGas, uint256 executeGas) internal {
        uint256 batchedTotal = submitGas + executeGas;
        console.log(label);
        console.log("  turns                          :", nTurns);
        console.log("  LEGACY total (single-tx warmth):", legacyGas);
        console.log("  BATCHED submits total          :", submitGas);
        console.log("  BATCHED executeBuffered        :", executeGas);
        console.log("  BATCHED total                  :", batchedTotal);
        if (batchedTotal < legacyGas) {
            console.log("  in-harness saves               :", legacyGas - batchedTotal);
        } else {
            console.log("  in-harness REGRESSION          :", batchedTotal - legacyGas);
        }
    }

    function test_batchedVsLegacy_B14() public {
        uint256 legacyGas = _measureLegacy(14);
        (uint256 submitGas, uint256 executeGas) = _measureBatched(14);
        _logComparison("=== CPU B=14 ===", 14, legacyGas, submitGas, executeGas);
    }

    function test_batchedVsLegacy_B8() public {
        uint256 legacyGas = _measureLegacy(8);
        (uint256 submitGas, uint256 executeGas) = _measureBatched(8);
        _logComparison("=== CPU B=8 ===", 8, legacyGas, submitGas, executeGas);
    }

    function test_batchedVsLegacy_B4() public {
        uint256 legacyGas = _measureLegacy(4);
        (uint256 submitGas, uint256 executeGas) = _measureBatched(4);
        _logComparison("=== CPU B=4 ===", 4, legacyGas, submitGas, executeGas);
    }

    /// @notice Authoritative per-tx cold-touch counts for the production estimate. Each
    ///         vm.startStateDiffRecording window represents one production tx — slots
    ///         first-touched per window pay the 2100g cold penalty in production.
    function test_accessTally_B14() public {
        // Legacy
        _resetState();
        _runLegacyWarmup();
        _setTeams(address(legacyCpu), measureTeam);
        bytes32 lkey = _startLegacyBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(ALICE);
        legacyCpu.selectMove(lkey, SWITCH_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();

        uint256 legacyCold;
        for (uint256 i = 0; i < 14; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("legacy-tally", lkey, i))));
            vm.startStateDiffRecording();
            vm.prank(ALICE);
            legacyCpu.selectMove(lkey, aliceMove, salt, 0);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
            engine.resetCallContext();
            (uint256 cold,,) = _coldAccesses(diffs);
            legacyCold += cold;
        }

        // Batched
        _resetState();
        _runBatchedWarmup();
        _setTeams(address(batchedCpu), measureTeam);
        bytes32 bkey = _startBatchedBattle();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(ALICE);
        batchedCpu.submitTurn(bkey, SWITCH_MOVE_INDEX, 0, uint104(0), SWITCH_MOVE_INDEX, 0, uint104(0));

        uint256 batchedSubmitCold;
        for (uint256 i = 0; i < 14; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint8 cpuMove = uint8((i + 1) % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("batched-tally", bkey, i))));
            vm.startStateDiffRecording();
            vm.prank(ALICE);
            batchedCpu.submitTurn(bkey, aliceMove, 0, salt, cpuMove, 0, salt);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
            (uint256 cold,,) = _coldAccesses(diffs);
            batchedSubmitCold += cold;
        }

        vm.startStateDiffRecording();
        batchedCpu.executeBuffered(bkey);
        Vm.AccountAccess[] memory execDiffs = vm.stopAndReturnStateDiff();
        (uint256 execCold,,) = _coldAccesses(execDiffs);

        console.log("=== ACCESS TALLY B=14 (production: each call own tx) ===");
        console.log("  LEGACY total cold first-touches :", legacyCold);
        console.log("  BATCHED submits cold first-touches:", batchedSubmitCold);
        console.log("  BATCHED execute cold first-touches:", execCold);
        console.log("  BATCHED total cold              :", batchedSubmitCold + execCold);
        console.log("  cold delta (legacy - batched)   :",
            int256(legacyCold) - int256(batchedSubmitCold + execCold));
        console.log("  each cold ~2000g penalty in prod");
    }
}

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

import {MockBatchedCPU} from "./mocks/MockBatchedCPU.sol";
import {CPUMoveManager} from "../src/cpu/CPUMoveManager.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice CPU batched-mode gas comparison: drive an N-turn CPU battle through legacy
///         `cpu.selectMove × N` vs batched `cpu.selectMoveWithStateHint × N + executeBuffered × 1`
///         and print the gas delta. Same warmup-then-measure harness as `BatchGasTest`:
///         run battle 1 to completion to warm storage slots / MappingAllocator's free list,
///         then start battle 2 (steady state) and measure.
///
///         HARNESS BIAS — same caveat as `BatchGasTest`: the legacy column is measured
///         inside ONE foundry tx so per-tx cold-SLOAD penalties don't reset between turns.
///         In production each `selectMove` is its own tx and pays cold-access fees per turn.
///         The "production legacy estimate" line adds back ~260 cold-SLOAD penalties + 14×
///         intrinsic tx cost (21k each) to approximate the per-tx-fresh production cost.
contract CPUBatchGasTest is Test {
    Engine engine;
    MockBatchedCPU cpu;
    DefaultValidator validator;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;

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
        cpu = new MockBatchedCPU(IEngine(address(engine)));
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 10})
        );
        typeCalc = new TestTypeCalculator();
        teamRegistry = new TestTeamRegistry();

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

        // Warmup team (low HP, one-shot move) — drives battle 1 to completion fast so battle 2
        // reuses the storageKey and effect slots in their warm post-prior-battle state.
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

        // Measured team (high HP) — 14 turns of attacks won't KO, so the battle stays in the
        // steady-state "both attack" loop the whole time.
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

    function _setRegistryTeams(Mon[] storage team) internal {
        Mon[] memory teamMem = new Mon[](team.length);
        for (uint256 i; i < team.length; i++) teamMem[i] = team[i];
        teamRegistry.setTeam(ALICE, teamMem);
        teamRegistry.setTeam(address(cpu), teamMem);
    }

    function _startCPUBattle() internal returns (bytes32) {
        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(cpu);
        engine.updateMatchmakers(makersToAdd, new address[](0));
        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: bytes32(0),
            p1: address(cpu),
            p1TeamIndex: 0,
            validator: validator,
            rngOracle: defaultOracle,
            ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(cpu),
            matchmaker: cpu
        });
        bytes32 battleKey = cpu.startBattle(proposal);
        vm.stopPrank();
        return battleKey;
    }

    /// @dev Drives a 2-mon low-HP battle to completion via legacy `selectMove`. After this the
    ///      storageKey is freed and the next `_startCPUBattle()` reuses it — battle 2's first
    ///      writes to BattleConfig/MonState/effect slots are nz→nz (warm) instead of z→nz (cold).
    function _runWarmupBattle() internal {
        _setRegistryTeams(warmupTeam);
        bytes32 wkey = _startCPUBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Script the CPU's moves: switch to mon 0, attack, switch to mon 1, attack.
        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](6);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        script[1] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        script[2] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 1});
        script[3] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        script[4] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        script[5] = MockBatchedCPU.ScriptedMove({moveIndex: 0, extraData: 0});
        cpu.setScript(script);

        uint8[6] memory aliceMoves = [SWITCH_MOVE_INDEX, uint8(0), SWITCH_MOVE_INDEX, 0, 0, 0];
        uint16[6] memory aliceExtras = [uint16(0), 0, 1, 0, 0, 0];

        for (uint256 i = 0; i < 6 && engine.getWinner(wkey) == address(0); i++) {
            vm.prank(ALICE);
            cpu.selectMove(wkey, aliceMoves[i], uint104(uint256(keccak256(abi.encode("warm", i)))), aliceExtras[i]);
            engine.resetCallContext();
        }
        require(engine.getWinner(wkey) != address(0), "warmup battle must end");
    }

    /// @dev Reset all state (engine + cpu + helpers) so we can re-measure cleanly. Mirrors
    ///      `BatchGasTest._resetForBatched`.
    function _resetForMeasure() internal {
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        cpu = new MockBatchedCPU(IEngine(address(engine)));
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 10})
        );
        teamRegistry = new TestTeamRegistry();
    }

    /// @dev Measure N turns of CPU legacy flow (one `selectMove` per turn).
    function _measureLegacyCPU(uint256 nTurns) internal returns (uint256) {
        _resetForMeasure();
        _runWarmupBattle();

        _setRegistryTeams(measureTeam);
        bytes32 battleKey = _startCPUBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Set up script for the CPU: switch on turn 0, alternate attack moves for measured turns.
        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](nTurns + 1);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        for (uint256 i = 1; i <= nTurns; i++) {
            script[i] = MockBatchedCPU.ScriptedMove({moveIndex: uint8(i % 2), extraData: 0});
        }
        cpu.setScript(script);

        // Lead-in switch (turn 0) — NOT counted (mirrors the BatchGasTest pattern).
        vm.prank(ALICE);
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();

        uint256 startGas = gasleft();
        for (uint256 i = 0; i < nTurns; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("legacy", battleKey, i))));
            vm.prank(ALICE);
            cpu.selectMove(battleKey, aliceMove, salt, 0);
            engine.resetCallContext();
        }
        return startGas - gasleft();
    }

    /// @dev Measure N turns via batched flow (N submits + 1 executeBuffered).
    function _measureBatchedCPU(uint256 nTurns) internal returns (uint256 submitGas, uint256 executeGas) {
        _resetForMeasure();
        _runWarmupBattle();

        _setRegistryTeams(measureTeam);
        bytes32 battleKey = _startCPUBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](nTurns + 1);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        for (uint256 i = 1; i <= nTurns; i++) {
            script[i] = MockBatchedCPU.ScriptedMove({moveIndex: uint8(i % 2), extraData: 0});
        }
        cpu.setScript(script);

        // Lead-in switch via legacy (NOT counted) — mirrors BatchGasTest.
        vm.prank(ALICE);
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();

        // Measured submits.
        uint256 startGas = gasleft();
        for (uint256 i = 0; i < nTurns; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("batched", battleKey, i))));
            CPUContext memory hint = engine.getCPUContext(battleKey);
            vm.prank(ALICE);
            cpu.selectMoveWithStateHint(battleKey, aliceMove, 0, salt, hint);
        }
        submitGas = startGas - gasleft();

        // Measured executeBuffered.
        uint256 g0 = gasleft();
        cpu.executeBuffered(battleKey);
        executeGas = g0 - gasleft();
        engine.resetCallContext();
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
        // Production estimate: empirical cold-touch counts from test_cpuBatchAccessTally_B14
        // show ~20 cold/legacy-tx and ~8 cold/batched-submit-tx + ~33 cold/executeBuffered-tx.
        // Scale linearly with N. ~2000g cold penalty per touch + 21k intrinsic per tx.
        uint256 legacyColdPenalty = nTurns * 20 * 2000;
        uint256 batchedColdPenalty = (nTurns * 8 * 2000) + (33 * 2000);
        uint256 legacyProd = legacyGas + legacyColdPenalty + nTurns * 21000;
        uint256 batchedProd = batchedTotal + batchedColdPenalty + (nTurns + 1) * 21000;
        console.log("  ---- production estimate ----");
        console.log("  LEGACY prod (cold + intrinsic):", legacyProd);
        console.log("  BATCHED prod                  :", batchedProd);
        if (batchedProd < legacyProd) {
            console.log("  prod saves                    :", legacyProd - batchedProd);
        } else {
            console.log("  prod REGRESSION               :", batchedProd - legacyProd);
        }
    }

    function test_cpuBatchGas_B14() public {
        uint256 legacyGas = _measureLegacyCPU(14);
        (uint256 submitGas, uint256 executeGas) = _measureBatchedCPU(14);
        _logComparison("=== CPU B=14 ===", 14, legacyGas, submitGas, executeGas);
    }

    function test_cpuBatchGas_B20() public {
        uint256 legacyGas = _measureLegacyCPU(20);
        (uint256 submitGas, uint256 executeGas) = _measureBatchedCPU(20);
        _logComparison("=== CPU B=20 ===", 20, legacyGas, submitGas, executeGas);
    }

    function test_cpuBatchGas_B30() public {
        uint256 legacyGas = _measureLegacyCPU(30);
        (uint256 submitGas, uint256 executeGas) = _measureBatchedCPU(30);
        _logComparison("=== CPU B=30 ===", 30, legacyGas, submitGas, executeGas);
    }

    function test_cpuBatchGas_B4() public {
        uint256 legacyGas = _measureLegacyCPU(4);
        (uint256 submitGas, uint256 executeGas) = _measureBatchedCPU(4);
        _logComparison("=== CPU B=4 ===", 4, legacyGas, submitGas, executeGas);
    }

    function test_cpuBatchGas_B8() public {
        uint256 legacyGas = _measureLegacyCPU(8);
        (uint256 submitGas, uint256 executeGas) = _measureBatchedCPU(8);
        _logComparison("=== CPU B=8 ===", 8, legacyGas, submitGas, executeGas);
    }

    // -----------------------------------------------------------------------
    // Access-tally test — authoritative cold/warm split per production tx
    // (each selectMove / selectMoveWithStateHint / executeBuffered is its own
    // tx, so we record each separately and sum). This is the ground truth
    // for the production cost estimate above.
    // -----------------------------------------------------------------------

    /// @dev Counts unique slots accessed per recording window. Each unique slot in a window pays
    ///      the cold-access penalty (2100g for SLOAD, 2100g extra for SSTORE) once per tx.
    function _coldAccesses(Vm.AccountAccess[] memory diffs) internal pure returns (uint256 coldCount, uint256 totalSload, uint256 totalSstore) {
        bytes32[] memory seenSlots = new bytes32[](512);
        uint256 seenN;
        for (uint256 i; i < diffs.length; i++) {
            Vm.StorageAccess[] memory sa = diffs[i].storageAccesses;
            for (uint256 j; j < sa.length; j++) {
                Vm.StorageAccess memory a = sa[j];
                if (a.isWrite) totalSstore++; else totalSload++;

                bool seen;
                for (uint256 k; k < seenN; k++) {
                    if (seenSlots[k] == a.slot) { seen = true; break; }
                }
                if (!seen) {
                    seenSlots[seenN++] = a.slot;
                    coldCount++;
                }
            }
        }
    }

    function test_cpuBatchAccessTally_B14() public {
        // ---- Legacy: 14 separate "tx" recordings, one per selectMove. ----
        _resetForMeasure();
        _runWarmupBattle();
        _setRegistryTeams(measureTeam);
        bytes32 legacyKey = _startCPUBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        MockBatchedCPU.ScriptedMove[] memory script = new MockBatchedCPU.ScriptedMove[](15);
        script[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        for (uint256 i = 1; i <= 14; i++) {
            script[i] = MockBatchedCPU.ScriptedMove({moveIndex: uint8(i % 2), extraData: 0});
        }
        cpu.setScript(script);

        // Lead-in switch (not counted).
        vm.prank(ALICE);
        cpu.selectMove(legacyKey, SWITCH_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();

        uint256 legacyTotalCold;
        uint256 legacyTotalSload;
        uint256 legacyTotalSstore;
        for (uint256 i = 0; i < 14; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("legacy-tally", legacyKey, i))));
            vm.startStateDiffRecording();
            vm.prank(ALICE);
            cpu.selectMove(legacyKey, aliceMove, salt, 0);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
            engine.resetCallContext();

            (uint256 cold, uint256 sl, uint256 ss) = _coldAccesses(diffs);
            legacyTotalCold += cold;
            legacyTotalSload += sl;
            legacyTotalSstore += ss;
        }

        // ---- Batched: 14 submits (each own tx) + 1 executeBuffered (own tx). ----
        _resetForMeasure();
        _runWarmupBattle();
        _setRegistryTeams(measureTeam);
        bytes32 batchedKey = _startCPUBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        MockBatchedCPU.ScriptedMove[] memory script2 = new MockBatchedCPU.ScriptedMove[](15);
        script2[0] = MockBatchedCPU.ScriptedMove({moveIndex: SWITCH_MOVE_INDEX, extraData: 0});
        for (uint256 i = 1; i <= 14; i++) {
            script2[i] = MockBatchedCPU.ScriptedMove({moveIndex: uint8(i % 2), extraData: 0});
        }
        cpu.setScript(script2);

        // Lead-in switch via legacy (not counted).
        vm.prank(ALICE);
        cpu.selectMove(batchedKey, SWITCH_MOVE_INDEX, uint104(0), 0);
        engine.resetCallContext();

        uint256 batchedSubmitCold;
        uint256 batchedSubmitSload;
        uint256 batchedSubmitSstore;
        for (uint256 i = 0; i < 14; i++) {
            uint8 aliceMove = uint8(i % 2);
            uint104 salt = uint104(uint256(keccak256(abi.encode("batched-tally", batchedKey, i))));
            CPUContext memory hint = engine.getCPUContext(batchedKey);
            vm.startStateDiffRecording();
            vm.prank(ALICE);
            cpu.selectMoveWithStateHint(batchedKey, aliceMove, 0, salt, hint);
            Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();

            (uint256 cold, uint256 sl, uint256 ss) = _coldAccesses(diffs);
            batchedSubmitCold += cold;
            batchedSubmitSload += sl;
            batchedSubmitSstore += ss;
        }

        vm.startStateDiffRecording();
        cpu.executeBuffered(batchedKey);
        Vm.AccountAccess[] memory execDiffs = vm.stopAndReturnStateDiff();
        engine.resetCallContext();
        (uint256 execCold, uint256 execSload, uint256 execSstore) = _coldAccesses(execDiffs);

        console.log("=== CPU B=14 ACCESS TALLY (production: each call own tx) ===");
        console.log("");
        console.log("LEGACY (14 selectMove txs, summed):");
        console.log("  total SLOADs           :", legacyTotalSload);
        console.log("  total SSTOREs          :", legacyTotalSstore);
        console.log("  cold first-touches     :", legacyTotalCold);
        console.log("");
        console.log("BATCHED submits (14 selectMoveWithStateHint txs, summed):");
        console.log("  total SLOADs           :", batchedSubmitSload);
        console.log("  total SSTOREs          :", batchedSubmitSstore);
        console.log("  cold first-touches     :", batchedSubmitCold);
        console.log("");
        console.log("BATCHED executeBuffered (1 tx):");
        console.log("  total SLOADs           :", execSload);
        console.log("  total SSTOREs          :", execSstore);
        console.log("  cold first-touches     :", execCold);
        console.log("");
        console.log("DELTA (production-faithful):");
        console.log("  cold-touch difference (legacy - batched):",
            int256(legacyTotalCold) - int256(batchedSubmitCold + execCold));
        console.log("  each cold-touch adds ~2000g penalty in production");
    }
}


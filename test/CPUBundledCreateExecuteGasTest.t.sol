// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {DefaultValidator} from "../src/DefaultValidator.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {IEffect} from "../src/effects/IEffect.sol";

import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Isolates the Engine-level gas delta from bundling CPU battle creation into the one-tx
///         batch-execute call: `startBattle` + `executeBatchedTurns` (2 calls, the pre-existing
///         CPU flow) vs the new `startBattleAndExecuteBatchedTurns` (1 call). Talks to Engine
///         directly (this test contract acts as its own moveManager/matchmaker) so the numbers
///         aren't diluted by CPU-heuristic or team-registry setup cost.
contract CPUBundledCreateExecuteGasTest is Test {
    address constant ALICE = address(0x1);
    address constant CPU_OLD = address(0xC9); // distinct p1 for the OLD-flow measurement
    address constant CPU_NEW = address(0xCA); // distinct p1 for the NEW-flow measurement (fresh key, fair COLD compare)
    // Base per-transaction cost (21000, EIP-2028 baseline) the OLD flow pays a SECOND time since
    // it's two real transactions; the NEW flow pays it once. Foundry's gasleft() deltas across
    // internal calls within one test never include this, so it's added back in explicitly.
    uint256 constant INTRINSIC_TX_GAS = 21000;

    Engine engine;
    TestTeamRegistry teamRegistry;
    DefaultValidator validator;
    DefaultRandomnessOracle oracle;
    IMoveSet attackMove;

    function setUp() public {
        engine = new Engine(0, 0);
        teamRegistry = new TestTeamRegistry();
        oracle = new DefaultRandomnessOracle();
        validator =
            new DefaultValidator(engine, DefaultValidator.Args({MONS_PER_TEAM: 1, MOVES_PER_MON: 1, TIMEOUT_DURATION: 10}));
        TestTypeCalculator typeCalc = new TestTypeCalculator();
        StandardAttackFactory attackFactory = new StandardAttackFactory(typeCalc);
        attackMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: Type.Liquid,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "m1",
                EFFECT: IEffect(address(0))
            })
        );

        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(attackMove)));
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 100,
                stamina: 10,
                speed: 2,
                attack: 1,
                defense: 1,
                specialAttack: 1,
                specialDefense: 1,
                type1: Type.Liquid,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
        Mon[] memory team = new Mon[](1);
        team[0] = mon;
        teamRegistry.setTeam(ALICE, team);
        teamRegistry.setTeam(CPU_OLD, team);
        teamRegistry.setTeam(CPU_NEW, team);

        address[] memory mk = new address[](1);
        mk[0] = address(this);
        vm.prank(ALICE);
        engine.updateMatchmakers(mk, new address[](0));
        vm.prank(CPU_OLD);
        engine.updateMatchmakers(mk, new address[](0));
        vm.prank(CPU_NEW);
        engine.updateMatchmakers(mk, new address[](0));
    }

    function _battle(address p1) internal view returns (Battle memory) {
        return Battle({
            p0: ALICE,
            p0TeamIndex: 0,
            p1: p1,
            p1TeamIndex: 0,
            teamRegistry: teamRegistry,
            validator: validator,
            rngOracle: oracle,
            ruleset: IRuleset(address(0)),
            engineHooks: new IEngineHook[](0),
            moveManager: address(this),
            matchmaker: IMatchmaker(address(this))
        });
    }

    /// @dev Turn 0 is a mandatory send-in (switch), then two non-concluding attack turns (100 HP
    ///      mon, 1 dmg/hit) so both flows exercise the same amount of real turn work without
    ///      tripping battle-conclusion logic.
    function _threeTurnEntries() internal pure returns (uint256[] memory entries) {
        entries = new uint256[](3);
        // Turn 0: both switch in mon 0 (extraData = 0).
        entries[0] = uint256(SWITCH_MOVE_INDEX) | (uint256(SWITCH_MOVE_INDEX) << 128);
        for (uint256 i = 1; i < 3; ++i) {
            uint256 p0Move = 0; // raw move index 0 -> the only registered move
            uint256 p1Move = 0;
            uint104 salt = uint104(uint256(keccak256(abi.encode("salt", i))));
            entries[i] = p0Move | (p1Move << 128) | (uint256(salt) << 24);
        }
    }

    // NOTE: OLD and NEW are measured in SEPARATE test functions (each gets its own fresh Engine
    // via setUp()) rather than side-by-side in one test. MappingAllocator's free-storage-key list
    // is a single shared stack — priming+freeing a key for OLD and then for NEW in the same test
    // would let NEW's own prime steal OLD's freed slot (and vice versa for whichever measurement
    // runs second), silently turning a "warm" measurement into a cold one. Isolating per-test
    // sidesteps that race entirely.

    function test_gas_oldFlow_cold() public {
        uint256[] memory entries = _threeTurnEntries();
        (bytes32 key,) = engine.computeBattleKey(ALICE, CPU_OLD);

        uint256 g0 = gasleft();
        engine.startBattle(_battle(CPU_OLD));
        uint256 startGas = g0 - gasleft();
        engine.resetCallContext();

        // In production this is a SEPARATE transaction: any storage startBattle just wrote (e.g.
        // BattleConfig/BattleData) would be cold again on the next tx's access list. vm.cool
        // simulates that tx boundary; without it, executeBatchedTurns here would unrealistically
        // benefit from warmth left behind by startBattle within this single test call.
        vm.cool(address(engine));

        uint256 g1 = gasleft();
        engine.executeBatchedTurns(key, entries);
        uint256 execGas = g1 - gasleft();
        engine.resetCallContext();

        console.log("");
        console.log("=== OLD flow (startBattle + executeBatchedTurns as 2 real txs), COLD ===");
        console.log("  startBattle gas          :", startGas);
        console.log("  executeBatchedTurns gas  :", execGas);
        console.log("  + 2nd tx intrinsic base  :", INTRINSIC_TX_GAS);
        console.log("  TOTAL                    :", startGas + execGas + INTRINSIC_TX_GAS);
    }

    function test_gas_newFlow_cold() public {
        uint256[] memory entries = _threeTurnEntries();

        uint256 g0 = gasleft();
        engine.startBattleAndExecuteBatchedTurns(_battle(CPU_NEW), entries);
        uint256 totalGas = g0 - gasleft();
        engine.resetCallContext();

        console.log("");
        console.log("=== NEW flow (startBattleAndExecuteBatchedTurns), COLD ===");
        console.log("  TOTAL                   :", totalGas);
    }

    function test_gas_oldFlow_warmRecycledKey() public {
        uint256[] memory entries = _threeTurnEntries();

        // Prime + free a key so the measured call recycles an already-initialized storageKey
        // (the realistic steady state after the first-ever battle on this key). NOTE:
        // computeBattleKey mixes in a per-pair nonce that startBattle bumps on every call, so the
        // battleKey itself is NOT stable across repeated startBattle calls for the same (p0,p1) —
        // only the underlying storage slot is recycled. Re-fetch the key fresh right before the
        // call whose key we actually need (StartBattleGasTest.t.sol follows the same pattern).
        (bytes32 primeKey,) = engine.computeBattleKey(ALICE, CPU_OLD);
        engine.startBattle(_battle(CPU_OLD));
        engine.resetCallContext();
        vm.warp(vm.getBlockTimestamp() + MAX_BATTLE_DURATION + 1);
        engine.end(primeKey);
        engine.resetCallContext();

        (bytes32 key,) = engine.computeBattleKey(ALICE, CPU_OLD);
        uint256 g0 = gasleft();
        engine.startBattle(_battle(CPU_OLD));
        uint256 startGas = g0 - gasleft();
        engine.resetCallContext();

        // Simulate the real tx boundary between startBattle and executeBatchedTurns — see the
        // comment in test_gas_oldFlow_cold.
        vm.cool(address(engine));

        uint256 g1 = gasleft();
        engine.executeBatchedTurns(key, entries);
        uint256 execGas = g1 - gasleft();
        engine.resetCallContext();

        console.log("");
        console.log("=== OLD flow (startBattle + executeBatchedTurns as 2 real txs), WARM recycled key ===");
        console.log("  startBattle gas          :", startGas);
        console.log("  executeBatchedTurns gas  :", execGas);
        console.log("  + 2nd tx intrinsic base  :", INTRINSIC_TX_GAS);
        console.log("  TOTAL                    :", startGas + execGas + INTRINSIC_TX_GAS);
    }

    function test_gas_newFlow_warmRecycledKey() public {
        uint256[] memory entries = _threeTurnEntries();

        (bytes32 key,) = engine.computeBattleKey(ALICE, CPU_NEW);
        engine.startBattle(_battle(CPU_NEW));
        engine.resetCallContext();
        vm.warp(vm.getBlockTimestamp() + MAX_BATTLE_DURATION + 1);
        engine.end(key);
        engine.resetCallContext();

        uint256 g0 = gasleft();
        engine.startBattleAndExecuteBatchedTurns(_battle(CPU_NEW), entries);
        uint256 totalGas = g0 - gasleft();
        engine.resetCallContext();

        console.log("");
        console.log("=== NEW flow (startBattleAndExecuteBatchedTurns), WARM recycled key ===");
        console.log("  TOTAL                   :", totalGas);
    }
}

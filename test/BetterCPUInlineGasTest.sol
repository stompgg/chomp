// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";

import {DefaultCommitManager} from "../src/commit-manager/DefaultCommitManager.sol";
import {BetterCPU} from "../src/cpu/BetterCPU.sol";

import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {MockCPURNG} from "./mocks/MockCPURNG.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

import {IEffect} from "../src/effects/IEffect.sol";
import {IValidator} from "../src/IValidator.sol";

import {DefaultMatchmaker} from "../src/matchmaker/DefaultMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";

/// @title BetterCPU inline-validator gas benchmark
/// @notice Measures BetterCPU.selectMove cost in the production-shape configuration:
///         validator == address(0) (inline validation via the engine's immutable defaults).
///         The existing BetterCPUTest suite uses DefaultValidator and therefore never hits
///         CPU.sol's inline validation fast path, so its numbers understate the production
///         savings from getCPURouteContext + inline-validation-in-CPU.
contract BetterCPUInlineGasTest is Test {
    Engine engine;
    DefaultCommitManager commitManager;
    BetterCPU cpu;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;
    MockCPURNG mockCPURNG;
    DefaultMatchmaker matchmaker;
    StandardAttackFactory attackFactory;

    address constant ALICE = address(1);

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        // Engine constructed with real inline-validation bounds so validator == address(0) works.
        engine = new Engine(4, 4, 10);
        commitManager = new DefaultCommitManager(engine);
        mockCPURNG = new MockCPURNG();
        typeCalc = new TestTypeCalculator();
        teamRegistry = new TestTeamRegistry();
        matchmaker = new DefaultMatchmaker(engine);
        attackFactory = new StandardAttackFactory(typeCalc);
    }

    function _createMon(Type t, uint32 hp, uint32 attack, uint32 defense) internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: hp,
                stamina: 10,
                speed: 10,
                attack: attack,
                defense: defense,
                specialAttack: attack,
                specialDefense: defense,
                type1: t,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
    }

    function _createAttack(uint32 basePower, Type moveType, MoveClass moveClass) internal returns (IMoveSet) {
        return attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: basePower,
                STAMINA_COST: 1,
                ACCURACY: 100,
                PRIORITY: 1,
                MOVE_TYPE: moveType,
                EFFECT_ACCURACY: 0,
                MOVE_CLASS: moveClass,
                CRIT_RATE: 0,
                VOLATILITY: 0,
                NAME: "Attack",
                EFFECT: IEffect(address(0))
            })
        );
    }

    function _startBattleInline(Mon[] memory aliceTeam, Mon[] memory cpuTeam) internal returns (bytes32) {
        cpu = new BetterCPU(4, engine, mockCPURNG, typeCalc);

        teamRegistry.setTeam(ALICE, aliceTeam);
        teamRegistry.setTeam(address(cpu), cpuTeam);

        ProposedBattle memory proposal = ProposedBattle({
            p0: ALICE,
            p0TeamIndex: 0,
            p0TeamHash: keccak256(
                abi.encodePacked(bytes32(""), uint256(0), teamRegistry.getMonRegistryIndicesForTeam(ALICE, 0))
            ),
            p1: address(cpu),
            p1TeamIndex: 0,
            validator: IValidator(address(0)), // inline validation
            rngOracle: defaultOracle,
            ruleset: IRuleset(address(0)),
            teamRegistry: teamRegistry,
            engineHooks: new IEngineHook[](0),
            moveManager: address(cpu),
            matchmaker: cpu
        });

        vm.startPrank(ALICE);
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(cpu);
        address[] memory makersToRemove = new address[](0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        return cpu.startBattle(proposal);
    }

    function _buildFourMoveSet() internal returns (uint256[] memory moves) {
        IMoveSet[] memory moveSet = new IMoveSet[](4);
        moveSet[0] = _createAttack(20, Type.Fire, MoveClass.Physical);
        moveSet[1] = _createAttack(40, Type.Fire, MoveClass.Physical);
        moveSet[2] = _createAttack(10, Type.Fire, MoveClass.Special);
        moveSet[3] = _createAttack(30, Type.Fire, MoveClass.Special);
        moves = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            moves[i] = uint256(uint160(address(moveSet[i])));
        }
    }

    /// @notice Hot path: both-players-move turns (flag == 2). Mon HP and defense are tuned so
    ///         no KOs fire during the measured window, keeping all sampled turns on the same
    ///         path through BetterCPU.calculateMove + CPU._calculateValidMoves.
    function test_betterCPUInlineGas_flag2_hotPath() public {
        uint256[] memory moves = _buildFourMoveSet();

        Mon[] memory aliceTeam = new Mon[](4);
        Mon[] memory cpuTeam = new Mon[](4);
        for (uint256 i = 0; i < 4; i++) {
            // High HP + high defense so 4 turns of attacks never KO anyone.
            aliceTeam[i] = _createMon(Type.Fire, 10000, 10, 1000);
            aliceTeam[i].moves = moves;
            cpuTeam[i] = _createMon(Type.Fire, 10000, 10, 1000);
            cpuTeam[i].moves = moves;
        }

        bytes32 battleKey = _startBattleInline(aliceTeam, cpuTeam);
        vm.warp(vm.getBlockTimestamp() + 1);
        mockCPURNG.setRNG(0);

        // Turn 0: lead selection. Both players "switch in" a starting mon.
        vm.startSnapshotGas("Turn0_Lead");
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));
        uint256 turn0Gas = vm.stopSnapshotGas("Turn0_Lead");
        engine.resetCallContext();

        // Turns 1-4: both attack with move 1. Every one is flag == 2, no KOs.
        vm.startSnapshotGas("Turn1_BothAttack");
        cpu.selectMove(battleKey, 1, "", 0);
        uint256 turn1Gas = vm.stopSnapshotGas("Turn1_BothAttack");
        engine.resetCallContext();

        vm.startSnapshotGas("Turn2_BothAttack");
        cpu.selectMove(battleKey, 1, "", 0);
        uint256 turn2Gas = vm.stopSnapshotGas("Turn2_BothAttack");
        engine.resetCallContext();

        vm.startSnapshotGas("Turn3_BothAttack");
        cpu.selectMove(battleKey, 1, "", 0);
        uint256 turn3Gas = vm.stopSnapshotGas("Turn3_BothAttack");
        engine.resetCallContext();

        vm.startSnapshotGas("Turn4_BothAttack");
        cpu.selectMove(battleKey, 1, "", 0);
        uint256 turn4Gas = vm.stopSnapshotGas("Turn4_BothAttack");
        engine.resetCallContext();

        // Sanity check: no winner yet.
        assertEq(engine.getWinner(battleKey), address(0), "battle must still be in progress");
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(battleKey), 2, "flag must still be 2");

        uint256 avgBothAttack = (turn1Gas + turn2Gas + turn3Gas + turn4Gas) / 4;

        console.log("========================================");
        console.log("BetterCPU inline, flag==2 hot path");
        console.log("========================================");
        console.log("Turn 0 (lead select)                       :", turn0Gas);
        console.log("Turn 1 (both attack, flag=2)               :", turn1Gas);
        console.log("Turn 2 (both attack, flag=2)               :", turn2Gas);
        console.log("Turn 3 (both attack, flag=2)               :", turn3Gas);
        console.log("Turn 4 (both attack, flag=2)               :", turn4Gas);
        console.log("Average flag=2 BetterCPU.selectMove        :", avgBothAttack);
        console.log("========================================");
    }

    /// @notice Cheap-router path: a turn where Alice is the only player that must act
    ///         (flag == 0) because CPU's previous move KO'd Alice's active mon. On this turn
    ///         CPUMoveManager.selectMove should fetch getCPURouteContext (~3.4k) and call
    ///         executeWithSingleMove directly, without ever touching getCPUContext or
    ///         BetterCPU.calculateMove.
    function test_betterCPUInlineGas_flag0_cheapRouter() public {
        uint256[] memory moves = _buildFourMoveSet();

        // CPU hits hard: one move dispatch KOs Alice's mon.
        Mon[] memory aliceTeam = new Mon[](4);
        Mon[] memory cpuTeam = new Mon[](4);
        for (uint256 i = 0; i < 4; i++) {
            aliceTeam[i] = _createMon(Type.Fire, 50, 10, 10);
            aliceTeam[i].moves = moves;
            cpuTeam[i] = _createMon(Type.Fire, 100, 200, 10);
            cpuTeam[i].moves = moves;
        }

        bytes32 battleKey = _startBattleInline(aliceTeam, cpuTeam);
        vm.warp(vm.getBlockTimestamp() + 1);
        mockCPURNG.setRNG(0);

        // Turn 0: lead.
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(0));
        engine.resetCallContext();

        // Turn 1: both attack. CPU's move 1 (BP=40, attack=200, defense=10) should KO Alice.
        cpu.selectMove(battleKey, 1, "", 0);
        engine.resetCallContext();

        // After the KO we should be in flag==0 (Alice forced switch).
        uint256 flag = engine.getPlayerSwitchForTurnFlagForBattleState(battleKey);
        assertEq(flag, 0, "expected flag==0 forced p0 switch after KO");

        // Measure the cheap-router path: Alice submits her switch via the CPU manager.
        vm.startSnapshotGas("Flag0_P0ForcedSwitch");
        cpu.selectMove(battleKey, SWITCH_MOVE_INDEX, 0, uint240(1));
        uint256 flag0Gas = vm.stopSnapshotGas("Flag0_P0ForcedSwitch");
        engine.resetCallContext();

        console.log("========================================");
        console.log("BetterCPU inline, flag==0 cheap-router path");
        console.log("========================================");
        console.log("Flag==0 selectMove (p0 forced switch, CPU manager):", flag0Gas);
        console.log("========================================");
    }
}

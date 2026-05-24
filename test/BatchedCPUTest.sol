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
import {IRuleset} from "../src/IRuleset.sol";
import {StandardAttackFactory} from "../src/moves/StandardAttackFactory.sol";
import {ATTACK_PARAMS} from "../src/moves/StandardAttackStructs.sol";
import {DefaultRandomnessOracle} from "../src/rng/DefaultRandomnessOracle.sol";

import {SimpleBatchedCPU} from "./mocks/SimpleBatchedCPU.sol";
import {BatchedCPUMoveManager} from "../src/cpu/BatchedCPUMoveManager.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Functional tests for `BatchedCPUMoveManager` — the off-chain-CPU variant where the
///         player supplies both her move and the CPU's response per turn.
contract BatchedCPUTest is Test {
    Engine engine;
    SimpleBatchedCPU cpu;
    DefaultValidator validator;
    DefaultRandomnessOracle defaultOracle;
    TestTypeCalculator typeCalc;
    TestTeamRegistry teamRegistry;

    address constant ALICE = address(0xA11CE);

    uint256 constant MONS_PER_TEAM = 2;
    uint256 constant MOVES_PER_MON = 2;

    IMoveSet moveA;
    IMoveSet moveB;

    function setUp() public {
        defaultOracle = new DefaultRandomnessOracle();
        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        cpu = new SimpleBatchedCPU(IEngine(address(engine)));
        validator = new DefaultValidator(
            engine,
            DefaultValidator.Args({MONS_PER_TEAM: MONS_PER_TEAM, MOVES_PER_MON: MOVES_PER_MON, TIMEOUT_DURATION: 10})
        );
        typeCalc = new TestTypeCalculator();
        teamRegistry = new TestTeamRegistry();

        StandardAttackFactory factory = new StandardAttackFactory(typeCalc);
        moveA = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 50, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "A", EFFECT: IEffect(address(0))
            })
        );
        moveB = factory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 40, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "B", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon();
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));
        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        teamRegistry.setTeam(ALICE, team);
        teamRegistry.setTeam(address(cpu), team);
    }

    function _createMon() internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 20, stamina: 20, speed: 10, attack: 30, defense: 10,
                specialAttack: 30, specialDefense: 10, type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
    }

    function _startBattle() internal returns (bytes32) {
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

    function _submit(
        bytes32 battleKey,
        uint8 pMove, uint16 pExtra, uint104 pSalt,
        uint8 cMove, uint16 cExtra, uint104 cSalt
    ) internal {
        vm.prank(ALICE);
        cpu.submitTurn(battleKey, pMove, pExtra, pSalt, cMove, cExtra, cSalt);
    }

    function test_submitAndExecute_singleTurn() public {
        bytes32 battleKey = _startBattle();

        // Lead-select: both sides switch to mon 0.
        _submit(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1), SWITCH_MOVE_INDEX, 0, uint104(2));

        (uint64 ex, uint64 buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 0, "pre-execute: numExecuted");
        assertEq(buf, 1, "pre-execute: numBuffered");

        cpu.executeBuffered(battleKey);

        (ex, buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 1, "post-execute: numExecuted");
        assertEq(buf, 0, "post-execute: numBuffered");
        assertEq(engine.getTurnIdForBattleState(battleKey), 1, "engine turnId advanced");

        uint256[] memory active = engine.getActiveMonIndexForBattleState(battleKey);
        assertEq(active[0], 0, "player active mon");
        assertEq(active[1], 0, "cpu active mon");
    }

    function test_multiBatchCounterAccounting() public {
        bytes32 battleKey = _startBattle();

        // Batch 1: 4 turns (lead + 3 attacks).
        _submit(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1), SWITCH_MOVE_INDEX, 0, uint104(2));
        _submit(battleKey, NO_OP_MOVE_INDEX, 0, uint104(3), NO_OP_MOVE_INDEX, 0, uint104(4));
        _submit(battleKey, NO_OP_MOVE_INDEX, 0, uint104(5), NO_OP_MOVE_INDEX, 0, uint104(6));
        _submit(battleKey, NO_OP_MOVE_INDEX, 0, uint104(7), NO_OP_MOVE_INDEX, 0, uint104(8));

        (uint64 ex, uint64 buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 0, "batch1 pre: ex");
        assertEq(buf, 4, "batch1 pre: buf");

        cpu.executeBuffered(battleKey);
        (ex, buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 4, "batch1 post: ex");
        assertEq(buf, 0, "batch1 post: buf");

        // Batch 2: 2 more turns.
        _submit(battleKey, NO_OP_MOVE_INDEX, 0, uint104(9), NO_OP_MOVE_INDEX, 0, uint104(10));
        _submit(battleKey, NO_OP_MOVE_INDEX, 0, uint104(11), NO_OP_MOVE_INDEX, 0, uint104(12));
        (ex, buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 4, "batch2 pre: ex unchanged");
        assertEq(buf, 2, "batch2 pre: buf");

        cpu.executeBuffered(battleKey);
        (ex, buf,) = cpu.getBufferStatus(battleKey);
        assertEq(ex, 6, "batch2 post: ex");
        assertEq(buf, 0, "batch2 post: buf");
        assertEq(engine.getTurnIdForBattleState(battleKey), 6, "engine turnId after batch2");
    }

    function test_revertsForNonP0() public {
        bytes32 battleKey = _startBattle();
        vm.prank(address(0xBAD));
        vm.expectRevert(BatchedCPUMoveManager.NotP0.selector);
        cpu.submitTurn(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1), SWITCH_MOVE_INDEX, 0, uint104(2));
    }

    function test_emptyBufferReverts() public {
        bytes32 battleKey = _startBattle();
        vm.expectRevert(BatchedCPUMoveManager.EmptyBuffer.selector);
        cpu.executeBuffered(battleKey);
    }

    function test_revertsAfterGameOver() public {
        bytes32 battleKey = _startBattle();
        vm.warp(block.timestamp + 1);

        // 4 turns drives 2-mon HP=20 team to game-over (1-hit-KO each).
        _submit(battleKey, SWITCH_MOVE_INDEX, 0, uint104(1), SWITCH_MOVE_INDEX, 0, uint104(2));
        _submit(battleKey, 0, 0, uint104(3), 0, 0, uint104(4));
        _submit(battleKey, SWITCH_MOVE_INDEX, 1, uint104(5), SWITCH_MOVE_INDEX, 1, uint104(6));
        _submit(battleKey, 0, 0, uint104(7), 0, 0, uint104(8));
        cpu.executeBuffered(battleKey);

        assertTrue(engine.getWinner(battleKey) != address(0), "battle ended");

        vm.prank(ALICE);
        vm.expectRevert(BatchedCPUMoveManager.BattleAlreadyComplete.selector);
        cpu.submitTurn(battleKey, 0, 0, uint104(9), 0, 0, uint104(10));
    }

    function test_bufferedTurnReadback() public {
        bytes32 battleKey = _startBattle();
        _submit(battleKey, 7, 42, uint104(0xCAFE), 9, 99, uint104(0xBEEF));
        (uint8 pm, uint16 pe, uint104 ps, uint8 cm, uint16 ce, uint104 cs) = cpu.getBufferedTurn(battleKey, 0);
        assertEq(pm, 7);
        assertEq(pe, 42);
        assertEq(uint256(ps), uint256(uint104(0xCAFE)));
        assertEq(cm, 9);
        assertEq(ce, 99);
        assertEq(uint256(cs), uint256(uint104(0xBEEF)));
    }
}

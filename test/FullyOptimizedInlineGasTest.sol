// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";


import {SignedCommitManager} from "../src/commit-manager/SignedCommitManager.sol";
import {Engine} from "../src/Engine.sol";
import {IEngine} from "../src/IEngine.sol";
import {IValidator} from "../src/IValidator.sol";
import {SignedCommitHelper} from "./abstract/SignedCommitHelper.sol";


import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";

import {EffectAttack} from "./mocks/EffectAttack.sol";
import {StatBoostsMove} from "./mocks/StatBoostsMove.sol";

import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../src/effects/status/FrostbiteStatus.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";

import {IEngineHook} from "../src/IEngineHook.sol";

import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @title Inline Engine Gas Test
/// @notice Same as EngineGasTest but uses inline validation (address(0) validator) for comparison
/// @title Fully Optimized Inline Gas Test
/// @notice Mirrors the battle sequences from InlineEngineGasTest but stacks every
///         available optimization: inline validation (address(0) validator),
///         inline RNG (address(0) oracle), inline stamina regen,
///         SignedMatchmaker (no propose/accept/confirm storage), and
///         SignedCommitManager::executeWithDualSignedMoves (1 TX per two-player turn).
/// @dev Forced single-player switches after KOs use SignedCommitManager::executeSinglePlayerMove.
contract FullyOptimizedInlineGasTest is BattleHelper, SignedCommitHelper {

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

    // Storage used by _analyzeSteps to track warm/cold SLOAD/SSTORE access
    // across one pass. Cleared between passes.
    mapping(bytes32 => bool) private _seenSlot;
    bytes32[] private _seenKeys;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        signedCommitManager = new SignedCommitManager(IEngine(address(engine)));
        signedMatchmaker = new SignedMatchmaker(engine);
        typeCalc = new TestTypeCalculator();
        defaultRegistry = new TestTeamRegistry();
    }

    /// @dev Starts a battle via SignedMatchmaker::startGame (1 TX instead of 3).
    ///      Also authorizes the matchmaker each call to mirror _startBattleInline.
    function _startBattleFullyOptimized(IRuleset ruleset) internal returns (bytes32) {
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
                validator: IValidator(address(0)),
                rngOracle: IRandomnessOracle(address(0)),
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

    /// @dev Executes a two-player turn in 1 TX via executeWithDualSignedMoves.
    ///      p0Move/p1Move semantics match _commitRevealExecuteForAliceAndBob so the
    ///      battle scripts can be transcribed directly from the non-optimized test.
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
        committerPk; // single-sig: no committer signature; committer is msg.sender
        bytes memory revealerSig = _signDualReveal(
            mgr, revealerPk, battleKey, turnId, committerMoveHash,
            revealerMoveIndex, revealerSalt, revealerExtraData
        );

        vm.prank(committer);
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            committerMoveIndex, committerSalt, committerExtraData,
            revealerMoveIndex, revealerSalt, revealerExtraData,
            revealerSig
        );
        engine.resetCallContext();
    }

    /// @dev Single-player forced switch after a KO. This uses the optimized
    ///      SignedCommitManager path because there is no hidden opponent move to reveal.
    function _fastSwitchReveal(bytes32 battleKey, bool isP0, uint16 extraData) internal {
        vm.prank(isP0 ? p0 : p1);
        signedCommitManager.executeSinglePlayerMove(battleKey, SWITCH_MOVE_INDEX, uint104(0), extraData);
        engine.resetCallContext();
    }

    /// @notice Compares the inherited single-player reveal flow against the dedicated
    ///         SignedCommitManager single-player fast path.
    function test_signedCommitManagerOnePlayerActionGasComparison() public {
        Mon memory mon = _createMon();
        mon.stats.stamina = 5;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;
        mon.moves = new uint256[](4);

        IMoveSet damageMove = new CustomAttack(
            ITypeCalculator(address(typeCalc)),
            CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 0, PRIORITY: 1})
        );
        for (uint256 i; i < mon.moves.length; i++) {
            mon.moves[i] = uint256(uint160(address(damageMove)));
        }

        Mon[] memory team = new Mon[](4);
        for (uint256 i; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);

        bytes32 oldFlowBattleKey = _startBattleFullyOptimized(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);
        _fastTurn(oldFlowBattleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(oldFlowBattleKey, 0, NO_OP_MOVE_INDEX, uint16(0), uint16(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(oldFlowBattleKey), 1);

        vm.prank(p1);
        uint256 gasBefore = gasleft();
        signedCommitManager.revealMove(oldFlowBattleKey, SWITCH_MOVE_INDEX, uint104(0), uint16(1), true);
        uint256 oldFlowGas = gasBefore - gasleft();
        engine.resetCallContext();

        _fastTurn(oldFlowBattleKey, 0, NO_OP_MOVE_INDEX, uint16(0), uint16(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(oldFlowBattleKey), 1);

        vm.prank(p1);
        gasBefore = gasleft();
        signedCommitManager.revealMove(oldFlowBattleKey, SWITCH_MOVE_INDEX, uint104(0), uint16(2), true);
        uint256 oldFlowSecondGas = gasBefore - gasleft();
        engine.resetCallContext();

        bytes32 fastPathBattleKey = _startBattleFullyOptimized(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);
        _fastTurn(fastPathBattleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(fastPathBattleKey, 0, NO_OP_MOVE_INDEX, uint16(0), uint16(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(fastPathBattleKey), 1);

        vm.prank(p1);
        gasBefore = gasleft();
        signedCommitManager.executeSinglePlayerMove(fastPathBattleKey, SWITCH_MOVE_INDEX, uint104(0), uint16(1));
        uint256 fastPathGas = gasBefore - gasleft();
        engine.resetCallContext();

        _fastTurn(fastPathBattleKey, 0, NO_OP_MOVE_INDEX, uint16(0), uint16(0));
        assertEq(engine.getPlayerSwitchForTurnFlagForBattleState(fastPathBattleKey), 1);

        vm.prank(p1);
        gasBefore = gasleft();
        signedCommitManager.executeSinglePlayerMove(fastPathBattleKey, SWITCH_MOVE_INDEX, uint104(0), uint16(2));
        uint256 fastPathSecondGas = gasBefore - gasleft();
        engine.resetCallContext();

        console.log("Old SignedCommitManager first revealMove gas:", oldFlowGas);
        console.log("New first executeSinglePlayerMove gas:", fastPathGas);
        console.log("First forced-switch savings:", oldFlowGas - fastPathGas);
        console.log("Old SignedCommitManager second revealMove gas:", oldFlowSecondGas);
        console.log("New second executeSinglePlayerMove gas:", fastPathSecondGas);
        console.log("Second forced-switch savings:", oldFlowSecondGas - fastPathSecondGas);

        assertLt(fastPathGas, oldFlowGas);
        assertLt(fastPathSecondGas, oldFlowSecondGas);
    }

    /// @notice Mirrors InlineEngineGasTest::test_consecutiveBattleGas move-for-move,
    ///         but every TX goes through the dual-signed fast path.
    function test_consecutiveBattleGas() public {
        Mon memory mon = _createMon();
        mon.stats.stamina = 5;
        mon.stats.attack = 10;
        mon.stats.specialAttack = 10;

        mon.moves = new uint256[](4);
        StatBoosts statBoosts = new StatBoosts();
        IMoveSet burnMove = new EffectAttack(new BurnStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet frostbiteMove = new EffectAttack(new FrostbiteStatus(statBoosts), EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));
        IMoveSet statBoostMove = new StatBoostsMove(statBoosts);
        IMoveSet damageMove = new CustomAttack(ITypeCalculator(address(typeCalc)), CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 1}));
        mon.moves[0] = uint256(uint160(address(burnMove)));
        mon.moves[1] = uint256(uint160(address(frostbiteMove)));
        mon.moves[2] = uint256(uint160(address(statBoostMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));

        Mon[] memory team = new Mon[](4);
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        // Use the INLINE_STAMINA_REGEN_RULESET sentinel so the engine takes its internal stamina-regen
        // fast path (no external StaminaRegen contract, no onAfterMove/onRoundEnd callbacks). This is
        // the intended production configuration for the fully-optimized stack.
        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);

        vm.startSnapshotGas("Fast_Setup_1");
        bytes32 battleKey = _startBattleFullyOptimized(ruleset);
        uint256 setup1Gas = vm.stopSnapshotGas("Fast_Setup_1");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Fast_Battle1");
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(battleKey, 0, 1, 0, 0);
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, 2, uint16(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastSwitchReveal(battleKey, true, uint16(0));
        _fastTurn(battleKey, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey, 3, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey, false, uint16(1));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey, true, uint16(2));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey, true, uint16(3));
        _fastTurn(battleKey, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 firstBattleGas = vm.stopSnapshotGas("Fast_Battle1");

        // Rearrange moves for battle 2 (same as InlineEngineGasTest)
        mon.moves[1] = uint256(uint160(address(burnMove)));
        mon.moves[2] = uint256(uint160(address(frostbiteMove)));
        mon.moves[3] = uint256(uint160(address(statBoostMove)));
        mon.moves[0] = uint256(uint160(address(damageMove)));
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        vm.startSnapshotGas("Fast_Setup_2");
        bytes32 battleKey2 = _startBattleFullyOptimized(IRuleset(address(ruleset)));
        uint256 setup2Gas = vm.stopSnapshotGas("Fast_Setup_2");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Fast_Battle2");
        _fastTurn(battleKey2, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(battleKey2, 3, 1, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey2, false, uint16(1));
        _fastTurn(battleKey2, SWITCH_MOVE_INDEX, 2, uint16(1), 0);
        _fastTurn(battleKey2, 3, NO_OP_MOVE_INDEX, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey2, false, uint16(2));
        _fastTurn(battleKey2, NO_OP_MOVE_INDEX, 3, 0, _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey2, NO_OP_MOVE_INDEX, 0, 0, 0);
        _fastSwitchReveal(battleKey2, true, uint16(2));
        _fastTurn(battleKey2, 3, 3, _packStatBoost(0, 2, uint256(MonStateIndexName.Attack), int32(90)), _packStatBoost(1, 2, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey2, false, uint16(3));
        _fastTurn(battleKey2, 0, NO_OP_MOVE_INDEX, 0, 0);
        uint256 secondBattleGas = vm.stopSnapshotGas("Fast_Battle2");

        // Battle 3: Repeat exact sequence of Battle 1
        mon.moves[0] = uint256(uint160(address(burnMove)));
        mon.moves[1] = uint256(uint160(address(frostbiteMove)));
        mon.moves[2] = uint256(uint160(address(statBoostMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));
        for (uint256 i = 0; i < team.length; i++) {
            team[i] = mon;
        }
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        vm.startSnapshotGas("Fast_Setup_3");
        bytes32 battleKey3 = _startBattleFullyOptimized(IRuleset(address(ruleset)));
        uint256 setup3Gas = vm.stopSnapshotGas("Fast_Setup_3");

        vm.warp(vm.getBlockTimestamp() + 1);

        vm.startSnapshotGas("Fast_Battle3");
        _fastTurn(battleKey3, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(battleKey3, 0, 1, 0, 0);
        _fastTurn(battleKey3, SWITCH_MOVE_INDEX, 2, uint16(1), _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey3, 2, 3, _packStatBoost(0, 1, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastSwitchReveal(battleKey3, true, uint16(0));
        _fastTurn(battleKey3, 2, NO_OP_MOVE_INDEX, _packStatBoost(0, 0, uint256(MonStateIndexName.Attack), int32(90)), 0);
        _fastTurn(battleKey3, 3, NO_OP_MOVE_INDEX, 0, 0);
        _fastSwitchReveal(battleKey3, false, uint16(1));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 2, 0, _packStatBoost(1, 1, uint256(MonStateIndexName.Attack), int32(90)));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey3, true, uint16(2));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        _fastSwitchReveal(battleKey3, true, uint16(3));
        _fastTurn(battleKey3, NO_OP_MOVE_INDEX, 3, 0, 0);
        uint256 thirdBattleGas = vm.stopSnapshotGas("Fast_Battle3");

        console.log("=== FULLY OPTIMIZED Gas Results ===");
        console.log("Setup 1 Gas:", setup1Gas);
        console.log("Setup 2 Gas:", setup2Gas);
        console.log("Setup 3 Gas:", setup3Gas);
        console.log("Battle 1 Gas:", firstBattleGas);
        console.log("Battle 2 Gas:", secondBattleGas);
        console.log("Battle 3 Gas:", thirdBattleGas);

        assertLt(setup2Gas, setup1Gas, "Setup 2 should be cheaper (storage reuse)");
        assertLt(setup3Gas, setup1Gas, "Setup 3 should be cheaper (storage reuse)");
    }
}

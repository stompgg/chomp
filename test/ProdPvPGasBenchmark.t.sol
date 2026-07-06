// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../lib/forge-std/src/Test.sol";

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {BattleHelper} from "./abstract/BattleHelper.sol";
import {GasMeasure} from "./abstract/GasMeasure.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {MockOnBattleEndHook} from "./mocks/MockOnBattleEndHook.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @title Production PvP gas benchmark — Engine built-in dual-signed buffer flow
/// @notice Benchmarks the ACTUAL production PvP stack: built-in dual-signed buffer
///         (BUILTIN_DUAL_SIGNED_MANAGER), inline validation (validator address(0)), inline RNG
///         (oracle address(0)), INLINE_STAMINA_REGEN_RULESET, SignedMatchmaker — measured both
///         bare and with a GachaTeamRegistry-shaped OnBattleEnd-only engine hook attached. Prod
///         battles always carry the gacha hook; the older gas tests pass zero hooks and therefore
///         hide its per-round bitmap-probing cost (finding B2).
/// @dev Production-faithful GasMeasure format: each turn / stage tx is measured as its own
///      cold-access tx via `vm.cool` + a deterministic storage-access tally.
contract ProdPvPGasBenchmark is BattleHelper, BatchHelper, GasMeasure {
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    SignedMatchmaker signedMatchmaker;
    TestTeamRegistry defaultRegistry;
    ITypeCalculator typeCalc;
    MockOnBattleEndHook gachaShapedHook;

    bool private _measuring;
    Tally private _acc;
    uint256 private _accGas;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);
        engine = new Engine(4, 4);
        signedMatchmaker = new SignedMatchmaker(engine);
        defaultRegistry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        gachaShapedHook = new MockOnBattleEndHook();

        // Low-power attack so multi-turn scripts never KO (hp 1000, ~5 damage per hit).
        IMoveSet attack = new CustomAttack(
            typeCalc, CustomAttack.Args({TYPE: Type.Fire, BASE_POWER: 5, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: 1})
        );
        Mon memory mon = _createMon();
        mon.stats.hp = 1000;
        mon.stats.stamina = 50;
        mon.stats.attack = 10;
        mon.stats.defense = 10;
        mon.stats.specialAttack = 10;
        mon.stats.specialDefense = 10;
        mon.moves = new uint256[](4);
        for (uint256 i; i < 4; i++) {
            mon.moves[i] = uint256(uint160(address(attack)));
        }

        Mon[] memory team = new Mon[](4);
        for (uint256 i; i < 4; i++) {
            team[i] = mon;
        }
        // p0 outspeeds p1 so priority is deterministic (no rng speed-tie branch).
        mon.stats.speed = 100;
        defaultRegistry.setTeam(p0, team);
        mon.stats.speed = 50;
        defaultRegistry.setTeam(p1, team);
    }

    function _beginMeasure() internal {
        _measuring = true;
        delete _acc;
        _accGas = 0;
    }

    function _endMeasure(string memory name) internal returns (uint256) {
        _measuring = false;
        _snapScenario(name, _acc, _accGas);
        return _accGas;
    }

    /// @dev Starts a built-in dual-signed battle via SignedMatchmaker::startGame with the given hooks.
    function _startBuiltinBattle(IEngineHook[] memory hooks) internal returns (bytes32 battleKey) {
        address[] memory makersToAdd = new address[](1);
        makersToAdd[0] = address(signedMatchmaker);
        address[] memory makersToRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(makersToAdd, makersToRemove);
        vm.prank(p1);
        engine.updateMatchmakers(makersToAdd, makersToRemove);

        bytes32 pairHash;
        (battleKey, pairHash) = engine.computeBattleKey(p0, p1);
        uint256 nonce = engine.pairHashNonces(pairHash);

        BattleOffer memory offer = BattleOffer({
            battle: Battle({
                p0: p0,
                p0TeamIndex: 0,
                p1: p1,
                p1TeamIndex: 0,
                teamRegistry: defaultRegistry,
                rngOracle: IRandomnessOracle(address(0)),
                ruleset: IRuleset(INLINE_STAMINA_REGEN_RULESET),
                moveManager: BUILTIN_DUAL_SIGNED_MANAGER,
                matchmaker: signedMatchmaker,
                engineHooks: hooks
            }),
            pairHashNonce: nonce,
            battleMode: BATTLE_MODE_SINGLES
        });

        bytes32 digest = signedMatchmaker.hashTypedData(BattleOfferLib.hashBattleOffer(offer));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(P0_PK, digest);
        vm.prank(p1);
        signedMatchmaker.startGame(offer, abi.encodePacked(r, s, v));
    }

    function _turnSalts(bytes32 battleKey, uint64 turnId) internal pure returns (uint104 p0s, uint104 p1s) {
        p0s = uint104(uint256(keccak256(abi.encode("p0", battleKey, turnId))));
        p1s = uint104(uint256(keccak256(abi.encode("p1", battleKey, turnId))));
    }

    /// @dev Real-time prod path: one combined submit-and-execute tx per turn.
    function _combinedTurn(bytes32 battleKey, uint64 turnId, uint8 p0m, uint16 p0e, uint8 p1m, uint16 p1e) internal {
        (uint104 p0s, uint104 p1s) = _turnSalts(battleKey, turnId);
        (uint256 packedMoves, bytes32 r, bytes32 vs) =
            _buildTurnSubmissionForEngine(address(engine), battleKey, turnId, p0m, p0e, p0s, p1m, p1e, p1s, P0_PK, P1_PK);
        if (_measuring) {
            vm.cool(address(engine));
            vm.startStateDiffRecording();
        }
        uint256 g0 = gasleft();
        vm.prank(_committerFor(turnId, p0, p1));
        engine.submitTurnMovesAndExecute(battleKey, packedMoves, r, vs);
        if (_measuring) {
            _accGas += g0 - gasleft();
            _acc = _addTally(_acc, _tally(vm.stopAndReturnStateDiff()));
        }
        engine.resetCallContext();
    }

    /// @dev Async prod path: stage one turn into the buffer without executing.
    function _stageTurn(bytes32 battleKey, uint64 turnId, uint8 p0m, uint16 p0e, uint8 p1m, uint16 p1e) internal {
        (uint104 p0s, uint104 p1s) = _turnSalts(battleKey, turnId);
        (uint256 packedMoves, bytes32 r, bytes32 vs) =
            _buildTurnSubmissionForEngine(address(engine), battleKey, turnId, p0m, p0e, p0s, p1m, p1e, p1s, P0_PK, P1_PK);
        if (_measuring) {
            vm.cool(address(engine));
            vm.startStateDiffRecording();
        }
        uint256 g0 = gasleft();
        vm.prank(_committerFor(turnId, p0, p1));
        engine.submitTurnMoves(battleKey, packedMoves, r, vs);
        if (_measuring) {
            _accGas += g0 - gasleft();
            _acc = _addTally(_acc, _tally(vm.stopAndReturnStateDiff()));
        }
        engine.resetCallContext();
    }

    /// @notice Five identical steady-state turns on a bare battle vs a gacha-hook-attached battle.
    ///         The hook's per-round bitmap probing shows up EXACTLY in the tally: +2 SLOADs per
    ///         turn (+1 cold), i.e. ~2.2k/turn of production cost the zero-hook gas tests hide.
    /// @dev Compare scenarios via the TALLY, not raw coldGas: the two battles use different
    ///      battleKeys, so salt-derived rng values differ and coldGas carries ~±1.5k of
    ///      value-variance noise across battle instances. Cross-VERSION diffs of the same
    ///      scenario are deterministic (fixed pks → fixed keys/salts) and are the real guard.
    function test_builtinTurnGas_bareVsHooked() public {
        bytes32 bare = _startBuiltinBattle(new IEngineHook[](0));
        vm.warp(vm.getBlockTimestamp() + 1);
        _combinedTurn(bare, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0);
        _beginMeasure();
        for (uint64 t = 1; t <= 5; t++) {
            _combinedTurn(bare, t, 0, 0, 0, 0);
        }
        uint256 bareGas = _endMeasure("BuiltinBare_5Turns");

        IEngineHook[] memory hooks = new IEngineHook[](1);
        hooks[0] = gachaShapedHook;
        bytes32 hooked = _startBuiltinBattle(hooks);
        vm.warp(vm.getBlockTimestamp() + 1);
        _combinedTurn(hooked, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0);
        _beginMeasure();
        for (uint64 t = 1; t <= 5; t++) {
            _combinedTurn(hooked, t, 0, 0, 0, 0);
        }
        uint256 hookedGas = _endMeasure("BuiltinHooked_5Turns");

        console.log("bare 5 turns (cold-per-tx):", bareGas);
        console.log("hooked 5 turns (cold-per-tx):", hookedGas);
        if (hookedGas >= bareGas) {
            console.log("hook tax over 5 turns:", hookedGas - bareGas);
        } else {
            console.log("hooked cheaper by (?):", bareGas - hookedGas);
        }
    }

    /// @notice Async staging flow: three staged turns (each its own tx) then a permissionless
    ///         drain. Baselines the stage-tx overhead (B3 targets its moveManager-sentinel SLOAD)
    ///         and the per-buffered-turn drain cost.
    function test_builtinStageThenDrainGas() public {
        bytes32 battleKey = _startBuiltinBattle(new IEngineHook[](0));
        vm.warp(vm.getBlockTimestamp() + 1);

        _beginMeasure();
        _stageTurn(battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0);
        _stageTurn(battleKey, 1, 0, 0, 0, 0);
        _stageTurn(battleKey, 2, 0, 0, 0, 0);
        uint256 stageGas = _endMeasure("Builtin_Stage3");

        _beginMeasure();
        vm.cool(address(engine));
        vm.startStateDiffRecording();
        uint256 g0 = gasleft();
        vm.prank(address(0xCAFE));
        engine.executeBuffered(battleKey);
        _accGas += g0 - gasleft();
        _acc = _addTally(_acc, _tally(vm.stopAndReturnStateDiff()));
        engine.resetCallContext();
        uint256 drainGas = _endMeasure("Builtin_Drain3");

        assertEq(engine.getTurnIdForBattleState(battleKey), 3, "all three buffered turns executed");
        console.log("stage 3 turns (cold-per-tx):", stageGas);
        console.log("drain of 3 turns (one tx):", drainGas);
    }
}

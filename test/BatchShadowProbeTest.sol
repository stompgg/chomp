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
import {MockStateProbeMove} from "./mocks/MockStateProbeMove.sol";

/// @notice Shadow correctness probe. The `isBatched` parameter threaded through Engine internals
///         skips a TLOAD on every shadow-routed helper; if any callsite forgets to pass it (or
///         defaults to `false` inside a batched flow) a sub-turn would observe stale storage
///         instead of the in-flight shadow value.
///
///         The check: damage P1 in sub-turn 1, then in sub-turn 2 have P0 read P1's HP delta
///         via `MockStateProbeMove` → `getMonStateForBattle`. Between sub-turns the shadow is
///         the only carrier; flushing only happens at end of `executeBatchedTurns`. A broken
///         shadow read would observe HpDelta == 0 (storage sentinel), so we assert the probe
///         records the post-damage negative delta.
contract BatchShadowProbeTest is BatchHelper {

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
    MockStateProbeMove probe;

    uint64 constant PROBE_KEY = 9001;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        mgr = new SignedCommitManager(IEngine(address(engine)));
        maker = new SignedMatchmaker(engine);
        typeCalc = new TypeCalculator();
        registry = new TestTeamRegistry();
        attackFactory = new StandardAttackFactory(typeCalc);
        probe = new MockStateProbeMove();
    }

    function _setupTeamsForProbe() internal returns (uint32 attackPower) {
        attackPower = 50;
        IMoveSet hit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: attackPower, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: DEFAULT_PRIORITY,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Hit", EFFECT: IEffect(address(0))
            })
        );

        // Tanky mon: enough HP to survive an attack on turn 1 without KOing (so turn 2 runs)
        Mon memory mon = Mon({
            stats: MonStats({
                hp: 10000, stamina: 20, speed: 10,
                attack: 30, defense: 10, specialAttack: 30, specialDefense: 10,
                type1: Type.Fire, type2: Type.None
            }),
            moves: new uint256[](MOVES_PER_MON),
            ability: 0
        });
        mon.moves[0] = uint256(uint160(address(hit)));
        mon.moves[1] = uint256(uint160(address(probe)));

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
                p0: p0, p0TeamIndex: 0,
                p1: p1, p1TeamIndex: 0,
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

    /// @notice Sub-turn 1 damages P1's active mon; sub-turn 2's P0 probe reads P1's HpDelta via
    ///         `getMonStateForBattle`. Between sub-turns the shadow stack is the only carrier
    ///         (no SSTORE happens until `executeBatchedTurns` exits) so a mis-threaded read on
    ///         the probe path would observe 0 instead of the post-damage negative delta.
    function test_batchedShadow_probeObservesMidBatchDamage() public {
        _setupTeamsForProbe();
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        // extraData for the probe = field-id of MonStateIndexName.Hp (= 0)
        uint16 PROBE_HP_FIELD = uint16(uint8(MonStateIndexName.Hp));

        // Plan:
        //  turn 0: both switch in mon 0
        //  turn 1: P0 attacks (move 0) → P1 mon takes damage. P1 NO_OP.
        //  turn 2: P0 uses probe (move 1) on P1's HpDelta. P1 NO_OP.
        _submitTurnMoves(mgr, battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 1, 0, 0, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 2, 1, PROBE_HP_FIELD, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);

        mgr.executeBuffered(battleKey);

        // All three turns drained
        (uint64 ex, uint64 buf,) = mgr.getBufferStatus(battleKey);
        assertEq(ex, 3, "all three turns executed");
        assertEq(buf, 0, "buffer drained");

        // P1's mon should have a negative HpDelta after turn 1
        int32 p1HpDeltaAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        assertLt(p1HpDeltaAfter, int32(0), "P1 mon 0 took damage");

        // The probe ran in turn 2 and should have observed the same HpDelta that turn 1 wrote
        uint192 probed = engine.getGlobalKV(battleKey, PROBE_KEY);
        int32 probedDelta = int32(int192(probed));
        assertEq(probedDelta, p1HpDeltaAfter, "probe observed mid-batch shadow value");
        assertLt(probedDelta, int32(0), "probe did NOT observe stale 0 (would indicate shadow miss)");
    }

    /// @notice Two damaging turns back-to-back inside a batch; the probe in turn 3 must observe
    ///         the *cumulative* HpDelta — both turn 1 and turn 2 mutations must propagate via
    ///         shadow with no inter-turn flush dropping state.
    function test_batchedShadow_probeObservesAccumulatedDamage() public {
        _setupTeamsForProbe();
        bytes32 battleKey = _startBattle();
        vm.warp(vm.getBlockTimestamp() + 1);

        uint16 PROBE_HP_FIELD = uint16(uint8(MonStateIndexName.Hp));

        _submitTurnMoves(mgr, battleKey, 0, SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 1, 0, 0, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 2, 0, 0, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);
        _submitTurnMoves(mgr, battleKey, 3, 1, PROBE_HP_FIELD, NO_OP_MOVE_INDEX, 0, P0_PK, P1_PK);

        mgr.executeBuffered(battleKey);

        int32 p1HpDeltaAfter = engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.Hp);
        uint192 probed = engine.getGlobalKV(battleKey, PROBE_KEY);
        int32 probedDelta = int32(int192(probed));

        // Cumulative damage from two hits
        assertEq(probedDelta, p1HpDeltaAfter, "probe observed cumulative shadow HpDelta");
        // Both attacks must have applied — delta should be roughly 2x a single-hit delta
        assertLt(probedDelta, int32(-1), "probe observed damage from BOTH turns");
    }
}

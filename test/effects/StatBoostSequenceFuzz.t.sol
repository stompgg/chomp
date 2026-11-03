// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../lib/forge-std/src/Test.sol";

import "../../src/Constants.sol";
import "../../src/Enums.sol";
import "../../src/Structs.sol";

import {Engine} from "../../src/Engine.sol";
import {IEngine} from "../../src/IEngine.sol";
import {DefaultCommitManager} from "../../src/commit-manager/DefaultCommitManager.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {StatBoostLib} from "../../src/lib/StatBoostLib.sol";
import {DefaultMatchmaker} from "../../src/matchmaker/DefaultMatchmaker.sol";

import {BattleHelper} from "../abstract/BattleHelper.sol";
import {BoostOp, BoostScriptMove} from "../mocks/BoostScriptMove.sol";
import {MockRandomnessOracle} from "../mocks/MockRandomnessOracle.sol";
import {TestTeamRegistry} from "../mocks/TestTeamRegistry.sol";

contract UpdateMonStateListener is BasicEffect {
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x8100;
    }
}

/// @notice Drives random boost sequences through the Engine and checks every stat against an
///         independent model of the full recompute, after every step and after temp expiry.
contract StatBoostSequenceFuzz is Test, BattleHelper {
    uint256 constant MAX_OPS = 24;

    Engine engine;
    DefaultCommitManager commitManager;
    MockRandomnessOracle mockOracle;
    TestTeamRegistry registry;
    DefaultMatchmaker matchmaker;
    BoostScriptMove script;
    UpdateMonStateListener listener;

    // Model: one word per live source, in no particular order.
    bytes32[] sources;

    function setUp() public {
        mockOracle = new MockRandomnessOracle();
        registry = new TestTeamRegistry();
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        commitManager = new DefaultCommitManager(IEngine(address(engine)));
        matchmaker = new DefaultMatchmaker(engine);
        script = new BoostScriptMove();
        listener = new UpdateMonStateListener();
    }

    function _mon(uint32[5] memory base) internal view returns (Mon memory) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(script)));
        return Mon({
            stats: MonStats({
                hp: 1000,
                stamina: 100,
                speed: base[4],
                attack: base[0],
                defense: base[1],
                specialAttack: base[2],
                specialDefense: base[3],
                type1: Type.Fire,
                type2: Type.None
            }),
            moves: moves,
            ability: 0
        });
    }

    function _opFrom(uint256 s) internal pure returns (BoostOp memory op) {
        uint256 roll = s % 100;
        op.kind = roll < 70 ? 0 : roll < 95 ? 1 : 2;
        op.caller = uint8((s >> 8) % 6);
        op.perm = (s >> 16) & 1 == 1;
        op.statCount = uint8(1 + ((s >> 17) & 1));
        op.statA = uint8(2 + ((s >> 18) & 0xFF) % 5);
        op.statB = uint8(2 + ((s >> 26) & 0xFF) % 5);
        // Mostly the 15-50% that live moves use, with the full uint8 range as the edge case.
        op.pct = (s >> 34) & 3 == 0 ? uint8(s >> 36) : uint8(15 + (s >> 36) % 36);
        op.mul = (s >> 44) & 1 == 1;
    }

    function _key(uint8 caller) internal view returns (uint168) {
        return StatBoostLib.generateKeyNoSalt(0, 0, address(script.callers(caller)));
    }

    function _modelApply(BoostOp memory op) internal {
        if (op.kind == 2) {
            delete sources;
            return;
        }
        uint168 key = _key(op.caller);
        uint256 n = sources.length;
        uint256 found = n;
        for (uint256 i; i < n; ++i) {
            (bool perm, uint168 k) = StatBoostLib.unpackBoostHeader(sources[i]);
            if (k == key && perm == op.perm) {
                found = i;
                break;
            }
        }
        if (op.kind == 1) {
            if (found != n) {
                sources[found] = sources[n - 1];
                sources.pop();
            }
            return;
        }
        StatBoostToApply[] memory boosts = new StatBoostToApply[](op.statCount);
        StatBoostType boostType = op.mul ? StatBoostType.Multiply : StatBoostType.Divide;
        boosts[0] = StatBoostToApply(MonStateIndexName(op.statA), op.pct, boostType);
        if (op.statCount == 2) {
            boosts[1] = StatBoostToApply(MonStateIndexName(op.statB), op.pct, boostType);
        }
        if (found == n) {
            sources.push(StatBoostLib.packBoostData(key, op.perm, boosts));
            return;
        }
        (,, uint8[5] memory p, uint8[5] memory c, bool[5] memory m) = StatBoostLib.unpackBoostData(sources[found]);
        (p, c, m) = StatBoostLib.mergeExistingAndNewBoosts(p, c, m, boosts);
        sources[found] = StatBoostLib.packBoostDataWithArrays(key, op.perm, p, c, m);
    }

    function _expected(uint32[5] memory base) internal view returns (int32[5] memory deltas) {
        uint32[5] memory counts;
        uint256[5] memory numerators;
        for (uint256 i; i < sources.length; ++i) {
            (,, uint8[5] memory p, uint8[5] memory c, bool[5] memory m) = StatBoostLib.unpackBoostData(sources[i]);
            StatBoostLib.accumulateBoosts(base, p, c, m, counts, numerators);
        }
        uint32[5] memory boosted = StatBoostLib.finalizeBoostedStats(base, counts, numerators);
        for (uint256 k; k < 5; ++k) {
            deltas[k] = int32(boosted[k]) - int32(base[k]);
        }
    }

    function _assertDeltas(int32[5] memory got, int32[5] memory want, string memory label) internal pure {
        for (uint256 k; k < 5; ++k) {
            int32 g = got[k] == CLEARED_MON_STATE_SENTINEL ? int32(0) : got[k];
            assertEq(g, want[k], label);
        }
    }

    function _run(uint256 seed, bool withListener) internal {
        uint32[5] memory base;
        for (uint256 k; k < 5; ++k) {
            base[k] = uint32(1 + uint256(keccak256(abi.encode(seed, "base", k))) % 2000);
        }

        BoostOp[] memory ops = new BoostOp[](1 + seed % MAX_OPS);
        for (uint256 i; i < ops.length; ++i) {
            ops[i] = _opFrom(uint256(keccak256(abi.encode(seed, i))));
        }
        script.setScript(ops, withListener ? IEffect(address(listener)) : IEffect(address(0)));

        Mon[] memory team = new Mon[](2);
        team[0] = _mon(base);
        team[1] = _mon(base);
        registry.setTeam(ALICE, team);
        registry.setTeam(BOB, team);

        bytes32 battleKey = _startBattle(engine, mockOracle, registry, matchmaker, address(commitManager));
        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0)
        );
        _commitRevealExecuteForAliceAndBob(engine, commitManager, battleKey, 0, NO_OP_MOVE_INDEX, 0, 0);

        assertEq(script.recordedLength(), ops.length, "every step ran");
        for (uint256 i; i < ops.length; ++i) {
            _modelApply(ops[i]);
            _assertDeltas(script.recordedAt(i), _expected(base), "delta after step");
        }

        _commitRevealExecuteForAliceAndBob(
            engine, commitManager, battleKey, SWITCH_MOVE_INDEX, NO_OP_MOVE_INDEX, uint16(1), 0
        );
        for (uint256 i = sources.length; i > 0; --i) {
            if (!StatBoostLib.isPerm(sources[i - 1])) {
                sources[i - 1] = sources[sources.length - 1];
                sources.pop();
            }
        }
        int32[5] memory after_;
        for (uint256 k; k < 5; ++k) {
            after_[k] = engine.getMonStateForBattle(battleKey, 0, 0, StatBoostLib.statBoostIndexToMonStateIndex(k));
        }
        _assertDeltas(after_, _expected(base), "delta after temp expiry");
    }

    function testFuzz_boostSequenceMatchesModel(uint256 seed) public {
        _run(seed, false);
    }

    function testFuzz_boostSequenceWithListenerMatchesModel(uint256 seed) public {
        _run(seed, true);
    }
}

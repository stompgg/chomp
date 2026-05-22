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

import {SignedCommitHelper} from "./abstract/SignedCommitHelper.sol";
import {EffectAttack} from "./mocks/EffectAttack.sol";
import {PerTurnTickEffect} from "./mocks/PerTurnTickEffect.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// Counts SLOAD / SSTORE access patterns on a warm steady-state turn, to ground the OPT_PLAN.md
/// gas math in real data instead of estimates.
///
/// Per-turn budgets (locked by §11 Phase 0.1; run forge test -vv --match-contract BatchInstrumentationTest):
///   clean damage trade   : 16 cold SLOADs / 10 SSTOREs / 16 unique slots / 3 multi-write
///   effect-heavy turn    : 20 cold SLOADs / 16 SSTOREs / 20 unique slots / 5 multi-write
///   forced-switch turn   : 10 cold SLOADs /  5 SSTOREs / 10 unique slots / 1 multi-write
///   multi-mon switch turn: 16 cold SLOADs /  8 SSTOREs / 16 unique slots / 2 multi-write
///
/// These four numbers are the per-turn gas budget the §5 shadow layer has to clear at B>=2.
/// Multi-write slots (same slot written 2+ times in one turn) are the biggest amortization
/// targets — at B=2 a previously-multi-written slot becomes one shadow read + one flush.
contract BatchInstrumentationTest is SignedCommitHelper {

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
    StandardAttackFactory attackFactory;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);

        engine = new Engine(MONS_PER_TEAM, MOVES_PER_MON, 1);
        signedCommitManager = new SignedCommitManager(IEngine(address(engine)));
        signedMatchmaker = new SignedMatchmaker(engine);
        typeCalc = new TypeCalculator();
        defaultRegistry = new TestTeamRegistry();
        attackFactory = new StandardAttackFactory(typeCalc);
    }

    function _startBattle(IRuleset ruleset) internal returns (bytes32) {
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

        if (turnId % 2 == 0) {
            committerMoveIndex = p0MoveIndex;
            committerExtraData = p0ExtraData;
            revealerMoveIndex = p1MoveIndex;
            revealerExtraData = p1ExtraData;
            committerPk = P0_PK;
            revealerPk = P1_PK;
        } else {
            committerMoveIndex = p1MoveIndex;
            committerExtraData = p1ExtraData;
            revealerMoveIndex = p0MoveIndex;
            revealerExtraData = p0ExtraData;
            committerPk = P1_PK;
            revealerPk = P0_PK;
        }

        bytes32 committerMoveHash =
            keccak256(abi.encodePacked(committerMoveIndex, committerSalt, committerExtraData));
        bytes memory revealerSig = _signDualReveal(
            address(signedCommitManager),
            revealerPk,
            battleKey,
            turnId,
            committerMoveHash,
            revealerMoveIndex,
            revealerSalt,
            revealerExtraData
        );

        vm.prank(vm.addr(committerPk));
        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            committerMoveIndex, committerSalt, committerExtraData,
            revealerMoveIndex, revealerSalt, revealerExtraData,
            revealerSig
        );
        engine.resetCallContext();
    }

    function _createMon(Type t1) internal pure returns (Mon memory) {
        return Mon({
            stats: MonStats({
                hp: 10000,
                stamina: 50,
                speed: 10,
                attack: 30,
                defense: 10,
                specialAttack: 30,
                specialDefense: 10,
                type1: t1,
                type2: Type.None
            }),
            moves: new uint256[](0),
            ability: 0
        });
    }

    /// @dev Iterates account accesses returned by stopAndReturnStateDiff and counts SLOAD/SSTORE
    /// per (account, slot) — distinguishing first-touch (cold) from subsequent (warm), and
    /// for SSTORE distinguishing zero→nonzero / nonzero→nonzero / no-op.
    function _summarizeAccesses(Vm.AccountAccess[] memory accesses)
        internal
        pure
        returns (
            uint256 totalSloadCount,
            uint256 totalSstoreCount,
            uint256 coldSloads,
            uint256 warmSloads,
            uint256 coldSstores,
            uint256 warmSstores,
            uint256 zeroToNonzeroSstores,
            uint256 nonzeroToNonzeroSstores,
            uint256 noopSstores,
            uint256 uniqueSlotsTouched,
            uint256 multiWriteSlots
        )
    {
        // Count slot-touch frequencies via a small fixed-capacity table (we don't expect many uniques)
        bytes32[] memory keys = new bytes32[](256);
        uint8[] memory writes = new uint8[](256);
        bool[] memory reads = new bool[](256);
        uint256 keyCount;

        for (uint256 i = 0; i < accesses.length; i++) {
            Vm.StorageAccess[] memory storageAccesses = accesses[i].storageAccesses;
            for (uint256 j = 0; j < storageAccesses.length; j++) {
                Vm.StorageAccess memory a = storageAccesses[j];
                bytes32 key = keccak256(abi.encode(a.account, a.slot));

                // Locate or create entry
                uint256 idx = keyCount;
                for (uint256 k = 0; k < keyCount; k++) {
                    if (keys[k] == key) {
                        idx = k;
                        break;
                    }
                }
                if (idx == keyCount) {
                    keys[idx] = key;
                    keyCount++;
                }

                if (a.isWrite) {
                    totalSstoreCount++;
                    writes[idx]++;
                    if (a.previousValue == bytes32(0) && a.newValue != bytes32(0)) zeroToNonzeroSstores++;
                    else if (a.previousValue != bytes32(0) && a.newValue != bytes32(0) && a.previousValue != a.newValue)
                        nonzeroToNonzeroSstores++;
                    else if (a.previousValue == a.newValue) noopSstores++;

                    if (writes[idx] == 1 && !reads[idx]) {
                        coldSstores++;
                    } else {
                        warmSstores++;
                    }
                } else {
                    totalSloadCount++;
                    if (!reads[idx] && writes[idx] == 0) {
                        coldSloads++;
                        reads[idx] = true;
                    } else {
                        warmSloads++;
                    }
                }
            }
        }

        uniqueSlotsTouched = keyCount;
        for (uint256 i = 0; i < keyCount; i++) {
            if (writes[i] >= 2) multiWriteSlots++;
        }
    }

    /// @notice Per-turn storage-access profile for a clean PvP damage-trade turn (steady state).
    function test_storageAccessProfile_cleanDamageTradeTurn() public {
        IMoveSet moveA = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "AttackA", EFFECT: IEffect(address(0))
            })
        );
        IMoveSet moveB = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 25, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Special,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "AttackB", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon(Type.Fire);
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(moveA)));
        mon.moves[1] = uint256(uint160(address(moveB)));
        mon.moves[2] = uint256(uint160(address(moveA)));
        mon.moves[3] = uint256(uint160(address(moveB)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);
        bytes32 battleKey = _startBattle(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Warm-up: lead-in switch + 1 damage trade.
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(battleKey, 0, 0, 0, 0);

        // Now profile a steady-state warm turn.
        vm.startStateDiffRecording();
        _fastTurn(battleKey, 1, 1, 0, 0);
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();

        (
            uint256 totalSload,
            uint256 totalSstore,
            uint256 coldSload,
            uint256 warmSload,
            uint256 coldSstore,
            uint256 warmSstore,
            uint256 z2nz,
            uint256 nz2nz,
            uint256 noop,
            uint256 unique,
            uint256 multiWrite
        ) = _summarizeAccesses(diffs);

        console.log("=== CLEAN DAMAGE-TRADE TURN - STORAGE PROFILE ===");
        console.log("Total SLOADs                   :", totalSload);
        console.log("  Cold (first-touch in tx)     :", coldSload);
        console.log("  Warm                         :", warmSload);
        console.log("Total SSTOREs                  :", totalSstore);
        console.log("  Cold (first-touch in tx)     :", coldSstore);
        console.log("  Warm                         :", warmSstore);
        console.log("    zero -> nonzero            :", z2nz);
        console.log("    nonzero -> nonzero (diff)  :", nz2nz);
        console.log("    no-op (same value)         :", noop);
        console.log("Unique slots touched           :", unique);
        console.log("Slots written 2+ times in turn :", multiWrite);
    }

    /// @dev Shared log shape so all four scenarios produce comparable per-turn numbers.
    function _logDiffsBlock(string memory label, Vm.AccountAccess[] memory diffs) internal {
        (
            uint256 totalSload,
            uint256 totalSstore,
            uint256 coldSload,
            uint256 warmSload,
            uint256 coldSstore,
            uint256 warmSstore,
            uint256 z2nz,
            uint256 nz2nz,
            uint256 noop,
            uint256 unique,
            uint256 multiWrite
        ) = _summarizeAccesses(diffs);

        console.log(label);
        console.log("Total SLOADs                   :", totalSload);
        console.log("  Cold (first-touch in tx)     :", coldSload);
        console.log("  Warm                         :", warmSload);
        console.log("Total SSTOREs                  :", totalSstore);
        console.log("  Cold (first-touch in tx)     :", coldSstore);
        console.log("  Warm                         :", warmSstore);
        console.log("    zero -> nonzero            :", z2nz);
        console.log("    nonzero -> nonzero (diff)  :", nz2nz);
        console.log("    no-op (same value)         :", noop);
        console.log("Unique slots touched           :", unique);
        console.log("Slots written 2+ times in turn :", multiWrite);
    }

    /// @dev Records a state diff over a single `_fastTurn` call and prints the summary block.
    function _profileTurn(
        string memory label,
        bytes32 battleKey,
        uint8 p0Move,
        uint8 p1Move,
        uint16 p0Extra,
        uint16 p1Extra
    ) internal {
        vm.startStateDiffRecording();
        _fastTurn(battleKey, p0Move, p1Move, p0Extra, p1Extra);
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
        _logDiffsBlock(label, diffs);
    }

    /// @notice Per-turn storage profile when both active mons carry a multi-step effect.
    /// @dev Setup: ALICE & BOB each carry a PerTurnTickEffect attached to their active mon
    ///      (added via EffectAttack in turn 1). Profiled turn is a normal damage trade with
    ///      RoundStart, RoundEnd, and AfterDamage all firing the per-mon effect storage SLOADs.
    function test_storageAccessProfile_effectHeavyTurn() public {
        PerTurnTickEffect tickEffect = new PerTurnTickEffect();
        IMoveSet applyTick = new EffectAttack(IEffect(address(tickEffect)),
            EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1}));

        IMoveSet damageMove = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "DMG", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon(Type.Fire);
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(applyTick)));
        mon.moves[1] = uint256(uint160(address(damageMove)));
        mon.moves[2] = uint256(uint160(address(damageMove)));
        mon.moves[3] = uint256(uint160(address(damageMove)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);
        bytes32 battleKey = _startBattle(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Warm-up: lead-in switch, then both players use EffectAttack so each side's mon
        // ends up with the tick effect attached. Then a warm trade so all effect slots are
        // already SSTOREd nonzero by the time we measure.
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(battleKey, 0, 0, 0, 0); // both apply tick
        _fastTurn(battleKey, 1, 1, 0, 0); // warm trade

        _profileTurn("=== EFFECT-HEAVY TURN - STORAGE PROFILE ===", battleKey, 2, 2, 0, 0);
    }

    /// @dev Single-player forced-switch path: `_fastTurn` goes through `executeWithDualSignedMoves`
    /// which reverts with `NotTwoPlayerTurn()` when `playerSwitchForTurnFlag != 2`. The switch turn
    /// goes through `executeSinglePlayerMove`, which requires `msg.sender == acting player`.
    function _fastSinglePlayerTurn(bytes32 battleKey, address actingPlayer, uint8 moveIndex, uint16 extraData)
        internal
    {
        uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
        uint104 salt = uint104(uint256(keccak256(abi.encode("single", battleKey, turnId))));

        vm.prank(actingPlayer);
        signedCommitManager.executeSinglePlayerMove(battleKey, moveIndex, salt, extraData);
        engine.resetCallContext();
    }

    /// @notice Per-turn storage profile for the forced single-player switch turn that follows a KO.
    /// @dev Setup: p0's active mon HP is tuned low so p1's first attack KOs it. The next turn has
    ///      playerSwitchForTurnFlag == 0 (p0-only). Profile that switch turn — exercises the
    ///      `flag != 2` early-return branch that batch dispatch will key off of in §6.1.
    function test_storageAccessProfile_forcedSwitchTurn() public {
        IMoveSet bigHit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 200, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 5,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Big", EFFECT: IEffect(address(0))
            })
        );
        IMoveSet softHit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 1, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Soft", EFFECT: IEffect(address(0))
            })
        );

        // Glass mon for p0; tough mon for p1. Both teams have 4 mons so a KO doesn't end the battle.
        Mon memory glass = _createMon(Type.Fire);
        glass.stats.hp = 5;
        glass.moves = new uint256[](MOVES_PER_MON);
        glass.moves[0] = uint256(uint160(address(softHit)));
        glass.moves[1] = uint256(uint160(address(softHit)));
        glass.moves[2] = uint256(uint160(address(softHit)));
        glass.moves[3] = uint256(uint160(address(softHit)));

        Mon memory tough = _createMon(Type.Fire);
        tough.moves = new uint256[](MOVES_PER_MON);
        tough.moves[0] = uint256(uint160(address(bigHit)));
        tough.moves[1] = uint256(uint160(address(bigHit)));
        tough.moves[2] = uint256(uint160(address(bigHit)));
        tough.moves[3] = uint256(uint160(address(bigHit)));

        Mon[] memory p0Team = new Mon[](MONS_PER_TEAM);
        Mon[] memory p1Team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) {
            p0Team[i] = glass;
            p1Team[i] = tough;
        }
        defaultRegistry.setTeam(p0, p0Team);
        defaultRegistry.setTeam(p1, p1Team);

        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);
        bytes32 battleKey = _startBattle(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Lead-in switch.
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        // KO turn: p1's big hit takes priority and KO's p0's glass mon. playerSwitchForTurnFlag
        // becomes 0 for the next turn.
        _fastTurn(battleKey, 0, 0, 0, 0);

        // Now profile the single-player switch turn. p0 sends in mon 1 via executeSinglePlayerMove;
        // the engine routes via `playerSwitchForTurnFlag == 0` and skips p1's half entirely.
        vm.startStateDiffRecording();
        _fastSinglePlayerTurn(battleKey, p0, SWITCH_MOVE_INDEX, uint16(1));
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
        _logDiffsBlock("=== FORCED-SWITCH TURN - STORAGE PROFILE ===", diffs);
    }

    /// @notice Per-turn storage profile for a turn where one player switches mid-battle while the
    ///         other attacks. Touches three distinct mon-state slots in a single turn (p0 mon 0
    ///         out, p0 mon 1 in, p1 mon 0 attacking), exercising the sparse MonState read pattern
    ///         that the shadow layer's lazy-load bookkeeping has to handle.
    function test_storageAccessProfile_multiMonTurn() public {
        IMoveSet hit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Hit", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon(Type.Fire);
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(hit)));
        mon.moves[1] = uint256(uint160(address(hit)));
        mon.moves[2] = uint256(uint160(address(hit)));
        mon.moves[3] = uint256(uint160(address(hit)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        IRuleset ruleset = IRuleset(INLINE_STAMINA_REGEN_RULESET);
        bytes32 battleKey = _startBattle(ruleset);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Warm-up: lead-in switch + one trade to warm Mon-0 slots on both sides.
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(battleKey, 0, 0, 0, 0);

        // Profile a turn where p0 switches to mon 1 while p1 attacks. p0 mon 1's MonState slot
        // is cold — first touch in tx; p0 mon 0's slot is warmed but read again for switch-out
        // bookkeeping; p1 mon 0's slot reads attacker state. Three distinct mon slots in one turn.
        _profileTurn(
            "=== MULTI-MON SWITCH TURN - STORAGE PROFILE ===",
            battleKey,
            SWITCH_MOVE_INDEX,
            1,
            uint16(1),
            0
        );
    }
}

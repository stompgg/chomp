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

import {BurnStatus} from "../src/effects/status/BurnStatus.sol";
import {StatBoosts} from "../src/effects/StatBoosts.sol";
import {EffectAttack} from "./mocks/EffectAttack.sol";
import {StatBoostsMove} from "./mocks/StatBoostsMove.sol";
import {MockKVWriterMove} from "./mocks/MockKVWriterMove.sol";

import {TypeCalculator} from "../src/types/TypeCalculator.sol";
import {ITypeCalculator} from "../src/types/ITypeCalculator.sol";

import {SignedCommitHelper} from "./abstract/SignedCommitHelper.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";

/// Counts SLOAD / SSTORE access patterns on a warm steady-state turn, to ground the PLAN_OPT.md
/// gas math in real data instead of estimates.
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
        bytes memory committerSig =
            _signCommit(address(signedCommitManager), committerPk, committerMoveHash, battleKey, turnId);
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

        signedCommitManager.executeWithDualSignedMoves(
            battleKey,
            committerMoveIndex, committerSalt, committerExtraData,
            revealerMoveIndex, revealerSalt, revealerExtraData,
            committerSig,
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

    /// @dev Mirrors BattleHelper._packStatBoost so this test stays self-contained while still
    /// using the shared StatBoostsMove extraData layout.
    function _packStatBoost(uint256 playerIndex, uint256 monIndex, uint256 statIndex, int32 boostAmount)
        internal
        pure
        returns (uint16)
    {
        return uint16(
            (playerIndex & 0x1)
            | ((monIndex & 0x7) << 1)
            | ((statIndex & 0xF) << 4)
            | ((uint256(uint8(int8(boostAmount))) & 0xFF) << 8)
        );
    }

    /// @dev Forced switch / single-player turn entry point. After a KO the engine sets
    /// playerSwitchForTurnFlag to the player who must switch; the dual-signed path doesn't
    /// apply, only `executeSinglePlayerMove`.
    function _fastSinglePlayerTurn(bytes32 battleKey, uint8 moveIndex, uint16 extraData) internal {
        (,, uint8 playerFlag,,,) = _getCommitContextLite(battleKey);
        address acting = playerFlag == 0 ? p0 : p1;
        uint64 turnId = uint64(engine.getTurnIdForBattleState(battleKey));
        uint104 salt = uint104(uint256(keccak256(abi.encode("single", battleKey, turnId))));
        vm.prank(acting);
        signedCommitManager.executeSinglePlayerMove(battleKey, moveIndex, salt, extraData);
        engine.resetCallContext();
    }

    /// @dev Just the slice of CommitContext we need to find the acting player on a forced-switch
    /// turn. Defined here so the test doesn't pull in the whole struct surface.
    function _getCommitContextLite(bytes32 battleKey)
        internal
        view
        returns (
            address pa,
            address pb,
            uint8 playerSwitchForTurnFlag,
            uint8 winnerIndex,
            uint48 startTimestamp,
            uint64 turnId
        )
    {
        CommitContext memory ctx = engine.getCommitContext(battleKey);
        return (ctx.p0, ctx.p1, ctx.playerSwitchForTurnFlag, ctx.winnerIndex, ctx.startTimestamp, ctx.turnId);
    }

    function _printSummary(string memory label, Vm.AccountAccess[] memory diffs) internal pure {
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

        console.log("===", label, "- STORAGE PROFILE ===");
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
        vm.startSnapshotGas("LegacyTurn_CleanDamageTrade");
        vm.startStateDiffRecording();
        _fastTurn(battleKey, 1, 1, 0, 0);
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
        vm.stopSnapshotGas("LegacyTurn_CleanDamageTrade");

        _printSummary("CLEAN DAMAGE-TRADE TURN", diffs);
    }

    /// @notice Per-turn storage-access profile for a turn with BurnStatus DOT + StatBoosts active.
    ///         Exercises the effect-list slots, status flag in globalKV (via StatusEffect), and
    ///         the StatBoosts mirror slots.
    function test_storageAccessProfile_effectHeavyTurn() public {
        StatBoosts statBoosts = new StatBoosts();
        BurnStatus burnStatus = new BurnStatus(statBoosts);

        IMoveSet damage = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Damage", EFFECT: IEffect(address(0))
            })
        );
        IMoveSet burnMove = new EffectAttack(
            burnStatus,
            EffectAttack.Args({TYPE: Type.Fire, STAMINA_COST: 1, PRIORITY: 1})
        );
        IMoveSet boostMove = new StatBoostsMove(statBoosts);

        Mon memory mon = _createMon(Type.Fire);
        mon.moves = new uint256[](MOVES_PER_MON);
        mon.moves[0] = uint256(uint160(address(damage)));
        mon.moves[1] = uint256(uint160(address(burnMove)));
        mon.moves[2] = uint256(uint160(address(boostMove)));
        mon.moves[3] = uint256(uint160(address(damage)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        bytes32 battleKey = _startBattle(IRuleset(INLINE_STAMINA_REGEN_RULESET));
        vm.warp(vm.getBlockTimestamp() + 1);

        // Warm-up: lead-in switch, then both sides apply burn + boost so the profiled turn is steady-state.
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        // p0 applies burn to p1, p1 boosts own attack.
        _fastTurn(
            battleKey,
            1,
            2,
            uint16(0),
            _packStatBoost(1, 0, uint256(MonStateIndexName.Attack), int32(50))
        );
        // One full damage turn to fully warm effect slots / boosts.
        _fastTurn(battleKey, 0, 0, 0, 0);

        // Profile: warm damage trade with burn ticking + stat-boost stack consulted.
        vm.startSnapshotGas("LegacyTurn_EffectHeavy");
        vm.startStateDiffRecording();
        _fastTurn(battleKey, 3, 3, 0, 0);
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
        vm.stopSnapshotGas("LegacyTurn_EffectHeavy");

        _printSummary("EFFECT-HEAVY TURN (Burn DOT + StatBoosts)", diffs);
    }

    /// @notice Per-turn storage-access profile for a forced single-player switch turn (post-KO).
    ///         Exercises the `executeSinglePlayerMove` path and forced-switch dispatch (flag != 2).
    function test_storageAccessProfile_forcedSwitchTurn() public {
        // Cheap-to-KO mons: enough damage in one warm turn to KO the defender so the next turn
        // is a forced single-player switch.
        IMoveSet bigHit = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 200, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "BigHit", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon(Type.Fire);
        mon.stats.hp = 50; // Low HP so a single bigHit KOs.
        mon.stats.defense = 1;
        mon.moves = new uint256[](MOVES_PER_MON);
        for (uint256 i; i < MOVES_PER_MON; i++) mon.moves[i] = uint256(uint160(address(bigHit)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        bytes32 battleKey = _startBattle(IRuleset(INLINE_STAMINA_REGEN_RULESET));
        vm.warp(vm.getBlockTimestamp() + 1);

        // Warm-up: lead-in switch, then a damage trade that KOs p1's active mon. p0 outspeeds via
        // priority — both moves have PRIORITY 1, p0 (committer on turn 0 of damage) wins ties via parity.
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        // After the next damage trade we expect at least one side KO'd because hp=50 vs 200 base power.
        _fastTurn(battleKey, 0, 0, 0, 0);

        // The forced switch could land on either side. Read the flag to confirm and execute.
        (,, uint8 flag,,,) = _getCommitContextLite(battleKey);
        require(flag == 0 || flag == 1, "expected single-player forced switch");

        vm.startSnapshotGas("LegacyTurn_ForcedSwitch");
        vm.startStateDiffRecording();
        _fastSinglePlayerTurn(battleKey, SWITCH_MOVE_INDEX, uint16(1));
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
        vm.stopSnapshotGas("LegacyTurn_ForcedSwitch");

        _printSummary("FORCED-SWITCH TURN (single-player)", diffs);
    }

    /// @notice Per-turn storage-access profile for a normal two-player turn where one side opts
    ///         to switch instead of attack. Covers the switch-first dispatch on the warm path.
    function test_storageAccessProfile_multiMonTurn() public {
        IMoveSet attack = attackFactory.createAttack(
            ATTACK_PARAMS({
                BASE_POWER: 30, STAMINA_COST: 1, ACCURACY: 100, PRIORITY: 1,
                MOVE_TYPE: Type.Fire, EFFECT_ACCURACY: 0, MOVE_CLASS: MoveClass.Physical,
                CRIT_RATE: 0, VOLATILITY: 0, NAME: "Attack", EFFECT: IEffect(address(0))
            })
        );

        Mon memory mon = _createMon(Type.Fire);
        mon.moves = new uint256[](MOVES_PER_MON);
        for (uint256 i; i < MOVES_PER_MON; i++) mon.moves[i] = uint256(uint160(address(attack)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        bytes32 battleKey = _startBattle(IRuleset(INLINE_STAMINA_REGEN_RULESET));
        vm.warp(vm.getBlockTimestamp() + 1);

        // Warm-up: lead-in switch + a damage trade to warm storage on the active mon pair.
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        _fastTurn(battleKey, 0, 0, 0, 0);

        // Profile: p0 attacks while p1 voluntarily switches in mon 2. Touches a second mon's
        // MonState slot (cold for p1 mon 2), exercises switch-priority dispatch.
        vm.startSnapshotGas("LegacyTurn_MultiMon");
        vm.startStateDiffRecording();
        _fastTurn(battleKey, 1, SWITCH_MOVE_INDEX, uint16(0), uint16(2));
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
        vm.stopSnapshotGas("LegacyTurn_MultiMon");

        _printSummary("MULTI-MON TURN (attack + switch)", diffs);
    }

    /// @notice Per-turn storage-access profile for a turn where both sides write to globalKV.
    ///         Stresses the slot most relevant to the §5.1 lazy-load shadow path.
    function test_storageAccessProfile_globalKVHeavyTurn() public {
        IMoveSet kvWriter = new MockKVWriterMove();

        Mon memory mon = _createMon(Type.Fire);
        mon.moves = new uint256[](MOVES_PER_MON);
        for (uint256 i; i < MOVES_PER_MON; i++) mon.moves[i] = uint256(uint160(address(kvWriter)));

        Mon[] memory team = new Mon[](MONS_PER_TEAM);
        for (uint256 i; i < MONS_PER_TEAM; i++) team[i] = mon;
        defaultRegistry.setTeam(p0, team);
        defaultRegistry.setTeam(p1, team);

        bytes32 battleKey = _startBattle(IRuleset(INLINE_STAMINA_REGEN_RULESET));
        vm.warp(vm.getBlockTimestamp() + 1);

        // Warm-up: lead-in switch + a globalKV write turn so the key entries / count slot are warm
        // on the profiled turn (steady state, not first-write).
        _fastTurn(battleKey, SWITCH_MOVE_INDEX, SWITCH_MOVE_INDEX, uint16(0), uint16(0));
        // Both sides write to distinct keys to populate two globalKV slots.
        _fastTurn(battleKey, 0, 0, uint16(1) | (uint16(5) << 10), uint16(2) | (uint16(7) << 10));

        // Profile: both sides overwrite their respective KV slot. Tests warm globalKV touch only.
        vm.startSnapshotGas("LegacyTurn_GlobalKVHeavy");
        vm.startStateDiffRecording();
        _fastTurn(battleKey, 1, 1, uint16(1) | (uint16(9) << 10), uint16(2) | (uint16(11) << 10));
        Vm.AccountAccess[] memory diffs = vm.stopAndReturnStateDiff();
        vm.stopSnapshotGas("LegacyTurn_GlobalKVHeavy");

        _printSummary("GLOBALKV-HEAVY TURN", diffs);
    }
}

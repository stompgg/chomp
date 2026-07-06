// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {IEngineHook} from "../src/IEngineHook.sol";
import {IRuleset} from "../src/IRuleset.sol";
import {BattleOfferLib} from "../src/matchmaker/BattleOfferLib.sol";
import {IMatchmaker} from "../src/matchmaker/IMatchmaker.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";
import {IRandomnessOracle} from "../src/rng/IRandomnessOracle.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Multi (2v2, 4 seats) end-to-end flows: party matchmaking (named seats, open-seat
///         fills, CPU seats), the seat-quarter roster partition, and the D18 human-only
///         committer/revealer rotation on the built-in dual-signed buffer. Mocks only.
contract MultiFlowsTest is BatchHelper {
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    uint256 constant P2_PK = 0xCA7;
    uint256 constant P3_PK = 0xD06;
    address p0;
    address p1;
    address p2;
    address p3;

    Engine engine;
    SignedMatchmaker signedMatchmaker;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    IMoveSet weakAttack; // BP 10 into Type.Air = neutral
    IMoveSet killAttack; // BP 100
    bytes32 battleKey;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);
        p2 = vm.addr(P2_PK);
        p3 = vm.addr(P3_PK);
        engine = new Engine(GAME_MONS_PER_TEAM, GAME_MOVES_PER_MON);
        signedMatchmaker = new SignedMatchmaker(engine);
        registry = new TestTeamRegistry();
        typeCalc = new TestTypeCalculator();
        weakAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 10, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: DEFAULT_PRIORITY
            })
        );
        killAttack = new CustomAttack(
            typeCalc,
            CustomAttack.Args({
                TYPE: Type.Fire, BASE_POWER: 100, ACCURACY: 100, STAMINA_COST: 1, PRIORITY: DEFAULT_PRIORITY
            })
        );

        // Every seat approves both the signed matchmaker and this test (direct-start harness).
        address[] memory toAdd = new address[](2);
        toAdd[0] = address(signedMatchmaker);
        toAdd[1] = address(this);
        address[] memory seats = _seats();
        for (uint256 i; i < 4; ++i) {
            vm.prank(seats[i]);
            engine.updateMatchmakers(toAdd, new address[](0));
        }
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _seats() internal view returns (address[] memory seats) {
        seats = new address[](4);
        seats[0] = p0;
        seats[1] = p1;
        seats[2] = p2;
        seats[3] = p3;
    }

    function _mkMon(uint32 hp, uint32 speed, IMoveSet move0) internal pure returns (Mon memory mon) {
        uint256[] memory moves = new uint256[](1);
        moves[0] = uint256(uint160(address(move0)));
        mon = Mon({
            stats: MonStats({
                hp: hp,
                stamina: 5,
                speed: speed,
                attack: 10,
                defense: 10,
                specialAttack: 10,
                specialDefense: 10,
                type1: Type.Air,
                type2: Type.None
            }),
            ability: 0,
            moves: moves
        });
    }

    /// @dev 4 mons per seat (Multi launch shape), all identical.
    function _mkTeam(uint32 hp, uint32 speed, IMoveSet move0) internal pure returns (Mon[] memory team) {
        team = new Mon[](4);
        for (uint256 i; i < 4; ++i) {
            team[i] = _mkMon(hp, speed, move0);
        }
    }

    function _setDefaultTeams() internal {
        registry.setTeam(p0, _mkTeam(1000, 40, killAttack));
        registry.setTeam(p2, _mkTeam(1000, 30, killAttack));
        registry.setTeam(p1, _mkTeam(100, 20, weakAttack));
        registry.setTeam(p3, _mkTeam(100, 10, weakAttack));
    }

    function _battle(address moveManager) internal view returns (Battle memory) {
        return Battle({
            p0: p0,
            p0TeamIndex: 0,
            p1: p1,
            p1TeamIndex: 0,
            p2: p2,
            p2TeamIndex: 0,
            p3: p3,
            p3TeamIndex: 0,
            teamRegistry: registry,
            rngOracle: IRandomnessOracle(address(0)),
            ruleset: IRuleset(address(0)),
            moveManager: moveManager,
            matchmaker: IMatchmaker(address(this)),
            engineHooks: new IEngineHook[](0)
        });
    }

    function _offer() internal view returns (BattleOffer memory offer) {
        (, bytes32 partyHash) = engine.computePartyKey(p0, p1, p2, p3);
        Battle memory battle = _battle(BUILTIN_DUAL_SIGNED_MANAGER);
        battle.matchmaker = signedMatchmaker;
        offer = BattleOffer({
            battle: battle, pairHashNonce: engine.pairHashNonces(partyHash), battleMode: BATTLE_MODE_MULTI
        });
    }

    function _signOpenDigest(uint256 pk, BattleOffer memory offer, uint8 openSeatsMask)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = signedMatchmaker.hashTypedData(BattleOfferLib.hashBattleOfferForSigning(offer, openSeatsMask));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSeatFill(uint256 pk, BattleOffer memory offer, uint8 openSeatsMask, uint8 seatIndex)
        internal
        view
        returns (bytes memory)
    {
        bytes32 openDigest =
            signedMatchmaker.hashTypedData(BattleOfferLib.hashBattleOfferForSigning(offer, openSeatsMask));
        bytes32 digest = signedMatchmaker.hashTypedData(BattleOfferLib.hashSeatFill(openDigest, seatIndex));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _startDirect() internal {
        _setDefaultTeams();
        (battleKey,) = engine.computePartyKey(p0, p1, p2, p3);
        engine.startBattleWithMode(_battle(address(this)), BATTLE_MODE_MULTI);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Wire word per side: [m0 8 | e0 16 | m1 8 | e1 16 | salt 104].
    function _sideWord(uint8 m0, uint16 e0, uint8 m1, uint16 e1, uint104 salt) internal pure returns (uint256) {
        return uint256(m0) | (uint256(e0) << 8) | (uint256(m1) << 24) | (uint256(e1) << 32) | (uint256(salt) << 48);
    }

    function _target(uint256 absSlot) internal pure returns (uint16) {
        return uint16(uint256(1) << (TARGET_BITS_SHIFT + absSlot));
    }

    /// @dev Turn 0: every slot sends in its quarter's lead (slot-0 lanes mon 0, slot-1 lanes mon 4).
    function _sendInLeads() internal {
        engine.executeWithSlotMoves(
            battleKey,
            _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xAAA)),
            _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xBBB))
        );
    }

    function _noOpWord(uint104 salt) internal pure returns (uint256) {
        return _sideWord(NO_OP_MOVE_INDEX, 0, NO_OP_MOVE_INDEX, 0, salt);
    }

    // ---------------------------------------------------------------------
    // Party key + seat views
    // ---------------------------------------------------------------------

    function test_partyKey_permutationInvariantAndDuplicateReverts() public {
        (bytes32 keyA, bytes32 hashA) = engine.computePartyKey(p0, p1, p2, p3);
        (bytes32 keyB, bytes32 hashB) = engine.computePartyKey(p3, p2, p1, p0);
        assertEq(keyA, keyB, "sorted preimage is permutation-invariant");
        assertEq(hashA, hashB);

        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.computePartyKey(p0, p1, p0, p3);
    }

    function test_getSeatsCanonicalOrder() public {
        _startDirect();
        address[4] memory seats = engine.getSeats(battleKey);
        assertEq(seats[0], p0);
        assertEq(seats[1], p2);
        assertEq(seats[2], p1);
        assertEq(seats[3], p3);
    }

    // ---------------------------------------------------------------------
    // Battle-start shape validation
    // ---------------------------------------------------------------------

    function test_multiRequiresBothExtraSeats() public {
        _setDefaultTeams();
        Battle memory battle = _battle(address(this));
        battle.p3 = address(0);
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.startBattleWithMode(battle, BATTLE_MODE_MULTI);

        // ...and non-Multi modes must leave them empty.
        Battle memory doublesBattle = _battle(address(this));
        doublesBattle.p3 = address(0);
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.startBattleWithMode(doublesBattle, BATTLE_MODE_DOUBLES);
    }

    function test_multiAllSeatsMustApproveMatchmaker() public {
        _setDefaultTeams();
        address stranger = address(0xDEAD);
        registry.setTeam(stranger, _mkTeam(100, 10, weakAttack));
        Battle memory battle = _battle(address(this));
        battle.p3 = stranger; // never called updateMatchmakers
        vm.expectRevert(Engine.MatchmakerNotAuthorized.selector);
        engine.startBattleWithMode(battle, BATTLE_MODE_MULTI);
    }

    function test_multiSeatTeamsMustBeExactlyFour() public {
        _setDefaultTeams();
        registry.setTeam(p2, new Mon[](0)); // 3-mon seat team breaks the fixed stride-4 partition
        Mon[] memory shortTeam = new Mon[](3);
        shortTeam[0] = _mkMon(100, 10, weakAttack);
        shortTeam[1] = _mkMon(100, 10, weakAttack);
        shortTeam[2] = _mkMon(100, 10, weakAttack);
        registry.setTeam(p2, shortTeam);
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.startBattleWithMode(_battle(address(this)), BATTLE_MODE_MULTI);
    }

    function test_multiBuiltinRequiresHumanPerSide() public {
        _setDefaultTeams();
        // Side 1 (p1 + p3) fully CPU: the dual-signed rotation would have no revealer.
        registry.setWhitelistedOpponent(p1, true);
        registry.setWhitelistedOpponent(p3, true);
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        engine.startBattleWithMode(_battle(BUILTIN_DUAL_SIGNED_MANAGER), BATTLE_MODE_MULTI);

        // A manager-mediated battle with the same seating is fine (relay trust, D19).
        (battleKey,) = engine.computePartyKey(p0, p1, p2, p3);
        engine.startBattleWithMode(_battle(address(this)), BATTLE_MODE_MULTI);
        assertEq(engine.getSeats(battleKey)[1], p2);
    }

    // ---------------------------------------------------------------------
    // Matchmaker: named offers, open seats, CPU seats
    // ---------------------------------------------------------------------

    function test_matchmaker_namedOfferAllSeatsSign() public {
        _setDefaultTeams();
        BattleOffer memory offer = _offer();
        bytes[4] memory seatSigs;
        // Canonical order [p0, p2, p1, p3]; p3 submits so its slot stays empty (msg.sender rule).
        seatSigs[0] = _signOpenDigest(P0_PK, offer, 0);
        seatSigs[1] = _signOpenDigest(P2_PK, offer, 0);
        seatSigs[2] = _signOpenDigest(P1_PK, offer, 0);

        (bytes32 expectedKey,) = engine.computePartyKey(p0, p1, p2, p3);
        vm.expectEmit(true, false, false, true);
        emit Engine.SlotBattleStart(expectedKey, p0, p1, BATTLE_MODE_MULTI, p2, p3);
        vm.prank(p3);
        signedMatchmaker.startGame(offer, 0, seatSigs);
    }

    function test_matchmaker_missingSeatConsentReverts() public {
        _setDefaultTeams();
        BattleOffer memory offer = _offer();
        bytes[4] memory seatSigs;
        seatSigs[0] = _signOpenDigest(P0_PK, offer, 0);
        seatSigs[2] = _signOpenDigest(P1_PK, offer, 0);
        // p2 (canonical seat 1) neither signed nor submits.
        vm.prank(p3);
        vm.expectRevert(SignedMatchmaker.MissingConsent.selector);
        signedMatchmaker.startGame(offer, 0, seatSigs);
    }

    function test_matchmaker_openSeatFilledViaSeatFill() public {
        _setDefaultTeams();
        // Creator publishes with the p3 seat open (canonical bit 3): p3 is blinded to
        // address(0) in every signature; the joiner authorizes via SeatFill.
        BattleOffer memory offer = _offer();
        offer.battle.p3 = address(0);
        offer.pairHashNonce = signedMatchmaker.openBattleOfferNonce(p0);
        uint8 mask = 8;

        bytes[4] memory seatSigs;
        seatSigs[0] = _signOpenDigest(P0_PK, offer, mask);
        seatSigs[1] = _signOpenDigest(P2_PK, offer, mask);
        seatSigs[3] = _signSeatFill(P3_PK, offer, mask, 3);

        offer.battle.p3 = p3; // submitter seats the joiner before submission
        (bytes32 key,) = engine.computePartyKey(p0, p1, p2, p3); // pre-start nonce
        vm.prank(p1);
        signedMatchmaker.startGame(offer, mask, seatSigs);
        assertEq(signedMatchmaker.openBattleOfferNonce(p0), 1, "open offer consumed the creator nonce");
        assertEq(engine.getSeats(key)[3], p3);
    }

    function test_matchmaker_cpuSeatNeedsNoConsent() public {
        _setDefaultTeams();
        registry.setWhitelistedOpponent(p3, true);
        BattleOffer memory offer = _offer();
        offer.battle.moveManager = address(this); // CPU battles ride a manager (D19)
        bytes[4] memory seatSigs;
        seatSigs[0] = _signOpenDigest(P0_PK, offer, 0);
        seatSigs[1] = _signOpenDigest(P2_PK, offer, 0);
        // p3 is a whitelisted opponent: no signature lane needed. p1 submits.
        (bytes32 key,) = engine.computePartyKey(p0, p1, p2, p3); // pre-start nonce
        vm.prank(p1);
        signedMatchmaker.startGame(offer, 0, seatSigs);
        assertEq(engine.getSeats(key)[3], p3);
    }

    function test_matchmaker_duplicateSeatReverts() public {
        _setDefaultTeams();
        BattleOffer memory offer = _offer();
        offer.battle.p2 = p1;
        bytes[4] memory seatSigs;
        seatSigs[0] = _signOpenDigest(P0_PK, offer, 0);
        seatSigs[1] = _signOpenDigest(P1_PK, offer, 0);
        seatSigs[2] = _signOpenDigest(P1_PK, offer, 0);
        vm.prank(p3);
        vm.expectRevert(Engine.InvalidBattleConfig.selector);
        signedMatchmaker.startGame(offer, 0, seatSigs);
    }

    function test_matchmaker_wrongPartyNonceReverts() public {
        _setDefaultTeams();
        BattleOffer memory offer = _offer();
        offer.pairHashNonce += 1;
        bytes[4] memory seatSigs;
        seatSigs[0] = _signOpenDigest(P0_PK, offer, 0);
        seatSigs[1] = _signOpenDigest(P2_PK, offer, 0);
        seatSigs[2] = _signOpenDigest(P1_PK, offer, 0);
        vm.prank(p3);
        vm.expectRevert(SignedMatchmaker.InvalidNonce.selector);
        signedMatchmaker.startGame(offer, 0, seatSigs);
    }

    // ---------------------------------------------------------------------
    // Roster partition (fixed stride 4)
    // ---------------------------------------------------------------------

    function test_partition_turn0SendInsLandInQuarters() public {
        _startDirect();
        // Slot-1 lanes ask for mon 0 (out of quarter) — coerced to the quarter's first legal (4).
        engine.executeWithSlotMoves(
            battleKey,
            _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 0, uint104(0xAAA)),
            _sideWord(SWITCH_MOVE_INDEX, 2, SWITCH_MOVE_INDEX, 6, uint104(0xBBB))
        );
        uint256[4] memory slots = engine.getActiveSlots(battleKey);
        assertEq(slots[0], 0, "A0 lead from seat-0 quarter");
        assertEq(slots[1], 4, "A1 coerced into seat-1 quarter");
        assertEq(slots[2], 2, "B0 chose within quarter");
        assertEq(slots[3], 6, "B1 chose within quarter");
    }

    function test_partition_crossQuarterSwitchFizzles() public {
        _startDirect();
        _sendInLeads();
        // A0 tries to switch into p2's quarter (mon 5); A1 tries p0's quarter (mon 1).
        engine.executeWithSlotMoves(
            battleKey, _sideWord(SWITCH_MOVE_INDEX, 5, SWITCH_MOVE_INDEX, 1, uint104(0xA1)), _noOpWord(uint104(0xB1))
        );
        uint256[4] memory slots = engine.getActiveSlots(battleKey);
        assertEq(slots[0], 0, "cross-quarter switch fizzles (A0)");
        assertEq(slots[1], 4, "cross-quarter switch fizzles (A1)");

        // Legal in-quarter switches work.
        engine.executeWithSlotMoves(
            battleKey, _sideWord(SWITCH_MOVE_INDEX, 1, SWITCH_MOVE_INDEX, 5, uint104(0xA2)), _noOpWord(uint104(0xB2))
        );
        slots = engine.getActiveSlots(battleKey);
        assertEq(slots[0], 1);
        assertEq(slots[1], 5);
    }

    // ---------------------------------------------------------------------
    // D18 rotation on the built-in dual-signed buffer
    // ---------------------------------------------------------------------

    /// @dev Canonical human rotation for this suite's seating. `cpuMask` bits are canonical
    ///      ([p0, p2, p1, p3]); mirrors the engine's rule.
    function _rotation(uint64 turnId, uint8 cpuMask)
        internal
        view
        returns (uint256 committerPk, uint256 revealerPk, bool committerIsSide0)
    {
        uint256[4] memory canonicalPks = [P0_PK, P2_PK, P1_PK, P3_PK];
        uint256[4] memory humans;
        uint256 side0Count;
        uint256 n;
        for (uint256 i; i < 4; ++i) {
            if (cpuMask & (1 << i) != 0) continue;
            humans[n++] = canonicalPks[i];
            if (i < 2) ++side0Count;
        }
        uint256 ci = turnId % n;
        committerPk = humans[ci];
        committerIsSide0 = ci < side0Count;
        revealerPk = committerIsSide0 ? humans[side0Count + (turnId % (n - side0Count))] : humans[turnId % side0Count];
    }

    function _submitRotatingTurn(uint64 turnId, uint256 side0Word, uint256 side1Word, uint8 cpuMask) internal {
        (uint256 committerPk, uint256 revealerPk, bool committerIsSide0) = _rotation(turnId, cpuMask);
        (uint256 committerPacked, uint256 revealerPacked) =
            committerIsSide0 ? (side0Word, side1Word) : (side1Word, side0Word);
        bytes memory sig = _signDualSlotRevealForEngine(
            address(engine), revealerPk, battleKey, turnId, keccak256(abi.encodePacked(committerPacked)), revealerPacked
        );
        (bytes32 r, bytes32 vs) = _compactSig(sig);
        vm.prank(vm.addr(committerPk));
        engine.submitSlotTurnMovesAndExecute(battleKey, committerPacked, revealerPacked, r, vs);
        engine.resetCallContext();
    }

    function _startBuiltin() internal {
        _setDefaultTeams();
        (battleKey,) = engine.computePartyKey(p0, p1, p2, p3);
        engine.startBattleWithMode(_battle(BUILTIN_DUAL_SIGNED_MANAGER), BATTLE_MODE_MULTI);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function test_rotation_fourHumansFullCycle() public {
        _startBuiltin();
        uint256 side0SendIn = _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xAAA));
        uint256 side1SendIn = _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xBBB));

        // Turn 0 must come from p0 (canonical seat 0): p2 committing is rejected.
        {
            bytes memory sig = _signDualSlotRevealForEngine(
                address(engine), P1_PK, battleKey, 0, keccak256(abi.encodePacked(side0SendIn)), side1SendIn
            );
            (bytes32 r, bytes32 vs) = _compactSig(sig);
            vm.prank(p2);
            vm.expectRevert(Engine.NotCommitter.selector);
            engine.submitSlotTurnMovesAndExecute(battleKey, side0SendIn, side1SendIn, r, vs);
        }

        // t0: p0 -> p1. t1: p2 -> p3. t2: p1 -> p0. t3: p3 -> p2. All four turns no-op after
        // the send-ins; reaching t4 proves each (committer, revealer) pair validated.
        _submitRotatingTurn(0, side0SendIn, side1SendIn, 0);
        for (uint64 t = 1; t < 5; ++t) {
            _submitRotatingTurn(t, _noOpWord(uint104(0xA0 + t)), _noOpWord(uint104(0xB0 + t)), 0);
        }
        assertEq(engine.getTurnIdForBattleState(battleKey), 5);
    }

    function test_rotation_wrongRevealerSignatureRejected() public {
        _startBuiltin();
        uint256 side0SendIn = _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xAAA));
        uint256 side1SendIn = _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xBBB));
        // Turn 0's revealer is p1 (mirror seat); a p3 signature must be rejected.
        bytes memory sig = _signDualSlotRevealForEngine(
            address(engine), P3_PK, battleKey, 0, keccak256(abi.encodePacked(side0SendIn)), side1SendIn
        );
        (bytes32 r, bytes32 vs) = _compactSig(sig);
        vm.prank(p0);
        vm.expectRevert(Engine.InvalidSignature.selector);
        engine.submitSlotTurnMovesAndExecute(battleKey, side0SendIn, side1SendIn, r, vs);
    }

    function test_rotation_cpuSeatSkipped() public {
        _setDefaultTeams();
        // p2 (canonical seat 1, side 0) is a CPU: humans = [p0 | p1, p3], so the committer
        // cycle is p0, p1, p3 and side-0 reveals always fall to p0.
        registry.setWhitelistedOpponent(p2, true);
        (battleKey,) = engine.computePartyKey(p0, p1, p2, p3);
        engine.startBattleWithMode(_battle(BUILTIN_DUAL_SIGNED_MANAGER), BATTLE_MODE_MULTI);
        vm.warp(vm.getBlockTimestamp() + 1);

        uint8 cpuMask = 2;
        _submitRotatingTurn(
            0,
            _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xAAA)),
            _sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 4, uint104(0xBBB)),
            cpuMask
        );
        // One full 3-human cycle plus wrap: t1 = p1 -> p0, t2 = p3 -> p0, t3 = p0 -> p3.
        for (uint64 t = 1; t < 4; ++t) {
            _submitRotatingTurn(t, _noOpWord(uint104(0xA0 + t)), _noOpWord(uint104(0xB0 + t)), cpuMask);
        }
        assertEq(engine.getTurnIdForBattleState(battleKey), 4);

        // And the skipped CPU seat can never commit.
        uint256 side0Word = _noOpWord(uint104(0xF7));
        uint256 side1Word = _noOpWord(uint104(0xF8));
        bytes memory sig = _signDualSlotRevealForEngine(
            address(engine), P1_PK, battleKey, 4, keccak256(abi.encodePacked(side0Word)), side1Word
        );
        (bytes32 r, bytes32 vs) = _compactSig(sig);
        vm.prank(p2);
        vm.expectRevert(Engine.NotCommitter.selector);
        engine.submitSlotTurnMovesAndExecute(battleKey, side0Word, side1Word, r, vs);
    }

    // ---------------------------------------------------------------------
    // Full battle: side wipe across quarters ends the game
    // ---------------------------------------------------------------------

    function test_multiFullBattle_sideWipeAcrossQuarters() public {
        _startDirect();
        _sendInLeads();
        // 8 kill rounds: A's two actives KO B's current actives; B's replacements keep
        // stepping in from each seat's quarter until side 1 is out of mons.
        for (uint256 round; round < 4; ++round) {
            engine.executeWithSlotMoves(
                battleKey,
                _sideWord(0, _target(2), 0, _target(3), uint104(0xA0 + uint8(round))),
                _sideWord(0, _target(0), 0, _target(0), uint104(0xB0 + uint8(round)))
            );
            if (engine.getWinner(battleKey) != address(0)) break;
            // Forced-switch turn: each KO'd B slot brings its quarter's next mon.
            engine.executeWithSlotMoves(
                battleKey,
                _noOpWord(uint104(0xC0 + uint8(round))),
                _sideWord(
                    SWITCH_MOVE_INDEX,
                    uint16(round + 1),
                    SWITCH_MOVE_INDEX,
                    uint16(round + 5),
                    uint104(0xD0 + uint8(round))
                )
            );
        }
        assertEq(engine.getWinner(battleKey), p0, "side-0 lead reported as winner");
    }
}

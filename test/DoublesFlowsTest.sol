// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../src/Constants.sol";
import "../src/Enums.sol";
import "../src/Structs.sol";

import {Engine} from "../src/Engine.sol";
import {SignedMatchmaker} from "../src/matchmaker/SignedMatchmaker.sol";
import {IMoveSet} from "../src/moves/IMoveSet.sol";

import {BatchHelper} from "./abstract/BatchHelper.sol";
import {defaultBattle, sideWord, signOffer, targetBits} from "./abstract/SlotWire.sol";
import {CustomAttack} from "./mocks/CustomAttack.sol";
import {TestTeamRegistry} from "./mocks/TestTeamRegistry.sol";
import {TestTypeCalculator} from "./mocks/TestTypeCalculator.sol";

/// @notice Doubles signed offers + the built-in dual-signed slot buffer flows.
contract DoublesFlowsTest is BatchHelper {
    uint256 constant P0_PK = 0xA11CE;
    uint256 constant P1_PK = 0xB0B;
    address p0;
    address p1;

    Engine engine;
    SignedMatchmaker signedMatchmaker;
    TestTeamRegistry registry;
    TestTypeCalculator typeCalc;
    IMoveSet weakAttack; // BP 10 (neutral typing), stamina 1
    IMoveSet killAttack; // BP 100, stamina 1
    bytes32 battleKey;

    function setUp() public {
        p0 = vm.addr(P0_PK);
        p1 = vm.addr(P1_PK);
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

        address[] memory toAdd = new address[](1);
        toAdd[0] = address(signedMatchmaker);
        address[] memory toRemove = new address[](0);
        vm.prank(p0);
        engine.updateMatchmakers(toAdd, toRemove);
        vm.prank(p1);
        engine.updateMatchmakers(toAdd, toRemove);
    }

    function _mkMon(uint32 hp, uint32 speed, IMoveSet move0) internal view returns (Mon memory mon) {
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
                type1: Type.Air, // neutral into Fire attacks
                type2: Type.None
            }),
            ability: 0,
            moves: moves
        });
    }

    function _offer(uint8 battleMode) internal view returns (BattleOffer memory offer) {
        (, bytes32 pairHash) = engine.computeBattleKey(p0, p1);
        offer = BattleOffer({
            battle: defaultBattle(p0, p1, registry, BUILTIN_DUAL_SIGNED_MANAGER, signedMatchmaker),
            pairHashNonce: engine.pairHashNonces(pairHash),
            battleMode: battleMode
        });
    }

    function _startDoublesViaOffer(Mon[] memory aTeam, Mon[] memory bTeam) internal {
        registry.setTeam(p0, aTeam);
        registry.setTeam(p1, bTeam);
        BattleOffer memory offer = _offer(BATTLE_MODE_DOUBLES);
        (battleKey,) = engine.computeBattleKey(p0, p1);
        bytes[4] memory seatSigs;
        seatSigs[0] = signOffer(signedMatchmaker, P0_PK, offer, 0);
        vm.prank(p1);
        signedMatchmaker.startGame(offer, 0, seatSigs);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _combinedSlotTurn(uint64 turnId, uint256 side0, uint256 side1) internal {
        (uint256 committerPacked, uint256 revealerPacked, bytes32 r, bytes32 vs) =
            _buildSlotTurnSubmissionForEngine(address(engine), battleKey, turnId, side0, side1, P0_PK, P1_PK);
        vm.prank(_committerFor(turnId, p0, p1));
        engine.submitSlotTurnMovesAndExecute(battleKey, committerPacked, revealerPacked, r, vs);
        engine.resetCallContext();
    }

    function _stageSlotTurn(uint64 turnId, uint256 side0, uint256 side1) internal {
        (uint256 committerPacked, uint256 revealerPacked, bytes32 r, bytes32 vs) =
            _buildSlotTurnSubmissionForEngine(address(engine), battleKey, turnId, side0, side1, P0_PK, P1_PK);
        vm.prank(_committerFor(turnId, p0, p1));
        engine.submitSlotTurnMoves(battleKey, committerPacked, revealerPacked, r, vs);
    }

    function _sendInLeads(uint64 turnId) internal {
        _combinedSlotTurn(
            turnId,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xAAA)),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xBBB))
        );
    }

    function _standardTeams() internal view returns (Mon[] memory aTeam, Mon[] memory bTeam) {
        aTeam = new Mon[](2);
        aTeam[0] = _mkMon(1000, 40, killAttack);
        aTeam[1] = _mkMon(1000, 30, killAttack);
        bTeam = new Mon[](2);
        bTeam[0] = _mkMon(100, 20, weakAttack);
        bTeam[1] = _mkMon(100, 10, weakAttack);
    }

    function test_signedOffer_startsDoublesBattle() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        registry.setTeam(p0, aTeam);
        registry.setTeam(p1, bTeam);
        BattleOffer memory offer = _offer(BATTLE_MODE_DOUBLES);
        bytes[4] memory seatSigs;
        seatSigs[0] = signOffer(signedMatchmaker, P0_PK, offer, 0);
        (bytes32 expectedKey,) = engine.computeBattleKey(p0, p1);

        vm.expectEmit(true, false, false, true);
        emit Engine.SlotBattleStart(expectedKey, p0, p1, BATTLE_MODE_DOUBLES, address(0), address(0));
        vm.prank(p1);
        signedMatchmaker.startGame(offer, 0, seatSigs);

        battleKey = expectedKey;
        vm.warp(vm.getBlockTimestamp() + 1);
        _sendInLeads(0);
        uint256[4] memory slots = engine.getActiveSlots(battleKey);
        assertEq(slots[0], 0);
        assertEq(slots[1], 1);
        assertEq(slots[2], 0);
        assertEq(slots[3], 1);
    }

    function test_signedOffer_wrongModeSignatureRejected() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        registry.setTeam(p0, aTeam);
        registry.setTeam(p1, bTeam);
        // p0 signs a SINGLES offer; p1 tries to start it as Doubles.
        BattleOffer memory signedOffer = _offer(BATTLE_MODE_SINGLES);
        BattleOffer memory tampered = _offer(BATTLE_MODE_DOUBLES);
        bytes[4] memory seatSigs;
        seatSigs[0] = signOffer(signedMatchmaker, P0_PK, signedOffer, 0);
        vm.prank(p1);
        vm.expectRevert(SignedMatchmaker.InvalidSignature.selector);
        signedMatchmaker.startGame(tampered, 0, seatSigs);
    }

    function test_combinedSlotTurns_fullBattle() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoublesViaOffer(aTeam, bTeam);
        _sendInLeads(0);

        // Turn 1: A kills both B actives (side wipe, no bench) -> p0 wins.
        uint256 side0 = sideWord(0, targetBits(2), 0, targetBits(3), uint104(0xA1));
        uint256 side1 = sideWord(0, targetBits(0), 0, targetBits(0), uint104(0xB1));
        vm.expectEmit(true, false, false, true);
        emit Engine.SlotMovesSubmitted(battleKey, side0, side1);
        _combinedSlotTurn(1, side0, side1);

        assertEq(engine.getWinner(battleKey), p0, "side wipe -> p0 wins");
    }

    function test_stageThenDrain() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoublesViaOffer(aTeam, bTeam);

        uint256 t0side0 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xAAA));
        uint256 t0side1 = sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, uint104(0xBBB));
        uint256 t1side0 = sideWord(0, targetBits(2), NO_OP_MOVE_INDEX, 0, uint104(0xA1));
        uint256 t1side1 = sideWord(0, targetBits(0), NO_OP_MOVE_INDEX, 0, uint104(0xB1));
        _stageSlotTurn(0, t0side0, t0side1);
        _stageSlotTurn(1, t1side0, t1side1);

        (uint64 numExecuted, uint256[] memory sideWords) = engine.getBufferedSlotTurns(battleKey);
        assertEq(numExecuted, 0);
        assertEq(sideWords.length, 4);
        assertEq(sideWords[0], t0side0);
        assertEq(sideWords[1], t0side1);
        assertEq(sideWords[2], t1side0);
        assertEq(sideWords[3], t1side1);

        engine.executeBuffered(battleKey);
        engine.resetCallContext();
        assertEq(engine.getTurnIdForBattleState(battleKey), 2, "both buffered turns executed");
        // Turn 1's kill landed: B slot 0's mon is KO'd.
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1);
    }

    function test_reverts_modeAndRoleGuards() public {
        (Mon[] memory aTeam, Mon[] memory bTeam) = _standardTeams();
        _startDoublesViaOffer(aTeam, bTeam);

        // v1 (singles) staging on a doubles battle
        vm.prank(p0);
        vm.expectRevert(Engine.WrongBattleMode.selector);
        engine.submitTurnMoves(battleKey, 0, bytes32(0), bytes32(0));

        // v1 buffer view on a doubles battle
        vm.expectRevert(Engine.WrongBattleMode.selector);
        engine.getBufferedTurns(battleKey);

        // wrong committer (turn 0 committer is p0)
        (uint256 committerPacked, uint256 revealerPacked, bytes32 r, bytes32 vs) = _buildSlotTurnSubmissionForEngine(
            address(engine),
            battleKey,
            0,
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, 1),
            sideWord(SWITCH_MOVE_INDEX, 0, SWITCH_MOVE_INDEX, 1, 2),
            P0_PK,
            P1_PK
        );
        vm.prank(p1);
        vm.expectRevert(Engine.NotCommitter.selector);
        engine.submitSlotTurnMoves(battleKey, committerPacked, revealerPacked, r, vs);

        // garbage signature
        vm.prank(p0);
        vm.expectRevert();
        engine.submitSlotTurnMoves(battleKey, committerPacked, revealerPacked, bytes32(uint256(1)), bytes32(uint256(2)));
    }

    function test_slotSubmitOnSinglesBattle_reverts() public {
        // Start a SINGLES builtin battle via the same offer flow (mode 0).
        Mon[] memory aTeam = new Mon[](1);
        aTeam[0] = _mkMon(1000, 40, killAttack);
        Mon[] memory bTeam = new Mon[](1);
        bTeam[0] = _mkMon(100, 20, weakAttack);
        registry.setTeam(p0, aTeam);
        registry.setTeam(p1, bTeam);
        BattleOffer memory offer = _offer(BATTLE_MODE_SINGLES);
        (battleKey,) = engine.computeBattleKey(p0, p1);
        bytes[4] memory seatSigs;
        seatSigs[0] = signOffer(signedMatchmaker, P0_PK, offer, 0);
        vm.prank(p1);
        signedMatchmaker.startGame(offer, 0, seatSigs);

        vm.prank(p0);
        vm.expectRevert(Engine.WrongBattleMode.selector);
        engine.submitSlotTurnMoves(battleKey, 0, 0, bytes32(0), bytes32(0));
    }
}

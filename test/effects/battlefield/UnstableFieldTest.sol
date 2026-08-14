// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../../src/Constants.sol";
import "../../../src/Enums.sol";
import "../../../src/Structs.sol";

import {IRuleset} from "../../../src/IRuleset.sol";
import {IEffect} from "../../../src/effects/IEffect.sol";
import {UnstableField} from "../../../src/effects/battlefield/UnstableField.sol";

import {sideWord, targetBits} from "../../abstract/SlotWire.sol";
import {FieldHarness} from "./FieldHarness.sol";

/// @notice UnstableField: every live active is dragged out for a random benched mon at round end.
contract UnstableFieldTest is FieldHarness {
    UnstableField field;
    IRuleset ruleset;

    function setUp() public {
        _setUpHarness();
        field = new UnstableField();
        ruleset = _ruleset(IEffect(address(field)), INLINE_STAMINA_REGEN_RULESET);
    }

    function _startFourMonSingles(IRuleset rules) internal {
        _startSingles(_mkTeam(4, 1000, 5, 10, weakAttack), _mkTeam(4, 1000, 5, 5, weakAttack), rules);
    }

    function test_turnZeroArmsTheFieldWithoutDragging() public {
        _startFourMonSingles(ruleset);
        _singlesLeads(0);

        // Switch-in abilities do not fire on turn 0, so the leads stay put.
        assertEq(_active(A0), 0, "Alice keeps her lead through turn 0");
        assertEq(_active(B0), 0, "Bob keeps his lead through turn 0");
    }

    function test_bothActivesAreDraggedEveryFullTurn() public {
        _startFourMonSingles(ruleset);
        _singlesLeads(0);

        _singlesTurn(NO_OP_MOVE_INDEX, 0, 1, NO_OP_MOVE_INDEX, 0, 0);
        uint256 aFirst = _active(A0);
        uint256 bFirst = _active(B0);
        assertTrue(aFirst != 0, "Alice's lead was dragged out");
        assertTrue(bFirst != 0, "Bob's lead was dragged out");

        _singlesTurn(NO_OP_MOVE_INDEX, 0, 2, NO_OP_MOVE_INDEX, 0, 0);
        assertTrue(_active(A0) != aFirst, "Alice is dragged again the next turn");
        assertTrue(_active(B0) != bFirst, "Bob is dragged again the next turn");
    }

    function test_dragTargetIsNeverKOed() public {
        // Bob's roster is all 1 HP, so Alice's kill move leaves only KO'd benchers behind.
        Mon[] memory aTeam = _mkTeam(4, 1000, 5, 10, killAttack);
        Mon[] memory bTeam = _mkTeam(2, 1, 5, 5, weakAttack);
        _startSingles(aTeam, bTeam, ruleset);
        _singlesLeads(0);

        // Alice KOs Bob's active. The KO'd slot is skipped (Bob picks on his forced-switch turn),
        // and Alice's own drag must not pull a KO'd mon either.
        _singlesTurn(0, 0, 1, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(_active(B0), 0, "the KO'd active stays put for the forced switch");
        assertEq(engine.getMonStateForBattle(battleKey, 0, _active(A0), MonStateIndexName.IsKnockedOut), 0);

        // Bob sends in his last mon on the forced-switch turn (no effects run there).
        engine.executeWithSingleMove(battleKey, SWITCH_MOVE_INDEX, 0, 1);
        assertEq(_active(B0), 1, "Bob's replacement arrives untouched by the field");
    }

    function test_soleSurvivorIsNotDragged() public {
        // A one-mon side has no legal replacement: the drag silently no-ops.
        _startSingles(_mkTeam(1, 1000, 5, 10, weakAttack), _mkTeam(4, 1000, 5, 5, weakAttack), ruleset);
        _singlesLeads(0);
        _singlesTurn(NO_OP_MOVE_INDEX, 0, 1, NO_OP_MOVE_INDEX, 0, 0);

        assertEq(_active(A0), 0, "Alice's only mon stays in");
        assertTrue(_active(B0) != 0, "Bob still gets dragged");
    }

    function test_doublesSlotsDragToDistinctMons() public {
        Mon[] memory team = _mkTeam(4, 1000, 5, 10, weakAttack);
        _startDoubles(team, team, ruleset);
        _slotLeads(1, 0);
        assertEq(_active(A0), 0, "no drags on turn 0");
        assertEq(_active(A1), 1, "no drags on turn 0");

        _restTurn(1);
        assertTrue(_active(A0) != 0 && _active(A1) != 1, "both of side 0's slots were dragged");
        assertTrue(_active(A0) != _active(A1), "the two slots never land on the same mon");
        assertTrue(_active(B0) != _active(B1), "same for side 1");
    }

    function test_multiDragsStayInsideEachSeatsQuarter() public {
        _startMulti(ruleset);
        _slotLeads(4, 0);
        _restTurn(1);

        // Seat 0 owns roster [0..3], seat 1 owns [4..7] on each side.
        assertTrue(_active(A0) < 4, "side 0 slot 0 stays in seat 0's quarter");
        assertTrue(_active(A1) >= 4, "side 0 slot 1 stays in seat 1's quarter");
        assertTrue(_active(B0) < 4, "side 1 slot 0 stays in seat 0's quarter");
        assertTrue(_active(B1) >= 4, "side 1 slot 1 stays in seat 1's quarter");
        assertTrue(_active(A0) != 0 || _active(A1) != 4, "at least one side-0 slot moved");
    }

    function test_regenStillRunsAlongsideTheDrags() public {
        _startFourMonSingles(ruleset);
        _singlesLeads(0);

        // Alice attacks (-1 stamina) and is then dragged out; the round-end regen follows the lane,
        // so it lands on whoever is standing there at the end of the turn.
        _singlesTurn(0, 0, 1, NO_OP_MOVE_INDEX, 0, 0);
        uint256 aNew = _active(A0);
        assertTrue(aNew != 0, "Alice was dragged");
        assertEq(_stamina(0, 0), -1, "the mon that acted keeps its spent stamina");
        assertEq(_stamina(0, aNew), 0, "the incoming mon is at full stamina");
    }
}

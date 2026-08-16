// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../../src/Constants.sol";
import "../../../src/Enums.sol";
import "../../../src/Structs.sol";

import {IRuleset} from "../../../src/IRuleset.sol";
import {IEffect} from "../../../src/effects/IEffect.sol";
import {FluxField} from "../../../src/effects/battlefield/FluxField.sol";

import {FieldHarness} from "./FieldHarness.sol";

/// @notice FluxField: round-end stamina becomes a per-mon [-2, +2] roll; the resting regen stays.
contract FluxFieldTest is FieldHarness {
    // Salts precomputed offline against the engine's rng stream (keccak(p0Salt, p1Salt) then
    // keccak(rng, absSlot) % 100 against the weight table). Side 1 always salts 0.
    uint104 constant SALT_NEUTRAL = 99; // singles: A0 and B0 both roll 0
    uint104 constant SALT_PLUS2_MINUS2 = 5; // singles: A0 +2, B0 -2
    uint104 constant SALT_PLUS1_MINUS1 = 9; // singles: A0 +1, B0 -1
    uint104 constant SALT_DOUBLES_DRAIN = 769; // doubles: slots roll -2, -1, -1, -2

    FluxField field;
    IRuleset ruleset;

    function setUp() public {
        _setUpHarness();
        field = new FluxField();
        ruleset = _ruleset(IEffect(address(field)), INLINE_REST_REGEN_MARKER);
    }

    function _startRestedSingles() internal {
        _startSingles(_mkTeam(2, 1000, 8, 10, weakAttack), _mkTeam(2, 1000, 8, 5, weakAttack), ruleset);
        _singlesLeads(SALT_NEUTRAL);
    }

    function _bothAttack(uint104 salt) internal {
        _singlesTurn(0, 0, salt, 0, 0, 0);
    }

    function test_rollAppliesPerMonAndReplacesRoundEndRegen() public {
        _startRestedSingles();

        // A neutral roll leaves the spent stamina alone: no vanilla +1 round-end regen under flux.
        _bothAttack(SALT_NEUTRAL);
        assertEq(_stamina(0, 0), -1, "attacker keeps the full stamina cost");
        assertEq(_stamina(1, 0), -1, "attacker keeps the full stamina cost");

        _bothAttack(SALT_NEUTRAL);
        assertEq(_stamina(0, 0), -2, "still no round-end regen");

        // Each active rolls independently: A0 gains 2, B0 loses 2, on top of this turn's -1.
        _bothAttack(SALT_PLUS2_MINUS2);
        assertEq(_stamina(0, 0), -1, "A0: -3 spent, +2 flux");
        assertEq(_stamina(1, 0), -5, "B0: -3 spent, -2 flux");
    }

    function test_gainIsClampedAtFullStamina() public {
        // Turn 0 leaves both mons at full stamina, so A0's +1 has nowhere to go and B0's -1 lands.
        _startSingles(_mkTeam(2, 1000, 8, 10, weakAttack), _mkTeam(2, 1000, 8, 5, weakAttack), ruleset);
        _singlesLeads(SALT_PLUS1_MINUS1);

        assertEq(_stamina(0, 0), 0, "a gain never pushes stamina above base");
        assertEq(_stamina(1, 0), -1, "the drain lands normally");
    }

    function test_drainIsClampedAtZeroStamina() public {
        // Bob's mon has a single point of stamina, so one attack empties it.
        _startSingles(_mkTeam(2, 1000, 8, 10, weakAttack), _mkTeam(2, 1000, 1, 5, weakAttack), ruleset);
        _singlesLeads(SALT_NEUTRAL);

        _singlesTurn(NO_OP_MOVE_INDEX, 0, SALT_NEUTRAL, 0, 0, 0);
        assertEq(_stamina(1, 0), -1, "Bob's mon is empty");

        // Bob re-submits the move he can no longer afford (the engine skips it, and a skipped move
        // is not a rest, so no resting regen), then eats a -1 roll that has nowhere to go.
        _singlesTurn(NO_OP_MOVE_INDEX, 0, SALT_PLUS1_MINUS1, 0, 0, 0);
        assertEq(_stamina(1, 0), -1, "a drain never pushes current stamina below zero");
    }

    function test_restingRegenStillApplies() public {
        _startRestedSingles();
        _bothAttack(SALT_NEUTRAL);
        assertEq(_stamina(0, 0), -1, "spent one stamina");

        // Resting is the Engine's inline AfterMove regen, which the field's marker keeps enabled.
        _singlesTurn(NO_OP_MOVE_INDEX, 0, SALT_NEUTRAL, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(_stamina(0, 0), 0, "resting still regenerates one stamina");
    }

    function test_koedActiveIsSkipped() public {
        Mon[] memory aTeam = _mkTeam(2, 1000, 8, 10, killAttack);
        Mon[] memory bTeam = _mkTeam(2, 1, 8, 5, weakAttack);
        _startSingles(aTeam, bTeam, ruleset);
        _singlesLeads(SALT_NEUTRAL);

        // B0 is KO'd this turn, so the -2 roll for its slot must not touch its stamina.
        _bothAttack(SALT_PLUS2_MINUS2);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "B0 is KO'd");
        // Alice outspeeds and KOs before Bob ever moves, so nothing but a flux roll could touch it.
        assertEq(_stamina(1, 0), 0, "the KO'd mon's stamina is untouched");
    }

    function test_doublesRollsEachSlotIndependently() public {
        Mon[] memory team = _mkTeam(2, 1000, 8, 10, weakAttack);
        _startDoubles(team, team, ruleset);
        _slotLeads(1, SALT_DOUBLES_DRAIN);

        // Send-ins cost no stamina, so these deltas are the round-end rolls alone.
        assertEq(_stamina(0, 0), -2, "side 0 slot 0 rolled -2");
        assertEq(_stamina(0, 1), -1, "side 0 slot 1 rolled -1 from its own draw");
        assertEq(_stamina(1, 0), -1, "side 1 slot 0 rolled -1");
        assertEq(_stamina(1, 1), -2, "side 1 slot 1 rolled -2");
    }

    function test_rollDistributionMatchesTheWeightTable() public view {
        // Deterministic tally over a fixed rng window; the table is [15, 20, 20, 25, 20] out of 100.
        uint256[5] memory counts;
        for (uint256 i; i < 1000; ++i) {
            counts[uint256(int256(field.roll(i, 0)) + 2)] += 1;
        }
        assertEq(counts[0], 150, "-2");
        assertEq(counts[1], 203, "-1");
        assertEq(counts[2], 210, "0");
        assertEq(counts[3], 229, "+1");
        assertEq(counts[4], 208, "+2");
    }
}

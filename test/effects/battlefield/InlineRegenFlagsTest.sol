// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../../src/Constants.sol";
import "../../../src/Enums.sol";
import "../../../src/Structs.sol";

import {DefaultRuleset} from "../../../src/DefaultRuleset.sol";
import {IRuleset} from "../../../src/IRuleset.sol";
import {IEffect} from "../../../src/effects/IEffect.sol";
import {Storm} from "../../../src/effects/battlefield/Storm.sol";

import {FieldHarness} from "./FieldHarness.sol";

/// @notice The inline-regen marker plumbing: a ruleset carrying real global effects can opt into
///         either half of the Engine's inline stamina regen, or neither.
contract InlineRegenFlagsTest is FieldHarness {
    Storm storm;

    function setUp() public {
        _setUpHarness();
        storm = new Storm();
    }

    function _rulesetOf(address entry0) internal returns (IRuleset) {
        IEffect[] memory effects = new IEffect[](1);
        effects[0] = IEffect(entry0);
        return new DefaultRuleset(engine, effects);
    }

    function _rulesetOf(address entry0, address entry1) internal returns (IRuleset) {
        IEffect[] memory effects = new IEffect[](2);
        effects[0] = IEffect(entry0);
        effects[1] = IEffect(entry1);
        return new DefaultRuleset(engine, effects);
    }

    /// @dev Turn 0 sends in the leads, turn 1 spends 2 stamina on a move.
    function _startAndSpend(IRuleset ruleset) internal {
        Mon[] memory team = _mkTeam(2, 1000, 8, 10, costlyAttack);
        _startSingles(team, team, ruleset);
        _singlesLeads(0);
        _singlesTurn(0, 0, 1, 0, 0, 0);
    }

    function test_sentinelRulesetKeepsBothRegenHalves() public {
        _startAndSpend(IRuleset(INLINE_STAMINA_REGEN_RULESET));
        assertEq(_stamina(0, 0), -1, "round-end regen refunded one of the two spent");

        _singlesTurn(NO_OP_MOVE_INDEX, 0, 2, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(_stamina(0, 0), 0, "resting regen refunded the other");
    }

    function test_fullMarkerInsideARulesetKeepsRegenAndInstallsTheEffect() public {
        _startAndSpend(_rulesetOf(INLINE_STAMINA_REGEN_RULESET, address(storm)));

        assertEq(_stamina(0, 0), -1, "round-end regen runs alongside a real global effect");
        // Storm's round-end damage proves the effect was installed and that the marker neither
        // consumed its slot nor was called as an effect itself.
        assertLt(engine.getMonStateForBattle(battleKey, 0, 0, MonStateIndexName.Hp), 0, "Storm ticked");
    }

    function test_restOnlyMarkerSuppressesRoundEndRegen() public {
        _startAndSpend(_rulesetOf(INLINE_REST_REGEN_MARKER, address(storm)));
        assertEq(_stamina(0, 0), -2, "no round-end regen under the rest-only marker");

        _singlesTurn(NO_OP_MOVE_INDEX, 0, 2, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(_stamina(0, 0), -1, "resting regen still fires");
    }

    function test_rulesetWithoutAMarkerGetsNoInlineRegen() public {
        _startAndSpend(_rulesetOf(address(storm)));
        assertEq(_stamina(0, 0), -2, "no inline regen at all");

        _singlesTurn(NO_OP_MOVE_INDEX, 0, 2, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(_stamina(0, 0), -2, "not even the resting half");
    }

    /// @dev Recycled config storage must never leak a previous battle's regen flags.
    function test_regenFlagsAreRewrittenPerBattle() public {
        _startAndSpend(IRuleset(INLINE_STAMINA_REGEN_RULESET));
        assertEq(_stamina(0, 0), -1, "full regen in the first battle");

        // Run the first battle to game over so its storage key is freed for reuse.
        _singlesTurn(SWITCH_MOVE_INDEX, 1, 3, SWITCH_MOVE_INDEX, 1, 0);
        Mon[] memory frail = _mkTeam(2, 1, 8, 10, killAttack);
        _startSingles(frail, frail, IRuleset(INLINE_STAMINA_REGEN_RULESET));
        _singlesLeads(0);
        _singlesTurn(0, 0, 1, 0, 0, 0);
        _singlesTurn(SWITCH_MOVE_INDEX, 1, 2, SWITCH_MOVE_INDEX, 1, 0);
        _singlesTurn(0, 0, 3, 0, 0, 0);
        assertTrue(engine.getWinner(battleKey) != address(0), "first battles concluded");

        _startAndSpend(_rulesetOf(address(storm)));
        assertEq(_stamina(0, 0), -2, "a marker-less ruleset starts with no inline regen");
    }
}

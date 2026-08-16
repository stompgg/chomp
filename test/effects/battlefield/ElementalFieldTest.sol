// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../../../src/Constants.sol";
import "../../../src/Enums.sol";
import "../../../src/Structs.sol";

import {IRuleset} from "../../../src/IRuleset.sol";
import {IEffect} from "../../../src/effects/IEffect.sol";
import {ElementalField} from "../../../src/effects/battlefield/ElementalField.sol";
import {BurnStatus} from "../../../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../../../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../../../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../../../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../../../src/effects/status/ZapStatus.sol";

import {FieldHarness} from "./FieldHarness.sol";

/// @notice ElementalField: every status-free live active picks up a random status at round end.
contract ElementalFieldTest is FieldHarness {
    // Status class ids, as folded into each status's getStepsBitmap().
    uint256 constant BURN = 1;
    uint256 constant FROSTBITE = 2;
    uint256 constant SLEEP = 3;
    uint256 constant PANIC = 4;

    // Salts precomputed offline against the engine's rng stream (keccak(p0Salt, p1Salt) then
    // keccak(rng, absSlot) % 5). Side 1 always salts 0.
    uint104 constant SALT_FROSTBITE_PANIC = 10; // singles: slot A0 -> Frostbite, slot B0 -> Panic
    uint104 constant SALT_B0_BURN = 5; // singles: slot B0 -> Burn (slot A0 -> Frostbite)
    uint104 constant SALT_ALL_SLEEP = 26; // doubles: every slot -> Sleep

    ElementalField field;
    BurnStatus burnStatus;
    FrostbiteStatus frostbiteStatus;
    SleepStatus sleepStatus;
    PanicStatus panicStatus;
    ZapStatus zapStatus;
    IRuleset ruleset;

    function setUp() public {
        _setUpHarness();
        burnStatus = new BurnStatus();
        frostbiteStatus = new FrostbiteStatus();
        sleepStatus = new SleepStatus();
        panicStatus = new PanicStatus();
        zapStatus = new ZapStatus();
        field = new ElementalField(burnStatus, frostbiteStatus, sleepStatus, panicStatus, zapStatus);
        ruleset = _ruleset(IEffect(address(field)), INLINE_STAMINA_REGEN_RULESET);
    }

    function _startTwoMonSingles(IRuleset rules) internal {
        _startSingles(_mkTeam(2, 1000, 5, 10, weakAttack), _mkTeam(2, 1000, 5, 5, weakAttack), rules);
    }

    /// @dev A full turn where both sides rest, carrying the salt that decides the round-end rolls.
    function _rollTurn(uint104 salt) internal {
        _singlesTurn(NO_OP_MOVE_INDEX, 0, salt, NO_OP_MOVE_INDEX, 0, 0);
    }

    /// @dev Burn's extraData packs the degree in its low byte.
    function _burnDegree(uint256 side, uint256 monIndex) internal view returns (uint256) {
        (bool exists,, bytes32 data) = engine.getEffectData(battleKey, side, monIndex, address(burnStatus));
        assertTrue(exists, "expected a burn entry");
        return uint256(data) & 0xFF;
    }

    function test_turnZeroArmsTheFieldWithoutStatusing() public {
        _startTwoMonSingles(ruleset);
        _singlesLeads(SALT_FROSTBITE_PANIC);

        assertEq(_statusClass(0, 0), 0, "the leads arrive clean");
        assertEq(_statusClass(1, 0), 0, "the leads arrive clean");
    }

    function test_bothActivesGetTheirRolledStatus() public {
        _startTwoMonSingles(ruleset);
        _singlesLeads(0);
        _rollTurn(SALT_FROSTBITE_PANIC);

        assertEq(_statusClass(0, 0), FROSTBITE, "A0 rolled Frostbite");
        assertEq(_statusClass(1, 0), PANIC, "B0 rolled Panic");
    }

    function test_alreadyStatusedMonIsSkippedAndNotEscalated() public {
        _startTwoMonSingles(ruleset);
        _singlesLeads(0);
        _rollTurn(SALT_B0_BURN);
        assertEq(_statusClass(1, 0), BURN, "B0 rolled Burn");
        assertEq(_burnDegree(1, 0), 1, "a fresh burn is degree 1");

        // The same salt re-rolls Burn for the same slot: skipping the already-statused mon is what
        // keeps it off the Engine's re-apply route, which would otherwise escalate the degree.
        _rollTurn(SALT_B0_BURN);
        assertEq(_burnDegree(1, 0), 1, "a re-rolled Burn never reaches the escalation path");
    }

    function test_blockedRollFizzlesInsteadOfRerolling() public {
        // Every slot rolls Sleep, but only one mon per side may sleep at a time.
        Mon[] memory team = _mkTeam(2, 1000, 5, 10, weakAttack);
        _startDoubles(team, team, ruleset);
        _slotLeads(1, 0);
        _restTurn(SALT_ALL_SLEEP);

        assertEq(_statusClass(0, 0), SLEEP, "side 0 slot 0 sleeps");
        assertEq(_statusClass(0, 1), 0, "side 0 slot 1's roll is blocked and fizzles");
        assertEq(_statusClass(1, 0), SLEEP, "side 1 slot 0 sleeps");
        assertEq(_statusClass(1, 1), 0, "side 1 slot 1's roll is blocked and fizzles");
    }

    function test_koedActiveIsSkipped() public {
        Mon[] memory aTeam = _mkTeam(2, 1000, 5, 10, killAttack);
        Mon[] memory bTeam = _mkTeam(2, 1, 5, 5, weakAttack);
        _startSingles(aTeam, bTeam, ruleset);
        _singlesLeads(0);
        _rollTurn(SALT_FROSTBITE_PANIC);
        assertEq(_statusClass(1, 0), PANIC, "the first roll turn statused B0");

        // Alice KOs Bob's active; the round-end roll must leave the corpse alone.
        _singlesTurn(0, 0, SALT_B0_BURN, NO_OP_MOVE_INDEX, 0, 0);
        assertEq(engine.getMonStateForBattle(battleKey, 1, 0, MonStateIndexName.IsKnockedOut), 1, "B0 is KO'd");
        assertEq(_statusClass(1, 0), PANIC, "KO'd active keeps its old status and gets no new roll");
    }

    function test_forcedSwitchTurnAppliesNothing() public {
        Mon[] memory aTeam = _mkTeam(2, 1000, 5, 10, killAttack);
        Mon[] memory bTeam = _mkTeam(2, 1, 5, 5, weakAttack);
        _startSingles(aTeam, bTeam, ruleset);
        _singlesLeads(0);
        _singlesTurn(0, 0, SALT_B0_BURN, NO_OP_MOVE_INDEX, 0, 0);

        // Bob's replacement arrives on a forced-switch turn, which runs no effects at all.
        engine.executeWithSingleMove(battleKey, SWITCH_MOVE_INDEX, 0, 1);
        assertEq(_active(B0), 1, "Bob switched in mon 1");
        assertEq(_statusClass(1, 1), 0, "no status is applied on a forced-switch turn");
    }

    function test_multiStatusesEverySeatsActive() public {
        _startMulti(ruleset);
        _slotLeads(4, 0);
        _restTurn(SALT_FROSTBITE_PANIC);

        assertTrue(_statusClass(0, 0) != 0, "side 0 slot 0 statused");
        assertTrue(_statusClass(0, 4) != 0, "side 0 slot 1 statused");
        assertTrue(_statusClass(1, 0) != 0, "side 1 slot 0 statused");
        assertTrue(_statusClass(1, 4) != 0, "side 1 slot 1 statused");
    }
}

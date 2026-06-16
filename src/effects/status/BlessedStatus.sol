// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";

import {StatusEffect} from "./StatusEffect.sol";

contract BlessedStatus is StatusEffect {
    // Heal a flat 1/16 of max HP at the end of each turn and another 1/16 on removal.
    int32 public constant HEAL_DENOM = 16;
    // Fixed nominal duration; a 1/3 per-turn early-end (see onRoundStart) makes the effective
    // duration 1-3 turns, mirroring Sleep / Panic.
    uint256 constant DURATION = 3;

    function name() public pure override returns (string memory) {
        return "Blessed";
    }

    // Steps: OnApply, RoundStart, RoundEnd, OnRemove
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x0F;
    }

    // On apply, set the per-mon status flag (one status per mon) and seed the duration counter.
    function onApply(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 data,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) public override returns (bytes32 updatedExtraData, bool removeAfterRun) {
        super.onApply(engine, battleKey, rng, data, targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
        return (bytes32(DURATION), false);
    }

    // At the start of the turn, roll a 1/3 chance to end early (this is what makes the duration 1-3
    // turns). Ending early routes through onRemove, which grants the removal heal.
    function onRoundStart(
        IEngine,
        bytes32,
        uint256 rng,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    ) external pure override returns (bytes32, bool) {
        rng = uint256(keccak256(abi.encode(rng, targetIndex, monIndex)));
        bool endEarly = rng % 3 == 0;
        return (extraData, endEarly);
    }

    // Heal at the end of the turn, then tick the duration down; removing at 1 routes through onRemove.
    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256,
        uint256
    ) external override returns (bytes32, bool removeAfterRun) {
        _heal(engine, battleKey, targetIndex, monIndex);
        uint256 turnsLeft = uint256(extraData);
        if (turnsLeft == 1) {
            return (extraData, true);
        } else {
            return (bytes32(turnsLeft - 1), false);
        }
    }

    // On removal (self-driven via duration/early-end, or external), grant a final heal and clear the
    // status flag.
    function onRemove(
        IEngine engine,
        bytes32 battleKey,
        bytes32 extraData,
        uint256 targetIndex,
        uint256 monIndex,
        uint256 p0ActiveMonIndex,
        uint256 p1ActiveMonIndex
    ) public override {
        _heal(engine, battleKey, targetIndex, monIndex);
        super.onRemove(engine, battleKey, extraData, targetIndex, monIndex, p0ActiveMonIndex, p1ActiveMonIndex);
    }

    // Heal maxHp/HEAL_DENOM, clamped so we never overheal (copy of the ChainExpansion clamp).
    function _heal(IEngine engine, bytes32 battleKey, uint256 targetIndex, uint256 monIndex) internal {
        int32 amtToHeal =
            int32(engine.getMonValueForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp)) / HEAL_DENOM;
        int32 hpDelta = engine.getMonStateForBattle(battleKey, targetIndex, monIndex, MonStateIndexName.Hp);
        // hpDelta is negative when damaged; cap the heal to the damage taken so we can't exceed max HP.
        if (amtToHeal > (-1 * hpDelta)) {
            amtToHeal = -1 * hpDelta;
        }
        if (amtToHeal != 0) {
            engine.updateMonState(targetIndex, monIndex, MonStateIndexName.Hp, amtToHeal);
        }
    }
}

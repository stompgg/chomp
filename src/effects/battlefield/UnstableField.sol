// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, EMPTY_ACTIVE_LANE} from "../../Constants.sol";
import {IEngine} from "../../IEngine.sol";
import {SwitchTargetLib} from "../../lib/SwitchTargetLib.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {BasicEffect} from "../BasicEffect.sol";

/// @notice Battlefield field: at the end of every full turn, every live active is dragged out for a
///         random benched mon. Forced-switch turns run no effect hooks at all, so they are skipped
///         by construction.
contract UnstableField is BasicEffect {
    // Steps: RoundEnd + ALWAYS_APPLIES.
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x0004 | uint32(ALWAYS_APPLIES_BIT);
    }

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256,
        uint256,
        uint256 activesPacked
    ) external override returns (bytes32, bool) {
        // Turn-0 latch, kept in this effect's own extraData (which the Engine persists) so no turn
        // id read is needed: switch-in abilities do not fire on turn 0, so the first round end only
        // arms the field instead of dragging.
        if (extraData == bytes32(0)) {
            return (bytes32(uint256(1)), false);
        }

        uint256 p0KOs = engine.getKOBitmap(battleKey, 0);
        uint256 p1KOs = engine.getKOBitmap(battleKey, 1);

        for (uint256 slot; slot < 4; ++slot) {
            uint256 monIndex = TargetLib.activeAt(activesPacked, slot);
            if (monIndex == EMPTY_ACTIVE_LANE) {
                continue;
            }
            uint256 side = TargetLib.sideOf(slot);
            // A KO'd active already gets a forced-switch turn, where its own player picks.
            if ((((side == 0 ? p0KOs : p1KOs) >> monIndex) & 1) != 0) {
                continue;
            }
            int32 target = SwitchTargetLib.findRandomNonKOed(
                engine,
                battleKey,
                side,
                slot & 1,
                monIndex,
                TargetLib.activeAt(activesPacked, slot ^ 1),
                uint256(keccak256(abi.encode(rng, slot)))
            );
            if (target != -1) {
                uint256 newMonIndex = uint256(uint32(target));
                engine.switchActiveMonForSlot(side, slot & 1, newMonIndex);
                // Track the drag locally: the ally lane read above must see this side's new active,
                // not the mon that just left.
                activesPacked = TargetLib.withLane(activesPacked, slot, newMonIndex);
            }
        }
        return (extraData, false);
    }
}

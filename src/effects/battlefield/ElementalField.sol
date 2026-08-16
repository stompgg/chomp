// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, EMPTY_ACTIVE_LANE} from "../../Constants.sol";
import {IEngine} from "../../IEngine.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {BasicEffect} from "../BasicEffect.sol";
import {IEffect} from "../IEffect.sol";

/// @notice Battlefield field: from turn 1 on, each status-free active picks up a random status at
///         the end of every full turn. Forced-switch turns run no effect hooks at all, so they are
///         skipped by construction.
contract ElementalField is BasicEffect {
    uint256 private constant NUM_STATUSES = 5;

    IEffect private immutable BURN;
    IEffect private immutable FROSTBITE;
    IEffect private immutable SLEEP;
    IEffect private immutable PANIC;
    IEffect private immutable ZAP;

    constructor(
        IEffect _BURN_STATUS,
        IEffect _FROSTBITE_STATUS,
        IEffect _SLEEP_STATUS,
        IEffect _PANIC_STATUS,
        IEffect _ZAP_STATUS
    ) {
        BURN = _BURN_STATUS;
        FROSTBITE = _FROSTBITE_STATUS;
        SLEEP = _SLEEP_STATUS;
        PANIC = _PANIC_STATUS;
        ZAP = _ZAP_STATUS;
    }

    // Steps: RoundEnd + fresh RoundEnd context (status lanes) + ALWAYS_APPLIES.
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x00040004 | uint32(ALWAYS_APPLIES_BIT);
    }

    function _statusAt(uint256 index) internal view returns (IEffect) {
        if (index == 0) {
            return BURN;
        } else if (index == 1) {
            return FROSTBITE;
        } else if (index == 2) {
            return SLEEP;
        } else if (index == 3) {
            return PANIC;
        }
        return ZAP;
    }

    function onRoundEnd(
        IEngine engine,
        bytes32 battleKey,
        uint256 rng,
        bytes32 extraData,
        uint256,
        uint256,
        uint256 hookContext
    ) external override returns (bytes32, bool) {
        // Turn-0 latch, kept in this effect's own extraData (which the Engine persists) so no turn
        // id read is needed: the leads only just arrived, so the first round end arms the field
        // instead of statusing them.
        if (extraData == bytes32(0)) {
            return (bytes32(uint256(1)), false);
        }

        // KO state is not part of the RoundEnd context, and a KO'd active is about to be replaced.
        uint256 p0KOs = engine.getKOBitmap(battleKey, 0);
        uint256 p1KOs = engine.getKOBitmap(battleKey, 1);

        for (uint256 slot; slot < 4; ++slot) {
            uint256 monIndex = TargetLib.activeAt(hookContext, slot);
            if (monIndex == EMPTY_ACTIVE_LANE) {
                continue;
            }
            uint256 side = TargetLib.sideOf(slot);
            if ((((side == 0 ? p0KOs : p1KOs) >> monIndex) & 1) != 0) {
                continue;
            }
            // Statuses are exclusive: skipping an already-statused mon here is what keeps a repeat
            // roll from escalating an existing status via the Engine's re-apply route.
            if (TargetLib.hookStatusClass(hookContext, side, monIndex) != 0) {
                continue;
            }
            IEffect status = _statusAt(uint256(keccak256(abi.encode(rng, slot))) % NUM_STATUSES);
            // Statuses build their own extraData in onApply. A status with an extra apply condition
            // (Sleep's one-sleeper-per-side rule) can reject the roll — the mon then gets nothing.
            engine.addEffect(side, monIndex, status, bytes32(0));
        }
        return (extraData, false);
    }
}

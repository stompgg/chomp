// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {ALWAYS_APPLIES_BIT, EMPTY_ACTIVE_LANE} from "../../Constants.sol";
import {MonStateIndexName} from "../../Enums.sol";
import {IEngine} from "../../IEngine.sol";
import {TargetLib} from "../../lib/TargetLib.sol";
import {BasicEffect} from "../BasicEffect.sol";

/// @notice Battlefield field: replaces round-end stamina regen with a per-mon roll in [-2, +2].
///         Ships with INLINE_REST_REGEN_MARKER, so the Engine still grants the resting (NO_OP)
///         regen and this effect owns round end alone.
contract FluxField is BasicEffect {
    // Cumulative weights out of 100 over [-2, -1, 0, +1, +2] = [15, 20, 20, 25, 20].
    uint256 private constant CUM_MINUS_TWO = 15;
    uint256 private constant CUM_MINUS_ONE = 35;
    uint256 private constant CUM_ZERO = 55;
    uint256 private constant CUM_PLUS_ONE = 80;

    // Steps: RoundEnd + ALWAYS_APPLIES.
    function getStepsBitmap() external pure override returns (uint32) {
        return 0x0004 | uint32(ALWAYS_APPLIES_BIT);
    }

    function roll(uint256 rng, uint256 slot) public pure returns (int32) {
        uint256 h = uint256(keccak256(abi.encode(rng, slot))) % 100;
        if (h < CUM_MINUS_TWO) {
            return -2;
        } else if (h < CUM_MINUS_ONE) {
            return -1;
        } else if (h < CUM_ZERO) {
            return 0;
        } else if (h < CUM_PLUS_ONE) {
            return 1;
        }
        return 2;
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
        uint256 p0KOs = engine.getKOBitmap(battleKey, 0);
        uint256 p1KOs = engine.getKOBitmap(battleKey, 1);

        for (uint256 slot; slot < 4; ++slot) {
            uint256 monIndex = TargetLib.activeAt(activesPacked, slot);
            if (monIndex == EMPTY_ACTIVE_LANE) {
                continue;
            }
            uint256 side = TargetLib.sideOf(slot);
            if ((((side == 0 ? p0KOs : p1KOs) >> monIndex) & 1) != 0) {
                continue;
            }
            int32 amount = roll(rng, slot);
            if (amount == 0) {
                continue;
            }
            _applyFlux(engine, battleKey, side, monIndex, amount);
        }
        return (extraData, false);
    }

    /// @dev Clamped to [0, base stamina]: the ceiling matches vanilla regen (which never pushes the
    ///      delta above zero), the floor matches Panic's drain.
    function _applyFlux(IEngine engine, bytes32 battleKey, uint256 side, uint256 monIndex, int32 amount) internal {
        int32 base = int32(engine.getMonValueForBattle(battleKey, side, monIndex, MonStateIndexName.Stamina));
        int32 delta = engine.getMonStateForBattle(battleKey, side, monIndex, MonStateIndexName.Stamina);
        int32 newDelta = delta + amount;
        if (newDelta > 0) {
            newDelta = 0;
        } else if (newDelta < -base) {
            newDelta = -base;
        }
        if (newDelta != delta) {
            engine.updateMonState(side, monIndex, MonStateIndexName.Stamina, newDelta - delta);
        }
    }
}

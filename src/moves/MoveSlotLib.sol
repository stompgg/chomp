// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {IMoveSet} from "./IMoveSet.sol";

/// @notice Abstracts reading move properties from a raw uint256 move slot.
/// If upper bits are set (rawSlot >> 160 != 0), the slot is packed inline data.
/// Otherwise, the lower 160 bits are an IMoveSet contract address.
library MoveSlotLib {
    function isInline(uint256 raw) internal pure returns (bool) {
        return raw >> 160 != 0;
    }

    function basePower(uint256 raw, bytes32 battleKey) internal view returns (uint32) {
        if (raw >> 160 != 0) {
            return uint32((raw >> 248) & 0xFF);
        }
        // External: try IAttackMove.basePower — not all external moves expose this
        // Callers should handle the external case themselves if they need try/catch
        revert("MoveSlotLib: use try/catch for external basePower");
    }

    function moveClass(uint256 raw, IEngine engine, bytes32 battleKey) internal view returns (MoveClass) {
        if (raw >> 160 != 0) {
            return MoveClass(uint8((raw >> 246) & 0x3));
        }
        return IMoveSet(address(uint160(raw))).moveClass(engine, battleKey);
    }

    function moveType(uint256 raw, IEngine engine, bytes32 battleKey) internal view returns (Type) {
        if (raw >> 160 != 0) {
            return Type(uint8((raw >> 240) & 0xF));
        }
        return IMoveSet(address(uint160(raw))).moveType(engine, battleKey);
    }

    function stamina(uint256 raw, IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        internal
        view
        returns (uint32)
    {
        if (raw >> 160 != 0) {
            return uint32((raw >> 236) & 0xF);
        }
        return IMoveSet(address(uint160(raw))).stamina(engine, battleKey, playerIndex, monIndex);
    }

    function priority(uint256 raw, IEngine engine, bytes32 battleKey, uint256 playerIndex)
        internal
        view
        returns (uint32)
    {
        if (raw >> 160 != 0) {
            return uint32(DEFAULT_PRIORITY + ((raw >> 244) & 0x3));
        }
        return IMoveSet(address(uint160(raw))).priority(engine, battleKey, playerIndex);
    }

    function toIMoveSet(uint256 raw) internal pure returns (IMoveSet) {
        return IMoveSet(address(uint160(raw)));
    }
}

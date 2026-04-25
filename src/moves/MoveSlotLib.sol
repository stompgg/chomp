// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {MoveMeta} from "../Structs.sol";
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

    /// @notice Bundled metadata read for a move slot. For inline slots, all five fields
    ///         come from bit-unpacking the slot itself — pure memory ops. For external slots,
    ///         it's a single IMoveSet.getMeta staticcall instead of the 5-call fan-out
    ///         (moveType / moveClass / priority / stamina + extraDataType).
    /// @dev `basePower` is 0 for non-attack slots — callers that care should still try the
    ///      IAttackMove(addr).basePower(battleKey) shim for legacy custom attacks that haven't
    ///      adopted MoveMeta. For inline slots and StandardAttack-based moves, basePower is
    ///      authoritative here.
    function decodeMeta(uint256 raw, IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        internal
        view
        returns (MoveMeta memory meta)
    {
        if (raw >> 160 != 0) {
            // Inline slot: bit-unpack everything in one function. Same bit positions as the
            // individual getters above — keep them in sync.
            meta.basePower = uint32((raw >> 248) & 0xFF);
            meta.moveClass = MoveClass(uint8((raw >> 246) & 0x3));
            meta.priority = uint32(DEFAULT_PRIORITY + ((raw >> 244) & 0x3));
            meta.moveType = Type(uint8((raw >> 240) & 0xF));
            meta.stamina = uint32((raw >> 236) & 0xF);
            meta.extraDataType = ExtraDataType.None; // inline moves have no target data
            return meta;
        }
        meta = IMoveSet(address(uint160(raw))).getMeta(engine, battleKey, playerIndex, monIndex);
    }
}

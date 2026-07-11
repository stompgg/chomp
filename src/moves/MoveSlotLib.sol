// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import "../Constants.sol";
import "../Enums.sol";
import {IEngine} from "../IEngine.sol";
import {MoveMeta} from "../Structs.sol";
import {IMoveSet} from "./IMoveSet.sol";

/// @notice Abstracts reading move properties from a raw uint256 move slot.
/// Three forms: MOVE_META_TAG set = a deployed IMoveSet address with packed static
/// stamina/priority (0xF nibble = dynamic, staticcall live); untagged with upper bits set =
/// packed inline data; bare address = deployed move without metadata.
library MoveSlotLib {
    function isInline(uint256 raw) internal pure returns (bool) {
        return raw & MOVE_META_TAG == 0 && raw >> 160 != 0;
    }

    /// @notice Pack a deployed move address with its static metadata (0xF = dynamic).
    function packDeployed(address moveAddr, uint256 staminaVal, uint256 priorityVal)
        internal
        pure
        returns (uint256)
    {
        return uint256(uint160(moveAddr)) | MOVE_META_TAG | ((staminaVal & 0xF) << 236) | ((priorityVal & 0xF) << 244);
    }

    function basePower(
        uint256 raw,
        bytes32 /* battleKey */
    )
        internal
        pure
        returns (uint32)
    {
        if (isInline(raw)) {
            return uint32((raw >> 248) & 0xFF);
        }
        // External: try IAttackMove.basePower — not all external moves expose this
        // Callers should handle the external case themselves if they need try/catch
        revert("MoveSlotLib: use try/catch for external basePower");
    }

    function moveClass(uint256 raw, IEngine engine, bytes32 battleKey) internal view returns (MoveClass) {
        if (isInline(raw)) {
            return MoveClass(uint8((raw >> 246) & 0x3));
        }
        return IMoveSet(address(uint160(raw))).moveClass(engine, battleKey);
    }

    function moveType(uint256 raw, IEngine engine, bytes32 battleKey) internal view returns (Type) {
        if (isInline(raw)) {
            return Type(uint8((raw >> 240) & 0xF));
        }
        return IMoveSet(address(uint160(raw))).moveType(engine, battleKey);
    }

    function stamina(uint256 raw, IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        internal
        view
        returns (uint32)
    {
        // Inline and tagged deployed words share the stamina nibble position; only the
        // dynamic sentinel (tagged) falls through to the live call.
        if (raw >> 160 != 0) {
            uint256 s = (raw >> 236) & 0xF;
            if (raw & MOVE_META_TAG == 0 || s != MOVE_META_DYNAMIC) {
                return uint32(s);
            }
        }
        return IMoveSet(address(uint160(raw))).stamina(engine, battleKey, playerIndex, monIndex);
    }

    function priority(uint256 raw, IEngine engine, bytes32 battleKey, uint256 playerIndex)
        internal
        view
        returns (uint32)
    {
        if (raw & MOVE_META_TAG != 0) {
            uint256 p = (raw >> 244) & 0xF;
            if (p != MOVE_META_DYNAMIC) {
                return uint32(p); // tagged words store the ABSOLUTE priority
            }
        } else if (raw >> 160 != 0) {
            return uint32(DEFAULT_PRIORITY + ((raw >> 244) & 0x3)); // inline: 2-bit offset
        }
        return IMoveSet(address(uint160(raw))).priority(engine, battleKey, playerIndex);
    }

    function toIMoveSet(uint256 raw) internal pure returns (IMoveSet) {
        return IMoveSet(address(uint160(raw)));
    }

    /// @notice Bundled metadata read for a move slot. For inline slots, all five fields
    ///         come from bit-unpacking the slot itself — pure memory ops. For external slots,
    ///         it's a single IMoveSet.getMeta staticcall instead of the 5-call fan-out
    ///         (moveType / moveClass / priority / stamina).
    /// @dev `basePower` is 0 for non-attack slots — callers that care should still try the
    ///      IAttackMove(addr).basePower(battleKey) shim for legacy custom attacks that haven't
    ///      adopted MoveMeta. For inline slots and StandardAttack-based moves, basePower is
    ///      authoritative here.
    function decodeMeta(uint256 raw, IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex)
        internal
        view
        returns (MoveMeta memory meta)
    {
        if (isInline(raw)) {
            // Inline slot: bit-unpack everything in one function. Same bit positions as the
            // individual getters above — keep them in sync.
            meta.basePower = uint32((raw >> 248) & 0xFF);
            meta.moveClass = MoveClass(uint8((raw >> 246) & 0x3));
            meta.priority = uint32(DEFAULT_PRIORITY + ((raw >> 244) & 0x3));
            meta.moveType = Type(uint8((raw >> 240) & 0xF));
            meta.stamina = uint32((raw >> 236) & 0xF);
            return meta;
        }
        meta = IMoveSet(address(uint160(raw))).getMeta(engine, battleKey, playerIndex, monIndex);
    }
}

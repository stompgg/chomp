// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {EffectStep} from "../Enums.sol";

/// @title EffectBitmap
/// @notice Library for checking effect step eligibility based on address bitmaps
/// @dev The most significant N bits of an effect's address encode which EffectSteps it runs at,
///      where N is the number of steps defined in the EffectStep enum.
///      This allows gas-efficient checks without external calls to shouldRunAtStep().
///
///      Bitmap encoding (from address MSB):
///        Bit (NUM_EFFECT_STEPS-1) → First EffectStep (step 0)
///        Bit (NUM_EFFECT_STEPS-2) → Second EffectStep (step 1)
///        ...
///        Bit 0 → Last EffectStep (step NUM_EFFECT_STEPS-1)
///
///      The bitmap is stored in the most significant bits of the address. For example,
///      if NUM_EFFECT_STEPS=9 and an effect runs at steps 2 and 7, its bitmap would be
///      0b001000010, and its address would start with 0x21...
///
///      When adding new EffectSteps to the enum, update NUM_EFFECT_STEPS and re-mine
///      addresses for all effects to include the new step bits.
library EffectBitmap {
    /// @notice Number of effect steps in the EffectStep enum
    /// @dev Update this constant when adding new steps to the EffectStep enum
    uint256 internal constant NUM_EFFECT_STEPS = 9;

    /// @notice Number of bits to shift right to extract the bitmap from an address
    /// @dev Address is 160 bits, we want the top NUM_EFFECT_STEPS bits
    uint256 internal constant BITMAP_SHIFT = 160 - NUM_EFFECT_STEPS;

    /// @notice Check if an effect should run at a given step based on its address bitmap
    /// @param effect The effect contract address (with bitmap encoded in MSB)
    /// @param step The EffectStep to check
    /// @return True if the effect should run at this step
    function shouldRunAtStep(address effect, EffectStep step) internal pure returns (bool) {
        // Extract the top NUM_EFFECT_STEPS bits of the address
        uint256 bitmap = uint160(effect) >> BITMAP_SHIFT;

        // Check if the bit corresponding to this step is set
        // EffectStep enum value N maps to bit (NUM_EFFECT_STEPS - 1 - N)
        // So step 0 maps to the highest bit, step (NUM_EFFECT_STEPS-1) maps to bit 0
        uint256 stepBit = 1 << (NUM_EFFECT_STEPS - 1 - uint8(step));

        return (bitmap & stepBit) != 0;
    }

    /// @notice Extract the full bitmap from an effect address
    /// @param effect The effect contract address
    /// @return The bitmap value (NUM_EFFECT_STEPS bits)
    function extractBitmap(address effect) internal pure returns (uint16) {
        return uint16(uint160(effect) >> BITMAP_SHIFT);
    }

    /// @notice Validate that an effect's address bitmap matches expected value
    /// @param effect The effect contract address
    /// @param expectedBitmap The expected bitmap value
    /// @return True if the bitmap matches
    function validateBitmap(address effect, uint16 expectedBitmap) internal pure returns (bool) {
        return extractBitmap(effect) == expectedBitmap;
    }
}

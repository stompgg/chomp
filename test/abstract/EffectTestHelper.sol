// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {EffectStep} from "../../src/Enums.sol";
import {EffectBitmap} from "../../src/lib/EffectBitmap.sol";

/// @title EffectTestHelper
/// @notice Helper for deploying effects at addresses with correct bitmaps in tests
/// @dev Uses vm.etch to place effect bytecode at addresses that have the correct
///      EffectStep bitmap encoded in their most significant bits.
///
///      This is necessary because Engine.sol now uses EffectBitmap.shouldRunAtStep()
///      which reads the bitmap from the effect's address rather than calling the
///      effect's shouldRunAtStep() function.
///
///      Usage:
///        StatBoosts statBoosts = new StatBoosts(engine);
///        statBoosts = StatBoosts(deployWithCorrectBitmap(statBoosts));
abstract contract EffectTestHelper is Test {
    /// @notice Deploy an effect at an address with the correct bitmap based on its shouldRunAtStep
    /// @dev Queries the effect's shouldRunAtStep for all steps, builds the bitmap, and
    ///      copies the bytecode to an address with that bitmap encoded in its MSB.
    /// @param effect The already-deployed effect contract
    /// @return The effect at a new address with correct bitmap (cast to your desired type)
    function deployWithCorrectBitmap(IEffect effect) internal returns (address) {
        uint16 bitmap = _computeBitmapFromEffect(effect);
        return deployWithBitmap(address(effect), bitmap);
    }

    /// @notice Deploy any contract at an address with the specified bitmap
    /// @dev Creates the contract normally, then copies its bytecode to a target address
    ///      that has the correct bitmap encoded in its MSB.
    /// @param deployed The already-deployed contract address
    /// @param bitmap The bitmap the contract should have
    /// @return The new address with correct bitmap (cast to your desired type)
    function deployWithBitmap(address deployed, uint16 bitmap) internal returns (address) {
        // Compute a target address that has the correct bitmap
        address targetAddr = _computeAddressWithBitmap(bitmap, uint256(uint160(deployed)));

        // Copy the bytecode to the target address
        vm.etch(targetAddr, deployed.code);

        return targetAddr;
    }

    /// @notice Compute the bitmap from an effect's shouldRunAtStep function
    /// @param effect The effect to query
    /// @return bitmap The computed bitmap
    function _computeBitmapFromEffect(IEffect effect) internal returns (uint16 bitmap) {
        uint256 numSteps = EffectBitmap.NUM_EFFECT_STEPS;
        for (uint256 i = 0; i < numSteps; i++) {
            if (effect.shouldRunAtStep(EffectStep(i))) {
                // Bit position: MSB is step 0, LSB is step (numSteps-1)
                bitmap |= uint16(1 << (numSteps - 1 - i));
            }
        }
    }

    /// @notice Compute an address that has the specified bitmap in its MSB
    /// @param bitmap The desired bitmap (NUM_EFFECT_STEPS bits)
    /// @param seed A seed value to make the address unique
    /// @return An address with the bitmap encoded in its most significant bits
    function _computeAddressWithBitmap(uint16 bitmap, uint256 seed) internal pure returns (address) {
        // The bitmap is stored in the top NUM_EFFECT_STEPS bits of the address
        // For NUM_EFFECT_STEPS=9, we need to place the 9-bit bitmap in bits 159-151
        // This means: address = (bitmap << 151) | (lower 151 bits)

        uint256 numSteps = EffectBitmap.NUM_EFFECT_STEPS;
        uint256 bitmapShift = 160 - numSteps;

        // Use seed to generate the lower bits, but mask out the top bits
        uint160 lowerBits = uint160(seed) & uint160((1 << bitmapShift) - 1);

        // Place bitmap in the top bits
        uint160 topBits = uint160(bitmap) << bitmapShift;

        return address(topBits | lowerBits);
    }
}

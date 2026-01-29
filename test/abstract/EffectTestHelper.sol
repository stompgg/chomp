// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {EffectBitmap} from "../../src/lib/EffectBitmap.sol";
import {IEngine} from "../../src/IEngine.sol";
import {IEffect} from "../../src/effects/IEffect.sol";

// Effects
import {StaminaRegen} from "../../src/effects/StaminaRegen.sol";
import {StatBoosts} from "../../src/effects/StatBoosts.sol";
import {Overclock} from "../../src/effects/battlefield/Overclock.sol";
import {BurnStatus} from "../../src/effects/status/BurnStatus.sol";
import {FrostbiteStatus} from "../../src/effects/status/FrostbiteStatus.sol";
import {PanicStatus} from "../../src/effects/status/PanicStatus.sol";
import {SleepStatus} from "../../src/effects/status/SleepStatus.sol";
import {ZapStatus} from "../../src/effects/status/ZapStatus.sol";

/// @title EffectTestHelper
/// @notice Helper for deploying effects at addresses with correct bitmaps in tests
/// @dev Uses vm.etch to place effect bytecode at addresses that have the correct
///      EffectStep bitmap encoded in their most significant bits.
///
///      This is necessary because Engine.sol now uses EffectBitmap.shouldRunAtStep()
///      which reads the bitmap from the effect's address rather than calling the
///      effect's shouldRunAtStep() function.
abstract contract EffectTestHelper is Test {
    /// @notice Deploy an effect at an address with the correct bitmap
    /// @dev Creates the effect with `new`, then copies its bytecode to a target address
    ///      that has the correct bitmap encoded in its MSB.
    /// @param effect The effect contract to deploy
    /// @param expectedBitmap The bitmap the effect should have
    /// @return The address of the deployed effect (with correct bitmap)
    function _deployEffectWithBitmap(IEffect effect, uint16 expectedBitmap) internal returns (IEffect) {
        // Compute a target address that has the correct bitmap
        address targetAddr = _computeAddressWithBitmap(expectedBitmap, uint256(uint160(address(effect))));

        // Copy the bytecode to the target address
        vm.etch(targetAddr, address(effect).code);

        return IEffect(targetAddr);
    }

    /// @notice Compute an address that has the specified bitmap in its MSB
    /// @param bitmap The desired bitmap (NUM_EFFECT_STEPS bits)
    /// @param seed A seed value to make the address unique
    /// @return An address with the bitmap encoded in its most significant bits
    function _computeAddressWithBitmap(uint16 bitmap, uint256 seed) internal pure returns (address) {
        // The bitmap is stored in the top NUM_EFFECT_STEPS bits of the address
        // For NUM_EFFECT_STEPS=9, we need to place the 9-bit bitmap in bits 159-151
        // This means: address = (bitmap << 151) | (lower 151 bits)

        // Use seed to generate the lower bits, but mask out the top 9 bits
        uint160 lowerBits = uint160(seed) & ((1 << 151) - 1);

        // Place bitmap in the top 9 bits
        uint160 topBits = uint160(bitmap) << 151;

        return address(topBits | lowerBits);
    }

    // ============ Effect-specific deployment helpers ============

    /// @notice Deploy StaminaRegen with correct bitmap (0x042: RoundEnd, AfterMove)
    function deployStaminaRegen(IEngine engine) internal returns (StaminaRegen) {
        StaminaRegen effect = new StaminaRegen(engine);
        return StaminaRegen(address(_deployEffectWithBitmap(effect, 0x042)));
    }

    /// @notice Deploy StatBoosts with correct bitmap (0x008: OnMonSwitchOut)
    function deployStatBoosts(IEngine engine) internal returns (StatBoosts) {
        StatBoosts effect = new StatBoosts(engine);
        return StatBoosts(address(_deployEffectWithBitmap(effect, 0x008)));
    }

    /// @notice Deploy Overclock with correct bitmap (0x170: OnApply, RoundEnd, OnMonSwitchIn, OnRemove)
    function deployOverclock(IEngine engine, StatBoosts statBoosts) internal returns (Overclock) {
        Overclock effect = new Overclock(engine, statBoosts);
        return Overclock(address(_deployEffectWithBitmap(effect, 0x170)));
    }

    /// @notice Deploy BurnStatus with correct bitmap (0x1E0: OnApply, RoundStart, RoundEnd, OnRemove)
    function deployBurnStatus(IEngine engine, StatBoosts statBoosts) internal returns (BurnStatus) {
        BurnStatus effect = new BurnStatus(engine, statBoosts);
        return BurnStatus(address(_deployEffectWithBitmap(effect, 0x1E0)));
    }

    /// @notice Deploy FrostbiteStatus with correct bitmap (0x160: OnApply, RoundEnd, OnRemove)
    function deployFrostbiteStatus(IEngine engine, StatBoosts statBoosts) internal returns (FrostbiteStatus) {
        FrostbiteStatus effect = new FrostbiteStatus(engine, statBoosts);
        return FrostbiteStatus(address(_deployEffectWithBitmap(effect, 0x160)));
    }

    /// @notice Deploy PanicStatus with correct bitmap (0x1E0: OnApply, RoundStart, RoundEnd, OnRemove)
    function deployPanicStatus(IEngine engine) internal returns (PanicStatus) {
        PanicStatus effect = new PanicStatus(engine);
        return PanicStatus(address(_deployEffectWithBitmap(effect, 0x1E0)));
    }

    /// @notice Deploy SleepStatus with correct bitmap (0x1E0: OnApply, RoundStart, RoundEnd, OnRemove)
    function deploySleepStatus(IEngine engine) internal returns (SleepStatus) {
        SleepStatus effect = new SleepStatus(engine);
        return SleepStatus(address(_deployEffectWithBitmap(effect, 0x1E0)));
    }

    /// @notice Deploy ZapStatus with correct bitmap (0x1E0: OnApply, RoundStart, RoundEnd, OnRemove)
    function deployZapStatus(IEngine engine) internal returns (ZapStatus) {
        ZapStatus effect = new ZapStatus(engine);
        return ZapStatus(address(_deployEffectWithBitmap(effect, 0x1E0)));
    }

    /// @notice Deploy any effect with a custom bitmap
    /// @dev Use this for mon abilities and other effects not covered by specific helpers
    function deployEffectWithCustomBitmap(IEffect effect, uint16 bitmap) internal returns (IEffect) {
        return _deployEffectWithBitmap(effect, bitmap);
    }
}

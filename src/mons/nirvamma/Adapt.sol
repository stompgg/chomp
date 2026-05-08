// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// @inline-ability: singleton-local

import {EffectInstance} from "../../Structs.sol";

import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

/// @dev Source identity: low 160 bits = msg.sender for external dealDamage callers; full packed
///      move slot for the inline-StandardAttack path. Two attackers wielding the same
///      StandardAttack share identity (matches IEffect.onAfterDamage source semantics).
///      extraData stores the latched source in bits 0-254; bit 255 is the stale flag set on
///      switch-out. The 1-bit truncation collides only when an inline source has its high bit
///      set, which corresponds to basePower >= 128 — negligible in practice.
contract Adapt is IAbility, BasicEffect {
    int32 public constant DAMAGE_DENOM = 2;

    uint256 private constant STALE_BIT = uint256(1) << 255;
    uint256 private constant SOURCE_MASK = ~STALE_BIT;

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Adapt";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i = 0; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) {
                return;
            }
        }
        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(STALE_BIT));
    }

    // Steps: OnMonSwitchOut, AfterDamage, PreDamage
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x260;
    }

    function onPreDamage(
        IEngine engine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256 source
    ) external override returns (bytes32, bool) {
        uint256 ed = uint256(extraData);
        if ((ed & STALE_BIT) == 0 && ed == (source & SOURCE_MASK)) {
            int32 running = engine.getPreDamage();
            engine.setPreDamage(running / DAMAGE_DENOM);
        }
        return (extraData, false);
    }

    function onAfterDamage(
        IEngine,
        bytes32,
        uint256,
        bytes32 extraData,
        uint256,
        uint256,
        uint256,
        uint256,
        int32 damage,
        uint256 source
    ) external pure override returns (bytes32, bool) {
        // Latch only on the first damage of the session (stale bit set). No displacement:
        // once a source is latched it sticks until swap-out.
        if (damage > 0 && (uint256(extraData) & STALE_BIT) != 0) {
            return (bytes32(source & SOURCE_MASK), false);
        }
        return (extraData, false);
    }

    function onMonSwitchOut(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256)
        external
        pure
        override
        returns (bytes32, bool)
    {
        return (bytes32(uint256(extraData) | STALE_BIT), false);
    }
}

// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

// @inline-ability: singleton-local

import {IEngine} from "../../IEngine.sol";
import {IAbility} from "../../abilities/IAbility.sol";
import {BasicEffect} from "../../effects/BasicEffect.sol";
import {IEffect} from "../../effects/IEffect.sol";

/// @dev Source identity: low 160 bits = msg.sender for external dealDamage callers; full packed
///      move slot for the inline-StandardAttack path. Two attackers wielding the same
///      StandardAttack share identity (matches IEffect.onAfterDamage source semantics).
///      extraData stores the latched source directly. bytes32(0) = not latched yet — safe because
///      msg.sender / packed move slots always have non-zero low bits in practice.
contract Adaptor is IAbility, BasicEffect {
    int32 public constant DAMAGE_DENOM = 2;

    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "Adaptor";
    }

    function activateOnSwitch(IEngine engine, bytes32, uint256 playerIndex, uint256 monIndex) external {
        engine.addEffectIfNotPresent(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: AfterDamage, PreDamage
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x240;
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
        if (extraData == bytes32(source)) {
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
        if (damage > 0 && extraData == bytes32(0)) {
            return (bytes32(source), false);
        }
        return (extraData, false);
    }
}

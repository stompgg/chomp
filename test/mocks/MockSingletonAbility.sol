// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IEngine} from "../../src/IEngine.sol";
import {IAbility} from "../../src/abilities/IAbility.sol";
import {IEffect} from "../../src/effects/IEffect.sol";
import {BasicEffect} from "../../src/effects/BasicEffect.sol";
import "../../src/Structs.sol";

/// @notice Mock ability that follows the singleton self-register pattern (type 0x01).
/// Registers itself as an effect on switch-in with idempotency check.
/// Tracks call count in extraData for testing.
contract MockSingletonAbility is IAbility, BasicEffect {
    function name() public pure override(IAbility, BasicEffect) returns (string memory) {
        return "MockSingleton";
    }

    function activateOnSwitch(IEngine engine, bytes32 battleKey, uint256 playerIndex, uint256 monIndex) external {
        (EffectInstance[] memory effects,) = engine.getEffects(battleKey, playerIndex, monIndex);
        for (uint256 i; i < effects.length; i++) {
            if (address(effects[i].effect) == address(this)) return;
        }
        engine.addEffect(playerIndex, monIndex, IEffect(address(this)), bytes32(0));
    }

    // Steps: AfterDamage (just to verify hooks run)
    function getStepsBitmap() external pure override returns (uint16) {
        return 0x8040; // ALWAYS_APPLIES | AfterDamage
    }

    function onAfterDamage(IEngine, bytes32, uint256, bytes32 extraData, uint256, uint256, uint256, uint256, int32)
        external
        pure
        override
        returns (bytes32, bool)
    {
        // Increment counter in extraData
        uint256 count = uint256(extraData);
        return (bytes32(count + 1), false);
    }
}
